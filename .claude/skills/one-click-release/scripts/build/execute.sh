#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -euo pipefail

STAGE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPTS_DIR=$(cd "${STAGE_DIR}/.." && pwd)
source "${SCRIPTS_DIR}/lib/common.sh"
source "${SCRIPTS_DIR}/lib/report.sh"
source "${SCRIPTS_DIR}/lib/release.sh"
source "${SCRIPTS_DIR}/lib/stage-runner.sh"

STAGE_NAME=build
STAGE_STEPS=(2.1 2.2 2.3 2.4 2.5 2.6 2.7 2.8 2.9)

ocr_describe_action() {
  case "$1" in
    2.1) printf 'Process open release PRs: rebase behind PRs and auto-merge green PRs.\n' ;;
    2.2) printf 'Trigger rebuild commits for repositories stale in the core snapshot.\n' ;;
    2.3) printf 'Create the core stage Release CR from the latest verified snapshot.\n' ;;
    2.4) printf 'Process nudge PRs, including conflict consolidation when required.\n' ;;
    2.5) printf 'Run staging operator-update-images, merge its verified PR, and render the staging catalog.\n' ;;
    2.6) printf 'Trigger bundle and index rebuilds for stale FBC snapshots.\n' ;;
    2.7) printf 'Create the bundle stage Release CR after the core stage release succeeds.\n' ;;
    2.8) printf 'Create index stage Release CRs after the bundle stage release succeeds.\n' ;;
    2.9) printf 'Create and merge the hack code-freeze PR.\n' ;;
  esac
}

pr_ready() {
  local url=$1 data
  data=$(gh pr view "${url}" --json mergeable,mergeStateStatus,statusCheckRollup)
  jq -e '.mergeable != "CONFLICTING" and .mergeStateStatus != "DIRTY" and
    ([.statusCheckRollup[]? | select((.status//"") != "COMPLETED")] | length) == 0 and
    ([.statusCheckRollup[]? | select((.conclusion//"") != "" and ((.conclusion | IN("SUCCESS","NEUTRAL","SKIPPED")) | not))] | length) == 0' \
    <<<"${data}" >/dev/null
}

process_pr_urls() {
  local url failed=0
  while IFS= read -r url; do
    [[ -n "${url}" ]] || continue
    local data mergeable merge_state
    data=$(gh pr view "${url}" --json mergeable,mergeStateStatus,statusCheckRollup)
    mergeable=$(jq -r '.mergeable' <<<"${data}")
    merge_state=$(jq -r '.mergeStateStatus' <<<"${data}")

    if [[ "${mergeable}" == "CONFLICTING" || "${merge_state}" == "DIRTY" ]]; then
      printf 'CONFLICT — requires manual resolution: %s\n' "${url}" >&2
      ((failed += 1))
    elif [[ "${merge_state}" == "BEHIND" ]]; then
      printf 'BEHIND — rebasing: %s\n' "${url}" >&2
      gh pr update-branch "${url}" --rebase
      ((failed += 1))
    elif jq -e '[.statusCheckRollup[]? | select((.status//"") != "COMPLETED")] | length > 0' <<<"${data}" >/dev/null 2>&1; then
      printf 'CI PENDING — checks still running: %s\n' "${url}" >&2
      ((failed += 1))
    elif ! pr_ready "${url}"; then
      printf 'CI FAILING — requires manual investigation: %s\n' "${url}" >&2
      ((failed += 1))
    else
      gh pr edit "${url}" --add-label lgtm,approved,one-click-release
      gh pr review --approve "${url}"
      gh pr merge "${url}" -d -r --auto
    fi
  done
  ((failed == 0)) || return 2
}

execute_2_1() {
  local prs
  prs=$(gh search prs --owner openshift-pipelines --base "${RELEASE_BRANCH}" --state open \
    --json url 'label:hack,upstream,automated') || {
    printf 'Unable to query release PRs; refusing to treat the result as empty.\n' >&2
    return 2
  }
  process_pr_urls < <(jq -r '.[].url' <<<"${prs}")
}

core_snapshot_rows() {
  local apps core snapshot components
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json)
  core=$(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name | contains("core") and contains($mm)) | .metadata.name' <<<"${apps}" | head -1)
  snapshot=$(ocr_latest_snapshot "${core}")
  components=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components}')
  python3 -c '
import json,sys
repos={}
for c in json.load(sys.stdin):
  src=c.get("source",{}).get("git",{}); repo=src.get("url","").removesuffix(".git").replace("https://github.com/","")
  if repo and not repo.endswith("/operator"): repos.setdefault(repo,set()).add(src.get("revision",""))
for repo,revs in sorted(repos.items()): print(repo+"|"+",".join(sorted(revs)))
' <<<"${components}"
}

push_placeholder() {
  local repo=$1 path=$2 message=$3 temp
  temp=$(mktemp -d)
  git clone --depth 1 -b "${RELEASE_BRANCH}" "https://github.com/${repo}.git" "${temp}/repo"
  (
    cd "${temp}/repo"
    mkdir -p "$(dirname "${path}")"
    printf 'Forced rebuild at %s\n' "$(date +"${TZ_FMT}")" >"${path}"
    git config user.name "${GITHUB_USER:-One Click Release Bot}"
    git config user.email "${GITHUB_EMAIL:-one-click-release-bot@redhat.com}"
    git add "${path}"
    git commit -m "${message}"
    git push origin "${RELEASE_BRANCH}"
  )
  rm -rf "${temp}"
}

execute_2_2() {
  ocr_require_konflux || return 2
  local repo revs head stale=0 pending=0
  while IFS='|' read -r repo revs; do
    head=$(git ls-remote "https://github.com/${repo}.git" "refs/heads/${RELEASE_BRANCH}" | awk '{print $1}')
    if [[ "${revs}" == *,* || "${revs}" != "${head}" ]]; then
      ((stale += 1))
      if ocr_mutation_done "core-rebuild-${repo}"; then
        printf 'Rebuild for %s was already pushed; waiting for a current snapshot.\n' "${repo}"
        ((pending += 1))
        continue
      fi
      push_placeholder "${repo}" .konflux/patches/.placeholder 'One Click Release: build all konflux components'
      ocr_mark_mutation "core-rebuild-${repo}"
      ((pending += 1))
    fi
  done < <(core_snapshot_rows)
  if ((stale == 0)); then
    printf 'All repos are current in the core snapshot.\n'
    return 0
  fi
  printf '%d repo(s) stale; %d rebuild(s) pending.\n' "${stale}" "${pending}" >&2
  return 2
}

find_app() {
  local kind=$1
  ocr_oc_get applications.appstudio.redhat.com -o json | jq -r --arg mm "${MM_DASHED}" --arg kind "${kind}" \
    '.items[] | select(.metadata.name | contains($kind) and contains($mm)) | .metadata.name' | head -1
}

find_release_plan() {
  local app=$1 env=$2 exclude=${3:-}
  ocr_oc_get releaseplans -o json | jq -r --arg app "${app}" --arg env "${env}" --arg exclude "${exclude}" '
    [.items[] | select(.spec.application==$app and (.metadata.name | contains($env)))
      | select($exclude=="" or (.metadata.name | contains($exclude) | not))][0].metadata.name // empty'
}

successful_release_exists() {
  local kind=$1 env=$2 exclude=${3:-}
  ocr_oc_get releases -o json | jq -e --arg mm "${MM_DASHED}" --arg kind "${kind}" --arg env "${env}" --arg exclude "${exclude}" '
    any(.items[]; (.spec.releasePlan | contains($mm) and contains($kind) and contains($env)) and
      ($exclude=="" or (.spec.releasePlan | contains($exclude) | not)) and
      any(.status.conditions[]?; .type=="Released" and .status=="True"))' >/dev/null
}

existing_release_for_snapshot() {
  local rp=$1 snapshot=$2
  ocr_oc_get releases -o json | jq -r --arg rp "${rp}" --arg snapshot "${snapshot}" '
    [.items[] | select(.spec.releasePlan==$rp and .spec.snapshot==$snapshot)
      | {name:.metadata.name,status:([.status.conditions[]? | select(.type=="Released")][0].status // "Unknown"),created:(.metadata.creationTimestamp // "")}]
      | sort_by(.created) | .[-1]
      | if . == null then empty else "\(.name)|\(.status)" end'
}

create_stage_release() {
  local kind=$1 app snapshot rp path
  app=$(find_app "${kind}")
  [[ -n "${app}" ]] || {
    printf '%s application not found.\n' "${kind}" >&2
    return 2
  }
  snapshot=$(ocr_latest_snapshot "${app}")
  [[ -n "${snapshot}" ]] || {
    printf 'No snapshot for %s.\n' "${app}" >&2
    return 2
  }
  rp=$(find_release_plan "${app}" stage cdn)
  [[ -n "${rp}" ]] || {
    printf 'No stage release plan for %s.\n' "${app}" >&2
    return 2
  }
  local existing existing_name existing_status
  existing=$(existing_release_for_snapshot "${rp}" "${snapshot}")
  if [[ -n "${existing}" ]]; then
    existing_name=${existing%%|*}
    existing_status=${existing#*|}
    printf 'Release %s already exists for this snapshot (Released=%s).\n' "${existing_name}" "${existing_status}" >&2
    [[ "${existing_status}" == True ]] && return 0
    [[ "${existing_status}" == False ]] || return 2
    printf 'The latest attempt failed; creating the supported retry Release CR.\n' >&2
  fi
  path="${REPORT_BASE}/manifest/stage/release-${VERSION}-${kind}-stage.yaml"
  ocr_write_release_manifest "${path}" "${app}" "${rp}" "${snapshot}"
  ocr_create_release_manifest "${path}"
}

execute_2_3() {
  ocr_require_konflux || return 2
  create_stage_release core || return $?
  # Record the core snapshot for the production release (step 4.2)
  local core_app
  core_app=$(find_app core)
  STAGE_CORE_SNAPSHOT=$(ocr_latest_snapshot "${core_app}")
  export STAGE_CORE_SNAPSHOT
  printf 'STAGE_CORE_SNAPSHOT=%s\n' "${STAGE_CORE_SNAPSHOT}" >>"${REPORT_BASE}/stage-vars.env"
}

consolidate_conflicting_nudges() {
  local prs temp branch body number diff image digest branch_rc
  prs=$(gh pr list --repo openshift-pipelines/operator --base "${RELEASE_BRANCH}" --label konflux-nudge \
    --state open --limit 50 --json number,url,mergeable --jq '[.[] | select(.mergeable=="CONFLICTING")]')
  (($(jq length <<<"${prs}") > 0)) || return 0
  branch="one-click-release/consolidated-nudge-${VERSION}"
  if ocr_remote_branch_matches openshift-pipelines/operator "${RELEASE_BRANCH}" "${branch}" '^project\.yaml$' 'sha256:[0-9a-f]{64}' 'sha256:[0-9a-f]{64}'; then
    : # Resume below by creating the missing PR from the existing branch.
  else
    branch_rc=$?
    ((branch_rc == 1)) || return 2
    temp=$(mktemp -d)
    git clone --depth 1 -b "${RELEASE_BRANCH}" https://github.com/openshift-pipelines/operator.git "${temp}/operator"
    (
      cd "${temp}/operator"
      while IFS= read -r number; do
        diff=$(gh pr diff --repo openshift-pipelines/operator "${number}")
        while IFS= read -r line; do
          image=$(sed -E 's#^\+.*[[:space:]]([^[:space:]]+)@sha256:[a-f0-9]{64}.*#\1#' <<<"${line}")
          digest=$(grep -oE '@sha256:[a-f0-9]{64}' <<<"${line}" | head -1 | cut -d: -f2)
          [[ -n "${image}" && -n "${digest}" ]] || continue
          sed_i -E "s#(${image}@sha256:)[a-f0-9]{64}#\\1${digest}#g" project.yaml
        done < <(grep -E '^\+.*@sha256:[a-f0-9]{64}' <<<"${diff}")
      done < <(jq -r '.[].number' <<<"${prs}")
      git diff --quiet project.yaml && {
        printf 'No digest changes extracted from conflicting PRs.\n' >&2
        exit 2
      }
      git config user.name "${GITHUB_USER:-One Click Release Bot}"
      git config user.email "${GITHUB_EMAIL:-one-click-release-bot@redhat.com}"
      git checkout -b "${branch}"
      git add project.yaml
      git commit -m "chore(deps): consolidated nudge updates for ${VERSION}"
      git push origin "${branch}"
    )
    rm -rf "${temp}"
  fi
  body=$(jq -r 'map("- #\(.number)") | join("\n")' <<<"${prs}")
  gh pr create --repo openshift-pipelines/operator --base "${RELEASE_BRANCH}" --head "${branch}" \
    --title "chore(deps): consolidated nudge updates for ${VERSION}" \
    --body "Consolidates SHA updates from conflicting nudge PRs:
${body}" \
    --label konflux-nudge,lgtm,approved,one-click-release
  while IFS= read -r number; do
    gh pr close --repo openshift-pipelines/operator "${number}" \
      --comment 'Superseded by the consolidated nudge PR; its SHA update is included there.'
  done < <(jq -r '.[].number' <<<"${prs}")
}

execute_2_4() {
  local prs urls=() ready_urls=() url data state failed=0
  prs=$(gh pr list --repo openshift-pipelines/operator --base "${RELEASE_BRANCH}" --label konflux-nudge \
    --state open --limit 100 --json url,mergeable,mergeStateStatus)
  mapfile -t urls < <(jq -r '.[].url' <<<"${prs}")
  ((${#urls[@]} > 0)) || return 0
  for url in "${urls[@]}"; do
    data=$(gh pr view "${url}" --json mergeable,mergeStateStatus,statusCheckRollup)
    state=$(jq -r '.mergeStateStatus' <<<"${data}")
    if [[ "${state}" == BEHIND ]]; then
      gh pr update-branch "${url}" --rebase
      ((failed += 1))
    elif pr_ready "${url}"; then
      ready_urls+=("${url}")
    elif [[ $(jq -r '.mergeable' <<<"${data}") != CONFLICTING ]]; then
      printf 'Nudge PR has failing or pending CI: %s\n' "${url}" >&2
      ((failed += 1))
    fi
  done
  if ((${#ready_urls[@]} > 0)); then
    printf '%s\n' "${ready_urls[@]}" | process_pr_urls
  fi
  consolidate_conflicting_nudges
  ((failed == 0)) || return 2
}

latest_run_id() {
  local workflow=$1
  gh run list --repo openshift-pipelines/operator --workflow="${workflow}" --limit 5 \
    --json databaseId,event --jq '[.[] | select(.event=="workflow_dispatch")][0].databaseId // empty'
}

wait_in_progress_runs() {
  local workflow=$1 id runs
  runs=$(gh run list --repo openshift-pipelines/operator --workflow="${workflow}" --limit 5 \
    --json databaseId,status) || {
    printf 'Unable to query in-progress %s runs; refusing to dispatch a duplicate.\n' "${workflow}" >&2
    return 2
  }
  while IFS= read -r id; do
    [[ -n "${id}" ]] && gh run watch --repo openshift-pipelines/operator "${id}"
  done < <(jq -r '.[] | select(.status=="in_progress" or .status=="queued") | .databaseId' <<<"${runs}")
}

execute_2_5() {
  local id pr diff merged_pr
  wait_in_progress_runs operator-update-images.yaml
  pr=$(gh pr list --repo openshift-pipelines/operator --head "actions/update/operator-update-images-${RELEASE_BRANCH}" \
    --state open --limit 1 --json number --jq '.[0].number // empty')
  if [[ -n "${pr}" ]]; then
    diff=$(gh pr diff --repo openshift-pipelines/operator "${pr}")
    if grep -E '^\+.*image:.*(quay\.io|devel)' <<<"${diff}" >/dev/null; then
      gh pr close --repo openshift-pipelines/operator "${pr}" --comment 'Closing devel output before the staging dispatch.'
      pr=''
    fi
  fi
  merged_pr=$(gh pr list --repo openshift-pipelines/operator --head "actions/update/operator-update-images-${RELEASE_BRANCH}" \
    --state merged --limit 1 --json number --jq '.[0].number // empty')
  if [[ -n "${merged_pr}" ]]; then
    diff=$(gh pr diff --repo openshift-pipelines/operator "${merged_pr}") || {
      printf 'Unable to inspect merged staging CSV PR; refusing to continue.\n' >&2
      return 2
    }
    if grep -E '^\+.*image:.*(quay\.io|devel)' <<<"${diff}" >/dev/null; then
      merged_pr=''
    fi
  fi
  if [[ -z "${pr}" && -z "${merged_pr}" ]]; then
    gh workflow run operator-update-images.yaml --repo openshift-pipelines/operator --ref "${RELEASE_BRANCH}" -f environment=staging
    id=$(latest_run_id operator-update-images.yaml)
    [[ -n "${id}" ]] && gh run watch --repo openshift-pipelines/operator "${id}"
    pr=$(gh pr list --repo openshift-pipelines/operator --head "actions/update/operator-update-images-${RELEASE_BRANCH}" \
      --state open --limit 1 --json number --jq '.[0].number // empty')
  fi
  if [[ -n "${merged_pr}" ]]; then
    pr=''
  fi
  if [[ -z "${pr}" && -z "${merged_pr}" ]]; then
    printf 'Staging CSV PR not found after workflow completion.\n' >&2
    return 2
  fi
  if [[ -n "${pr}" ]]; then
    diff=$(gh pr diff --repo openshift-pipelines/operator "${pr}")
    if grep -E '^\+.*image:.*(quay\.io|devel)' <<<"${diff}" >/dev/null; then
      printf 'CSV PR contains non-staging image references; refusing to merge.\n' >&2
      return 2
    fi
    gh pr edit --repo openshift-pipelines/operator "${pr}" --add-label lgtm,approved,one-click-release
    gh pr review --approve --repo openshift-pipelines/operator "${pr}"
    gh pr merge --repo openshift-pipelines/operator "${pr}" -d -r --auto
  fi
  wait_in_progress_runs render-olm-catalog.yaml
  gh workflow run render-olm-catalog.yaml --repo openshift-pipelines/operator \
    -f "branch=${RELEASE_BRANCH}" -f environment=staging
  id=$(latest_run_id render-olm-catalog.yaml)
  [[ -n "${id}" ]] && gh run watch --repo openshift-pipelines/operator "${id}"
}

execute_2_6() {
  ocr_require_konflux || return 2
  local apps head bundle snapshot rev stale_bundle=false stale_index=false app
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json)
  head=$(git ls-remote https://github.com/openshift-pipelines/operator.git "refs/heads/${RELEASE_BRANCH}" | awk '{print $1}')
  bundle=$(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name|contains("bundle") and contains($mm)) | .metadata.name' <<<"${apps}" | head -1)
  snapshot=$(ocr_latest_snapshot "${bundle}")
  if [[ -z "${snapshot}" ]]; then
    stale_bundle=true
  else
    rev=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components[0].source.git.revision}')
    ocr_operator_revision_is_generated "${rev}" "${head}" || stale_bundle=true
  fi
  while IFS= read -r app; do
    snapshot=$(ocr_latest_snapshot "${app}")
    [[ -n "${snapshot}" ]] || continue
    rev=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components[0].source.git.revision}')
    [[ "${rev}" == "${head}" ]] || stale_index=true
  done < <(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name|contains("index") and contains($mm)) | .metadata.name' <<<"${apps}")
  if [[ "${stale_bundle}" == true ]]; then
    if ocr_mutation_done fbc-bundle-rebuild; then printf 'Bundle rebuild already pushed; waiting for its snapshot.\n'; else
      push_placeholder openshift-pipelines/operator .konflux/olm-catalog/bundle/.placeholder 'One Click Release: rebuild bundle'
      ocr_mark_mutation fbc-bundle-rebuild
    fi
  fi
  if [[ "${stale_index}" == true ]]; then
    if ocr_mutation_done fbc-index-rebuild; then printf 'Index rebuild already pushed; waiting for snapshots.\n'; else
      push_placeholder openshift-pipelines/operator .konflux/olm-catalog/index/.placeholder 'One Click Release: rebuild index images'
      ocr_mark_mutation fbc-index-rebuild
    fi
  fi
  if [[ "${stale_bundle}" == true || "${stale_index}" == true ]]; then
    printf 'FBC snapshot(s) still stale; waiting for rebuild(s) to complete.\n' >&2
    return 2
  fi
  printf 'All FBC snapshots are current.\n'
}

execute_2_7() {
  ocr_require_konflux || return 2
  successful_release_exists core stage cdn || {
    printf 'Core stage release has not succeeded.\n' >&2
    return 2
  }
  create_stage_release bundle
}

execute_2_8() {
  ocr_require_konflux || return 2
  successful_release_exists bundle stage || {
    printf 'Bundle stage release has not succeeded.\n' >&2
    return 2
  }
  local apps app snapshot rp ocp path made=0
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json)
  while IFS= read -r app; do
    snapshot=$(ocr_latest_snapshot "${app}")
    [[ -n "${snapshot}" ]] || continue
    rp=$(find_release_plan "${app}" stage)
    [[ -n "${rp}" ]] || {
      printf 'No stage release plan for %s.\n' "${app}" >&2
      return 2
    }
    local existing existing_name existing_status
    existing=$(existing_release_for_snapshot "${rp}" "${snapshot}")
    if [[ -n "${existing}" ]]; then
      existing_name=${existing%%|*}
      existing_status=${existing#*|}
      printf 'Release %s already exists for %s (Released=%s); skipping duplicate creation.\n' "${existing_name}" "${app}" "${existing_status}"
      if [[ "${existing_status}" == True ]]; then
        ((made += 1))
        continue
      fi
      [[ "${existing_status}" == False ]] || {
        printf 'Existing release %s is still pending; refusing a duplicate.\n' "${existing_name}" >&2
        return 2
      }
    fi
    ocp=${app#openshift-pipelines-index-}
    ocp=${ocp%-"${MM_DASHED}"}
    ocp=${ocp/-/.}
    path="${REPORT_BASE}/manifest/stage/release-${VERSION}-index-${ocp}-stage.yaml"
    ocr_write_release_manifest "${path}" "${app}" "${rp}" "${snapshot}"
    ocr_create_release_manifest "${path}"
    ((made += 1))
  done < <(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name | contains("index") and contains($mm)) | .metadata.name' <<<"${apps}" | sort)
  ((made > 0)) || {
    printf 'No index applications with snapshots found.\n' >&2
    return 2
  }
}

execute_2_9() {
  local temp branch pr open_url branch_rc
  temp=$(mktemp -d)
  branch="release/${VERSION}/code-freeze"
  open_url=$(gh pr list --repo openshift-pipelines/hack --head "${branch}" --state open --limit 1 --json url --jq '.[0].url // empty')
  if [[ -n "${open_url}" ]]; then
    if pr_ready "${open_url}"; then
      gh pr merge "${open_url}" --rebase
      rm -rf "${temp}"
      return
    fi
    printf 'Existing code-freeze PR is not ready: %s\n' "${open_url}" >&2
    rm -rf "${temp}"
    return 2
  fi
  if ocr_remote_branch_matches openshift-pipelines/hack main "${branch}" "^config/downstream/releases/${MAJOR_MINOR//./\\.}\\.yaml$" '^\s*code-freeze:\s*(false|true)$' '^\s*code-freeze:\s*true$'; then
    gh pr create --repo openshift-pipelines/hack --base main --head "${branch}" \
      --title "[bot:${MAJOR_MINOR}] Set code freeze for ${VERSION}" \
      --body 'Resumes the previously pushed code-freeze branch.' --label automated
    pr=$(gh pr list --repo openshift-pipelines/hack --head "${branch}" --state open --limit 1 --json number --jq '.[0].number')
    gh pr merge --repo openshift-pipelines/hack "${pr}" --rebase
    rm -rf "${temp}"
    return
  else
    branch_rc=$?
    ((branch_rc == 1)) || {
      rm -rf "${temp}"
      return 2
    }
  fi
  git clone --depth 1 https://github.com/openshift-pipelines/hack.git "${temp}/hack"
  (
    cd "${temp}/hack"
    sed_i 's/code-freeze: false/code-freeze: true/' "config/downstream/releases/${MAJOR_MINOR}.yaml"
    git diff --quiet && {
      printf 'code-freeze is already true or field missing.\n'
      exit 0
    }
    git config user.name "${GITHUB_USER:-One Click Release Bot}"
    git config user.email "${GITHUB_EMAIL:-one-click-release-bot@redhat.com}"
    git checkout -b "${branch}"
    git add "config/downstream/releases/${MAJOR_MINOR}.yaml"
    git commit -m "[bot:${MAJOR_MINOR}] Set code freeze for ${VERSION}"
    git push origin "${branch}"
  )
  gh pr create --repo openshift-pipelines/hack --base main --head "${branch}" \
    --title "[bot:${MAJOR_MINOR}] Set code freeze for ${VERSION}" \
    --body 'Sets code-freeze: true after stage builds and releases complete.' --label automated
  pr=$(gh pr list --repo openshift-pipelines/hack --head "${branch}" --state open --limit 1 --json number --jq '.[0].number')
  gh pr merge --repo openshift-pipelines/hack "${pr}" --rebase
  rm -rf "${temp}"
}

ocr_execute_step() {
  case "$1" in
    2.1) execute_2_1 ;; 2.2) execute_2_2 ;; 2.3) execute_2_3 ;; 2.4) execute_2_4 ;;
    2.5) execute_2_5 ;; 2.6) execute_2_6 ;; 2.7) execute_2_7 ;; 2.8) execute_2_8 ;; 2.9) execute_2_9 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  ocr_execute_stage "${1:-}" "${2:-}"
fi
