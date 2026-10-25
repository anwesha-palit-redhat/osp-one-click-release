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
STAGE_STEPS=(4.1 4.2 4.3 4.4 4.5 4.6 4.7 4.8 4.9 4.10 4.11 4.12)

ocr_step_title() {
  case "$1" in
    4.1) printf '%s' 'Verify stage releases' ;;
    4.2) printf '%s' 'Core production release' ;;
    4.3) printf '%s' 'Production CSV update' ;;
    4.4) printf '%s' 'Merge production CSV PR' ;;
    4.5) printf '%s' 'Wait for prod bundle snapshot + bundle-core match' ;;
    4.6) printf '%s' 'Bundle production release' ;;
    4.7) printf '%s' 'OLM catalog render + index snapshots' ;;
    4.8) printf '%s' 'Index production releases' ;;
    4.9) printf '%s' 'CDN production release' ;;
    4.10) printf '%s' 'Verify image published' ;;
    4.11) printf '%s' 'List repos for release tag' ;;
    4.12) printf '%s' 'Push release tags' ;;
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
    # Prefer STAGE_CORE_SNAPSHOT from stage-vars.env for the core app so
    # stray snapshots that overwrite the per-app state file cannot break it.
    snapshot=''
    if [[ "${app}" == "${core_app}" && -f "${REPORT_BASE}/stage-vars.env" ]]; then
      snapshot=$(grep -m1 '^STAGE_CORE_SNAPSHOT=' "${REPORT_BASE}/stage-vars.env" | cut -d= -f2-) || snapshot=''
    fi
    if [[ -z "${snapshot}" && -f "${REPORT_BASE}/.state/stage-${app}-snapshot" ]]; then
      snapshot=$(<"${REPORT_BASE}/.state/stage-${app}-snapshot")
    fi
    if [[ -z "${snapshot}" ]]; then
      snapshot=$(ocr_latest_snapshot "${app}")
    fi
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
  name=$(jq -er --arg mm "${MM_DASHED}" --arg kind "${kind}" --arg exclude "${exclude}" --arg snapshot "${expected_snapshot}" '
    [.items[] | select(.spec.releasePlan | contains($mm) and contains($kind) and contains("prod"))
      | select($exclude=="" or (.spec.releasePlan | contains($exclude) | not))
      | select($snapshot=="" or .spec.snapshot==$snapshot)]
      | sort_by(.metadata.creationTimestamp // "") | .[-1].metadata.name // ""' <<<"${data}") || {
    STEP_DETAILS="unable to select exact ${kind} production release evidence"
    return "${OCR_RC_BLOCKED}"
  }
  STEP_DETAILS="${kind} production release: ${name:-not found}; expected snapshot=${expected_snapshot:-any}; succeeded=${count}"
  ((count > 0)) || return "${OCR_RC_BLOCKED}"
}

verify_4_2() {
  ocr_require_konflux || return $?
  local stage_snapshot user_snapshot
  # Read pinned snapshot from stage-vars.env (written by build step 2.10)
  stage_snapshot=''
  if [[ -f "${REPORT_BASE}/stage-vars.env" ]]; then
    stage_snapshot=$(grep -m1 '^STAGE_CORE_SNAPSHOT=' "${REPORT_BASE}/stage-vars.env" | cut -d= -f2-) || stage_snapshot=''
    [[ -z "${stage_snapshot}" ]] || printf 'Using STAGE_CORE_SNAPSHOT from stage-vars.env: %s\n' "${stage_snapshot}"
  fi
  # Fall back to per-app state file
  if [[ -z "${stage_snapshot}" ]]; then
    local core_app
    core_app=$(ocr_oc_get applications.appstudio.redhat.com -o json 2>/dev/null | jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name|contains("core") and contains($mm)) | .metadata.name' | head -1)
    if [[ -n "${core_app}" && -f "${REPORT_BASE}/.state/stage-${core_app}-snapshot" ]]; then
      stage_snapshot=$(<"${REPORT_BASE}/.state/stage-${core_app}-snapshot")
    fi
  fi
  [[ -n "${stage_snapshot}" ]] || {
    STEP_DETAILS='succeeded core stage snapshot not found'
    return "${OCR_RC_BLOCKED}"
  }
  STEP_DETAILS="stage core snapshot: ${stage_snapshot}"
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
  local core_app
  core_app=$(ocr_oc_get applications.appstudio.redhat.com -o json 2>/dev/null | jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name|contains("core") and contains($mm)) | .metadata.name' | head -1)
  if [[ -n "${core_app}" && -f "${REPORT_BASE}/.state/stage-${core_app}-snapshot" ]]; then core_snapshot=$(<"${REPORT_BASE}/.state/stage-${core_app}-snapshot"); else core_snapshot=''; fi
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
  if ! ocr_diff_has_only_production_images "${diff}"; then
    STEP_DETAILS="merged CSV PR #${number} lacks exact production-registry evidence or contains another registry"
    return "${OCR_RC_BLOCKED}"
  fi
  STEP_DETAILS="production CSV PR #${number} merged; no staging image additions"
  STEP_LINKS="operator [#${number}](${url})"
  printf '%s\n' "${merge_sha}" >"${REPORT_BASE}/.state/production-csv-merge-sha"
}

verify_4_5() {
  ocr_require_konflux || return $?
  local apps app snapshot rev head created merge_sha ancestry bundle_app
  local image_mismatch=''
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json)
  bundle_app=$(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name | contains("bundle") and contains($mm)) | .metadata.name' <<<"${apps}" | head -1)

  # Bundle is rebuilt for production — always use latest to find the post-rebuild snapshot
  snapshot=$(ocr_latest_snapshot "${bundle_app}")
  [[ -n "${snapshot}" ]] || {
    STEP_DETAILS='bundle snapshot not found'
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

  # Verify FBC bundle references the correct core image digest from production
  local core_app core_snapshot core_image
  core_app=$(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name | contains("core") and contains($mm)) | .metadata.name' <<<"${apps}" | head -1)
  if [[ -n "${core_app}" ]]; then
    # Try per-app state file first (written by build stage verify_2_6 / verify_2_10)
    if [[ -f "${REPORT_BASE}/.state/stage-${core_app}-snapshot" ]]; then
      core_snapshot=$(<"${REPORT_BASE}/.state/stage-${core_app}-snapshot")
    fi
    # Fall back to stage-vars.env if available
    if [[ -z "${core_snapshot:-}" && -f "${REPORT_BASE}/stage-vars.env" ]]; then
      core_snapshot=$(grep -m1 '^STAGE_CORE_SNAPSHOT=' "${REPORT_BASE}/stage-vars.env" | cut -d= -f2-) || core_snapshot=''
    fi
    if [[ -n "${core_snapshot:-}" ]]; then
      core_image=$(ocr_snapshot_component_image "${core_snapshot}" 2>/dev/null)
      if [[ -n "${core_image}" ]]; then
        if ! ocr_verify_fbc_references_core_image "${rev}" "${core_image}" "bundle"; then
          image_mismatch+=" bundle"
        fi
      fi
    fi
  fi

  if [[ -n "${image_mismatch}" ]]; then
    STEP_DETAILS+="; ⚠ core image digest mismatch:${image_mismatch}"
  fi

  # Pin the production bundle snapshot for use by verify_4_6/execute_4_6
  printf '%s\n' "${snapshot}" >"${REPORT_BASE}/.state/prod-4.5-${bundle_app}-snapshot"

  # Bundle-core digest comparison for production
  local prod_bundle_snap_file="${REPORT_BASE}/.state/user-prod-bundle-snapshot"
  if [[ -f "${prod_bundle_snap_file}" ]]; then
    local user_prod_snap core_snap compare_out
    user_prod_snap=$(<"${prod_bundle_snap_file}")
    if [[ "${snapshot}" != "${user_prod_snap}" ]]; then
      STEP_DETAILS+="; prod bundle snapshot changed: verified=${user_prod_snap}, current=${snapshot}; re-run execute 4.5 to re-verify"
      return "${OCR_RC_BLOCKED}"
    fi
    # Resolve core snapshot
    if [[ -f "${REPORT_BASE}/stage-vars.env" ]]; then
      core_snap=$(grep -m1 '^STAGE_CORE_SNAPSHOT=' "${REPORT_BASE}/stage-vars.env" | cut -d= -f2-) || core_snap=''
    fi
    if [[ -z "${core_snap:-}" && -n "${core_app:-}" && -f "${REPORT_BASE}/.state/stage-${core_app}-snapshot" ]]; then
      core_snap=$(<"${REPORT_BASE}/.state/stage-${core_app}-snapshot")
    fi
    [[ -n "${core_snap:-}" ]] || {
      STEP_DETAILS+="; core snapshot not found for digest comparison"
      return "${OCR_RC_BLOCKED}"
    }
    printf 'Comparing prod bundle snapshot %s against core snapshot %s\n' "${user_prod_snap}" "${core_snap}"
    compare_out=$(compare_bundle_core_digests "${user_prod_snap}" "${core_snap}" 2>&1) || {
      STEP_DETAILS+="; prod bundle-core digest mismatch; ${compare_out}"
      return "${OCR_RC_BLOCKED}"
    }
    STEP_DETAILS+="; prod bundle-core digests verified (${compare_out})"
  else
    STEP_DETAILS+="; prod bundle snapshot not yet provided — run execute 4.5 to set it"
    return "${OCR_RC_BLOCKED}"
  fi
}

verify_4_6() {
  ocr_require_konflux || return $?
  local apps app snapshot bundle_app
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json)
  bundle_app=$(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name|contains("bundle") and contains($mm)) | .metadata.name' <<<"${apps}" | head -1)

  # Use the production-pinned bundle snapshot (saved by verify_4_5)
  if [[ -f "${REPORT_BASE}/.state/prod-4.5-${bundle_app}-snapshot" ]]; then
    snapshot=$(<"${REPORT_BASE}/.state/prod-4.5-${bundle_app}-snapshot")
  else
    snapshot=$(ocr_latest_snapshot "${bundle_app}")
  fi
  [[ -n "${snapshot}" ]] || {
    STEP_DETAILS='bundle snapshot not found'
    return "${OCR_RC_BLOCKED}"
  }

  # Re-verify: if user pinned a prod bundle snapshot at step 4.5, ensure it still matches
  local prod_bundle_snap_file="${REPORT_BASE}/.state/user-prod-bundle-snapshot"
  if [[ -f "${prod_bundle_snap_file}" ]]; then
    local pinned_snap core_snap compare_out
    pinned_snap=$(<"${prod_bundle_snap_file}")
    if [[ "${snapshot}" != "${pinned_snap}" ]]; then
      STEP_DETAILS="prod bundle snapshot changed since step 4.5: verified=${pinned_snap}, current=${snapshot}; re-run execute 4.5 to re-verify"
      return "${OCR_RC_BLOCKED}"
    fi
    # Re-run full digest comparison as safety net
    if [[ -f "${REPORT_BASE}/stage-vars.env" ]]; then
      core_snap=$(grep -m1 '^STAGE_CORE_SNAPSHOT=' "${REPORT_BASE}/stage-vars.env" | cut -d= -f2-) || core_snap=''
    fi
    if [[ -z "${core_snap:-}" ]]; then
      local core_app
      core_app=$(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name|contains("core") and contains($mm)) | .metadata.name' <<<"${apps}" | head -1)
      if [[ -n "${core_app}" && -f "${REPORT_BASE}/.state/stage-${core_app}-snapshot" ]]; then
        core_snap=$(<"${REPORT_BASE}/.state/stage-${core_app}-snapshot")
      fi
    fi
    if [[ -n "${core_snap:-}" ]]; then
      compare_out=$(compare_bundle_core_digests "${pinned_snap}" "${core_snap}" 2>&1) || {
        STEP_DETAILS="prod bundle-core digest mismatch at step 4.6; ${compare_out}; re-run execute 4.5"
        return "${OCR_RC_BLOCKED}"
      }
    fi
  fi

  verify_release bundle '' "${snapshot}"
}

verify_4_7() {
  ocr_require_konflux || return $?
  local run run_url apps app snapshot rev created checked=0 stale=0 old=0 error releases bundle_release_created
  local state_file number recorded_head recorded_commit_at pr pr_url pr_state head_oid merged_at merge_sha diff ancestry release_stage commit
  if ! ocr_workflow_provenance_matches production-render render-olm-catalog.yaml production "${RELEASE_BRANCH}"; then
    # No recorded render dispatch. Look for a recent successful push-event
    # render-olm-catalog run on the release branch, then check whether
    # current index snapshots post-date it.
    local recent_runs='' render_created=''
    recent_runs=$(gh run list --repo openshift-pipelines/operator --workflow=render-olm-catalog.yaml --limit 10 \
      --json databaseId,status,conclusion,createdAt,headBranch,event 2>/dev/null) || recent_runs='[]'
    local today
    today=$(date -u +'%Y-%m-%d')
    render_created=$(jq -r --arg b "${RELEASE_BRANCH}" --arg today "${today}" '
      [.[] | select(.headBranch==$b and .status=="completed" and .conclusion=="success"
        and (.createdAt | startswith($today)))]
      | sort_by(.createdAt) | last | .createdAt // empty' <<<"${recent_runs}")
    if [[ -n "${render_created}" ]]; then
      # Found a successful push render on the release branch — check if
      # all index snapshots are current and post-date that render.
      local skip_checked=0 skip_stale=0
      apps=$(ocr_oc_get applications.appstudio.redhat.com -o json)
      while IFS= read -r app; do
        snapshot=$(ocr_latest_snapshot "${app}")
        [[ -n "${snapshot}" ]] || continue
        ((skip_checked += 1))
        rev=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components[0].source.git.revision}')
        created=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.metadata.creationTimestamp}')
        if ocr_operator_release_stage_at "${rev}"; then release_stage=production; else release_stage=unknown; fi
        if [[ "${release_stage}" == production && "${created}" > "${render_created}" ]]; then
          printf '%s\n' "${snapshot}" >"${REPORT_BASE}/.state/prod-4.7-${app}-snapshot"
        else
          ((skip_stale += 1))
        fi
      done < <(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name | contains("index") and contains($mm)) | .metadata.name' <<<"${apps}" | sort)
      if ((skip_checked > 0 && skip_stale == 0)); then
        STEP_DETAILS="no render dispatch recorded but ${skip_checked} index snapshots are current (post-date render at ${render_created})"
        return 0
      fi
    fi
    STEP_DETAILS='no locally recorded production render dispatch; staging or unrelated runs are never accepted'
    return "${OCR_RC_BLOCKED}"
  fi
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
  state_file="${REPORT_BASE}/.state/production-catalog-pr"
  [[ -s "${state_file}" ]] || {
    STEP_DETAILS='exact production catalog PR provenance is missing'
    return "${OCR_RC_BLOCKED}"
  }
  IFS='|' read -r number recorded_head recorded_commit_at <"${state_file}"
  [[ "${number}" =~ ^[0-9]+$ && "${recorded_head}" =~ ^[0-9a-f]{40}$ && ("${recorded_commit_at}" == "${created}" || "${recorded_commit_at}" > "${created}") ]] || {
    STEP_DETAILS='recorded production catalog PR provenance is malformed'
    return "${OCR_RC_BLOCKED}"
  }
  pr=$(gh pr view --repo openshift-pipelines/operator "${number}" \
    --json state,url,headRefOid,mergedAt,mergeCommit 2>"${REPORT_BASE}/.state/gh-error") || {
    error=$(<"${REPORT_BASE}/.state/gh-error")
    ocr_fail_with_error 'unable to verify production catalog PR' "${error}"
    return $?
  }
  pr_state=$(jq -r '.state // empty' <<<"${pr}")
  pr_url=$(jq -r '.url // empty' <<<"${pr}")
  head_oid=$(jq -r '.headRefOid // empty' <<<"${pr}")
  merged_at=$(jq -r '.mergedAt // empty' <<<"${pr}")
  merge_sha=$(jq -r '.mergeCommit.oid // empty' <<<"${pr}")
  commit=$(gh api "repos/openshift-pipelines/operator/commits/${recorded_head}" 2>"${REPORT_BASE}/.state/gh-error") || {
    error=$(<"${REPORT_BASE}/.state/gh-error")
    ocr_fail_with_error 'unable to verify production catalog head commit' "${error}"
    return $?
  }
  jq -e --arg date "${recorded_commit_at}" '(.author.login=="openshift-pipelines-bot" or .author.login=="github-actions[bot]" or .author.login=="red-hat-konflux[bot]") and .commit.committer.date==$date' <<<"${commit}" >/dev/null || {
    STEP_DETAILS="recorded production catalog head ${recorded_head} lacks matching post-run bot provenance"
    return "${OCR_RC_BLOCKED}"
  }
  [[ "${pr_state}" == MERGED && "${head_oid}" == "${recorded_head}" && "${merged_at}" > "${created}" && "${merge_sha}" =~ ^[0-9a-f]{40}$ ]] || {
    STEP_DETAILS="production catalog PR #${number} is not a provenance-matching merge after run ${RUN_ID}"
    return "${OCR_RC_BLOCKED}"
  }
  diff=$(gh pr diff --repo openshift-pipelines/operator "${number}" 2>"${REPORT_BASE}/.state/gh-error") || {
    error=$(<"${REPORT_BASE}/.state/gh-error")
    ocr_fail_with_error 'unable to inspect production catalog PR diff' "${error}"
    return $?
  }
  ocr_diff_has_only_production_images "${diff}" || {
    STEP_DETAILS="production catalog PR #${number} lacks exact production-registry evidence or contains another registry"
    return "${OCR_RC_BLOCKED}"
  }
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json)
  : >"${REPORT_BASE}/.state/production-index-snapshots.tsv"
  while IFS= read -r app; do
    # Index is rebuilt for production — always use latest to find the post-rebuild snapshot
    snapshot=$(ocr_latest_snapshot "${app}")
    [[ -n "${snapshot}" ]] || continue
    ((checked += 1))
    rev=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components[0].source.git.revision}')
    local snapshot_created
    snapshot_created=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.metadata.creationTimestamp}')
    ancestry=$(gh api "repos/openshift-pipelines/operator/compare/${merge_sha}...${rev}" --jq '.status' 2>/dev/null) || ancestry=unknown
    if ocr_operator_release_stage_at "${rev}"; then release_stage=production; else release_stage=unknown; fi
    [[ "${snapshot_created}" > "${merged_at}" ]] || ((old += 1))
    [[ ("${ancestry}" == ahead || "${ancestry}" == identical) && "${release_stage}" == production ]] || ((stale += 1))
    local snapshot_status="STALE"
    if [[ ("${ancestry}" == ahead || "${ancestry}" == identical) && "${release_stage}" == production && "${snapshot_created}" > "${merged_at}" ]]; then
      snapshot_status="CURRENT"
      # Pin the production index snapshot for use by verify_4_8/execute_4_8
      printf '%s\n' "${snapshot}" >"${REPORT_BASE}/.state/prod-4.7-${app}-snapshot"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "${app}" "${snapshot}" "${rev}" "${snapshot_created}" "${snapshot_status}" >>"${REPORT_BASE}/.state/production-index-snapshots.tsv"
  done < <(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name | contains("index") and contains($mm)) | .metadata.name' <<<"${apps}" | sort)
  STEP_DETAILS="production render run ${RUN_ID} succeeded; ${checked} index snapshots checked; ${stale} stale; ${old} pre-render"
  STEP_LINKS="[render-olm-catalog](${run_url}), operator [#${number}](${pr_url})"
  ((checked > 0 && stale == 0 && old == 0)) || return "${OCR_RC_BLOCKED}"
}

verify_4_8() {
  ocr_require_konflux || return $?
  local apps releases app snapshot total=0 succeeded=0 status
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json)
  releases=$(releases_json)
  while IFS= read -r app; do
    # Use the production-pinned index snapshot (saved by verify_4_7)
    if [[ -f "${REPORT_BASE}/.state/prod-4.7-${app}-snapshot" ]]; then
      snapshot=$(<"${REPORT_BASE}/.state/prod-4.7-${app}-snapshot")
    else
      snapshot=$(ocr_latest_snapshot "${app}")
    fi
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

verify_4_10() {
  local image="registry.redhat.io/openshift-pipelines/pipelines-operator-bundle:v${VERSION}"
  local state_file="${REPORT_BASE}/.state/published-bundle-image.tsv"
  local inspect digest digest_short created

  if command -v skopeo >/dev/null 2>&1; then
    inspect=$(skopeo inspect --no-creds "docker://${image}" 2>/dev/null) || {
      STEP_DETAILS="image not yet available at ${image}"
      return "${OCR_RC_BLOCKED}"
    }
    digest=$(jq -r '.Digest // empty' <<<"${inspect}")
    created=$(jq -r '.Created // empty' <<<"${inspect}")
    digest_short=${digest:0:19}
    STEP_DETAILS="available; digest ${digest_short}; published $(ocr_abs_time "${created}")"
    printf '%s\t%s\t%s\n' "${image}" "${digest}" "${created}" >"${state_file}"
    STEP_LINKS="[${image}](https://catalog.redhat.com/software/containers/search?q=openshift-pipelines)"
  elif command -v docker >/dev/null 2>&1; then
    docker pull "${image}" >/dev/null 2>&1 || {
      STEP_DETAILS="image not yet available at ${image}"
      return "${OCR_RC_BLOCKED}"
    }
    digest=$(docker inspect --format='{{index .RepoDigests 0}}' "${image}" 2>/dev/null | cut -d@ -f2)
    digest_short=${digest:0:19}
    STEP_DETAILS="available; digest ${digest_short}"
    printf '%s\t%s\t\n' "${image}" "${digest}" >"${state_file}"
    STEP_LINKS="[${image}](https://catalog.redhat.com/software/containers/search?q=openshift-pipelines)"
  else
    STEP_DETAILS="skopeo and docker unavailable; cannot verify published image"
    return "${OCR_RC_SKIPPED}"
  fi
}

verify_4_11() {
  ocr_require_konflux || return $?
  local snapshot components repo rev tag_ref total=0 tagged=0
  local state_file="${REPORT_BASE}/.state/release-tag-repos.tsv"

  # Use the pinned core snapshot
  snapshot=''
  if [[ -f "${REPORT_BASE}/stage-vars.env" ]]; then
    snapshot=$(grep -m1 '^STAGE_CORE_SNAPSHOT=' "${REPORT_BASE}/stage-vars.env" | cut -d= -f2-) || snapshot=''
  fi
  if [[ -z "${snapshot}" ]]; then
    local core_app
    core_app=$(ocr_oc_get applications.appstudio.redhat.com -o json 2>/dev/null | jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name|contains("core") and contains($mm)) | .metadata.name' | head -1)
    if [[ -n "${core_app}" && -f "${REPORT_BASE}/.state/stage-${core_app}-snapshot" ]]; then
      snapshot=$(<"${REPORT_BASE}/.state/stage-${core_app}-snapshot")
    fi
  fi
  [[ -n "${snapshot}" ]] || {
    STEP_DETAILS='core snapshot not found'
    return "${OCR_RC_BLOCKED}"
  }

  components=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components}' 2>/dev/null) || {
    STEP_DETAILS='unable to read snapshot components'
    return "${OCR_RC_BLOCKED}"
  }

  : >"${state_file}"
  while IFS=$'\t' read -r repo rev; do
    [[ -n "${repo}" ]] || continue
    ((total += 1))
    tag_ref=$(git ls-remote "https://github.com/${repo}.git" "refs/tags/${RELEASE_TAG}" 2>/dev/null | awk '{print $1}')
    if [[ -n "${tag_ref}" ]]; then
      printf '%s\t%s\tyes\n' "${repo}" "${rev}" >>"${state_file}"
      ((tagged += 1))
    else
      printf '%s\t%s\tno\n' "${repo}" "${rev}" >>"${state_file}"
    fi
  done < <(python3 -c '
import json, sys
repos = {}
for c in json.load(sys.stdin):
    src = c.get("source", {}).get("git", {})
    url = src.get("url", "").removesuffix(".git")
    repo = url.replace("https://github.com/", "")
    rev = src.get("revision", "")
    if not repo or not rev:
        continue
    repos.setdefault(repo, rev)
for repo, rev in sorted(repos.items()):
    print(f"{repo}\t{rev}")
' <<<"${components}")

  STEP_DETAILS="${tagged}/${total} repos already tagged with ${RELEASE_TAG}"
  # This step always passes — it just lists repos for confirmation
}

verify_4_12() {
  local state_file="${REPORT_BASE}/.state/release-tag-repos.tsv"
  [[ -s "${state_file}" ]] || {
    STEP_DETAILS='repo list not found; run step 4.11 first'
    return "${OCR_RC_BLOCKED}"
  }
  local repo rev tag_exists total=0 tagged=0
  while IFS=$'\t' read -r repo rev tag_exists; do
    [[ -n "${repo}" ]] || continue
    ((total += 1))
    # Re-check live tag status
    local tag_ref
    tag_ref=$(git ls-remote "https://github.com/${repo}.git" "refs/tags/${RELEASE_TAG}" 2>/dev/null | awk '{print $1}')
    [[ -n "${tag_ref}" ]] && ((tagged += 1))
  done <"${state_file}"
  STEP_DETAILS="${tagged}/${total} repos tagged with ${RELEASE_TAG}"
  ((tagged == total)) || return "${OCR_RC_BLOCKED}"
}

ocr_verify_step() {
  case "$1" in
    4.1) verify_4_1 ;; 4.2) verify_4_2 ;; 4.3) verify_4_3 ;; 4.4) verify_4_4 ;;
    4.5) verify_4_5 ;; 4.6) verify_4_6 ;; 4.7) verify_4_7 ;; 4.8) verify_4_8 ;;
    4.9) verify_4_9 ;; 4.10) verify_4_10 ;; 4.11) verify_4_11 ;; 4.12) verify_4_12 ;;
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
  file="${REPORT_BASE}/.state/published-bundle-image.tsv"
  if [[ -s "${file}" ]]; then
    printf '\n## Published Bundle Image\n\n| Image | Digest | Published |\n|-------|--------|----------|\n'
    while IFS=$'\t' read -r image digest created; do
      printf '| %s | %s | %s |\n' "${image}" "${digest}" "$([[ -n "${created}" ]] && ocr_abs_time "${created}" || printf '—')"
    done <"${file}"
  fi
  file="${REPORT_BASE}/.state/release-tag-repos.tsv"
  if [[ -s "${file}" ]]; then
    printf '\n## Release Tag Repos\n\n| Repository | Revision | Tagged |\n|------------|----------|--------|\n'
    while IFS=$'\t' read -r repo rev tag_exists; do
      printf '| %s | %s | %s |\n' "${repo}" "${rev:0:12}" "${tag_exists}"
    done <"${file}"
  fi
}

ocr_verify_stage "${1:-}"
