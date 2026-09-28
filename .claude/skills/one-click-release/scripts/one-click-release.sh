#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  one-click-release.sh verify VERSION
  one-click-release.sh verify VERSION --stage STAGE
  one-click-release.sh execute VERSION --stage STAGE [--step STEP]
  one-click-release.sh run VERSION --through STAGE

Stages: config, build, image-copy, production-release

Verification is read-only. Execution always requires an exact interactive
approval phrase. production-release also requires its separate production gate.
EOF
}

stage_script() {
  local stage=$1 action=$2
  printf '%s/%s/%s.sh' "${SCRIPT_DIR}" "${stage}" "${action}"
}

run_verify() {
  local version=$1 stage=$2
  if [[ "${stage}" == production-release ]]; then
    ocr_init_context "${version}"
    ocr_confirm_production || return 3
  fi
  "$(stage_script "${stage}" verify)" "${version}"
}

command=${1:-}
case "${command}" in
  verify)
    version=${2:-}
    shift 2 || true
    stage=''
    while (($#)); do
      case "$1" in
        --stage)
          stage=$(ocr_normalize_stage "${2:-}")
          shift 2
          ;;
        *)
          usage >&2
          exit 64
          ;;
      esac
    done
    ocr_validate_version "${version}" || exit 64
    if [[ -n "${stage}" ]]; then
      run_verify "${version}" "${stage}"
    else
      for stage in config build image-copy; do
        run_verify "${version}" "${stage}"
      done
      printf 'Non-production stages verified. production-release remains a separate explicit action.\n'
    fi
    ;;
  execute)
    version=${2:-}
    shift 2 || true
    stage=''
    step=''
    while (($#)); do
      case "$1" in
        --stage)
          stage=$(ocr_normalize_stage "${2:-}")
          shift 2
          ;;
        --step)
          step=${2:-}
          shift 2
          ;;
        *)
          usage >&2
          exit 64
          ;;
      esac
    done
    ocr_validate_version "${version}" || exit 64
    [[ -n "${stage}" ]] || {
      printf '%s\n' '--stage is required for execute.' >&2
      exit 64
    }
    "$(stage_script "${stage}" execute)" "${version}" "${step}"
    ;;
  run)
    version=${2:-}
    shift 2 || true
    through=''
    while (($#)); do
      case "$1" in
        --through)
          through=$(ocr_normalize_stage "${2:-}")
          shift 2
          ;;
        *)
          usage >&2
          exit 64
          ;;
      esac
    done
    ocr_validate_version "${version}" || exit 64
    [[ -n "${through}" ]] || {
      printf '%s\n' '--through is required for run.' >&2
      exit 64
    }
    for stage in config build image-copy production-release; do
      run_verify "${version}" "${stage}"
      [[ "${stage}" == "${through}" ]] && break
    done
    ;;
  -h | --help | help) usage ;;
  *)
    usage >&2
    exit 64
    ;;
esac
