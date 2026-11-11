#!/usr/bin/env bash
# Shared helpers for base-image verify and execute.
# shellcheck disable=SC1091

BIU_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIU_PY="${BIU_DIR}/base_image.py"
BIU_IMAGE_MAP="${BIU_DIR}/../common/base-image-map.json"
BIU_COMPONENTS_FILE="${BIU_DIR}/../common/components.json"
BIU_ORG="openshift-pipelines"

# shellcheck source=../lib/common.sh
source "${BIU_DIR}/../lib/common.sh"

biu_parse_args() {
  local allow_yes=$1
  shift
  REQUESTED_VERSION=""
  BIU_YES=false
  BIU_REWRITE_IMAGES=""
  BIU_REWRITE_FROM_CLI=false
  BIU_COMPONENT_FILTER=()
  local part seen existing
  while (($#)); do
    case "$1" in
      --component)
        [[ $# -ge 2 ]] || {
          printf '%s\n' "--component requires a component name" >&2
          return 64
        }
        IFS=',' read -r -a parts <<<"$2"
        for part in "${parts[@]}"; do
          [[ -n "$part" ]] || continue
          existing=false
          if [[ ${#BIU_COMPONENT_FILTER[@]} -gt 0 ]]; then
            for seen in "${BIU_COMPONENT_FILTER[@]}"; do
              [[ "$seen" == "$part" ]] && existing=true
            done
          fi
          [[ "$existing" == false ]] && BIU_COMPONENT_FILTER+=("$part")
        done
        shift 2
        ;;
      --yes)
        if [[ "$allow_yes" != true ]]; then
          printf '%s\n' "--yes is only valid for execute.sh" >&2
          return 64
        fi
        BIU_YES=true
        shift
        ;;
      --rewrite-images)
        if [[ "$allow_yes" != true ]]; then
          printf '%s\n' "--rewrite-images is only valid for execute.sh" >&2
          return 64
        fi
        BIU_REWRITE_IMAGES=yes
        BIU_REWRITE_FROM_CLI=true
        shift
        ;;
      -h | --help)
        return 80
        ;;
      --)
        shift
        break
        ;;
      -*)
        printf 'Unknown option %s\n' "$1" >&2
        return 64
        ;;
      *)
        if [[ -n "$REQUESTED_VERSION" ]]; then
          printf 'Unexpected argument %s\n' "$1" >&2
          return 64
        fi
        REQUESTED_VERSION=$1
        shift
        ;;
    esac
  done
  if [[ -z "$REQUESTED_VERSION" ]]; then
    printf '%s\n' "Missing version. Expected X.Y or X.Y.Z, for example 1.24." >&2
    return 64
  fi
}

biu_init() {
  local requested=$1
  REQUESTED_VERSION=$requested
  if [[ $requested =~ ^[0-9]+\.[0-9]+$ ]]; then
    MAJOR_MINOR=$requested
  elif [[ $requested =~ ^([0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
    MAJOR_MINOR=${BASH_REMATCH[1]}
  else
    printf 'Invalid version %q; expected X.Y or X.Y.Z.\n' "$requested" >&2
    return 64
  fi
  RELEASE_BRANCH="release-v${MAJOR_MINOR}.x"
  REPO_ROOT=$(ocr_repo_root)
  if [[ -f "${REPO_ROOT}/.env" ]]; then
    ocr_load_env_file "${REPO_ROOT}/.env"
  fi
  REPORT_TIMESTAMP=$(date +'%Y-%m-%d_%H-%M-%S_%Z')
  BIU_WORK=$(mktemp -d "${TMPDIR:-/tmp}/base-image-update.XXXXXX")
  trap 'rm -rf "${BIU_WORK}"' EXIT
  BIU_FINDINGS="${BIU_WORK}/findings.jsonl"
  BIU_DIGESTS="${BIU_WORK}/digests.json"
  BIU_SUMMARY="${BIU_WORK}/summary.json"
  : >"${BIU_FINDINGS}"
  export GIT_TERMINAL_PROMPT=0
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
}

biu_require_tools() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || {
      printf 'Required command not found: %s\n' "$cmd" >&2
      return 1
    }
  done
}

biu_require_identity() {
  if [[ -z "${GITHUB_USER:-}" || -z "${GITHUB_EMAIL:-}" ]]; then
    printf 'GITHUB_USER and GITHUB_EMAIL are required so commits include a Signed-off-by trailer.\n' >&2
    printf 'Set them in the environment or in %s/.env.\n' "${REPO_ROOT}" >&2
    return 1
  fi
  if [[ "${GITHUB_USER}" == *$'\n'* || "${GITHUB_EMAIL}" == *$'\n'* ]]; then
    printf '%s\n' "GITHUB_USER and GITHUB_EMAIL must be single-line values." >&2
    return 1
  fi
}

biu_load_components() {
  local names name filter found
  local -a all=()
  names=$(python3 "${BIU_PY}" list-components --components "${BIU_COMPONENTS_FILE}" --minor "${MAJOR_MINOR}") || return $?
  while IFS= read -r name; do
    [[ -n "$name" ]] && all+=("$name")
  done <<<"$names"
  if [[ ${#all[@]} -eq 0 ]]; then
    printf 'No components listed for minor %s.\n' "${MAJOR_MINOR}" >&2
    return 1
  fi
  if [[ ${#BIU_COMPONENT_FILTER[@]} -eq 0 ]]; then
    BIU_SELECTED=("${all[@]}")
    return 0
  fi
  BIU_SELECTED=()
  for filter in "${BIU_COMPONENT_FILTER[@]}"; do
    found=false
    for name in "${all[@]}"; do
      if [[ "$name" == "$filter" ]]; then
        local already=false selected
        if [[ ${#BIU_SELECTED[@]} -gt 0 ]]; then
          for selected in "${BIU_SELECTED[@]}"; do
            [[ "$selected" == "$filter" ]] && already=true
          done
        fi
        [[ "$already" == false ]] && BIU_SELECTED+=("$filter")
        found=true
        break
      fi
    done
    if [[ "$found" == false ]]; then
      printf 'Component %s is not listed for minor %s.\n' "$filter" "${MAJOR_MINOR}" >&2
      return 1
    fi
  done
}

biu_fetch_digests() {
  python3 "${BIU_PY}" digests --map "${BIU_IMAGE_MAP}" --minor "${MAJOR_MINOR}" --out "${BIU_DIGESTS}"
}

biu_record() {
  python3 "${BIU_PY}" record \
    --findings "${BIU_FINDINGS}" \
    --map "${BIU_IMAGE_MAP}" \
    --minor "${MAJOR_MINOR}" \
    --org "${BIU_ORG}" \
    --component "$1" \
    --status "$2" \
    --detail "${3:-}"
}

biu_result() {
  python3 "${BIU_PY}" result \
    --findings "${BIU_FINDINGS}" \
    --component "$1" \
    --status "$2" \
    --url "${3:-}" \
    --detail "${4:-}"
}

biu_branch_exists() {
  local repo=$1 branch=$2 rc=0
  git ls-remote --exit-code "https://github.com/${repo}.git" "refs/heads/${branch}" >/dev/null 2>&1 || rc=$?
  case ${rc} in
    0) return 0 ;;
    2) return 1 ;;
    *)
      printf 'Unable to query %s branch %s.\n' "${repo}" "${branch}" >&2
      return 2
      ;;
  esac
}

biu_clone() {
  local repo=$1 dest=$2 branch=$3 log rc=0
  log=$(git clone --quiet --depth 1 --filter=blob:none --sparse --single-branch --no-tags \
    --branch "${branch}" "https://github.com/${repo}.git" "${dest}" 2>&1) || rc=$?
  if [[ ${rc} -eq 0 ]]; then
    log=$(git -C "${dest}" sparse-checkout set .konflux/dockerfiles 2>&1) || rc=$?
  fi
  if [[ ${rc} -ne 0 ]]; then
    BIU_LAST_ERROR=$(ocr_redact "${log}")
    return 1
  fi
}

biu_prepare_checkout() {
  local component=$1 dest=$2
  local full="${BIU_ORG}/${component}" rc=0
  biu_branch_exists "${full}" "${RELEASE_BRANCH}" && rc=0 || rc=$?
  if [[ ${rc} -eq 0 ]]; then
    if ! biu_clone "${full}" "${dest}" "${RELEASE_BRANCH}"; then
      biu_record "${component}" "CLONE_FAILED" "${BIU_LAST_ERROR:-clone failed}"
      return 1
    fi
    return 0
  fi
  if [[ ${rc} -eq 1 ]]; then
    biu_record "${component}" "NO_BRANCH" "${RELEASE_BRANCH} does not exist"
  else
    biu_record "${component}" "QUERY_FAILED" "unable to query ${RELEASE_BRANCH}"
  fi
  return 1
}

biu_scan_checkout() {
  local mode=$1 component=$2 dest=$3
  local -a rewrite=()
  if [[ "${mode}" == apply ]]; then
    rewrite=(--rewrite-images "${BIU_REWRITE_IMAGES:-yes}")
  fi
  python3 "${BIU_PY}" "${mode}" \
    --findings "${BIU_FINDINGS}" \
    --map "${BIU_IMAGE_MAP}" \
    --minor "${MAJOR_MINOR}" \
    --digests "${BIU_DIGESTS}" \
    --org "${BIU_ORG}" \
    --root "${dest}" \
    --component "${component}" \
    "${rewrite[@]}"
}

biu_report_file() {
  local mode=$1
  REPORT_DIR="${REPO_ROOT}/reports/${MAJOR_MINOR}/base-image-update/${mode}"
  mkdir -p "${REPORT_DIR}"
  REPORT_FILE="${REPORT_DIR}/report_${REPORT_TIMESTAMP}.md"
}

biu_render() {
  local mode=$1
  biu_report_file "${mode}"
  python3 "${BIU_PY}" "render-${mode}" \
    --findings "${BIU_FINDINGS}" \
    --digests "${BIU_DIGESTS}" \
    --map "${BIU_IMAGE_MAP}" \
    --components "${BIU_COMPONENTS_FILE}" \
    --repo-root "${REPO_ROOT}" \
    --generated "${REPORT_TIMESTAMP}" \
    --requested "${REQUESTED_VERSION}" \
    --minor "${MAJOR_MINOR}" \
    --branch "${RELEASE_BRANCH}" \
    --out "${REPORT_FILE}" \
    --summary "${BIU_SUMMARY}"
  printf '%sReport written to:%s %s\n' "${OCR_CYAN}" "${OCR_RESET}" "$(ocr_report_path_display "${REPORT_FILE}")"
}

biu_finish() {
  local mode=$1
  biu_render "${mode}"
  python3 - "${BIU_SUMMARY}" "${mode}" <<'PY'
import json
import sys

summary = json.load(open(sys.argv[1], encoding="utf-8"))
mode = sys.argv[2]
if mode == "verify":
    if summary.get("errors", 0):
        raise SystemExit(2)
    if summary.get("mismatch", 0) or summary.get("incomplete", 0):
        raise SystemExit(1)
elif summary.get("failed", 0):
    raise SystemExit(1)
raise SystemExit(0)
PY
}
