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
STAGE_STEPS=(2.1 2.2 2.3 2.4 2.5 2.6 2.7 2.8 2.9 2.10 2.11 2.12 2.13)

find_app() {
  local kind=$1
  ocr_oc_get applications.appstudio.redhat.com -o json | jq -r --arg mm "${MM_DASHED}" --arg kind "${kind}" \
    '.items[] | select(.metadata.name | contains($kind) and contains($mm)) | .metadata.name' | head -1
}

ocr_step_title() {
  case "$1" in
    2.1) printf '%s' 'Ensure code freeze inactive' ;;
    2.2) printf '%s' 'Trigger update-sources' ;;
    2.3) printf '%s' 'Process release PRs' ;;
    2.4) printf '%s' 'Code freeze' ;;
    2.5) printf '%s' 'Digest verification' ;;
    2.6) printf '%s' 'Wait for core snapshot' ;;
    2.7) printf '%s' 'Process nudge PRs' ;;
    2.8) printf '%s' 'Gate: snapshot + digests' ;;
    2.9) printf '%s' 'Core stage release' ;;
    2.10) printf '%s' 'OLM catalog render' ;;
    2.11) printf '%s' 'Wait for FBC build' ;;
    2.12) printf '%s' 'Bundle stage release' ;;
    2.13) printf '%s' 'Index stage releases' ;;
  esac
}

release_status_json() {
  ocr_oc_get releases -o json 2>/dev/null
}

verify_2_3() {
  local prs count error
  prs=$(gh search prs --owner openshift-pipelines --base "${RELEASE_BRANCH}" --state open \
    --json repository,url,title,labels 'label:hack,upstream,automated' 2>"${REPORT_BASE}/.state/gh-error") || {
    error=$(<"${REPORT_BASE}/.state/gh-error")
    ocr_fail_with_error 'unable to query release PRs' "${error}"
    return $?
  }
  count=$(jq length <<<"${prs}")
  STEP_DETAILS="${count} open release PRs"
  if ((count > 0)); then
    STEP_LINKS=$(jq -r 'map("\(.repository.nameWithOwner | split("/")[-1]) [#\(.url | split("/")[-1])](\(.url))") | join(", ")' <<<"${prs}")
    return "${OCR_RC_BLOCKED}"
  fi
}

verify_2_6() {
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
  : >"${REPORT_BASE}/.state/core-snapshot-comparison.tsv"
  while IFS='|' read -r repo revs; do
    [[ -n "${repo}" ]] || continue
    head=$(git ls-remote "https://github.com/${repo}.git" "refs/heads/${RELEASE_BRANCH}" | awk '{print $1}')
    if [[ "${revs}" == *,* || "${revs}" != "${head}" ]]; then
      stale+=" ${repo}"
    fi
    printf '%s\t%s\t%s\t%s\n' "${repo}" "${revs}" "${head}" "$([[ "${revs}" != *,* && "${revs}" == "${head}" ]] && echo CURRENT || echo STALE)" >>"${REPORT_BASE}/.state/core-snapshot-comparison.tsv"
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

verify_2_9() {
  ocr_require_konflux || return $?
  verify_release_kind core stage cdn
}

verify_2_7() {
  local prs count error
  prs=$(gh search prs --owner openshift-pipelines --base "${RELEASE_BRANCH}" --state open \
    --json repository,url,title,labels 'label:konflux-nudge' 2>"${REPORT_BASE}/.state/gh-error") || {
    error=$(<"${REPORT_BASE}/.state/gh-error")
    ocr_fail_with_error 'unable to query nudge PRs' "${error}"
    return $?
  }
  count=$(jq length <<<"${prs}")
  STEP_DETAILS="${count} open nudge PRs"
  if ((count > 0)); then
    STEP_LINKS=$(jq -r 'map("operator [#\(.url | split("/")[-1])](\(.url))") | join(", ")' <<<"${prs}")
    return "${OCR_RC_BLOCKED}"
  fi
}

verify_2_10() {
  local csv runs run_url state catalogs diff registry_ok=true error

  # Find the most recent commit on the release branch that modified the OLM catalog
  local catalog_sha catalog_pr_json
  catalog_sha=$(gh api "repos/openshift-pipelines/operator/commits?sha=${RELEASE_BRANCH}&path=.konflux/olm-catalog&per_page=1" --jq '.[0].sha // empty' 2>/dev/null)

  if [[ -n "${catalog_sha}" ]]; then
    csv=$(gh api "repos/openshift-pipelines/operator/commits/${catalog_sha}/pulls" \
      --jq '[.[] | select(.merged_at != null) | {number, url: .html_url, mergedAt: .merged_at}]' 2>/dev/null)
  fi

  # Fallback to old method if commits API returned nothing
  if [[ -z "${csv}" || "$(jq length <<<"${csv}" 2>/dev/null)" -eq 0 ]]; then
    csv=$(gh pr list --repo openshift-pipelines/operator \
      --head "actions/update/operator-update-images-${RELEASE_BRANCH}" --state merged --limit 1 \
      --json number,url,mergedAt)
  fi
  runs=$(gh run list --repo openshift-pipelines/operator --workflow=render-olm-catalog.yaml --limit 10 \
    --json status,conclusion,createdAt,displayTitle,headBranch,url,event 2>"${REPORT_BASE}/.state/gh-error") || {
    error=$(<"${REPORT_BASE}/.state/gh-error")
    ocr_fail_with_error 'unable to query staging render runs' "${error}"
    return $?
  }
  local run_created run_status
  run_url=$(jq -r --arg b "${RELEASE_BRANCH}" '[.[] | select(.event=="workflow_dispatch" and .status=="completed" and .conclusion=="success") | select((.displayTitle//"")|contains($b))][0].url // [.[] | select(.event=="workflow_dispatch" and .status=="completed" and .conclusion=="success")][0].url // empty' <<<"${runs}")
  run_created=$(jq -r --arg url "${run_url}" '.[] | select(.url==$url) | .createdAt' <<<"${runs}" | head -1)
  run_status=$(jq -r --arg url "${run_url}" '.[] | select(.url==$url) | "\(.status)/\(.conclusion)"' <<<"${runs}" | head -1)
  state=$(jq -r '.[0].number // empty' <<<"${csv}")
  if [[ -n "${state}" ]]; then
    diff=$(gh pr diff --repo openshift-pipelines/operator "${state}" 2>"${REPORT_BASE}/.state/gh-error") || {
      error=$(<"${REPORT_BASE}/.state/gh-error")
      ocr_fail_with_error 'unable to inspect staging CSV PR diff' "${error}"
      return $?
    }
    grep -E '^\+.*image:.*(devel|staging)' <<<"${diff}" | grep -vE 'quay\.io/redhat-user-workloads' >/dev/null && registry_ok=false
  fi
  catalogs=$(gh api "repos/openshift-pipelines/operator/commits?sha=${RELEASE_BRANCH}&per_page=10" \
    --jq '[.[] | select(.commit.message | test("catalog|render|OCP catalog"; "i"))] | length' 2>"${REPORT_BASE}/.state/gh-error") || {
    error=$(<"${REPORT_BASE}/.state/gh-error")
    ocr_fail_with_error 'unable to verify catalog commits' "${error}"
    return $?
  }
  STEP_DETAILS="CSV PR merged=${state:-no}; staging registries=${registry_ok}; staging render=${run_status:-missing} at $(ocr_abs_time "${run_created}"); catalog commits=${catalogs}"
  [[ -n "${state}" && "${registry_ok}" == true && -n "${run_url}" && ${catalogs} -gt 0 ]] || return "${OCR_RC_BLOCKED}"
  STEP_LINKS="operator [#${state}]($(jq -r '.[0].url' <<<"${csv}")), [render-olm-catalog](${run_url})"
}

verify_2_11() {
  ocr_require_konflux || return $?
  local apps operator_head bundle snapshot rev stale='' checked=0 app
  : >"${REPORT_BASE}/.state/fbc-snapshot-comparison.tsv"
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json 2>/dev/null) || return "${OCR_RC_BLOCKED}"
  operator_head=$(git ls-remote https://github.com/openshift-pipelines/operator.git "refs/heads/${RELEASE_BRANCH}" | awk '{print $1}')
  bundle=$(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name | contains("bundle") and contains($mm)) | .metadata.name' <<<"${apps}" | head -1)
  snapshot=$(ocr_latest_snapshot "${bundle}")
  [[ -n "${snapshot}" ]] || {
    STEP_DETAILS='bundle snapshot not found'
    return "${OCR_RC_BLOCKED}"
  }
  rev=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components[0].source.git.revision}' 2>/dev/null)
  local bundle_status
  if ocr_operator_revision_is_generated "${rev}" "${operator_head}"; then
    bundle_status="CURRENT"
  else
    stale+=" bundle"
    bundle_status="GENERATED GAP/STALE"
  fi
  printf '%s\t%s\t%s\t%s\n' "${bundle}" "${snapshot}" "${rev}" "${bundle_status}" \
    >>"${REPORT_BASE}/.state/fbc-snapshot-comparison.tsv"
  while IFS= read -r app; do
    [[ -n "${app}" ]] || continue
    snapshot=$(ocr_latest_snapshot "${app}")
    [[ -z "${snapshot}" ]] && continue
    ((checked += 1))
    rev=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components[0].source.git.revision}' 2>/dev/null)
    local idx_status
    if ocr_operator_revision_is_generated "${rev}" "${operator_head}"; then
      idx_status="CURRENT"
    else
      stale+=" ${app}"
      idx_status="GENERATED GAP/STALE"
    fi
    printf '%s\t%s\t%s\t%s\n' "${app}" "${snapshot}" "${rev}" "${idx_status}" \
      >>"${REPORT_BASE}/.state/fbc-snapshot-comparison.tsv"
  done < <(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name | contains("index") and contains($mm)) | .metadata.name' <<<"${apps}" | sort)
  STEP_DETAILS="bundle snapshot present; ${checked} index snapshots checked"
  if [[ -n "${stale}" ]]; then
    STEP_DETAILS+="; stale:${stale}"
    return "${OCR_RC_BLOCKED}"
  fi
}

verify_2_12() {
  ocr_require_konflux || return $?
  verify_release_kind bundle stage
}

verify_2_13() {
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
      if any(.items[]; .spec.snapshot==$snap and (.spec.releasePlan | contains($mm) and contains("stage")) and
        ((.spec.releasePlan | contains("fbc")) or (.spec.releasePlan | contains("index"))) and
        any(.status.conditions[]?; .type=="Released" and .status=="True")) then "True" else "" end' <<<"${releases}")
    [[ "${status}" == True ]] && ((succeeded += 1))
  done < <(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name | contains("index") and contains($mm)) | .metadata.name' <<<"${apps}" | sort)
  STEP_DETAILS="${succeeded}/${total} index stage releases succeeded"
  ((total > 0 && succeeded == total)) || return "${OCR_RC_BLOCKED}"
}

verify_2_4() {
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

verify_2_5() {
  ocr_require_konflux || return "${OCR_RC_SKIP}"

  local core_app snapshot components_json project_yaml
  core_app=$(find_app core)
  [[ -n "${core_app}" ]] || {
    printf 'Core application not found.\n' >&2
    return "${OCR_RC_BLOCKED}"
  }

  # Get the latest core snapshot
  snapshot=$(ocr_latest_snapshot "${core_app}")
  [[ -n "${snapshot}" ]] || {
    printf 'No core snapshot found.\n' >&2
    return "${OCR_RC_BLOCKED}"
  }

  # Extract components from the snapshot
  components_json=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components}')

  # Get project.yaml from operator release branch
  project_yaml=$(gh api "repos/openshift-pipelines/operator/contents/project.yaml?ref=${RELEASE_BRANCH}" \
    --jq '.content' 2>/dev/null | base64 -d) || {
    printf 'Unable to fetch project.yaml from operator %s branch.\n' "${RELEASE_BRANCH}" >&2
    return "${OCR_RC_BLOCKED}"
  }

  printf 'Snapshot: %s\n' "${snapshot}"

  # Compare digests using Python
  local mismatch_count
  mismatch_count=$(python3 -c "
import json, sys, yaml

components = json.loads(sys.argv[1])
project = yaml.safe_load(sys.argv[2])

# Build map from image base path -> digest from project.yaml
proj_images = {}
for entry in project.get('images', []):
    val = entry.get('value', '')
    if '@sha256:' in val:
        base, digest = val.rsplit('@', 1)
        proj_images[base] = digest

# Compare snapshot containerImage digests against project.yaml
mismatches = 0
matched = 0
for c in components:
    image = c.get('containerImage', '')
    name = c.get('name', '')
    if '@sha256:' not in image:
        continue
    base, digest = image.rsplit('@', 1)
    short_name = base.split('/')[-1]
    if base in proj_images:
        if digest == proj_images[base]:
            print(f'MATCH\t{short_name}\t{digest[:19]}', file=sys.stderr)
            matched += 1
        else:
            print(f'MISMATCH\t{short_name}\tsnap={digest[:19]}\tproj={proj_images[base][:19]}', file=sys.stderr)
            mismatches += 1
    else:
        print(f'MISSING\t{short_name}\t(not in project.yaml)', file=sys.stderr)
        mismatches += 1

print(f'Checked {matched + mismatches} components: {matched} match, {mismatches} mismatch/missing', file=sys.stderr)
print(mismatches)
" "${components_json}" "${project_yaml}")

  if ((mismatch_count > 0)); then
    printf '%d component(s) have digest mismatches with project.yaml.\n' "${mismatch_count}" >&2
    return "${OCR_RC_BLOCKED}"
  fi

  printf 'All component digests in snapshot match project.yaml.\n'
  return 0
}

verify_2_1() {
  local cfg value
  cfg=$(gh api "repos/openshift-pipelines/hack/contents/config/downstream/releases/${MAJOR_MINOR}.yaml?ref=main" --jq '.content' | base64 -d)
  value=$(grep -E '^\s*code-freeze:' <<<"${cfg}" | awk '{print $2}' | head -1)
  if [[ "${value}" == "true" ]]; then
    STEP_DETAILS="code-freeze: true — build cannot proceed"
    return "${OCR_RC_BLOCKED}"
  fi
  STEP_DETAILS="code-freeze: ${value:-false}"
}

verify_2_2() {
  if ocr_mutation_done "trigger-update-sources"; then
    STEP_DETAILS="trigger-update-sources already dispatched"
    return 0
  fi
  STEP_DETAILS="trigger-update-sources not yet dispatched"
  return "${OCR_RC_BLOCKED}"
}

verify_2_8() {
  local snapshot_rc=0 digest_rc=0 failed=()
  verify_2_6 || snapshot_rc=$?
  verify_2_5 || digest_rc=$?
  if ((snapshot_rc != 0)); then
    failed+=("snapshot check (step 2.6)")
  fi
  if ((digest_rc != 0)); then
    failed+=("digest check (step 2.5)")
  fi
  if ((${#failed[@]} > 0)); then
    STEP_DETAILS="gate failed: $(IFS=', '; echo "${failed[*]}")"
    return "${OCR_RC_BLOCKED}"
  fi
  STEP_DETAILS="snapshot and digest checks both passed"
}

ocr_verify_step() {
  case "$1" in
    2.1) verify_2_1 ;; 2.2) verify_2_2 ;; 2.3) verify_2_3 ;; 2.4) verify_2_4 ;;
    2.5) verify_2_5 ;; 2.6) verify_2_6 ;; 2.7) verify_2_7 ;; 2.8) verify_2_8 ;;
    2.9) verify_2_9 ;; 2.10) verify_2_10 ;; 2.11) verify_2_11 ;; 2.12) verify_2_12 ;;
    2.13) verify_2_13 ;;
  esac
}

ocr_report_stage_details() {
  local file
  file="${REPORT_BASE}/.state/core-snapshot-comparison.tsv"
  if [[ -s "${file}" ]]; then
    printf '\n## Core Component Revision Comparison\n\n| Repository | Snapshot Revision(s) | Branch HEAD | Status |\n|------------|----------------------|-------------|--------|\n'
    while IFS=$'\t' read -r repo revisions head status; do printf '| %s | %s | %s | %s |\n' "${repo}" "${revisions}" "${head}" "${status}"; done <"${file}"
  fi
  file="${REPORT_BASE}/.state/fbc-snapshot-comparison.tsv"
  if [[ -s "${file}" ]]; then
    printf '\n## FBC Snapshot Comparison\n\n| Application | Snapshot | Revision | Status |\n|-------------|----------|----------|--------|\n'
    while IFS=$'\t' read -r app snapshot revision status; do printf '| %s | %s | %s | %s |\n' "${app}" "${snapshot}" "${revision}" "${status}"; done <"${file}"
  fi
}

ocr_verify_stage "${1:-}"
