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
STAGE_REPORT_TITLE='Build Stage Report'
STAGE_REPORT_DIR=build
STAGE_STEPS=(2.1 2.2 2.3 2.4 2.5 2.6 2.7 2.8 2.9)

ocr_step_title() {
  case "$1" in
    2.1) printf '%s' 'Process release PRs' ;;
    2.2) printf '%s' 'Wait for core snapshot' ;;
    2.3) printf '%s' 'Core stage release' ;;
    2.4) printf '%s' 'Process nudge PRs' ;;
    2.5) printf '%s' 'OLM catalog render' ;;
    2.6) printf '%s' 'Wait for FBC build' ;;
    2.7) printf '%s' 'Bundle stage release' ;;
    2.8) printf '%s' 'Index stage releases' ;;
    2.9) printf '%s' 'Code freeze' ;;
  esac
}

release_status_json() {
  ocr_oc_get releases -o json 2>/dev/null
}

verify_2_1() {
  local prs count
  prs=$(gh search prs --owner openshift-pipelines --base "${RELEASE_BRANCH}" --state open \
    --json repository,url,title,labels 'label:hack,upstream,automated' 2>/dev/null || printf '[]')
  count=$(jq length <<<"${prs}")
  STEP_DETAILS="${count} open release PRs"
  if ((count > 0)); then
    STEP_LINKS=$(jq -r 'map("\(.repository.nameWithOwner | split("/")[-1]) [#\(.url | split("/")[-1])](\(.url))") | join(", ")' <<<"${prs}")
    return "${OCR_RC_BLOCKED}"
  fi
}

verify_2_2() {
  ocr_require_konflux || return $?
  local apps core snapshot components rows stale=''
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json 2>/dev/null) || return "${OCR_RC_BLOCKED}"
  core=$(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name | contains("core") and contains($mm)) | .metadata.name' <<<"${apps}" | head -1)
  [[ -n "${core}" ]] || {
    STEP_DETAILS='core application not found'
    return "${OCR_RC_BLOCKED}"
  }
  snapshot=$(ocr_latest_snapshot "${core}")
  [[ -n "${snapshot}" ]] || {
    STEP_DETAILS="no push snapshot for ${core}"
    return "${OCR_RC_BLOCKED}"
  }
  components=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components}' 2>/dev/null) || return "${OCR_RC_BLOCKED}"
  rows=$(python3 -c '
import json,sys
repos={}
for c in json.load(sys.stdin):
  src=c.get("source",{}).get("git",{}); url=src.get("url","").removesuffix(".git")
  repo=url.replace("https://github.com/",""); rev=src.get("revision","")
  if repo.endswith("/operator") or not repo: continue
  repos.setdefault(repo,set()).add(rev)
for repo,revs in sorted(repos.items()): print(repo+"|"+",".join(sorted(revs)))
' <<<"${components}")
  local repo revs head
  while IFS='|' read -r repo revs; do
    [[ -n "${repo}" ]] || continue
    head=$(git ls-remote "https://github.com/${repo}.git" "refs/heads/${RELEASE_BRANCH}" | awk '{print $1}')
    if [[ "${revs}" == *,* || "${revs}" != "${head}" ]]; then
      stale+=" ${repo}"
    fi
  done <<<"${rows}"
  STEP_DETAILS="snapshot ${snapshot}; all non-operator repos current"
  if [[ -n "${stale}" ]]; then
    STEP_DETAILS="snapshot ${snapshot}; stale or split:${stale}"
    return "${OCR_RC_BLOCKED}"
  fi
}

verify_release_kind() {
  local kind=$1 env=$2 exclude=${3:-} data matches success latest apps app latest_snapshot
  data=$(release_status_json) || return "${OCR_RC_BLOCKED}"
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json 2>/dev/null) || return "${OCR_RC_BLOCKED}"
  app=$(jq -r --arg mm "${MM_DASHED}" --arg kind "${kind}" '.items[] | select(.metadata.name|contains($kind) and contains($mm)) | .metadata.name' <<<"${apps}" | head -1)
  latest_snapshot=$(ocr_latest_snapshot "${app}")
  matches=$(jq --arg mm "${MM_DASHED}" --arg kind "${kind}" --arg env "${env}" --arg exclude "${exclude}" --arg snapshot "${latest_snapshot}" '
    [.items[] | select(.spec.releasePlan | contains($mm) and contains($kind) and contains($env))
      | select($exclude == "" or (.spec.releasePlan | contains($exclude) | not))
      | select(.spec.snapshot == $snapshot)
      | {name:.metadata.name, rp:.spec.releasePlan, snapshot:.spec.snapshot,
         status:([.status.conditions[]? | select(.type=="Released")][0].status // "Unknown"),
         reason:([.status.conditions[]? | select(.type=="Released")][0].reason // "")}]' <<<"${data}")
  latest=$(jq -r '.[-1].name // empty' <<<"${matches}")
  success=$(jq '[.[] | select(.status=="True")] | length' <<<"${matches}")
  STEP_DETAILS="${kind} ${env} release: ${latest:-not found}; latest snapshot=${latest_snapshot:-missing}; succeeded=${success}"
  [[ -n "${latest_snapshot}" ]] && ((success > 0)) || return "${OCR_RC_BLOCKED}"
}

verify_2_3() {
  ocr_require_konflux || return $?
  verify_release_kind core stage cdn
}

verify_2_4() {
  local prs count
  prs=$(gh search prs --owner openshift-pipelines --base "${RELEASE_BRANCH}" --state open \
    --json repository,url,title,labels 'label:konflux-nudge' 2>/dev/null || printf '[]')
  count=$(jq length <<<"${prs}")
  STEP_DETAILS="${count} open nudge PRs"
  if ((count > 0)); then
    STEP_LINKS=$(jq -r 'map("operator [#\(.url | split("/")[-1])](\(.url))") | join(", ")' <<<"${prs}")
    return "${OCR_RC_BLOCKED}"
  fi
}

verify_2_5() {
  local csv runs run_url state catalogs diff registry_ok=true
  csv=$(gh pr list --repo openshift-pipelines/operator \
    --head "actions/update/operator-update-images-${RELEASE_BRANCH}" --state merged --limit 1 \
    --json number,url,mergedAt)
  runs=$(gh run list --repo openshift-pipelines/operator --workflow=render-olm-catalog.yaml --limit 10 \
    --json status,conclusion,createdAt,displayTitle,headBranch,url,event 2>/dev/null || printf '[]')
  run_url=$(jq -r --arg b "${RELEASE_BRANCH}" '[.[] | select(.event=="workflow_dispatch" and .status=="completed" and .conclusion=="success") | select((.displayTitle//"")|contains($b))][0].url // [.[] | select(.event=="workflow_dispatch" and .status=="completed" and .conclusion=="success")][0].url // empty' <<<"${runs}")
  state=$(jq -r '.[0].number // empty' <<<"${csv}")
  if [[ -n "${state}" ]]; then
    diff=$(gh pr diff --repo openshift-pipelines/operator "${state}" 2>/dev/null || true)
    grep -E '^\+.*image:.*(quay\.io|devel)' <<<"${diff}" >/dev/null && registry_ok=false
  fi
  catalogs=$(gh api "repos/openshift-pipelines/operator/commits?sha=${RELEASE_BRANCH}&per_page=10" \
    --jq '[.[] | select(.commit.message | test("catalog|render|OCP catalog"; "i"))] | length' 2>/dev/null || printf '0')
  STEP_DETAILS="CSV PR merged=${state:-no}; staging registries=${registry_ok}; staging render=$([[ -n "${run_url}" ]] && echo success || echo missing); catalog commits=${catalogs}"
  [[ -n "${state}" && "${registry_ok}" == true && -n "${run_url}" && ${catalogs} -gt 0 ]] || return "${OCR_RC_BLOCKED}"
  STEP_LINKS="operator [#${state}]($(jq -r '.[0].url' <<<"${csv}")), [render-olm-catalog](${run_url})"
}

snapshot_matches_or_automated_gap() {
  local revision=$1 head=$2
  [[ "${revision}" == "${head}" ]] && return 0
  local commits
  commits=$(gh api "repos/openshift-pipelines/operator/compare/${revision}...${head}" \
    --jq '.commits[].commit.message | split("\n")[0]' 2>/dev/null || return 1)
  [[ -n "${commits}" ]] || return 1
  ! grep -Eivq '^(chore|build|Merge|\[bot:|One Click Release|.*catalog|.*nudge|.*image)' <<<"${commits}"
}

verify_2_6() {
  ocr_require_konflux || return $?
  local apps operator_head bundle snapshot rev stale='' checked=0 app
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json 2>/dev/null) || return "${OCR_RC_BLOCKED}"
  operator_head=$(git ls-remote https://github.com/openshift-pipelines/operator.git "refs/heads/${RELEASE_BRANCH}" | awk '{print $1}')
  bundle=$(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name | contains("bundle") and contains($mm)) | .metadata.name' <<<"${apps}" | head -1)
  snapshot=$(ocr_latest_snapshot "${bundle}")
  [[ -n "${snapshot}" ]] || {
    STEP_DETAILS='bundle snapshot not found'
    return "${OCR_RC_BLOCKED}"
  }
  rev=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components[0].source.git.revision}' 2>/dev/null)
  snapshot_matches_or_automated_gap "${rev}" "${operator_head}" || stale+=" bundle"
  while IFS= read -r app; do
    [[ -n "${app}" ]] || continue
    snapshot=$(ocr_latest_snapshot "${app}")
    [[ -z "${snapshot}" ]] && continue
    ((checked += 1))
    rev=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components[0].source.git.revision}' 2>/dev/null)
    snapshot_matches_or_automated_gap "${rev}" "${operator_head}" || stale+=" ${app}"
  done < <(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name | contains("index") and contains($mm)) | .metadata.name' <<<"${apps}" | sort)
  STEP_DETAILS="bundle snapshot present; ${checked} index snapshots checked"
  if [[ -n "${stale}" ]]; then
    STEP_DETAILS+="; stale:${stale}"
    return "${OCR_RC_BLOCKED}"
  fi
}

verify_2_7() {
  ocr_require_konflux || return $?
  verify_release_kind bundle stage
}

verify_2_8() {
  ocr_require_konflux || return $?
  local apps releases app snapshot total=0 succeeded=0 status
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json 2>/dev/null) || return "${OCR_RC_BLOCKED}"
  releases=$(release_status_json) || return "${OCR_RC_BLOCKED}"
  while IFS= read -r app; do
    [[ -n "${app}" ]] || continue
    snapshot=$(ocr_latest_snapshot "${app}")
    [[ -z "${snapshot}" ]] && continue
    ((total += 1))
    status=$(jq -r --arg mm "${MM_DASHED}" --arg snap "${snapshot}" '
      [.items[] | select(.spec.snapshot==$snap and (.spec.releasePlan | contains($mm) and contains("stage")) and ((.spec.releasePlan | contains("fbc")) or (.spec.releasePlan | contains("index"))))
       | [.status.conditions[]? | select(.type=="Released")][0].status][0] // ""' <<<"${releases}")
    [[ "${status}" == True ]] && ((succeeded += 1))
  done < <(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name | contains("index") and contains($mm)) | .metadata.name' <<<"${apps}" | sort)
  STEP_DETAILS="${succeeded}/${total} index stage releases succeeded"
  ((total > 0 && succeeded == total)) || return "${OCR_RC_BLOCKED}"
}

verify_2_9() {
  local cfg value prs number url
  cfg=$(gh api "repos/openshift-pipelines/hack/contents/config/downstream/releases/${MAJOR_MINOR}.yaml" --jq '.content' | base64 -d)
  value=$(awk '/code-freeze:/ {print $2; exit}' <<<"${cfg}")
  prs=$(gh pr list --repo openshift-pipelines/hack --state all --limit 5 \
    --search "code-freeze ${MAJOR_MINOR} in:title" --json number,url 2>/dev/null || printf '[]')
  number=$(jq -r '.[0].number // empty' <<<"${prs}")
  url=$(jq -r '.[0].url // empty' <<<"${prs}")
  [[ -n "${number}" ]] && STEP_LINKS="hack [#${number}](${url})"
  STEP_DETAILS="code-freeze: ${value:-missing}"
  [[ "${value}" == true ]] || return "${OCR_RC_BLOCKED}"
}

ocr_verify_step() {
  case "$1" in
    2.1) verify_2_1 ;; 2.2) verify_2_2 ;; 2.3) verify_2_3 ;; 2.4) verify_2_4 ;;
    2.5) verify_2_5 ;; 2.6) verify_2_6 ;; 2.7) verify_2_7 ;; 2.8) verify_2_8 ;; 2.9) verify_2_9 ;;
  esac
}

ocr_verify_stage "${1:-}"
