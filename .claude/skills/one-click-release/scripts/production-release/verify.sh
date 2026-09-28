#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -euo pipefail

STAGE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPTS_DIR=$(cd "${STAGE_DIR}/.." && pwd)
source "${SCRIPTS_DIR}/lib/common.sh"
source "${SCRIPTS_DIR}/lib/report.sh"
source "${SCRIPTS_DIR}/lib/release.sh"
source "${SCRIPTS_DIR}/lib/stage-runner.sh"

STAGE_NAME='production-release'
STAGE_REPORT_TITLE='Production Release Stage Report'
STAGE_REPORT_DIR=release
STAGE_STEPS=(4.1 4.2 4.3 4.4 4.5 4.6 4.7 4.8 4.9)

ocr_step_title() {
  case "$1" in
    4.1) printf '%s' 'Verify stage releases' ;;
    4.2) printf '%s' 'Core production release' ;;
    4.3) printf '%s' 'Production CSV update' ;;
    4.4) printf '%s' 'Merge production CSV PR' ;;
    4.5) printf '%s' 'Wait for bundle snapshot' ;;
    4.6) printf '%s' 'Bundle production release' ;;
    4.7) printf '%s' 'OLM catalog render + index snapshots' ;;
    4.8) printf '%s' 'Index production releases' ;;
    4.9) printf '%s' 'CDN production release' ;;
  esac
}

releases_json() { ocr_oc_get releases -o json 2>/dev/null; }

verify_4_1() {
  ocr_require_konflux || return $?
  local data apps core_app bundle_app app snapshot rp status total=0 succeeded=0
  data=$(releases_json) || return "${OCR_RC_BLOCKED}"
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json) || return "${OCR_RC_BLOCKED}"
  core_app=$(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name|contains("core") and contains($mm)) | .metadata.name' <<<"${apps}" | head -1)
  bundle_app=$(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name|contains("bundle") and contains($mm)) | .metadata.name' <<<"${apps}" | head -1)
  : >"${REPORT_BASE}/.state/stage-release-prerequisites.tsv"
  while IFS= read -r app; do
    [[ -n "${app}" ]] || continue
    ((total += 1))
    snapshot=$(ocr_latest_snapshot "${app}")
    rp=$(jq -r --arg app "${app}" --arg snap "${snapshot}" '
      [.items[] | select(.metadata.labels["appstudio.openshift.io/application"]==$app or (.spec.releasePlan|contains($app|sub("^openshift-pipelines-"; ""))))
       | select(.spec.snapshot==$snap and (.spec.releasePlan|contains("stage")) and ((.spec.releasePlan|contains("cdn"))|not))
       | select(any(.status.conditions[]?; .type=="Released" and .status=="True"))
       | .spec.releasePlan] | sort | last // empty' <<<"${data}")
    status=missing
    if [[ -n "${snapshot}" && -n "${rp}" ]]; then
      status=True
      ((succeeded += 1))
    fi
    printf '%s\t%s\t%s\t%s\n' "${app}" "${rp}" "${snapshot}" "${status}" >>"${REPORT_BASE}/.state/stage-release-prerequisites.tsv"
    if [[ "${app}" == "${core_app}" ]]; then
      printf '%s\n' "${snapshot}" >"${REPORT_BASE}/.state/stage-core-snapshot"
    fi
  done < <(
    printf '%s\n%s\n' "${core_app}" "${bundle_app}"
    jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name|contains("index") and contains($mm)) | .metadata.name' <<<"${apps}" | sort
  )
  STEP_DETAILS="${succeeded}/${total} current core, bundle, and index snapshots have successful stage releases"
  ((total >= 3 && succeeded == total)) || return "${OCR_RC_BLOCKED}"
}

verify_release() {
  local kind=$1 exclude=${2:-} expected_snapshot=${3:-} data count name
  data=$(releases_json) || return "${OCR_RC_BLOCKED}"
  count=$(jq --arg mm "${MM_DASHED}" --arg kind "${kind}" --arg exclude "${exclude}" --arg snapshot "${expected_snapshot}" '
    [.items[] | select(.spec.releasePlan | contains($mm) and contains($kind) and contains("prod"))
      | select($exclude=="" or (.spec.releasePlan | contains($exclude) | not))
      | select($snapshot=="" or .spec.snapshot==$snapshot)
      | select(any(.status.conditions[]?; .type=="Released" and .status=="True"))] | length' <<<"${data}")
  name=$(jq -r --arg mm "${MM_DASHED}" --arg kind "${kind}" --arg exclude "${exclude}" --arg snapshot "${expected_snapshot}" '
    [.items[] | select(.spec.releasePlan | contains($mm) and contains($kind) and contains("prod"))
      | select($exclude=="" or (.spec.releasePlan | contains($exclude) | not))
      | select($snapshot=="" or .spec.snapshot==$snapshot) | sort_by(.metadata.creationTimestamp // "")][-1].metadata.name // empty' <<<"${data}")
  STEP_DETAILS="${kind} production release: ${name:-not found}; expected snapshot=${expected_snapshot:-any}; succeeded=${count}"
  ((count > 0)) || return "${OCR_RC_BLOCKED}"
}

verify_4_2() {
  ocr_require_konflux || return $?
  local stage_snapshot app latest
  if [[ -f "${REPORT_BASE}/.state/stage-core-snapshot" ]]; then stage_snapshot=$(<"${REPORT_BASE}/.state/stage-core-snapshot"); else stage_snapshot=''; fi
  [[ -n "${stage_snapshot}" ]] || {
    STEP_DETAILS='succeeded core stage snapshot not found'
    return "${OCR_RC_BLOCKED}"
  }
  app=$(ocr_oc_get applications.appstudio.redhat.com -o json | jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name|contains("core") and contains($mm)) | .metadata.name' | head -1)
  latest=$(ocr_latest_snapshot "${app}")
  [[ "${latest}" == "${stage_snapshot}" ]] || {
    STEP_DETAILS="verified core snapshot ${stage_snapshot} is no longer current (current ${latest:-missing})"
    return "${OCR_RC_BLOCKED}"
  }
  verify_release core cdn "${stage_snapshot}"
}

verify_4_3() {
  local run run_url prs number url pr_created run_error releases core_snapshot core_release_created
  ocr_workflow_provenance_matches production-csv operator-update-images.yaml production "${RELEASE_BRANCH}" || {
    STEP_DETAILS='no locally recorded production CSV dispatch; staging or unrelated runs are never accepted'
    return "${OCR_RC_BLOCKED}"
  }
  run=$(gh run view --repo openshift-pipelines/operator "${RUN_ID}" --json status,conclusion,createdAt,headBranch,url,event 2>"${REPORT_BASE}/.state/gh-error") || {
    run_error=$(<"${REPORT_BASE}/.state/gh-error")
    ocr_fail_with_error 'unable to verify recorded production CSV workflow run' "${run_error}"
    return $?
  }
  jq -e --arg branch "${RELEASE_BRANCH}" --arg created "${CREATED_AT}" '.event=="workflow_dispatch" and .headBranch==$branch and .createdAt==$created and .status=="completed" and .conclusion=="success"' <<<"${run}" >/dev/null || {
    STEP_DETAILS="recorded production CSV run ${RUN_ID} is not a successful dispatch on ${RELEASE_BRANCH}"
    return "${OCR_RC_BLOCKED}"
  }
  ocr_workflow_log_has_environment "${RUN_ID}" production || {
    STEP_DETAILS="recorded CSV run ${RUN_ID} does not contain verifiable environment=production execution evidence"
    return "${OCR_RC_BLOCKED}"
  }
  run_url=$(jq -r '.url' <<<"${run}")
  if [[ -f "${REPORT_BASE}/.state/stage-core-snapshot" ]]; then core_snapshot=$(<"${REPORT_BASE}/.state/stage-core-snapshot"); else core_snapshot=''; fi
  releases=$(releases_json) || return "${OCR_RC_BLOCKED}"
  core_release_created=$(jq -r --arg snap "${core_snapshot}" '[.items[] | select(.spec.snapshot==$snap and (.spec.releasePlan|contains("core") and contains("prod") and (contains("cdn")|not)))
    | select(any(.status.conditions[]?; .type=="Released" and .status=="True")) | .metadata.creationTimestamp] | sort | last // empty' <<<"${releases}")
  [[ -n "${core_release_created}" && "${CREATED_AT}" > "${core_release_created}" ]] || {
    STEP_DETAILS='recorded production CSV dispatch does not follow the verified core production release'
    return "${OCR_RC_BLOCKED}"
  }
  prs=$(gh pr list --repo openshift-pipelines/operator --head "actions/update/operator-update-images-${RELEASE_BRANCH}" \
    --state all --limit 5 --json number,url,state,mergedAt,createdAt)
  prs=$(jq --arg created "${CREATED_AT}" '[.[] | select(.createdAt >= $created)] | sort_by(.createdAt) | reverse' <<<"${prs}")
  number=$(jq -r '.[0].number // empty' <<<"${prs}")
  url=$(jq -r '.[0].url // empty' <<<"${prs}")
  local pr_state
  pr_state=$(jq -r '.[0].state // empty' <<<"${prs}")
  pr_created=$(jq -r '.[0].createdAt // empty' <<<"${prs}")
  STEP_DETAILS="production workflow=$([[ -n "${run_url}" ]] && echo success || echo missing); CSV PR=${number:-not found} ${pr_state}"
  [[ -n "${run_url}" && -n "${number}" ]] || return "${OCR_RC_BLOCKED}"
  printf '%s\n' "${number}" >"${REPORT_BASE}/.state/production-csv-pr"
  STEP_LINKS="[operator-update-images](${run_url}), operator [#${number}](${url})"
}

verify_4_4() {
  local number pr url diff merge_sha error
  if [[ -f "${REPORT_BASE}/.state/production-csv-pr" ]]; then number=$(<"${REPORT_BASE}/.state/production-csv-pr"); else number=''; fi
  [[ "${number}" =~ ^[0-9]+$ ]] || number=''
  [[ -n "${number}" ]] || {
    STEP_DETAILS='production CSV PR is not merged'
    return "${OCR_RC_BLOCKED}"
  }
  pr=$(gh pr view --repo openshift-pipelines/operator "${number}" --json state,url,mergedAt,mergeCommit 2>"${REPORT_BASE}/.state/gh-error") || {
    error=$(<"${REPORT_BASE}/.state/gh-error")
    ocr_fail_with_error 'unable to verify production CSV PR' "${error}"
    return $?
  }
  jq -e '.state=="MERGED" and .mergedAt!=null' <<<"${pr}" >/dev/null || {
    STEP_DETAILS="production CSV PR #${number} is not merged"
    return "${OCR_RC_BLOCKED}"
  }
  url=$(jq -r '.url' <<<"${pr}")
  merge_sha=$(jq -r '.mergeCommit.oid // empty' <<<"${pr}")
  diff=$(gh pr diff --repo openshift-pipelines/operator "${number}" 2>"${REPORT_BASE}/.state/gh-error") || {
    error=$(<"${REPORT_BASE}/.state/gh-error")
    ocr_fail_with_error 'unable to inspect production CSV PR diff' "${error}"
    return $?
  }
  if grep -Ei '^\+.*image:.*(stage|staging|devel)' <<<"${diff}" >/dev/null; then
    STEP_DETAILS="merged CSV PR #${number} contains non-production registry references"
    return "${OCR_RC_BLOCKED}"
  fi
  STEP_DETAILS="production CSV PR #${number} merged; no staging image additions"
  STEP_LINKS="operator [#${number}](${url})"
  printf '%s\n' "${merge_sha}" >"${REPORT_BASE}/.state/production-csv-merge-sha"
}

verify_4_5() {
  ocr_require_konflux || return $?
  local apps app snapshot rev head created merge_sha ancestry
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json)
  app=$(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name | contains("bundle") and contains($mm)) | .metadata.name' <<<"${apps}" | head -1)
  snapshot=$(ocr_latest_snapshot "${app}")
  [[ -n "${snapshot}" ]] || {
    STEP_DETAILS='production bundle snapshot not found'
    return "${OCR_RC_BLOCKED}"
  }
  rev=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components[0].source.git.revision}')
  created=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.metadata.creationTimestamp}')
  head=$(git ls-remote https://github.com/openshift-pipelines/operator.git "refs/heads/${RELEASE_BRANCH}" | awk '{print $1}')
  STEP_DETAILS="bundle snapshot ${snapshot} ($(ocr_abs_time "${created}")); revision ${rev:0:12}"
  if [[ -f "${REPORT_BASE}/.state/production-csv-merge-sha" ]]; then merge_sha=$(<"${REPORT_BASE}/.state/production-csv-merge-sha"); else merge_sha=''; fi
  [[ -n "${merge_sha}" ]] || {
    STEP_DETAILS+='; production CSV merge provenance missing'
    return "${OCR_RC_BLOCKED}"
  }
  ancestry=$(gh api "repos/openshift-pipelines/operator/compare/${merge_sha}...${rev}" --jq '.status' 2>/dev/null) || return "${OCR_RC_BLOCKED}"
  [[ "${ancestry}" == ahead || "${ancestry}" == identical ]] || {
    STEP_DETAILS+='; snapshot predates production CSV merge'
    return "${OCR_RC_BLOCKED}"
  }
  ocr_operator_revision_is_generated "${rev}" "${head}" || return "${OCR_RC_BLOCKED}"
}

verify_4_6() {
  ocr_require_konflux || return $?
  local apps app snapshot
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json)
  app=$(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name|contains("bundle") and contains($mm)) | .metadata.name' <<<"${apps}" | head -1)
  snapshot=$(ocr_latest_snapshot "${app}")
  [[ -n "${snapshot}" ]] || {
    STEP_DETAILS='latest bundle snapshot not found'
    return "${OCR_RC_BLOCKED}"
  }
  verify_release bundle '' "${snapshot}"
}

verify_4_7() {
  ocr_require_konflux || return $?
  local run run_url apps app snapshot rev head created checked=0 stale=0 old=0 error releases bundle_release_created
  ocr_workflow_provenance_matches production-render render-olm-catalog.yaml production "${RELEASE_BRANCH}" || {
    STEP_DETAILS='no locally recorded production render dispatch; staging or unrelated runs are never accepted'
    return "${OCR_RC_BLOCKED}"
  }
  run=$(gh run view --repo openshift-pipelines/operator "${RUN_ID}" --json status,conclusion,createdAt,headBranch,url,event 2>"${REPORT_BASE}/.state/gh-error") || {
    error=$(<"${REPORT_BASE}/.state/gh-error")
    ocr_fail_with_error 'unable to verify recorded production render run' "${error}"
    return $?
  }
  jq -e --arg branch "${RELEASE_BRANCH}" --arg created "${CREATED_AT}" '.event=="workflow_dispatch" and .headBranch==$branch and .createdAt==$created and .status=="completed" and .conclusion=="success"' <<<"${run}" >/dev/null || {
    STEP_DETAILS="recorded production render run ${RUN_ID} is not successful"
    return "${OCR_RC_BLOCKED}"
  }
  ocr_workflow_log_has_environment "${RUN_ID}" production || {
    STEP_DETAILS="recorded render run ${RUN_ID} does not contain verifiable environment=production execution evidence"
    return "${OCR_RC_BLOCKED}"
  }
  run_url=$(jq -r '.url' <<<"${run}")
  created=$(jq -r '.createdAt' <<<"${run}")
  releases=$(releases_json) || return "${OCR_RC_BLOCKED}"
  bundle_release_created=$(jq -r --arg mm "${MM_DASHED}" '[.items[] | select(.spec.releasePlan|contains($mm) and contains("bundle") and contains("prod"))
    | select(any(.status.conditions[]?; .type=="Released" and .status=="True")) | .metadata.creationTimestamp] | sort | last // empty' <<<"${releases}")
  [[ -n "${bundle_release_created}" && "${created}" > "${bundle_release_created}" ]] || {
    STEP_DETAILS='production render does not follow the successful bundle production release'
    return "${OCR_RC_BLOCKED}"
  }
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json)
  head=$(git ls-remote https://github.com/openshift-pipelines/operator.git "refs/heads/${RELEASE_BRANCH}" | awk '{print $1}')
  : >"${REPORT_BASE}/.state/production-index-snapshots.tsv"
  while IFS= read -r app; do
    snapshot=$(ocr_latest_snapshot "${app}")
    [[ -n "${snapshot}" ]] || continue
    ((checked += 1))
    rev=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components[0].source.git.revision}')
    local snapshot_created
    snapshot_created=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.metadata.creationTimestamp}')
    [[ "${snapshot_created}" > "${created}" ]] || ((old += 1))
    [[ "${rev}" == "${head}" ]] || ((stale += 1))
    printf '%s\t%s\t%s\t%s\t%s\n' "${app}" "${snapshot}" "${rev}" "${snapshot_created}" "$([[ "${rev}" == "${head}" && "${snapshot_created}" > "${created}" ]] && echo CURRENT || echo STALE)" >>"${REPORT_BASE}/.state/production-index-snapshots.tsv"
  done < <(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name | contains("index") and contains($mm)) | .metadata.name' <<<"${apps}" | sort)
  STEP_DETAILS="production render run ${RUN_ID} succeeded; ${checked} index snapshots checked; ${stale} stale; ${old} pre-render"
  STEP_LINKS="[render-olm-catalog](${run_url})"
  ((checked > 0 && stale == 0 && old == 0)) || return "${OCR_RC_BLOCKED}"
}

verify_4_8() {
  ocr_require_konflux || return $?
  local apps releases app snapshot total=0 succeeded=0 status
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json)
  releases=$(releases_json)
  while IFS= read -r app; do
    snapshot=$(ocr_latest_snapshot "${app}")
    [[ -n "${snapshot}" ]] || continue
    ((total += 1))
    status=$(jq -r --arg snap "${snapshot}" 'if any(.items[]; .spec.snapshot==$snap and (.spec.releasePlan|contains("prod")) and
      ((.spec.releasePlan|contains("fbc")) or (.spec.releasePlan|contains("index"))) and
      any(.status.conditions[]?; .type=="Released" and .status=="True")) then "True" else "" end' <<<"${releases}")
    [[ "${status}" == True ]] && ((succeeded += 1))
  done < <(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name | contains("index") and contains($mm)) | .metadata.name' <<<"${apps}" | sort)
  STEP_DETAILS="${succeeded}/${total} index production releases succeeded"
  ((total > 0 && succeeded == total)) || return "${OCR_RC_BLOCKED}"
}

verify_4_9() {
  ocr_require_konflux || return $?
  local snapshot data
  data=$(releases_json) || return "${OCR_RC_BLOCKED}"
  snapshot=$(ocr_latest_successful_release_snapshot "${data}" core prod cdn)
  [[ -n "${snapshot}" ]] || {
    STEP_DETAILS='succeeded core production snapshot not found'
    return "${OCR_RC_BLOCKED}"
  }
  verify_release cdn '' "${snapshot}"
}

ocr_verify_step() {
  case "$1" in
    4.1) verify_4_1 ;; 4.2) verify_4_2 ;; 4.3) verify_4_3 ;; 4.4) verify_4_4 ;;
    4.5) verify_4_5 ;; 4.6) verify_4_6 ;; 4.7) verify_4_7 ;; 4.8) verify_4_8 ;; 4.9) verify_4_9 ;;
  esac
}

ocr_report_stage_details() {
  local file
  file="${REPORT_BASE}/.state/stage-release-prerequisites.tsv"
  if [[ -s "${file}" ]]; then
    printf '\n## Stage Release Prerequisites\n\n| Application | Release Plan | Snapshot | Status |\n|-------------|--------------|----------|--------|\n'
    while IFS=$'\t' read -r app rp snapshot status; do printf '| %s | %s | %s | %s |\n' "${app}" "${rp:-—}" "${snapshot:-—}" "${status}"; done <"${file}"
  fi
  file="${REPORT_BASE}/.state/production-index-snapshots.tsv"
  if [[ -s "${file}" ]]; then
    printf '\n## Production Index Snapshots\n\n| Application | Snapshot | Revision | Created | Status |\n|-------------|----------|----------|---------|--------|\n'
    while IFS=$'\t' read -r app snapshot revision created status; do printf '| %s | %s | %s | %s | %s |\n' "${app}" "${snapshot}" "${revision}" "$(ocr_abs_time "${created}")" "${status}"; done <"${file}"
  fi
}

ocr_verify_stage "${1:-}"
