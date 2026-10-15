#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
one-click-release.sh — OpenShift Pipelines release automation

COMMANDS
  verify   VERSION [--stage STAGE] [--step STEP] [--skip STEPS]
             Check the current state of a release without making any changes.
             Without --stage, verifies config, build, and image-copy in order.
             --stage is required when --step is given.

  execute  VERSION --stage STAGE [--step STEP] [--skip STEPS] [--force]
             Execute the next blocked step in the given stage (or the step
             specified by --step). Each step requires an exact approval phrase
             typed interactively. production-release also requires a separate
             production gate phrase before any step executes.

  run      VERSION --through STAGE [--skip STEPS] [--wait SECS]
             Automated hands-off loop: verifies and executes every step in
             config → build → image-copy in order, polling blocked steps until
             they complete. Stops at and including STAGE.
             STAGE may be: config, build, or image-copy
             production-release is never allowed here — use execute instead.
             Steps 2.1 (code freeze), 2.2 (update-sources), 2.3 (release PRs)
             are skipped in run mode — handle them manually before running.

  unfreeze MAJOR_MINOR
             Lift code freeze for a minor release (e.g. 1.23) by setting
             code-freeze: false in openshift-pipelines/hack.

STAGES (in execution order)
  config             Steps 1.1–1.12  Release plan, Konflux, OPC, CLI config
  build              Steps 2.1–2.14  Snapshot verification, stage releases
  image-copy         Steps 3.1–3.2   Copy IIB index images to quay.io
  production-release Steps 4.1–4.10  Production releases + image publication

OPTIONS
  --stage STAGE   Target a specific stage (required for execute; optional for verify)
  --step  STEP    Target a single step within a stage (requires --stage)
  --skip  STEPS   Comma-separated steps to skip, e.g. --skip 1.5 or --skip 1.5,1.6
  --through STAGE Run through all stages up to and including STAGE (run only)
  --wait  SECS    Polling interval in run mode — default 300 (5 minutes)
  --force         Re-execute a step that already verifies as DONE (execute only)

EXAMPLES
  # Check all non-production stages
  one-click-release.sh verify 1.23.3

  # Check a single step
  one-click-release.sh verify 1.23.3 --stage build --step 2.10

  # Execute the next blocked build step
  one-click-release.sh execute 1.23.3 --stage build

  # Execute a specific step (must be the actual blocker or --force)
  one-click-release.sh execute 1.23.3 --stage build --step 2.10

  # Automated run through build (handles most steps; skips 2.1/2.2/2.3)
  one-click-release.sh run 1.23.3 --through build

  # Automated run with faster polling (60s) and skipping Pyxis step
  one-click-release.sh run 1.23.3 --through image-copy --wait 60 --skip 1.6

  # Production release (always interactive — never via run)
  one-click-release.sh execute 1.23.3 --stage production-release

  # Lift code freeze after a build cycle
  one-click-release.sh unfreeze 1.23
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
    step=''
    skip=''
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
        --skip)
          skip=${2:-}
          shift 2
          ;;
        *)
          usage >&2
          exit 64
          ;;
      esac
    done
    ocr_validate_version "${version}" || exit 64
    if [[ -n "${step}" && -z "${stage}" ]]; then
      printf '%s\n' '--stage is required when --step is given.' >&2
      exit 64
    fi
    [[ -z "${step}" ]] || export OCR_VERIFY_STEP="${step}"
    [[ -z "${skip}" ]] || export OCR_SKIP_STEPS="${skip}"
    if [[ -n "${stage}" ]]; then
      run_verify "${version}" "${stage}"
    else
      for stage in config build image-copy; do
        run_verify "${version}" "${stage}"
      done
      printf '%s✔ Non-production stages verified.%s production-release remains a separate explicit action.\n' \
        "${OCR_GREEN}${OCR_BOLD}" "${OCR_RESET}"
    fi
    ;;
  execute)
    version=${2:-}
    shift 2 || true
    stage=''
    step=''
    skip=''
    force=false
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
        --skip)
          skip=${2:-}
          shift 2
          ;;
        --force)
          force=true
          shift
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
    [[ -z "${skip}" ]] || export OCR_SKIP_STEPS="${skip}"
    [[ "${force}" == false ]] || export OCR_FORCE=1
    "$(stage_script "${stage}" execute)" "${version}" "${step}"
    ;;
  run)
    version=${2:-}
    shift 2 || true
    through=''
    skip=''
    wait_interval=''
    while (($#)); do
      case "$1" in
        --through)
          through=$(ocr_normalize_stage "${2:-}")
          shift 2
          ;;
        --skip)
          skip=${2:-}
          shift 2
          ;;
        --wait)
          wait_interval=${2:-}
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
    [[ "${through}" != production-release ]] || {
      printf '%s\n' 'run --through production-release is not allowed. Use: execute --stage production-release' >&2
      exit 64
    }
    [[ -z "${skip}" ]] || export OCR_SKIP_STEPS="${skip}"
    export OCR_RUN_THROUGH=true
    export OCR_WAIT_INTERVAL=${wait_interval:-300}
    # shellcheck source=lib/stage-runner.sh
    source "${SCRIPT_DIR}/lib/stage-runner.sh"
    for stage in config build image-copy production-release; do
      ocr_run_through_stage "${version}" "${stage}" "${SCRIPT_DIR}"
      [[ "${stage}" == "${through}" ]] && break
    done
    ;;
  unfreeze)
    MAJOR_MINOR=${2:-}
    [[ "${MAJOR_MINOR}" =~ ^[0-9]+\.[0-9]+$ ]] || {
      printf 'Invalid MAJOR_MINOR %q; expected X.Y (for example, 1.21).\n' "${MAJOR_MINOR}" >&2
      exit 64
    }
    MM_DASHED=${MAJOR_MINOR//./-}
    VERSION=${MAJOR_MINOR}.0
    RELEASE_BRANCH="release-v${MAJOR_MINOR}.x"
    export VERSION MAJOR_MINOR MM_DASHED RELEASE_BRANCH
    # shellcheck source=lib/release.sh
    source "${SCRIPT_DIR}/lib/release.sh"
    execute_code_unfreeze
    ;;
  -h | --help | help) usage ;;
  *)
    usage >&2
    exit 64
    ;;
esac
