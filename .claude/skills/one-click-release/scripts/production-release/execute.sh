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
STAGE_STEPS=(4.1 4.2 4.3 4.4 4.5 4.6 4.7 4.8 4.9)

ocr_describe_action() {
  case "$1" in
    4.1) printf 'Stage releases are prerequisites; repair them in the build stage.\n' ;;
    4.2) printf 'Create the core production Release CR using the succeeded stage core snapshot.\n' ;;
    4.3) printf 'Dispatch operator-update-images with environment=production.\n' ;;
    4.4) printf 'Validate and merge the production CSV PR.\n' ;;
    4.5) printf 'Trigger a production bundle rebuild.\n' ;;
    4.6) printf 'Create the bundle production Release CR.\n' ;;
    4.7) printf 'Wait for devel renders, dispatch the production catalog render, and wait for it.\n' ;;
    4.8) printf 'Create all index production Release CRs.\n' ;;
    4.9) printf 'Create the CDN production Release CR using the succeeded core production snapshot.\n' ;;
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
  ocr_oc_get releases -o json | jq -r --arg mm "${MM_DASHED}" --arg kind "${kind}" --arg env "${env}" --arg exclude "${exclude}" '
    [.items[] | select(.spec.releasePlan | contains($mm) and contains($kind) and contains($env))
      | select($exclude=="" or (.spec.releasePlan|contains($exclude)|not))
      | select(any(.status.conditions[]?; .type=="Released" and .status=="True"))][-1].spec.snapshot // empty'
}

existing_release_for_snapshot() {
  local rp=$1 snapshot=$2
  ocr_oc_get releases -o json | jq -r --arg rp "${rp}" --arg snapshot "${snapshot}" '
    [.items[] | select(.spec.releasePlan==$rp and .spec.snapshot==$snapshot)
      | {name:.metadata.name,status:([.status.conditions[]? | select(.type=="Released")][0].status // "Unknown")}][-1]
      | if . == null then empty else "\(.name)|\(.status)" end'
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
  local kind=$1 snapshot=${2:-} app rp path existing existing_name existing_status
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
  existing=$(existing_release_for_snapshot "${rp}" "${snapshot}")
  if [[ -n "${existing}" ]]; then
    existing_name=${existing%%|*}
    existing_status=${existing#*|}
    printf 'Release %s already exists for this snapshot (Released=%s); not creating a duplicate.\n' "${existing_name}" "${existing_status}" >&2
    [[ "${existing_status}" == True ]] && return 0 || return 2
  fi
  path="${REPORT_BASE}/manifest/prod/release-${VERSION}-${kind}-prod.yaml"
  ocr_write_release_manifest "${path}" "${app}" "${rp}" "${snapshot}"
  ocr_create_release_manifest "${path}"
}

execute_4_1() {
  printf 'No automatic mutation is defined for stage-release prerequisites. Return to build steps 2.3, 2.7, and 2.8.\n' >&2
  return 2
}

execute_4_2() {
  ocr_require_konflux || return 2
  local snapshot
  snapshot=$(successful_snapshot core stage cdn)
  [[ -n "${snapshot}" ]] || {
    printf 'No succeeded core stage snapshot found.\n' >&2
    return 2
  }
  create_prod_release core "${snapshot}"
}

execute_4_3() {
  local runs in_progress successful id
  runs=$(gh run list --repo openshift-pipelines/operator --workflow=operator-update-images.yaml --limit 10 \
    --json databaseId,status,conclusion,event,displayTitle,headBranch)
  in_progress=$(jq -r --arg b "${RELEASE_BRANCH}" '.[] | select(.event=="workflow_dispatch" and (.status=="queued" or .status=="in_progress"))
    | select((.displayTitle//"")|contains($b) or (.headBranch//"")==$b) | .databaseId' <<<"${runs}")
  if [[ -n "${in_progress}" ]]; then
    while IFS= read -r id; do gh run watch --repo openshift-pipelines/operator "${id}"; done <<<"${in_progress}"
    return
  fi
  successful=$(jq -r --arg b "${RELEASE_BRANCH}" '[.[] | select(.event=="workflow_dispatch" and .status=="completed" and .conclusion=="success")
    | select((.displayTitle//"")|contains($b) or (.headBranch//"")==$b)][0].databaseId // empty' <<<"${runs}")
  if [[ -n "${successful}" ]]; then
    printf 'A successful production dispatch already exists; wait for its CSV PR instead of dispatching again.\n' >&2
    return 2
  fi
  gh workflow run operator-update-images.yaml --repo openshift-pipelines/operator \
    --ref "${RELEASE_BRANCH}" -f environment=production
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
  local pr url diff
  pr=$(gh pr list --repo openshift-pipelines/operator --head "actions/update/operator-update-images-${RELEASE_BRANCH}" \
    --state open --limit 1 --json number,url)
  url=$(jq -r '.[0].url // empty' <<<"${pr}")
  [[ -n "${url}" ]] || {
    printf 'Production CSV PR not found.\n' >&2
    return 2
  }
  diff=$(gh pr diff "${url}")
  if grep -E '^\+.*image:.*(stage|staging)' <<<"${diff}" >/dev/null; then
    printf 'Production CSV PR contains staging references; refusing to merge.\n' >&2
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

execute_4_5() { push_operator_placeholder .konflux/olm-catalog/bundle/.placeholder 'One Click Release: rebuild bundle for production'; }

execute_4_6() {
  ocr_require_konflux || return 2
  local core
  core=$(successful_snapshot core prod cdn)
  [[ -n "${core}" ]] || {
    printf 'Core production release has not succeeded.\n' >&2
    return 2
  }
  create_prod_release bundle
}

wait_in_progress() {
  local id
  while IFS= read -r id; do [[ -n "${id}" ]] && gh run watch --repo openshift-pipelines/operator "${id}"; done \
    < <(gh run list --repo openshift-pipelines/operator --workflow=render-olm-catalog.yaml --limit 5 \
      --json databaseId,status --jq '.[] | select(.status=="in_progress" or .status=="queued") | .databaseId')
}

execute_4_7() {
  ocr_require_konflux || return 2
  local id apps head app snapshot rev stale=false
  wait_in_progress
  gh workflow run render-olm-catalog.yaml --repo openshift-pipelines/operator \
    -f "branch=${RELEASE_BRANCH}" -f environment=production
  id=$(gh run list --repo openshift-pipelines/operator --workflow=render-olm-catalog.yaml --limit 5 \
    --json databaseId,event --jq '[.[] | select(.event=="workflow_dispatch")][0].databaseId // empty')
  [[ -n "${id}" ]] && gh run watch --repo openshift-pipelines/operator "${id}"
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json)
  head=$(git ls-remote https://github.com/openshift-pipelines/operator.git "refs/heads/${RELEASE_BRANCH}" | awk '{print $1}')
  while IFS= read -r app; do
    snapshot=$(ocr_latest_snapshot "${app}")
    [[ -n "${snapshot}" ]] || continue
    rev=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components[0].source.git.revision}')
    [[ "${rev}" == "${head}" ]] || stale=true
  done < <(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name|contains("index") and contains($mm)) | .metadata.name' <<<"${apps}")
  if [[ "${stale}" == true ]]; then
    push_operator_placeholder .konflux/olm-catalog/index/.placeholder 'One Click Release: rebuild index images for production'
  fi
}

execute_4_8() {
  ocr_require_konflux || return 2
  local bundle apps app snapshot rp ocp path made=0 existing existing_name existing_status
  bundle=$(successful_snapshot bundle prod)
  [[ -n "${bundle}" ]] || {
    printf 'Bundle production release has not succeeded.\n' >&2
    return 2
  }
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json)
  while IFS= read -r app; do
    snapshot=$(ocr_latest_snapshot "${app}")
    [[ -n "${snapshot}" ]] || continue
    rp=$(find_prod_rp "${app}")
    [[ -n "${rp}" ]] || {
      printf 'No production release plan for %s.\n' "${app}" >&2
      return 2
    }
    existing=$(existing_release_for_snapshot "${rp}" "${snapshot}")
    if [[ -n "${existing}" ]]; then
      existing_name=${existing%%|*}
      existing_status=${existing#*|}
      printf 'Release %s already exists for %s (Released=%s); skipping duplicate creation.\n' "${existing_name}" "${app}" "${existing_status}"
      if [[ "${existing_status}" != False ]]; then
        ((made += 1))
        continue
      fi
    fi
    ocp=${app#openshift-pipelines-index-}
    ocp=${ocp%-"${MM_DASHED}"}
    ocp=${ocp/-/.}
    path="${REPORT_BASE}/manifest/prod/release-${VERSION}-index-${ocp}-prod.yaml"
    ocr_write_release_manifest "${path}" "${app}" "${rp}" "${snapshot}"
    ocr_create_release_manifest "${path}"
    ((made += 1))
  done < <(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name|contains("index") and contains($mm)) | .metadata.name' <<<"${apps}" | sort)
  ((made > 0)) || {
    printf 'No index applications with snapshots found.\n' >&2
    return 2
  }
}

execute_4_9() {
  ocr_require_konflux || return 2
  local snapshot path rp app release_name existing existing_name existing_status
  snapshot=$(successful_snapshot core prod cdn)
  [[ -n "${snapshot}" ]] || {
    printf 'No succeeded core production snapshot found.\n' >&2
    return 2
  }
  app="openshift-pipelines-core-${MM_DASHED}"
  rp="openshift-pipelines-${MM_DASHED}-core-cdn-prod"
  existing=$(existing_release_for_snapshot "${rp}" "${snapshot}")
  if [[ -n "${existing}" ]]; then
    existing_name=${existing%%|*}
    existing_status=${existing#*|}
    printf 'CDN release %s already exists for this snapshot (Released=%s); not creating a duplicate.\n' "${existing_name}" "${existing_status}" >&2
    [[ "${existing_status}" == True ]] && return 0 || return 2
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

ocr_execute_step() {
  case "$1" in
    4.1) execute_4_1 ;; 4.2) execute_4_2 ;; 4.3) execute_4_3 ;; 4.4) execute_4_4 ;;
    4.5) execute_4_5 ;; 4.6) execute_4_6 ;; 4.7) execute_4_7 ;; 4.8) execute_4_8 ;; 4.9) execute_4_9 ;;
  esac
}

ocr_execute_stage "${1:-}" "${2:-}"
