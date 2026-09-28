#!/usr/bin/env bash
# shellcheck disable=SC2034

# Shared context, command, credential, and approval helpers.

OCR_RC_BLOCKED=10
OCR_RC_SKIPPED=20
OCR_KONFLUX_NS="tekton-ecosystem-tenant"

ocr_repo_root() {
  if [[ -n "${OCR_REPO_ROOT:-}" ]]; then
    printf '%s\n' "${OCR_REPO_ROOT}"
    return
  fi
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  (cd "${lib_dir}/../../../../.." && pwd)
}

ocr_validate_version() {
  local version=${1:-}
  [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    printf 'Invalid version %q; expected X.Y.Z (for example, 1.21.3).\n' "${version}" >&2
    return 1
  }
}

ocr_init_context() {
  local version=${1:-}
  ocr_validate_version "${version}" || return 1

  VERSION=${version}
  MAJOR_MINOR=${VERSION%.*}
  MM_DASHED=${MAJOR_MINOR//./-}
  RELEASE_BRANCH="release-v${MAJOR_MINOR}.x"
  RELEASE_TAG="v${VERSION}"
  PATCH_VERSION=${VERSION##*.}
  if ((10#${PATCH_VERSION} > 0)); then
    IS_PATCH=true
  else
    IS_PATCH=false
  fi
  KONFLUX_NS=${OCR_KONFLUX_NS}
  TZ_FMT='%Y-%m-%d %H:%M %Z'
  REPO_ROOT=$(ocr_repo_root)

  if [[ -f "${REPO_ROOT}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/.env"
    set +a
  fi

  local reports_root=${OCR_REPORT_ROOT:-${REPO_ROOT}/reports}
  REPORT_BASE="${reports_root}/${MAJOR_MINOR}/${VERSION}"
  REPORT_TIMESTAMP=${OCR_REPORT_TIMESTAMP:-$(date +'%Y-%m-%d_%H-%M-%S_%Z')}
  export VERSION MAJOR_MINOR MM_DASHED RELEASE_BRANCH RELEASE_TAG IS_PATCH
  export KONFLUX_NS TZ_FMT REPO_ROOT REPORT_BASE REPORT_TIMESTAMP

  mkdir -p \
    "${REPORT_BASE}/config" \
    "${REPORT_BASE}/build" \
    "${REPORT_BASE}/image-copy" \
    "${REPORT_BASE}/release" \
    "${REPORT_BASE}/manifest/stage" \
    "${REPORT_BASE}/manifest/prod" \
    "${REPORT_BASE}/.state"
}

ocr_redact() {
  local text=${1-}
  local secret
  for secret in \
    "${GITHUB_TOKEN:-}" "${GH_TOKEN:-}" "${GITLAB_TOKEN:-}" \
    "${KONFLUX_TOKEN:-}" "${JIRA_TOKEN:-}" "${QUAY_PASSWORD:-}"; do
    if [[ -n "${secret}" ]]; then
      text=${text//${secret}/[REDACTED]}
    fi
  done
  printf '%s' "${text}"
}

ocr_require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    STEP_DETAILS="required command not found: $1"
    return "${OCR_RC_BLOCKED}"
  }
}

ocr_require_konflux() {
  if [[ -z "${KONFLUX_SERVER:-}" || -z "${KONFLUX_TOKEN:-}" ]]; then
    STEP_DETAILS="KONFLUX_SERVER or KONFLUX_TOKEN missing"
    return "${OCR_RC_SKIPPED}"
  fi
  ocr_require_command oc
}

ocr_require_gitlab() {
  if [[ -z "${GITLAB_URL:-}" || -z "${GITLAB_TOKEN:-}" ]]; then
    STEP_DETAILS="GITLAB_URL or GITLAB_TOKEN missing"
    return "${OCR_RC_SKIPPED}"
  fi
  ocr_require_command curl
}

ocr_oc_get() {
  oc get "$@" -n "${KONFLUX_NS}" \
    --server="${KONFLUX_SERVER}" --token="${KONFLUX_TOKEN}" \
    --insecure-skip-tls-verify
}

ocr_oc_create() {
  oc create "$@" \
    --server="${KONFLUX_SERVER}" --token="${KONFLUX_TOKEN}" \
    --insecure-skip-tls-verify
}

ocr_oc_wait_release() {
  local release_name=$1
  oc wait "release/${release_name}" -n "${KONFLUX_NS}" \
    --server="${KONFLUX_SERVER}" --token="${KONFLUX_TOKEN}" \
    --insecure-skip-tls-verify \
    --for=condition=Released --timeout=300s 2>&1 || true
}

ocr_gitlab_get() {
  local url=$1
  curl --silent --show-error --fail \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "${url}"
}

ocr_abs_time() {
  local value=${1:-}
  if [[ -z "${value}" || "${value}" == "null" ]]; then
    printf '%s' '—'
  else
    date -d "${value}" +"${TZ_FMT}" 2>/dev/null || printf '%s' "${value}"
  fi
}

ocr_confirm_action() {
  local stage=$1 step=$2
  local expected="execute ${VERSION} ${stage} ${step}"
  local answer=${OCR_ACTION_APPROVAL:-}
  if [[ -z "${answer}" ]]; then
    printf 'Explicit approval required. Type exactly: %s\n> ' "${expected}" >&2
    IFS= read -r answer
  fi
  [[ "${answer}" == "${expected}" ]] || {
    printf 'Execution approval not granted; no mutation was run.\n' >&2
    return 1
  }
}

ocr_confirm_production() {
  local expected="start production-release ${VERSION}"
  local answer=${OCR_PRODUCTION_APPROVAL:-}
  if [[ -z "${answer}" ]]; then
    printf 'Production release has a separate gate. Type exactly: %s\n> ' "${expected}" >&2
    IFS= read -r answer
  fi
  [[ "${answer}" == "${expected}" ]] || {
    printf 'Production approval not granted; production-release did not start.\n' >&2
    return 1
  }
  OCR_PRODUCTION_APPROVAL=${expected}
  export OCR_PRODUCTION_APPROVAL
}

ocr_normalize_stage() {
  case "${1:-}" in
    config) printf '%s\n' config ;;
    build) printf '%s\n' build ;;
    image-copy | image_copy) printf '%s\n' image-copy ;;
    production-release | production_release | release) printf '%s\n' production-release ;;
    *)
      printf 'Unknown stage %q. Expected config, build, image-copy, or production-release.\n' "${1:-}" >&2
      return 1
      ;;
  esac
}

ocr_report_path_display() {
  local path=$1
  if [[ "${path}" == "${REPO_ROOT}/"* ]]; then
    printf '%s' "${path#"${REPO_ROOT}"/}"
  else
    printf '%s' "${path}"
  fi
}
