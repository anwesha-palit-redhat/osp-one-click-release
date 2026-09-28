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

successful_release_count() {
  local data=$1 kind=$2 env=$3 exclude=${4:-}
  jq --arg mm "${MM_DASHED}" --arg kind "${kind}" --arg env "${env}" --arg exclude "${exclude}" '
    [.items[] | select(.spec.releasePlan | contains($mm) and contains($kind) and contains($env))
      | select($exclude=="" or (.spec.releasePlan | contains($exclude) | not))
      | select(any(.status.conditions[]?; .type=="Released" and .status=="True"))] | length' <<<"${data}"
}

verify_4_1() {
  ocr_require_konflux || return $?
  local data core failures snapshot
  data=$(releases_json) || return "${OCR_RC_BLOCKED}"
  core=$(successful_release_count "${data}" core stage cdn)
  failures=$(jq --arg mm "${MM_DASHED}" '[.items[] | select(.spec.releasePlan | contains($mm) and contains("stage"))
    | select(any(.status.conditions[]?; .type=="Released" and .status=="False"))] | length' <<<"${data}")
  snapshot=$(jq -r --arg mm "${MM_DASHED}" '[.items[] | select(.spec.releasePlan | contains($mm) and contains("core") and contains("stage") and (contains("cdn")|not))
    | select(any(.status.conditions[]?; .type=="Released" and .status=="True"))][0].spec.snapshot // empty' <<<"${data}")
  printf '%s\n' "${snapshot}" >"${REPORT_BASE}/.state/stage-core-snapshot"
  STEP_DETAILS="core stage succeeded=${core}; failed stage releases=${failures}; snapshot=${snapshot:-missing}"
  ((core > 0 && failures == 0)) || return "${OCR_RC_BLOCKED}"
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
      | select($snapshot=="" or .spec.snapshot==$snapshot)][-1].metadata.name // empty' <<<"${data}")
  STEP_DETAILS="${kind} production release: ${name:-not found}; expected snapshot=${expected_snapshot:-any}; succeeded=${count}"
  ((count > 0)) || return "${OCR_RC_BLOCKED}"
}

verify_4_2() {
  ocr_require_konflux || return $?
  local data stage_snapshot
  data=$(releases_json) || return "${OCR_RC_BLOCKED}"
  stage_snapshot=$(jq -r --arg mm "${MM_DASHED}" '[.items[] | select(.spec.releasePlan|contains($mm) and contains("core") and contains("stage") and (contains("cdn")|not))
    | select(any(.status.conditions[]?; .type=="Released" and .status=="True"))][-1].spec.snapshot // empty' <<<"${data}")
  [[ -n "${stage_snapshot}" ]] || {
    STEP_DETAILS='succeeded core stage snapshot not found'
    return "${OCR_RC_BLOCKED}"
  }
  verify_release core cdn "${stage_snapshot}"
}

verify_4_3() {
  local runs run_url prs number url
  runs=$(gh run list --repo openshift-pipelines/operator --workflow=operator-update-images.yaml --limit 10 \
    --json status,conclusion,createdAt,displayTitle,headBranch,url,event 2>/dev/null || printf '[]')
  run_url=$(jq -r --arg b "${RELEASE_BRANCH}" '[.[] | select(.event=="workflow_dispatch" and .status=="completed" and .conclusion=="success")
    | select((.displayTitle//"")|contains($b) or (.headBranch//"")==$b)][0].url // empty' <<<"${runs}")
  prs=$(gh pr list --repo openshift-pipelines/operator --head "actions/update/operator-update-images-${RELEASE_BRANCH}" \
    --state all --limit 1 --json number,url,state,mergedAt)
  number=$(jq -r '.[0].number // empty' <<<"${prs}")
  url=$(jq -r '.[0].url // empty' <<<"${prs}")
  local pr_state
  pr_state=$(jq -r '.[0].state // empty' <<<"${prs}")
  STEP_DETAILS="production workflow=$([[ -n "${run_url}" ]] && echo success || echo missing); CSV PR=${number:-not found} ${pr_state}"
  [[ -n "${run_url}" && -n "${number}" ]] || return "${OCR_RC_BLOCKED}"
  STEP_LINKS="[operator-update-images](${run_url}), operator [#${number}](${url})"
}

verify_4_4() {
  local prs number url diff
  prs=$(gh pr list --repo openshift-pipelines/operator --head "actions/update/operator-update-images-${RELEASE_BRANCH}" \
    --state merged --limit 1 --json number,url,mergedAt)
  number=$(jq -r '.[0].number // empty' <<<"${prs}")
  url=$(jq -r '.[0].url // empty' <<<"${prs}")
  [[ -n "${number}" ]] || {
    STEP_DETAILS='production CSV PR is not merged'
    return "${OCR_RC_BLOCKED}"
  }
  diff=$(gh pr diff --repo openshift-pipelines/operator "${number}" 2>/dev/null || true)
  if grep -E '^\+.*image:.*(stage|staging)' <<<"${diff}" >/dev/null; then
    STEP_DETAILS="merged CSV PR #${number} contains staging registry references"
    return "${OCR_RC_BLOCKED}"
  fi
  STEP_DETAILS="production CSV PR #${number} merged; no staging image additions"
  STEP_LINKS="operator [#${number}](${url})"
}

automated_gap_ok() {
  local rev=$1 head=$2 commits
  [[ "${rev}" == "${head}" ]] && return
  commits=$(gh api "repos/openshift-pipelines/operator/compare/${rev}...${head}" --jq '.commits[].commit.message | split("\n")[0]' 2>/dev/null || return 1)
  [[ -n "${commits}" ]] && ! grep -Eivq '^(chore|build|Merge|\[bot:|One Click Release|.*catalog|.*nudge|.*image)' <<<"${commits}"
}

verify_4_5() {
  ocr_require_konflux || return $?
  local apps app snapshot rev head created
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
  automated_gap_ok "${rev}" "${head}" || return "${OCR_RC_BLOCKED}"
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
  local runs run_url apps app snapshot rev head checked=0 stale=0
  runs=$(gh run list --repo openshift-pipelines/operator --workflow=render-olm-catalog.yaml --limit 10 \
    --json status,conclusion,createdAt,displayTitle,headBranch,url,event 2>/dev/null || printf '[]')
  run_url=$(jq -r '[.[] | select(.event=="workflow_dispatch" and .status=="completed" and .conclusion=="success")][0].url // empty' <<<"${runs}")
  [[ -n "${run_url}" ]] || {
    STEP_DETAILS='successful production render dispatch not found'
    return "${OCR_RC_BLOCKED}"
  }
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json)
  head=$(git ls-remote https://github.com/openshift-pipelines/operator.git "refs/heads/${RELEASE_BRANCH}" | awk '{print $1}')
  while IFS= read -r app; do
    snapshot=$(ocr_latest_snapshot "${app}")
    [[ -n "${snapshot}" ]] || continue
    ((checked += 1))
    rev=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components[0].source.git.revision}')
    [[ "${rev}" == "${head}" ]] || ((stale += 1))
  done < <(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name | contains("index") and contains($mm)) | .metadata.name' <<<"${apps}" | sort)
  STEP_DETAILS="production render succeeded; ${checked} index snapshots checked; ${stale} stale"
  STEP_LINKS="[render-olm-catalog](${run_url})"
  ((checked > 0 && stale == 0)) || return "${OCR_RC_BLOCKED}"
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
    status=$(jq -r --arg snap "${snapshot}" '[.items[] | select(.spec.snapshot==$snap and (.spec.releasePlan|contains("prod")))
      | select((.spec.releasePlan|contains("fbc")) or (.spec.releasePlan|contains("index")))
      | [.status.conditions[]? | select(.type=="Released")][0].status][0] // ""' <<<"${releases}")
    [[ "${status}" == True ]] && ((succeeded += 1))
  done < <(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name | contains("index") and contains($mm)) | .metadata.name' <<<"${apps}" | sort)
  STEP_DETAILS="${succeeded}/${total} index production releases succeeded"
  ((total > 0 && succeeded == total)) || return "${OCR_RC_BLOCKED}"
}

verify_4_9() {
  ocr_require_konflux || return $?
  local snapshot
  snapshot=$(releases_json | jq -r --arg mm "${MM_DASHED}" '[.items[] | select(.spec.releasePlan|contains($mm) and contains("core") and contains("prod") and (contains("cdn")|not))
    | select(any(.status.conditions[]?; .type=="Released" and .status=="True"))][-1].spec.snapshot // empty')
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

ocr_init_context "${1:-}"
ocr_confirm_production
ocr_verify_stage "${1:-}"
