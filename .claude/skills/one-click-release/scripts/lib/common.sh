#!/usr/bin/env bash
# shellcheck disable=SC2034

# Shared context, command, credential, and approval helpers.

OCR_RC_BLOCKED=10
OCR_RC_SKIPPED=20
OCR_KONFLUX_NS="tekton-ecosystem-tenant"

ocr_cleanup_credentials() {
  [[ -n "${OCR_KUBECONFIG_FILE:-}" ]] && rm -f "${OCR_KUBECONFIG_FILE}"
  [[ -n "${OCR_CURL_CONFIG_FILE:-}" ]] && rm -f "${OCR_CURL_CONFIG_FILE}"
  return 0
}

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

  local context_repo_root
  context_repo_root=$(ocr_repo_root)

  if [[ -f "${context_repo_root}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${context_repo_root}/.env"
    set +a
  fi

  # Derived release context and the fixed namespace are authoritative. Rebuild
  # them after loading credentials so .env cannot retarget an invocation.
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
  REPO_ROOT=${context_repo_root}

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
  if [[ -z "${OCR_KUBECONFIG_FILE:-}" ]]; then
    OCR_KUBECONFIG_FILE=$(mktemp)
    chmod 600 "${OCR_KUBECONFIG_FILE}"
    local server=${KONFLUX_SERVER//\'/\'\'} token=${KONFLUX_TOKEN//\'/\'\'}
    {
      printf 'apiVersion: v1\nkind: Config\nclusters:\n- name: konflux\n  cluster:\n'
      printf "    server: '%s'\n    insecure-skip-tls-verify: true\n" "${server}"
      printf "users:\n- name: release-user\n  user:\n    token: '%s'\n" "${token}"
      printf 'contexts:\n- name: release\n  context:\n    cluster: konflux\n    user: release-user\n    namespace: %s\ncurrent-context: release\n' "${KONFLUX_NS}"
    } >"${OCR_KUBECONFIG_FILE}"
    export KUBECONFIG=${OCR_KUBECONFIG_FILE}
    trap ocr_cleanup_credentials EXIT
  fi
}

ocr_require_gitlab() {
  if [[ -z "${GITLAB_URL:-}" || -z "${GITLAB_TOKEN:-}" ]]; then
    STEP_DETAILS="GITLAB_URL or GITLAB_TOKEN missing"
    return "${OCR_RC_SKIPPED}"
  fi
  ocr_require_command curl
}

ocr_oc_get() {
  ocr_require_konflux || return $?
  oc get "$@" -n "${KONFLUX_NS}"
}

ocr_oc_create() {
  ocr_require_konflux || return $?
  oc create "$@"
}

ocr_oc_wait_release() {
  local release_name=$1
  ocr_require_konflux || return $?
  oc wait "release/${release_name}" -n "${KONFLUX_NS}" \
    --for=condition=Released --timeout=300s 2>&1 || true
}

ocr_gitlab_get() {
  local url=$1
  if [[ -z "${OCR_CURL_CONFIG_FILE:-}" ]]; then
    OCR_CURL_CONFIG_FILE=$(mktemp)
    chmod 600 "${OCR_CURL_CONFIG_FILE}"
    local token=${GITLAB_TOKEN//\\/\\\\}
    token=${token//\"/\\\"}
    printf 'silent\nshow-error\nfail\nheader = "PRIVATE-TOKEN: %s"\n' "${token}" >"${OCR_CURL_CONFIG_FILE}"
    trap ocr_cleanup_credentials EXIT
  fi
  curl --config "${OCR_CURL_CONFIG_FILE}" "${url}"
}

ocr_fail_with_error() {
  local message=$1 error=${2:-}
  error=$(ocr_redact "${error}")
  STEP_DETAILS=${message}
  [[ -n "${error}" ]] && STEP_DETAILS+="; error: ${error}"
  return "${OCR_RC_BLOCKED}"
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
  local answer=''
  printf 'Explicit approval required. Type exactly: %s\n> ' "${expected}" >&2
  IFS= read -r answer || true
  [[ "${answer}" == "${expected}" ]] || {
    printf 'Execution approval not granted; no mutation was run.\n' >&2
    return 1
  }
}

ocr_confirm_production() {
  local expected="start production-release ${VERSION}"
  local answer=''
  printf 'Production release has a separate gate. Type exactly: %s\n> ' "${expected}" >&2
  IFS= read -r answer || true
  [[ "${answer}" == "${expected}" ]] || {
    printf 'Production approval not granted; production-release did not start.\n' >&2
    return 1
  }
}

ocr_mutation_marker() {
  local key=${1//[^a-zA-Z0-9_.-]/_}
  printf '%s/.state/mutation-%s' "${REPORT_BASE}" "${key}"
}

ocr_mutation_done() { [[ -f "$(ocr_mutation_marker "$1")" ]]; }

ocr_mark_mutation() {
  local marker temp
  marker=$(ocr_mutation_marker "$1")
  temp="${marker}.tmp.$$"
  printf '%s\n' "$(date +"${TZ_FMT}")" >"${temp}"
  mv "${temp}" "${marker}"
}

ocr_workflow_state_file() { printf '%s/.state/workflow-%s.state' "${REPORT_BASE}" "$1"; }

ocr_record_workflow_run() {
  local key=$1 workflow=$2 environment=$3 branch=$4 id=$5 created=$6
  local path temp
  path=$(ocr_workflow_state_file "${key}")
  temp="${path}.tmp.$$"
  {
    printf 'WORKFLOW=%q\n' "${workflow}"
    printf 'ENVIRONMENT=%q\n' "${environment}"
    printf 'BRANCH=%q\n' "${branch}"
    printf 'RUN_ID=%q\n' "${id}"
    printf 'CREATED_AT=%q\n' "${created}"
  } >"${temp}"
  mv "${temp}" "${path}"
}

ocr_load_workflow_run() {
  local key=$1 path
  path=$(ocr_workflow_state_file "${key}")
  [[ -f "${path}" ]] || return 1
  WORKFLOW='' ENVIRONMENT='' BRANCH='' RUN_ID='' CREATED_AT=''
  # shellcheck disable=SC1090
  source "${path}"
  [[ -n "${WORKFLOW}" && -n "${ENVIRONMENT}" && -n "${BRANCH}" && "${RUN_ID}" =~ ^[0-9]+$ && -n "${CREATED_AT}" ]]
}

ocr_workflow_provenance_matches() {
  local key=$1 workflow=$2 environment=$3 branch=$4
  ocr_load_workflow_run "${key}" || return 1
  [[ "${WORKFLOW}" == "${workflow}" && "${ENVIRONMENT}" == "${environment}" && "${BRANCH}" == "${branch}" ]]
}

ocr_workflow_log_has_environment() {
  local run_id=$1 expected=$2 log
  log=$(gh run view --repo openshift-pipelines/operator "${run_id}" --log 2>/dev/null) || return 1
  grep -Eiq "(^|[^[:alnum:]_])(environment|ENVIRONMENT)[=:][[:space:]]*${expected}([^[:alnum:]_-]|$)" <<<"${log}"
}

ocr_operator_revision_is_generated() {
  local revision=$1 head=$2 compare actors_ok files_ok
  [[ "${revision}" == "${head}" ]] && return 0
  compare=$(gh api "repos/openshift-pipelines/operator/compare/${revision}...${head}" 2>/dev/null) || return 1
  actors_ok=$(jq -e '[.commits[] | (.author.login // "")] | length > 0 and all(.[]; . == "github-actions[bot]" or . == "openshift-pipelines-bot" or . == "red-hat-konflux[bot]")' <<<"${compare}" 2>/dev/null) || return 1
  files_ok=$(jq -e '[.files[].filename] | length > 0 and all(.[];
    test("^(\\.konflux/olm-catalog/(bundle|index)/\\.placeholder|olm/.*\\.(json|yaml|yml)|bundle/.*\\.(yaml|yml))$"))' <<<"${compare}" 2>/dev/null) || return 1
  [[ "${actors_ok}" == true && "${files_ok}" == true ]]
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
