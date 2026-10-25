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
STAGE_STEPS=(4.1 4.2 4.3 4.4 4.5 4.6 4.7 4.8 4.9 4.10 4.11 4.12)

ocr_describe_action() {
  case "$1" in
    4.1) printf 'Stage releases are prerequisites; repair them in the build stage.\n' ;;
    4.2) printf 'Create the core production Release CR using the succeeded stage core snapshot.\n' ;;
    4.3) printf 'Dispatch operator-update-images with environment=production.\n' ;;
    4.4) printf 'Validate and merge the production CSV PR.\n' ;;
    4.5) printf 'Prompt for prod bundle snapshot, verify digests against core, then trigger a production bundle rebuild.\n' ;;
    4.6) printf 'Create the bundle production Release CR.\n' ;;
    4.7) printf 'Wait for devel renders, dispatch the production catalog render, validate and merge its exact generated PR, then verify or trigger production index snapshots.\n' ;;
    4.8)
      printf 'Create all index production Release CRs.\n'
      printf '\nIndex snapshots to be released:\n'
      local _app _snap
      for _app in "${REPORT_BASE}/.state"/prod-4.7-openshift-pipelines-index-*-snapshot; do
        [[ -f "${_app}" ]] || continue
        _snap=$(<"${_app}")
        _app=$(basename "${_app}" | sed 's/^prod-4\.7-//;s/-snapshot$//')
        printf '  %s  →  %s\n' "${_app}" "${_snap}"
      done
      printf '\n'
      ;;
    4.9) printf 'Create the CDN production Release CR using the succeeded core production snapshot.\n' ;;
    4.10) printf 'Wait for the bundle image to appear on registry.redhat.io after the CDN pipeline completes.\n' ;;
    4.11) printf 'List downstream repos and revisions from the core snapshot for release tagging.\n' ;;
    4.12) printf 'Push v%s tag to each confirmed downstream repo.\n' "${VERSION}" ;;
  esac
}

find_app() {
  local kind=$1
  ocr_oc_get applications.appstudio.redhat.com -o json | jq -r --arg mm "${MM_DASHED}" --arg kind "${kind}" \
    '.items[] | select(.metadata.name | contains($kind) and contains($mm)) | .metadata.name' | head -1
}

find_prod_rp() {
  local app=$1 exclude=${2:-}
  ocr_oc_get releaseplans -o json | jq -r --arg app "${app}" --arg exclude "${exclude}" '
    [.items[] | select(.spec.application==$app and (.metadata.name|contains("prod")))
      | select($exclude=="" or (.metadata.name|contains($exclude)|not))][0].metadata.name // empty'
}

successful_snapshot() {
  local kind=$1 env=$2 exclude=${3:-}
  local data
  data=$(ocr_oc_get releases -o json) || return 1
  ocr_latest_successful_release_snapshot "${data}" "${kind}" "${env}" "${exclude}"
}

existing_release_for_snapshot() {
  local rp=$1 snapshot=$2
  ocr_oc_get releases -o json | jq -r --arg rp "${rp}" --arg snapshot "${snapshot}" '
    [.items[] | select(.spec.releasePlan==$rp and .spec.snapshot==$snapshot)
      | {name:.metadata.name,status:([.status.conditions[]? | select(.type=="Released")][0].status // "Unknown"),
         reason:([.status.conditions[]? | select(.type=="Released")][0].reason // "Unknown"),
         created:(.metadata.creationTimestamp // "")}]
      | sort_by(.created) | .[-1]
      | if . == null then empty else "\(.name)|\(.status)|\(.reason)" end'
}

push_operator_placeholder() {
  local path=$1 message=$2 temp
  temp=$(mktemp -d)
  git clone --depth 1 -b "${RELEASE_BRANCH}" https://github.com/openshift-pipelines/operator.git "${temp}/operator"
  (
    cd "${temp}/operator"
    mkdir -p "$(dirname "${path}")"
    printf 'Forced production rebuild at %s\n' "$(date +"${TZ_FMT}")" >"${path}"
    git config user.name "${GITHUB_USER:-One Click Release Bot}"
    git config user.email "${GITHUB_EMAIL:-one-click-release-bot@redhat.com}"
    git add "${path}"
    git commit -m "${message}"
    git push origin "${RELEASE_BRANCH}"
  )
  rm -rf "${temp}"
}

create_prod_release() {
  local kind=$1 snapshot=${2:-} app rp path existing existing_name existing_status existing_reason
  app=$(find_app "${kind}")
  [[ -n "${app}" ]] || {
    printf '%s app not found.\n' "${kind}" >&2
    return 2
  }
  [[ -n "${snapshot}" ]] || snapshot=$(ocr_latest_snapshot "${app}")
  [[ -n "${snapshot}" ]] || {
    printf 'No snapshot for %s.\n' "${app}" >&2
    return 2
  }
  rp=$(find_prod_rp "${app}" cdn)
  [[ -n "${rp}" ]] || {
    printf 'No production release plan for %s.\n' "${app}" >&2
    return 2
  }
  # Check for any existing release for this snapshot (exact release plan match)
  existing=$(existing_release_for_snapshot "${rp}" "${snapshot}")
  # Also check for releases with the same snapshot under any prod plan for this kind
  # (catches releases created with a slightly different plan name)
  if [[ -z "${existing}" ]]; then
    existing=$(ocr_oc_get releases -o json 2>/dev/null | jq -r --arg mm "${MM_DASHED}" --arg kind "${kind}" --arg snapshot "${snapshot}" '
      [.items[] | select(.spec.snapshot==$snapshot and (.spec.releasePlan | contains($mm) and contains($kind) and contains("prod")))
        | {name:.metadata.name,status:([.status.conditions[]? | select(.type=="Released")][0].status // "Unknown"),
           reason:([.status.conditions[]? | select(.type=="Released")][0].reason // "Unknown"),
           created:(.metadata.creationTimestamp // "")}]
        | sort_by(.created) | .[-1]
        | if . == null then empty else "\(.name)|\(.status)|\(.reason)" end')
  fi
  if [[ -n "${existing}" ]]; then
    existing_name=${existing%%|*}
    existing_status=${existing#*|}
    existing_status=${existing_status%%|*}
    existing_reason=${existing##*|}
    printf 'Release %s already exists for this snapshot (Released=%s, Reason=%s).\n' "${existing_name}" "${existing_status}" "${existing_reason}" >&2
    [[ "${existing_status}" == True ]] && return 0
    if [[ "${existing_status}" == False ]]; then
      if [[ "${existing_reason}" == Failed ]]; then
        printf 'The latest attempt failed; creating the supported retry Release CR.\n' >&2
      else
        printf 'Release %s is still in progress (Reason=%s); skipping duplicate creation.\n' "${existing_name}" "${existing_reason}" >&2
        return 2
      fi
    else
      return 2
    fi
  fi
  path="${REPORT_BASE}/manifest/prod/release-${VERSION}-${kind}-prod.yaml"
  ocr_write_release_manifest "${path}" "${app}" "${rp}" "${snapshot}"
  ocr_create_release_manifest "${path}" || return 2
}

execute_4_1() {
  printf 'No automatic mutation is defined for stage-release prerequisites. Return to build steps 2.3, 2.7, and 2.8.\n' >&2
  return 2
}

execute_4_2() {
  ocr_require_konflux || return 2
  local snapshot app user_snapshot
  # Read pinned snapshot from stage-vars.env (written by build step 2.10)
  snapshot=''
  if [[ -f "${REPORT_BASE}/stage-vars.env" ]]; then
    snapshot=$(grep -m1 '^STAGE_CORE_SNAPSHOT=' "${REPORT_BASE}/stage-vars.env" | cut -d= -f2-) || snapshot=''
  fi
  # Fall back to .state/stage-core-snapshot
  if [[ -z "${snapshot}" && -f "${REPORT_BASE}/.state/stage-core-snapshot" ]]; then
    snapshot=$(<"${REPORT_BASE}/.state/stage-core-snapshot")
  fi
  # Fall back to latest snapshot
  if [[ -z "${snapshot}" ]]; then
    snapshot=$(ocr_latest_snapshot "$(find_app core)")
  fi
  [[ -n "${snapshot}" ]] || {
    printf 'No succeeded core stage snapshot found.\n' >&2
    return 2
  }
  if [[ -n "${1:-}" ]]; then
    user_snapshot=$1
  else
    printf 'Stored stage core snapshot: %s\n' "${snapshot}" >&2
    printf 'Please enter the stage-core-snapshot to proceed with production release: ' >&2
    read -r user_snapshot </dev/tty
  fi
  [[ "${user_snapshot}" == "${snapshot}" ]] || {
    printf 'Snapshot mismatch: user provided '\''%s'\'' but stored stage core snapshot is '\''%s'\''\n' "${user_snapshot}" "${snapshot}" >&2
    return 2
  }
  [[ "$(successful_snapshot core stage cdn)" == "${snapshot}" ]] || {
    printf 'Pinned core snapshot no longer has a successful stage release.\n' >&2
    return 2
  }
  create_prod_release core "${snapshot}"
}

dispatch_or_resume() {
  local key=$1 workflow=$2 environment=$3 branch=$4 pending before dispatched ids run count id created i
  shift 4
  if ocr_workflow_provenance_matches "${key}" "${workflow}" "${environment}" "${branch}"; then return 0; fi
  pending="${REPORT_BASE}/.state/workflow-${key}.pending"
  if [[ ! -f "${pending}" ]]; then
    before=$(gh run list --repo openshift-pipelines/operator --workflow="${workflow}" --limit 30 --json databaseId) || return 2
    ids=$(jq -r 'map(.databaseId|tostring)|join(",")' <<<"${before}")
    dispatched=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    {
      printf 'BASELINE_IDS=%q\n' "${ids}"
      printf 'DISPATCHED_AT=%q\n' "${dispatched}"
    } >"${pending}"
    if ! gh workflow run "${workflow}" --repo openshift-pipelines/operator "$@"; then
      printf 'Workflow dispatch returned an error; retaining the pre-dispatch baseline so retry can recover without redispatching.\n' >&2
      return 2
    fi
  fi
  BASELINE_IDS='' DISPATCHED_AT=''
  # shellcheck disable=SC1090
  source "${pending}"
  for i in {1..10}; do
    run=$(gh run list --repo openshift-pipelines/operator --workflow="${workflow}" --limit 30 \
      --json databaseId,event,headBranch,createdAt,url) || return 2
    run=$(jq --arg baseline ",${BASELINE_IDS}," --arg branch "${branch}" --arg at "${DISPATCHED_AT}" '
      [.[] | select(.event=="workflow_dispatch" and .headBranch==$branch and .createdAt >= $at)
       | select(($baseline|contains(","+(.databaseId|tostring)+","))|not)]' <<<"${run}")
    count=$(jq length <<<"${run}")
    if ((count == 1)); then break; fi
    if ((count > 1)); then
      printf 'Multiple new %s runs make dispatch provenance ambiguous; refusing to guess.\n' "${workflow}" >&2
      return 2
    fi
    sleep 1
  done
  ((count == 1)) || {
    printf 'No unambiguous %s run is visible after the retained dispatch baseline; retry will not redispatch. If GitHub confirms the request was rejected and no post-baseline run exists, remove %s only after explicit approval.\n' "${workflow}" "${pending}" >&2
    return 2
  }
  id=$(jq -r '.[0].databaseId' <<<"${run}")
  created=$(jq -r '.[0].createdAt' <<<"${run}")
  ocr_record_workflow_run "${key}" "${workflow}" "${environment}" "${branch}" "${id}" "${created}"
  rm -f "${pending}"
  ocr_load_workflow_run "${key}"
}

execute_4_3() {
  local run status conclusion
  dispatch_or_resume production-csv operator-update-images.yaml production "${RELEASE_BRANCH}" \
    --ref "${RELEASE_BRANCH}" -f environment=production || return 2
  run=$(gh run view --repo openshift-pipelines/operator "${RUN_ID}" --json status,conclusion) || return 2
  status=$(jq -r '.status' <<<"${run}")
  conclusion=$(jq -r '.conclusion // ""' <<<"${run}")
  if [[ "${status}" != completed ]]; then
    gh run watch --repo openshift-pipelines/operator "${RUN_ID}" || return 2
    run=$(gh run view --repo openshift-pipelines/operator "${RUN_ID}" --json status,conclusion) || return 2
    conclusion=$(jq -r '.conclusion // ""' <<<"${run}")
  fi
  ocr_workflow_succeeded "${conclusion}" || {
    rm -f "$(ocr_workflow_state_file production-csv)"
    printf 'Production CSV workflow did not succeed (conclusion=%s); provenance cleared for an explicit retry.\n' "${conclusion:-missing}" >&2
    return 2
  }
}

pr_ready() {
  local data
  data=$(gh pr view "$1" --json mergeable,mergeStateStatus,statusCheckRollup)
  jq -e '.mergeable!="CONFLICTING" and .mergeStateStatus!="DIRTY" and
    ([.statusCheckRollup[]? | select((.status//"")!="COMPLETED")] | length)==0 and
    ([.statusCheckRollup[]? | select((.conclusion//"")!="" and ((.conclusion|IN("SUCCESS","NEUTRAL","SKIPPED"))|not))] | length)==0' \
    <<<"${data}" >/dev/null
}

execute_4_4() {
  local number pr url diff
  if [[ -f "${REPORT_BASE}/.state/production-csv-pr" ]]; then number=$(<"${REPORT_BASE}/.state/production-csv-pr"); else number=''; fi
  [[ "${number}" =~ ^[0-9]+$ ]] || {
    printf 'Exact production CSV PR provenance is missing.\n' >&2
    return 2
  }
  pr=$(gh pr view --repo openshift-pipelines/operator "${number}" --json state,url) || return 2
  url=$(jq -r '.url // empty' <<<"${pr}")
  [[ "$(jq -r '.state // empty' <<<"${pr}")" == OPEN && -n "${url}" ]] || {
    printf 'Recorded production CSV PR #%s is not open.\n' "${number}" >&2
    return 2
  }
  diff=$(gh pr diff "${url}")
  if ! ocr_diff_has_only_production_images "${diff}"; then
    printf 'Production CSV PR lacks exact registry.redhat.io/openshift-pipelines image evidence or contains another registry; refusing to merge.\n' >&2
    return 2
  fi
  pr_ready "${url}" || {
    printf 'Production CSV PR is not green and mergeable.\n' >&2
    return 2
  }
  gh pr edit "${url}" --add-label lgtm,approved,one-click-release
  gh pr review --approve "${url}"
  gh pr merge "${url}" -d -r --auto
}

execute_4_5() {
  ocr_require_konflux || return 2
  local bundle_snapshot
  printf 'Enter the production bundle snapshot name to verify against the core snapshot:\n'
  printf '(e.g. openshift-pipelines-bundle-%s-YYYYMMDD-HHMMSS-000)\n' "${MM_DASHED}"
  read -rp '> ' bundle_snapshot
  if [[ -n "${bundle_snapshot}" ]]; then
    # Validate the snapshot exists in Konflux
    ocr_oc_get snapshot "${bundle_snapshot}" -o jsonpath='{.metadata.name}' >/dev/null 2>&1 || {
      printf 'Snapshot %s not found in Konflux.\n' "${bundle_snapshot}" >&2
      return 2
    }
    printf '%s\n' "${bundle_snapshot}" >"${REPORT_BASE}/.state/user-prod-bundle-snapshot"
    printf 'Production bundle snapshot pinned: %s\n' "${bundle_snapshot}"
  else
    printf 'No bundle snapshot provided; triggering rebuild.\n'
  fi
  push_operator_placeholder .konflux/olm-catalog/bundle/.placeholder 'One Click Release: rebuild bundle for production'
}

execute_4_6() {
  ocr_require_konflux || return 2
  local core bundle_snapshot bundle_app
  core=$(successful_snapshot core prod cdn)
  [[ -n "${core}" ]] || {
    printf 'Core production release has not succeeded.\n' >&2
    return 2
  }
  bundle_app=$(find_app bundle)
  # Use the pinned production bundle snapshot (from verify_4_5)
  if [[ -f "${REPORT_BASE}/.state/prod-4.5-${bundle_app}-snapshot" ]]; then
    bundle_snapshot=$(<"${REPORT_BASE}/.state/prod-4.5-${bundle_app}-snapshot")
  else
    bundle_snapshot=$(ocr_latest_snapshot "${bundle_app}")
  fi
  create_prod_release bundle "${bundle_snapshot}"
}

wait_in_progress() {
  local id ids
  ids=$(gh run list --repo openshift-pipelines/operator --workflow=render-olm-catalog.yaml --limit 5 \
    --json databaseId,status --jq '.[] | select(.status=="in_progress" or .status=="queued") | .databaseId') || return 2
  while IFS= read -r id; do [[ -n "${id}" ]] && gh run watch --repo openshift-pipelines/operator "${id}"; done <<<"${ids}"
}

execute_4_7() {
  ocr_require_konflux || return 2
  local apps app snapshot rev snapshot_created stale=false found=0 run status conclusion
  local state_file number recorded_head recorded_commit_at pr url diff pr_state head_oid merged_at merge_sha ancestry release_stage stage_rc commit
  state_file="${REPORT_BASE}/.state/production-catalog-pr"

  # If the index rebuild placeholder was already pushed, skip the render/PR
  # workflow and go straight to checking whether index snapshots have caught up.
  if ocr_mutation_done production-index-placeholder && [[ -s "${state_file}" ]]; then
    IFS='|' read -r number recorded_head recorded_commit_at <"${state_file}"
    pr=$(gh pr view --repo openshift-pipelines/operator "${number}" \
      --json state,mergedAt,mergeCommit) || return 2
    merged_at=$(jq -r '.mergedAt // empty' <<<"${pr}")
    merge_sha=$(jq -r '.mergeCommit.oid // empty' <<<"${pr}")
    if [[ -n "${merged_at}" && -n "${merge_sha}" ]]; then
      # Jump to the index snapshot check below
      apps=$(ocr_oc_get applications.appstudio.redhat.com -o json)
      while IFS= read -r app; do
        snapshot=$(ocr_latest_snapshot "${app}")
        [[ -n "${snapshot}" ]] || { stale=true; continue; }
        ((found += 1))
        rev=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components[0].source.git.revision}')
        snapshot_created=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.metadata.creationTimestamp}')
        ancestry=$(gh api "repos/openshift-pipelines/operator/compare/${merge_sha}...${rev}" --jq '.status' 2>/dev/null) || ancestry=unknown
        if ocr_operator_release_stage_at "${rev}"; then release_stage=production; else release_stage=unknown; fi
        [[ ("${ancestry}" == ahead || "${ancestry}" == identical) && "${release_stage}" == production && "${snapshot_created}" > "${merged_at}" ]] || stale=true
      done < <(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name|contains("index") and contains($mm)) | .metadata.name' <<<"${apps}")
      ((found > 0)) || stale=true
      if [[ "${stale}" == true ]]; then
        printf 'Production index rebuild was already pushed; waiting for current push snapshots to appear.\n'
        printf 'Re-run this step once the index builds complete in Konflux.\n'
        return 2
      fi
      return 0
    fi
  fi

  if ! ocr_workflow_provenance_matches production-render render-olm-catalog.yaml production "${RELEASE_BRANCH}"; then
    rm -f "${state_file}"
  fi
  wait_in_progress || return 2
  dispatch_or_resume production-render render-olm-catalog.yaml production "${RELEASE_BRANCH}" \
    --ref "${RELEASE_BRANCH}" -f "branch=${RELEASE_BRANCH}" -f environment=production || return 2
  run=$(gh run view --repo openshift-pipelines/operator "${RUN_ID}" --json status,conclusion) || return 2
  status=$(jq -r '.status' <<<"${run}")
  conclusion=$(jq -r '.conclusion // ""' <<<"${run}")
  if [[ "${status}" != completed ]]; then
    gh run watch --repo openshift-pipelines/operator "${RUN_ID}" || return 2
    run=$(gh run view --repo openshift-pipelines/operator "${RUN_ID}" --json status,conclusion) || return 2
    conclusion=$(jq -r '.conclusion // ""' <<<"${run}")
  fi
  if ! ocr_workflow_succeeded "${conclusion}"; then
    rm -f "$(ocr_workflow_state_file production-render)"
    rm -f "${state_file}"
    printf 'Production render workflow did not succeed (conclusion=%s); provenance cleared for an explicit retry.\n' "${conclusion:-missing}" >&2
    return 2
  fi
  if [[ -s "${state_file}" ]]; then
    IFS='|' read -r number recorded_head recorded_commit_at <"${state_file}"
  else
    pr=$(gh pr list --repo openshift-pipelines/operator \
      --head "actions/update/operator-update-catalog-${RELEASE_BRANCH}" --state all --limit 5 \
      --json number,url,state,headRefOid,updatedAt) || return 2
    pr=$(jq 'sort_by(.updatedAt) | last // empty' <<<"${pr}")
    number=$(jq -r '.number // empty' <<<"${pr}")
    recorded_head=$(jq -r '.headRefOid // empty' <<<"${pr}")
    if [[ -z "${number}" || -z "${recorded_head}" ]]; then
      # Render workflow succeeded but produced no catalog PR (no changes needed).
      # The catalog was likely already rendered by a prior step. Ask the user to
      # confirm that push builds are ready before proceeding to index snapshot checks.
      printf '\nRender workflow completed with no changes (no catalog PR created).\n' >&2
      printf 'This typically means the catalog was already rendered by a prior merge.\n\n' >&2
      printf 'Current latest push index snapshots:\n' >&2
      local idx_app idx_snap idx_created
      apps=$(ocr_oc_get applications.appstudio.redhat.com -o json)
      while IFS= read -r idx_app; do
        idx_snap=$(ocr_latest_snapshot "${idx_app}")
        if [[ -n "${idx_snap}" ]]; then
          idx_created=$(ocr_oc_get snapshot "${idx_snap}" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
          printf '  %s  →  %s  (%s)\n' "${idx_app}" "${idx_snap}" "$(ocr_abs_time "${idx_created}")" >&2
        else
          printf '  %s  →  (no push snapshot found)\n' "${idx_app}" >&2
        fi
      done < <(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name|contains("index") and contains($mm)) | .metadata.name' <<<"${apps}" | sort)
      printf '\nAre the on-push index builds ready? Type "yes" to proceed to snapshot check: ' >&2
      local user_confirm
      read -r user_confirm
      if [[ "${user_confirm}" != "yes" ]]; then
        printf 'Aborting; re-run when index builds are complete.\n' >&2
        return 2
      fi
      # Use the production CSV merge SHA as the reference point for snapshot checks
      if [[ -f "${REPORT_BASE}/.state/production-csv-merge-sha" ]]; then
        merge_sha=$(<"${REPORT_BASE}/.state/production-csv-merge-sha")
        merged_at=$(gh api "repos/openshift-pipelines/operator/commits/${merge_sha}" --jq '.commit.committer.date' 2>/dev/null) || merged_at=''
      fi
      [[ -n "${merge_sha}" && -n "${merged_at}" ]] || {
        printf 'Cannot determine production CSV merge provenance for snapshot validation.\n' >&2
        return 2
      }
      # Skip the PR validation and jump straight to index snapshot checks
      apps=$(ocr_oc_get applications.appstudio.redhat.com -o json)
      while IFS= read -r app; do
        snapshot=$(ocr_latest_snapshot "${app}")
        [[ -n "${snapshot}" ]] || { stale=true; continue; }
        ((found += 1))
        rev=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components[0].source.git.revision}')
        snapshot_created=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.metadata.creationTimestamp}')
        ancestry=$(gh api "repos/openshift-pipelines/operator/compare/${merge_sha}...${rev}" --jq '.status' 2>/dev/null) || ancestry=unknown
        if ocr_operator_release_stage_at "${rev}"; then release_stage=production; else release_stage=unknown; fi
        [[ ("${ancestry}" == ahead || "${ancestry}" == identical) && "${release_stage}" == production && "${snapshot_created}" > "${merged_at}" ]] || stale=true
      done < <(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name|contains("index") and contains($mm)) | .metadata.name' <<<"${apps}")
      ((found > 0)) || stale=true
      if [[ "${stale}" == true ]]; then
        if ocr_mutation_done production-index-placeholder; then
          printf 'Production index rebuild was already pushed; waiting for current push snapshots to appear.\n'
          printf 'Re-run this step once the index builds complete in Konflux.\n'
        else
          push_operator_placeholder .konflux/olm-catalog/index/.placeholder 'One Click Release: rebuild index images for production'
          ocr_mark_mutation production-index-placeholder
        fi
        return 2
      fi
      return 0
    fi
    commit=$(gh api "repos/openshift-pipelines/operator/commits/${recorded_head}" 2>/dev/null) || return 2
    recorded_commit_at=$(jq -r '.commit.committer.date // empty' <<<"${commit}")
    jq -e '.author.login=="openshift-pipelines-bot" or .author.login=="github-actions[bot]" or .author.login=="red-hat-konflux[bot]"' <<<"${commit}" >/dev/null || return 2
    [[ "${number}" =~ ^[0-9]+$ && "${recorded_head}" =~ ^[0-9a-f]{40}$ && ("${recorded_commit_at}" == "${CREATED_AT}" || "${recorded_commit_at}" > "${CREATED_AT}") ]] || {
      printf 'Production catalog PR was not found after the recorded workflow run.\n' >&2
      return 2
    }
    printf '%s|%s|%s\n' "${number}" "${recorded_head}" "${recorded_commit_at}" >"${state_file}"
  fi
  pr=$(gh pr view --repo openshift-pipelines/operator "${number}" \
    --json state,url,headRefOid,mergedAt,mergeCommit) || return 2
  url=$(jq -r '.url // empty' <<<"${pr}")
  pr_state=$(jq -r '.state // empty' <<<"${pr}")
  head_oid=$(jq -r '.headRefOid // empty' <<<"${pr}")
  [[ "${head_oid}" == "${recorded_head}" ]] || {
    printf 'Production catalog PR head changed after provenance was recorded; refusing to guess.\n' >&2
    return 2
  }
  commit=$(gh api "repos/openshift-pipelines/operator/commits/${recorded_head}" 2>/dev/null) || return 2
  jq -e --arg date "${recorded_commit_at}" '(.author.login=="openshift-pipelines-bot" or .author.login=="github-actions[bot]" or .author.login=="red-hat-konflux[bot]") and .commit.committer.date==$date' <<<"${commit}" >/dev/null || {
    printf 'Recorded catalog head lacks matching post-run bot provenance.\n' >&2
    return 2
  }
  diff=$(gh pr diff --repo openshift-pipelines/operator "${number}") || return 2
  ocr_diff_has_only_production_images "${diff}" || {
    printf 'Catalog PR lacks exact production-registry evidence or contains another registry.\n' >&2
    return 2
  }
  if [[ "${pr_state}" != MERGED ]]; then
    [[ "${pr_state}" == OPEN ]] || {
      printf 'Recorded production catalog PR is neither open nor merged.\n' >&2
      return 2
    }
    pr_ready "${url}" || {
      printf 'Production catalog PR is not green and mergeable.\n' >&2
      return 2
    }
    gh pr edit "${url}" --add-label lgtm,approved,one-click-release
    gh pr review --approve "${url}"
    gh pr merge "${url}" -d -r --auto
    printf 'Production catalog PR merge requested; re-run after it merges and index snapshots propagate.\n' >&2
    return 2
  fi
  merged_at=$(jq -r '.mergedAt // empty' <<<"${pr}")
  merge_sha=$(jq -r '.mergeCommit.oid // empty' <<<"${pr}")
  [[ -n "${merged_at}" && "${merged_at}" > "${CREATED_AT}" && "${merge_sha}" =~ ^[0-9a-f]{40}$ ]] || {
    printf 'Merged catalog PR does not follow the recorded production workflow.\n' >&2
    return 2
  }
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json)
  while IFS= read -r app; do
    snapshot=$(ocr_latest_snapshot "${app}")
    if [[ -z "${snapshot}" ]]; then
      stale=true
      continue
    fi
    ((found += 1))
    rev=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components[0].source.git.revision}')
    snapshot_created=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.metadata.creationTimestamp}')
    ancestry=$(gh api "repos/openshift-pipelines/operator/compare/${merge_sha}...${rev}" --jq '.status' 2>/dev/null) || {
      printf 'Unable to prove index snapshot ancestry; refusing a placeholder mutation.\n' >&2
      return 2
    }
    if ocr_operator_release_stage_at "${rev}"; then
      release_stage=production
    else
      stage_rc=$?
      if ((stage_rc == 1)); then
        release_stage=nonproduction
      else
        printf 'Unable to query catalog state at snapshot revision %s; refusing a placeholder mutation.\n' "${rev}" >&2
        return 2
      fi
    fi
    [[ ("${ancestry}" == ahead || "${ancestry}" == identical) && "${release_stage}" == production && "${snapshot_created}" > "${merged_at}" ]] || stale=true
  done < <(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name|contains("index") and contains($mm)) | .metadata.name' <<<"${apps}")
  ((found > 0)) || stale=true
  if [[ "${stale}" == true ]]; then
    if ocr_mutation_done production-index-placeholder; then
      printf 'Production index rebuild was already pushed; waiting for current push snapshots to appear.\n'
      printf 'Re-run this step once the index builds complete in Konflux.\n'
    else
      push_operator_placeholder .konflux/olm-catalog/index/.placeholder 'One Click Release: rebuild index images for production'
      ocr_mark_mutation production-index-placeholder
    fi
    return 2
  fi
}

create_index_prod_release() {
  local app=$1 snapshot rp ocp path existing existing_name existing_status existing_reason
  if [[ -f "${REPORT_BASE}/.state/prod-4.7-${app}-snapshot" ]]; then
    snapshot=$(<"${REPORT_BASE}/.state/prod-4.7-${app}-snapshot")
  else
    snapshot=$(ocr_latest_snapshot "${app}")
  fi
  [[ -n "${snapshot}" ]] || { printf 'No snapshot for %s; skipping.\n' "${app}"; return 0; }
  rp=$(find_prod_rp "${app}")
  [[ -n "${rp}" ]] || {
    printf 'No production release plan for %s.\n' "${app}" >&2
    return 2
  }
  existing=$(existing_release_for_snapshot "${rp}" "${snapshot}")
  if [[ -n "${existing}" ]]; then
    existing_name=${existing%%|*}
    existing_status=${existing#*|}
    existing_status=${existing_status%%|*}
    existing_reason=${existing##*|}
    printf 'Release %s already exists for %s (Released=%s, Reason=%s).\n' "${existing_name}" "${app}" "${existing_status}" "${existing_reason}"
    if [[ "${existing_status}" == True ]]; then return 0; fi
    if [[ "${existing_status}" == False ]]; then
      if [[ "${existing_reason}" == Failed ]]; then
        printf 'The latest attempt for %s failed; creating a retry Release CR.\n' "${app}" >&2
      else
        printf 'Release %s for %s is still in progress (Reason=%s); skipping.\n' "${existing_name}" "${app}" "${existing_reason}"
        return 0
      fi
    else
      printf 'Existing release %s is in an unknown state; refusing a duplicate.\n' "${existing_name}" >&2
      return 2
    fi
  fi
  ocp=${app#openshift-pipelines-index-}
  ocp=${ocp%-"${MM_DASHED}"}
  ocp=${ocp/-/.}
  path="${REPORT_BASE}/manifest/prod/release-${VERSION}-index-${ocp}-prod.yaml"
  ocr_write_release_manifest "${path}" "${app}" "${rp}" "${snapshot}"
  ocr_create_release_manifest "${path}" || return 2
}

execute_4_8() {
  ocr_require_konflux || return 2
  local bundle apps app pids=() apps_list=()
  bundle=$(successful_snapshot bundle prod)
  [[ -n "${bundle}" ]] || {
    printf 'Bundle production release has not succeeded.\n' >&2
    return 2
  }
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json)
  local index_apps
  mapfile -t index_apps < <(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name|contains("index") and contains($mm)) | .metadata.name' <<<"${apps}" | sort)
  ((${#index_apps[@]} > 0)) || {
    printf 'No index applications found.\n' >&2
    return 2
  }
  printf '\nIndex snapshots to be released:\n' >&2
  local snap_display
  for app in "${index_apps[@]}"; do
    [[ -n "${app}" ]] || continue
    if [[ -f "${REPORT_BASE}/.state/prod-4.7-${app}-snapshot" ]]; then
      snap_display=$(<"${REPORT_BASE}/.state/prod-4.7-${app}-snapshot")
    else
      snap_display=$(ocr_latest_snapshot "${app}")
    fi
    printf '  %s  →  %s\n' "${app}" "${snap_display:-MISSING}" >&2
  done
  printf '\n' >&2
  for app in "${index_apps[@]}"; do
    [[ -n "${app}" ]] || continue
    apps_list+=("${app}")
    create_index_prod_release "${app}" &
    pids+=($!)
  done
  local i failed=0
  for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then
      printf 'Index production release done for %s.\n' "${apps_list[$i]}"
    else
      printf 'Index production release failed for %s.\n' "${apps_list[$i]}" >&2
      failed=1
    fi
  done
  ((failed == 0)) || return 2
}

execute_4_9() {
  ocr_require_konflux || return 2
  local snapshot path rp app release_name existing existing_name existing_status existing_reason
  snapshot=$(successful_snapshot core prod cdn)
  [[ -n "${snapshot}" ]] || {
    printf 'No succeeded core production snapshot found.\n' >&2
    return 2
  }
  app="openshift-pipelines-core-${MM_DASHED}"
  rp="openshift-pipelines-${MM_DASHED}-core-cdn-prod-rp"
  existing=$(existing_release_for_snapshot "${rp}" "${snapshot}")
  if [[ -n "${existing}" ]]; then
    existing_name=${existing%%|*}
    existing_status=${existing#*|}
    existing_status=${existing_status%%|*}
    existing_reason=${existing##*|}
    printf 'CDN release %s already exists for this snapshot (Released=%s, Reason=%s).\n' "${existing_name}" "${existing_status}" "${existing_reason}" >&2
    [[ "${existing_status}" == True ]] && return 0
    if [[ "${existing_status}" == False ]]; then
      if [[ "${existing_reason}" == Failed ]]; then
        printf 'The latest CDN attempt failed; creating a retry Release CR.\n' >&2
      else
        printf 'Release %s is still in progress (Reason=%s); skipping duplicate creation.\n' "${existing_name}" "${existing_reason}" >&2
        return 2
      fi
    else
      return 2
    fi
  fi
  path="${REPORT_BASE}/manifest/prod/release-${VERSION}-cdn-prod.yaml"
  {
    printf 'apiVersion: appstudio.redhat.com/v1alpha1\nkind: Release\nmetadata:\n'
    printf '  labels:\n    appstudio.openshift.io/application: %s\n' "${app}"
    printf '  generateName: %s-release-\n  namespace: %s\n' "${rp}" "${KONFLUX_NS}"
    printf 'spec:\n  data:\n  gracePeriodDays: 10\n  releasePlan: %s\n  snapshot: %s\n' "${rp}" "${snapshot}"
  } >"${path}"
  release_name=$(ocr_oc_create -f "${path}" -o jsonpath='{.metadata.name}')
  printf 'Created release: %s\n' "${release_name}"
  ocr_oc_wait_release "${release_name}" >/dev/null
  ocr_release_condition "${release_name}"
  printf '\nAfter success, update the product version YAML via GitLab MR to set invisible: false.\n'
}

execute_4_10() {
  printf 'Image publication to registry.redhat.io is handled by the CDN pipeline after step 4.9.\n'
  printf 'Re-verify once the CDN release completes (typically 10–30 minutes after CDN release succeeds).\n'
  return 2
}

release_tag_repos_tsv() {
  local snapshot=$1 components
  components=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components}' 2>/dev/null) || return 1
  python3 -c '
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
' <<<"${components}"
}

execute_4_11() {
  printf 'Step 4.11 is verify-only. Run verify to list repos for tagging.\n' >&2
  return 2
}

execute_4_12() {
  local state_file="${REPORT_BASE}/.state/release-tag-repos.tsv"
  [[ -s "${state_file}" ]] || {
    printf 'No confirmed repo list found. Run verify for step 4.11 first.\n' >&2
    return 2
  }
  local repo rev tag_exists failed=0 total=0 tagged=0
  while IFS=$'\t' read -r repo rev tag_exists; do
    [[ -n "${repo}" ]] || continue
    ((total += 1))
    if [[ "${tag_exists}" == "yes" ]]; then
      printf 'Tag %s already exists on %s; skipping.\n' "${RELEASE_TAG}" "${repo}"
      ((tagged += 1))
      continue
    fi
    printf 'Pushing tag %s to %s at %s...\n' "${RELEASE_TAG}" "${repo}" "${rev:0:12}"
    if gh api "repos/${repo}/git/refs" -f "ref=refs/tags/${RELEASE_TAG}" -f "sha=${rev}" --silent; then
      printf 'Tagged %s\n' "${repo}"
      ((tagged += 1))
    else
      printf 'Failed to tag %s\n' "${repo}" >&2
      ((failed += 1))
    fi
  done <"${state_file}"
  printf '%d/%d repos tagged.\n' "${tagged}" "${total}"
  ((failed == 0)) || return 2
}

ocr_execute_step() {
  case "$1" in
    4.1) execute_4_1 ;; 4.2) execute_4_2 ;; 4.3) execute_4_3 ;; 4.4) execute_4_4 ;;
    4.5) execute_4_5 ;; 4.6) execute_4_6 ;; 4.7) execute_4_7 ;; 4.8) execute_4_8 ;;
    4.9) execute_4_9 ;; 4.10) execute_4_10 ;; 4.11) execute_4_11 ;; 4.12) execute_4_12 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  ocr_execute_stage "${1:-}" "${2:-}"
fi
