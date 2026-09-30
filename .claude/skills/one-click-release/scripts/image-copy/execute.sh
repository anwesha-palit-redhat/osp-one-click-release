#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2016
set -euo pipefail

STAGE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPTS_DIR=$(cd "${STAGE_DIR}/.." && pwd)
source "${SCRIPTS_DIR}/lib/common.sh"
source "${SCRIPTS_DIR}/lib/report.sh"
source "${SCRIPTS_DIR}/lib/stage-runner.sh"

STAGE_NAME='image-copy'
STAGE_STEPS=(3.1 3.2)

ocr_describe_action() {
  case "$1" in
    3.1) printf 'Step 3.1 is read-only; fix or retry failed index stage releases in build step 2.8.\n' ;;
    3.2) printf 'Copy all resolved IIB images to their versioned quay.io stage tags.\n' ;;
  esac
}

execute_3_1() {
  printf 'No automatic mutation is defined for step 3.1. Return to build step 2.8 and repair the failed or incomplete index release.\n' >&2
  return 2
}

# Step 3.1 prerequisite: every index stage release Succeeded with an IIB image.
require_succeeded_state() {
  local state=$1 release rp status image ocp target snapshot
  while IFS=$'\t' read -r release rp status image ocp target snapshot; do
    if [[ "${status}" != Succeeded* && "${status}" != True* ]] || [[ -z "${image}" ]]; then
      printf 'Release %s is not Succeeded or has no IIB image; go back to step 2.8.\n' "${release}" >&2
      return 2
    fi
  done <"${state}"
}

write_copy_script() {
  local state=$1 path="${REPO_ROOT}/scripts/copy-index-images-${VERSION}-stage.sh"
  local release rp status image ocp target snapshot
  {
    printf '#!/bin/bash\n'
    printf '# Copy %s stage index images to quay.io/openshift-pipeline\n' "${VERSION}"
    printf '# Source: IIB images from index stage releases\n#\n'
    printf '# Generated: %s\n' "${REPORT_TIMESTAMP}"
    printf '# Prerequisites: VPN connected, quay.io login active\n#\n'
    printf '# Stage releases used:\n'
    while IFS=$'\t' read -r release rp status image ocp target snapshot; do
      printf '#   %s (%s)\n' "${release}" "${rp}"
    done <"${state}"
    printf '\nset -euo pipefail\n\n'
    printf 'echo "=== Logging into quay.io ==="\n'
    printf 'source "$(dirname "$0")/../.env"\n'
    printf 'echo "${QUAY_PASSWORD}" | skopeo login quay.io -u "${QUAY_USER}" --password-stdin\n\n'
    printf 'echo "=== Running image copy script ==="\n'
    printf 'echo "Copying %s stage index images to quay.io..."\n\n' "${VERSION}"
    while IFS=$'\t' read -r release rp status image ocp target snapshot; do
      printf '# OCP %s\n' "${ocp}"
      printf 'skopeo copy --all \\\n'
      printf '  docker://%s \\\n' "${image}"
      printf '  docker://%s \\\n' "${target}"
      printf '  --preserve-digests\n'
    done <"${state}"
    printf '\necho "Done — all index images copied."\n'
  } >"${path}"
  chmod +x "${path}"
  local shown
  shown=$(ocr_report_path_display "${path}")
  printf 'Copy script written to: %s\n\n' "${shown}"
  printf 'Run it (requires VPN + quay.io login):\n  ./%s\n\n' "${shown}"
  printf 'Or run the individual skopeo commands inside it.\n'
}

execute_3_2() {
  local state="${REPORT_BASE}/.state/image-copy-images.tsv"
  [[ -s "${state}" ]] || {
    printf 'No IIB digest state found; run image-copy verification first.\n' >&2
    return 2
  }
  require_succeeded_state "${state}" || return 2

  write_copy_script "${state}"
}

ocr_execute_step() { case "$1" in 3.1) execute_3_1 ;; 3.2) execute_3_2 ;; esac }
ocr_execute_stage "${1:-}" "${2:-}"