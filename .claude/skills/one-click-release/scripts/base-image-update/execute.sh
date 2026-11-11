#!/usr/bin/env bash
# Update Konflux Dockerfile base images and open one pull request per component.
#
# Usage:
#   execute.sh <X.Y|X.Y.Z> [--component NAME[,NAME...]] [--yes] [--rewrite-images]
#
# Example:
#   execute.sh 1.24
#   execute.sh 1.24 --component operator --yes
#
# Uses the same component list, release branch, minor image map, and catalog
# digests as verify.sh. For each downstream repository it checks out
# release-v<minor>.x, updates mapped ARG defaults under .konflux/dockerfiles,
# and opens a pull request labeled lgtm, approved, and automated. An existing
# base-image-update/<minor> branch is force-pushed so its open pull request
# receives the new digests. Pull requests are not merged.
#
# Interactive runs must type: update base images <minor>
# Non-interactive runs must pass --yes.
# If a Dockerfile image name differs from the map, the script asks before
# rewriting it. --yes does not answer that question. --rewrite-images does.
#
# Exit 0 when every component is up to date or has a pull request.
# Exit 1 when any component could not be updated.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
execute.sh — open pull requests that refresh Konflux base image digests

USAGE
  execute.sh <X.Y|X.Y.Z> [--component NAME[,NAME...]] [--yes] [--rewrite-images]

The version selects the minor release. 1.24 and 1.24.2 both use the 1.24
component list, the 1.24 base image map, and branch release-v1.24.x.

OPTIONS
  --component NAME   Update one component, or a comma-separated list.
                     Repeat the flag to add more components.
  --yes              Create pull requests without the interactive approval phrase.
                     This does not approve rewriting a different image name.
  --rewrite-images   Rewrite Dockerfile image names that differ from the map
                     without asking. Digest-only updates always proceed.

GITHUB_USER and GITHUB_EMAIL are required. Pull requests target
release-v<minor>.x, are labeled lgtm, approved, and automated, and are not
merged. When base-image-update/<minor> already exists and cannot be
fast-forwarded, that branch is force-pushed and the open pull request is reused.
EOF
}

biu_confirm_execute() {
  local expected="update base images ${MAJOR_MINOR}" answer=""
  [[ "${BIU_YES}" == true ]] && return 0
  printf '%sAbout to open pull requests.%s\n' "${OCR_YELLOW}${OCR_BOLD}" "${OCR_RESET}" >&2
  printf 'Minor %s, branch %s, %s component(s) in %s.\n' \
    "${MAJOR_MINOR}" "${RELEASE_BRANCH}" "${#BIU_SELECTED[@]}" "${BIU_ORG}" >&2
  printf '%s\n' "Pull requests are created and left open." >&2
  if [[ ! -t 0 ]]; then
    printf 'Re-run with --yes to approve: %s\n' "${expected}" >&2
    return 1
  fi
  printf 'Type exactly: %s%s%s\n> ' "${OCR_WHITE}" "${expected}" "${OCR_RESET}" >&2
  IFS= read -r answer || true
  if [[ "${answer}" != "${expected}" ]]; then
    printf '%s\n' "Approval not granted; no repositories were modified." >&2
    return 1
  fi
}

biu_collect_image_mismatches() {
  local component=$1 dest=$2 outfile=$3
  python3 "${BIU_PY}" image-mismatches \
    --map "${BIU_IMAGE_MAP}" \
    --minor "${MAJOR_MINOR}" \
    --digests "${BIU_DIGESTS}" \
    --org "${BIU_ORG}" \
    --root "${dest}" \
    --component "${component}" >"${outfile}"
}

biu_print_image_mismatches() {
  local component=$1 file=$2
  local count dockerfile line arg current_repo mapped_repo _current _desired
  count=$(wc -l <"${file}" | tr -d '[:space:]')
  printf '%sImage name mismatch%s between base-image-map.json and the Dockerfiles in %s (%s ARG line(s)).\n' \
    "${OCR_YELLOW}${OCR_BOLD}" "${OCR_RESET}" "${component}" "${count}" >&2
  while IFS=$'\t' read -r dockerfile line arg current_repo mapped_repo _current _desired; do
    [[ -n "${arg}" ]] || continue
    printf '  %s:%s %s\n' "${dockerfile}" "${line}" "${arg}" >&2
    printf '    dockerfile: %s\n' "${current_repo}" >&2
    printf '    map:        %s\n' "${mapped_repo}" >&2
  done <"${file}"
}

biu_decide_image_rewrite() {
  local component=$1 dest=$2
  local file="${BIU_WORK}/image-mismatches-${component}.tsv"
  local answer="" answer_lc=""
  biu_collect_image_mismatches "${component}" "${dest}" "${file}"
  if [[ ! -s "${file}" ]]; then
    return 0
  fi
  biu_print_image_mismatches "${component}" "${file}"
  if [[ "${BIU_REWRITE_IMAGES}" == yes ]]; then
    if [[ "${BIU_REWRITE_FROM_CLI:-false}" == true ]]; then
      printf '%s\n' "Rewriting these image names because --rewrite-images was set." >&2
    else
      printf '%s\n' "Rewriting these image names, as chosen earlier in this run." >&2
    fi
    return 0
  fi
  if [[ "${BIU_REWRITE_IMAGES}" == no ]]; then
    printf '%s\n' "Leaving these image names unchanged, as chosen earlier in this run." >&2
    return 0
  fi
  if [[ ! -t 0 ]]; then
    printf '%s\n' "No terminal is available, so these image names will be left unchanged. Re-run execute.sh with --rewrite-images to rewrite them." >&2
    BIU_REWRITE_IMAGES=no
    return 0
  fi
  printf '%s\n' "Digest-only updates still proceed either way." >&2
  printf 'Type yes to rewrite these image names for this run, or press Enter to leave them unchanged.\n> ' >&2
  IFS= read -r answer || true
  answer_lc=$(printf '%s' "${answer}" | tr '[:upper:]' '[:lower:]')
  if [[ "${answer_lc}" == yes ]]; then
    BIU_REWRITE_IMAGES=yes
    printf '%s\n' "Image names will be rewritten to the mapped repositories." >&2
  else
    BIU_REWRITE_IMAGES=no
    printf '%s\n' "Image names will be left unchanged." >&2
  fi
}

biu_unexpected_paths() {
  local dest=$1 line path
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    path=${line:3}
    [[ "${path}" == .konflux/dockerfiles/* ]] || return 0
  done < <(git -C "${dest}" status --porcelain --untracked-files=all)
  return 1
}

biu_add_pr_labels() {
  local repo=$1 url=$2 log rc=0
  log=$(gh pr edit --repo "${repo}" "${url}" --add-label lgtm,approved,automated 2>&1) || rc=$?
  if [[ ${rc} -ne 0 ]]; then
    printf 'WARNING: could not add labels lgtm, approved, automated to %s\n%s\n' \
      "${url}" "$(ocr_redact "${log}")" >&2
    return 1
  fi
}

biu_publish() {
  local component=$1 dest=$2
  local full="${BIU_ORG}/${component}"
  local branch="base-image-update/${MAJOR_MINOR}"
  local title="[bot:${MAJOR_MINOR}] Update base image digests"
  local commit_body pushed_branch base_sha commit parent log rc path bad detail url body_file err_file
  local -a changed=()

  if git -C "${dest}" diff --quiet -- .konflux/dockerfiles; then
    biu_result "${component}" "UP TO DATE" "" ""
    return 0
  fi
  if biu_unexpected_paths "${dest}"; then
    biu_result "${component}" "ABORTED" "" "working tree changed files outside .konflux/dockerfiles"
    return 0
  fi

  git -C "${dest}" config user.name "${GITHUB_USER}"
  git -C "${dest}" config user.email "${GITHUB_EMAIL}"
  base_sha=$(git -C "${dest}" rev-parse --verify HEAD)
  if ! git -C "${dest}" checkout -q -b "${branch}"; then
    biu_result "${component}" "COMMIT_FAILED" "" "could not create branch ${branch}"
    return 0
  fi
  git -C "${dest}" add -- .konflux/dockerfiles
  commit_body="Refresh Konflux Dockerfile base images on ${RELEASE_BRANCH} from the Red Hat Ecosystem Catalog."
  rc=0
  log=$(git -C "${dest}" commit -q \
    -m "${title}" \
    -m "${commit_body}" \
    -m "Signed-off-by: ${GITHUB_USER} <${GITHUB_EMAIL}>" 2>&1) || rc=$?
  if [[ ${rc} -ne 0 ]]; then
    biu_result "${component}" "COMMIT_FAILED" "" "$(ocr_redact "${log}")"
    printf '%s\n' "$(ocr_redact "${log}")" >&2
    return 0
  fi

  commit=$(git -C "${dest}" rev-parse --verify HEAD)
  parent=$(git -C "${dest}" rev-parse --verify "${commit}^")
  if [[ "${parent}" != "${base_sha}" ]]; then
    biu_result "${component}" "ABORTED" "" "commit was not based on ${RELEASE_BRANCH}"
    return 0
  fi
  mapfile -t changed < <(git -C "${dest}" diff-tree --no-commit-id --name-only -r "${commit}")
  bad=false
  if [[ ${#changed[@]} -eq 0 ]]; then
    bad=true
  fi
  for path in "${changed[@]}"; do
    [[ "${path}" == .konflux/dockerfiles/* ]] || bad=true
  done
  if [[ "${bad}" == true ]]; then
    biu_result "${component}" "ABORTED" "" "commit included files outside .konflux/dockerfiles and was not pushed"
    return 0
  fi

  pushed_branch=${branch}
  detail=""
  rc=0
  log=$(git -C "${dest}" push --set-upstream origin "HEAD:${branch}" 2>&1) || rc=$?
  if [[ ${rc} -ne 0 ]] && grep -Eqi 'non-fast-forward|fetch first|\[rejected\]' <<<"${log}"; then
    detail="Force-pushed ${branch} because it already existed and was not a fast-forward."
    rc=0
    log=$(git -C "${dest}" push --force --set-upstream origin "HEAD:${branch}" 2>&1) || rc=$?
  fi
  if [[ ${rc} -ne 0 ]]; then
    log=$(ocr_redact "${log}")
    printf '%s\n' "${log}" >&2
    biu_result "${component}" "PUSH_FAILED" "" "${log}"
    return 0
  fi

  url=$(gh pr list --repo "${full}" --base "${RELEASE_BRANCH}" --head "${pushed_branch}" \
    --state open --json url --jq '.[0].url // empty')
  if [[ -n "${url}" ]]; then
    if ! biu_add_pr_labels "${full}" "${url}"; then
      detail="${detail:+${detail} }Could not add labels lgtm, approved, automated."
    fi
    biu_result "${component}" "PR UPDATED" "${url}" "${detail}"
    return 0
  fi

  body_file="${BIU_WORK}/pr-body-${component}.md"
  err_file="${BIU_WORK}/pr-create-${component}.err"
  python3 "${BIU_PY}" pr-body \
    --findings "${BIU_FINDINGS}" \
    --map "${BIU_IMAGE_MAP}" \
    --minor "${MAJOR_MINOR}" \
    --component "${component}" \
    --branch "${RELEASE_BRANCH}" \
    --out "${body_file}"
  rc=0
  url=$(gh pr create --repo "${full}" --base "${RELEASE_BRANCH}" --head "${pushed_branch}" \
    --title "${title}" --body-file "${body_file}" --label lgtm,approved,automated 2>"${err_file}") || rc=$?
  url=${url//$'\r'/}
  url=${url//$'\n'/}
  if [[ ${rc} -ne 0 || -z "${url}" ]]; then
    log=$(ocr_redact "$(cat "${err_file}" 2>/dev/null || true)")
    printf '%s\n' "${log}" >&2
    biu_result "${component}" "PR_CREATE_FAILED" "" "${log}"
    return 0
  fi
  biu_result "${component}" "PR CREATED" "${url}" "${detail}"
}

biu_execute_all() {
  local component index=0 total=${#BIU_SELECTED[@]} dest outcome
  for component in "${BIU_SELECTED[@]}"; do
    index=$((index + 1))
    dest="${BIU_WORK}/src/${component}"
    rm -rf "${dest}"
    printf '%s==>%s %s (%s/%s)\n' "${OCR_CYAN}" "${OCR_RESET}" "${component}" "${index}" "${total}" >&2
    if biu_prepare_checkout "${component}" "${dest}"; then
      biu_decide_image_rewrite "${component}" "${dest}"
      if biu_scan_checkout apply "${component}" "${dest}"; then
        outcome=$(python3 "${BIU_PY}" outcome --findings "${BIU_FINDINGS}" --component "${component}")
        if [[ "${outcome}" == CHANGED ]]; then
          biu_publish "${component}" "${dest}"
        elif [[ "${outcome}" == MATCH ]]; then
          biu_result "${component}" "UP TO DATE" "" ""
        else
          biu_result "${component}" "${outcome}" "" ""
        fi
      else
        biu_result "${component}" "SCAN_FAILED" "" "could not update Dockerfiles"
      fi
    fi
    rm -rf "${dest}"
  done
}

main() {
  local rc=0
  biu_parse_args true "$@" || rc=$?
  if [[ ${rc} -eq 80 ]]; then
    usage
    exit 0
  fi
  if [[ ${rc} -ne 0 ]]; then
    usage >&2
    exit "${rc}"
  fi
  biu_require_tools git curl python3 gh
  biu_init "${REQUESTED_VERSION}"
  biu_require_identity
  biu_load_components
  biu_fetch_digests
  biu_confirm_execute
  export GH_PROMPT_DISABLED=1
  biu_execute_all
  biu_finish execute
}

main "$@"
