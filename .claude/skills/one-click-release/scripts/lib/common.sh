#!/usr/bin/env bash
# shellcheck disable=SC2034

# Shared context, command, credential, and approval helpers.

OCR_RC_BLOCKED=10
OCR_RC_SKIPPED=20
OCR_KONFLUX_NS="tekton-ecosystem-tenant"

# Portable in-place sed that works on both GNU sed (Linux) and BSD sed (macOS).
# BSD sed requires an explicit backup extension argument after -i; GNU sed does not.
# Usage: sed_i "s/old/new/" file  (same arguments as sed -i)
sed_i() {
  if sed --version 2>/dev/null | grep -q GNU; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

ocr_load_env_file() {
  local path=$1 line key value
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line=${line%$'\r'}
    [[ "${line}" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "${line}" =~ ^[[:space:]]*(export[[:space:]]+)?([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    key=${BASH_REMATCH[2]}
    value=${BASH_REMATCH[3]}
    case "${key}" in
      GITHUB_TOKEN | GH_TOKEN | GITHUB_USER | GITHUB_EMAIL | \
        KONFLUX_SERVER | KONFLUX_TOKEN | GITLAB_URL | GITLAB_TOKEN | \
        JIRA_URL | JIRA_EMAIL | JIRA_TOKEN | QUAY_USER | QUAY_PASSWORD) ;;
      *) continue ;;
    esac
    value="${value%"${value##*[![:space:]]}"}"
    if ((${#value} >= 2)) && { [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]] || [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; }; then
      value=${value:1:${#value}-2}
    fi
    printf -v "${key}" '%s' "${value}"
    export "${key?}"
  done <"${path}"
}

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
    # .env is data, not shell code. Only credential and identity assignments
    # are accepted so it cannot provide approvals, replace helpers, or alter
    # command lookup and release targeting.
    ocr_load_env_file "${context_repo_root}/.env"
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
  OCR_KONFLUX_NS='tekton-ecosystem-tenant'
  KONFLUX_NS='tekton-ecosystem-tenant'
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
  local candidate secret existing i j
  local -a secrets=()
  for candidate in "${GITHUB_TOKEN:-}" "${GH_TOKEN:-}" "${GITLAB_TOKEN:-}" \
    "${KONFLUX_TOKEN:-}" "${JIRA_TOKEN:-}" "${QUAY_PASSWORD:-}"; do
    [[ -n "${candidate}" ]] || continue
    for existing in "${secrets[@]}"; do [[ "${existing}" == "${candidate}" ]] && continue 2; done
    secrets+=("${candidate}")
  done
  for ((i = 0; i < ${#secrets[@]}; i++)); do
    for ((j = i + 1; j < ${#secrets[@]}; j++)); do
      if ((${#secrets[j]} > ${#secrets[i]})); then
        secret=${secrets[i]}
        secrets[i]=${secrets[j]}
        secrets[j]=${secret}
      fi
    done
  done
  for secret in "${secrets[@]}"; do
    if [[ -n "${secret}" ]]; then
      text=${text//"${secret}"/[REDACTED]}
    fi
  done
  printf '%s' "${text}"
}

ocr_workflow_succeeded() { [[ "${1:-}" == success ]]; }

ocr_diff_has_only_production_images() {
  local diff=$1
  python3 -c '
import re, sys
added = [line[1:] for line in sys.stdin if line.startswith("+") and not line.startswith("+++")]
refs=[]
token = re.compile(r"(?:[A-Za-z0-9._-]+(?::[0-9]+)?/)+[A-Za-z0-9._:@+-]+")
for line in added:
    if re.search(r"(?i)(image|value|pullspec)\s*[\"'"'"']?\s*:", line) or re.search(r"(?i)(quay\.io/|registry[^\s\"'"'"']*/)", line):
        refs.extend(token.findall(line))
approved=re.compile(r"^registry\.redhat\.io/openshift-pipelines/[^\s@]+@sha256:[0-9a-f]{64}$")
raise SystemExit(0 if refs and all(approved.fullmatch(ref) for ref in refs) else 1)
' <<<"${diff}"
}

ocr_require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    STEP_DETAILS="required command not found: $1"
    return "${OCR_RC_BLOCKED}"
  }
}

ocr_remote_branch_exists() {
  local repo=$1 branch=$2 rc
  set +e
  git ls-remote --exit-code "https://github.com/${repo}.git" "refs/heads/${branch}" >/dev/null 2>&1
  rc=$?
  set -e
  case ${rc} in
    0) return 0 ;;
    2) return 1 ;;
    *)
      printf 'Unable to query remote branch %s:%s; refusing to guess retry state.\n' "${repo}" "${branch}" >&2
      return 2
      ;;
  esac
}

ocr_remote_branch_matches() {
  local repo=$1 base=$2 branch=$3 file_pattern=$4 allowed_patch=$5 required_patch=$6 data
  ocr_remote_branch_exists "${repo}" "${branch}" || return $?
  data=$(gh api "repos/${repo}/compare/${base}...${branch}" 2>/dev/null) || {
    printf 'Unable to validate remote branch %s:%s; refusing recovery.\n' "${repo}" "${branch}" >&2
    return 2
  }
  jq -e --arg pattern "${file_pattern}" --arg allowed "${allowed_patch}" --arg required "${required_patch}" '
    [.files[] | (.patch // "") | split("\n")[] | select(test("^[+-][^+-]")) | .[1:]] as $changes
    | .status=="ahead" and (.files|length)>0 and all(.files[]; .filename|test($pattern))
      and ($changes|length)>0 and all($changes[]; test($allowed)) and any($changes[]; test($required))' \
    <<<"${data}" >/dev/null || {
    printf 'Remote branch %s:%s does not match the approved mutation scope.\n' "${repo}" "${branch}" >&2
    return 2
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

ocr_operator_release_stage_at() {
  local revision=$1 content
  content=$(gh api "repos/openshift-pipelines/operator/contents/olm/release-stage.txt?ref=${revision}" --jq '.content' 2>/dev/null) || return 2
  content=$(base64 -d <<<"${content}" 2>/dev/null) || return 2
  [[ "$(tr -d '[:space:]' <<<"${content}")" == production ]]
}

ocr_operator_revision_is_generated() {
  local revision=$1 head=$2 compare actors_ok files_ok
  [[ "${revision}" == "${head}" ]] && return 0
  compare=$(gh api "repos/openshift-pipelines/operator/compare/${revision}...${head}" 2>/dev/null) || return 1
  actors_ok=$(jq -e '[.commits[] | (.author.login // "")] | length > 0 and all(.[]; . == "github-actions[bot]" or . == "openshift-pipelines-bot" or . == "red-hat-konflux[bot]" or . == "red-hat-konflux-kflux-prd-rh02[bot]" or startswith("red-hat-konflux-"))' <<<"${compare}" 2>/dev/null) || return 1
  files_ok=$(jq -e '[.files[].filename] | length > 0 and all(.[];
    test("^(\\.konflux/olm-catalog/|olm/|bundle[/.]|nightly-bundle\\.)"))' <<<"${compare}" 2>/dev/null) || return 1
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
