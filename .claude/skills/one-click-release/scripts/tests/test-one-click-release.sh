#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPTS_DIR=$(cd "${TEST_DIR}/.." && pwd)
FIXTURE_BIN="${TEST_DIR}/fixtures/bin"
ORIGINAL_PATH=${PATH}
PASS=0
FAIL=0

pass() {
  printf 'ok - %s\n' "$1"
  ((PASS += 1))
}
fail() {
  printf 'not ok - %s\n' "$1"
  ((FAIL += 1))
}

assert_eq() {
  local expected=$1 actual=$2 message=$3
  if [[ "${actual}" == "${expected}" ]]; then pass "${message}"; else fail "${message} (expected=${expected}, actual=${actual})"; fi
}

assert_file() {
  local path=$1 message=$2
  if [[ -f "${path}" ]]; then pass "${message}"; else fail "${message} (${path} missing)"; fi
}

run_rc() {
  set +e
  "$@" >/tmp/ocr-test.out 2>/tmp/ocr-test.err
  local rc=$?
  set -e
  printf '%s' "${rc}"
}

tmp=$(mktemp -d)
trap 'rm -rf "${tmp}" /tmp/ocr-test.out /tmp/ocr-test.err' EXIT
export OCR_REPO_ROOT="${tmp}/repo"
export OCR_REPORT_ROOT="${tmp}/reports"
export OCR_REPORT_TIMESTAMP='2026-09-28_12-00-00_UTC'
export OCR_TEST_COMMAND_LOG="${tmp}/commands.log"
mkdir -p "${OCR_REPO_ROOT}"
: >"${OCR_TEST_COMMAND_LOG}"
export PATH="${FIXTURE_BIN}:${ORIGINAL_PATH}"

# shellcheck source=../lib/common.sh
source "${SCRIPTS_DIR}/lib/common.sh"
# shellcheck source=../lib/release.sh
source "${SCRIPTS_DIR}/lib/release.sh"

ocr_init_context 1.21.3
assert_eq '1.21' "${MAJOR_MINOR}" 'version parsing derives MAJOR_MINOR'
assert_eq '1-21' "${MM_DASHED}" 'version parsing derives MM_DASHED'
assert_eq 'release-v1.21.x' "${RELEASE_BRANCH}" 'version parsing derives release branch'
assert_eq 'true' "${IS_PATCH}" 'version parsing identifies patch release'
assert_eq 'production-release' "$(ocr_normalize_stage release)" 'stage aliases normalize predictably'
assert_eq '64' "$(run_rc "${SCRIPTS_DIR}/one-click-release.sh" verify 1.21)" 'invalid versions fail with usage exit'

manifest="${REPORT_BASE}/manifest/stage/release-${VERSION}-core-stage.yaml"
ocr_write_release_manifest "${manifest}" openshift-pipelines-core-1-21 core-stage-rp core-snapshot
assert_file "${manifest}" 'release helper writes the compatible manifest path'
if grep -q '^  generateName: core-stage-rp-$' "${manifest}" && grep -q '^  namespace: tekton-ecosystem-tenant$' "${manifest}"; then
  pass 'release manifests retain generateName and the fixed Konflux namespace'
else
  fail 'release manifests retain generateName and the fixed Konflux namespace'
fi
if grep -ERn 'oc[[:space:]]+apply[[:space:]]+-f.*release-|ocr_oc_create.*apply' "${SCRIPTS_DIR}"/{build,production-release,lib} >/tmp/ocr-test.out; then
  fail 'Release CR execution never uses oc apply'
else
  pass 'Release CR execution never uses oc apply'
fi

mutating='gh[[:space:]]+workflow[[:space:]]+run|gh[[:space:]]+pr[[:space:]]+(merge|edit|review|close|comment)|git[[:space:]]+push|oc[[:space:]]+create|kubectl[[:space:]]+apply|skopeo[[:space:]]+copy'
if grep -ERn "${mutating}" "${SCRIPTS_DIR}"/{config,build,image-copy,production-release}/verify.sh >/tmp/ocr-test.out; then
  fail 'verify scripts contain no mutating commands'
else
  pass 'verify scripts contain no mutating commands'
fi

export OCR_ACTION_APPROVAL='no'
: >"${OCR_TEST_COMMAND_LOG}"
assert_eq '3' "$(run_rc "${SCRIPTS_DIR}/one-click-release.sh" execute 1.21.3 --stage config --step 1.1)" 'execute rejects missing exact action approval'
if grep -q 'workflow run\|pr merge\|git push\|oc create\|skopeo copy' "${OCR_TEST_COMMAND_LOG}"; then
  fail 'rejected execute runs no mutation'
else
  pass 'rejected execute runs no mutation'
fi

export OCR_ACTION_APPROVAL='execute 1.21.3 config 1.1'
: >"${OCR_TEST_COMMAND_LOG}"
assert_eq '2' "$(run_rc "${SCRIPTS_DIR}/one-click-release.sh" execute 1.21.3 --stage config --step 1.1)" 'approved execute mutates then returns the re-verification blocker'
if grep -q 'workflow run release-new-patch.yaml' "${OCR_TEST_COMMAND_LOG}"; then pass 'approved execute invokes the intended mutation'; else fail 'approved execute invokes the intended mutation'; fi
: >"${OCR_TEST_COMMAND_LOG}"
assert_eq '2' "$(run_rc "${SCRIPTS_DIR}/one-click-release.sh" execute 1.21.3 --stage config --step 1.1)" 'safe rerun refuses to repeat a mutation while the same step still blocks'
if grep -q 'workflow run release-new-patch.yaml' "${OCR_TEST_COMMAND_LOG}"; then fail 'safe rerun avoids duplicate mutation'; else pass 'safe rerun avoids duplicate mutation'; fi

export OCR_PRODUCTION_APPROVAL='no'
assert_eq '3' "$(run_rc "${SCRIPTS_DIR}/one-click-release.sh" verify 1.21.3 --stage production-release)" 'production stage rejects missing distinct production approval'

export OCR_PRODUCTION_APPROVAL='start production-release 1.21.3'
export KONFLUX_SERVER='https://konflux.invalid'
export KONFLUX_TOKEN='placeholder-token-value'
assert_eq '2' "$(run_rc "${SCRIPTS_DIR}/one-click-release.sh" verify 1.21.3 --stage production-release)" 'production approval opens read-only verification and preserves blocker exit'

export OCR_TEST_OC_SCENARIO=image
assert_eq '0' "$(run_rc "${SCRIPTS_DIR}/one-click-release.sh" verify 1.21.3 --stage image-copy)" 'image-copy verification parses IIB release artifacts and matching quay digests'
assert_file "${OCR_REPORT_ROOT}/1.21/1.21.3/.state/image-copy-images.tsv" 'image-copy verification persists resumable digest state'
unset OCR_TEST_OC_SCENARIO

assert_eq '[REDACTED] and [REDACTED]' "$(GITHUB_TOKEN=github-secret KONFLUX_TOKEN=cluster-secret ocr_redact 'github-secret and cluster-secret')" 'secret redaction removes credential values'

unset OCR_PRODUCTION_APPROVAL
unset OCR_ACTION_APPROVAL
: >"${OCR_TEST_COMMAND_LOG}"
assert_eq '2' "$(run_rc "${SCRIPTS_DIR}/one-click-release.sh" verify 1.21.3 --stage config)" 'verification exits nonzero on the first blocker'
report="${OCR_REPORT_ROOT}/1.21/1.21.3/config/report_2026-09-28_12-00-00_UTC.md"
assert_file "${report}" 'verification writes the compatible report path'
if grep -q '^| 1.1 | Create new patch version | ACTION NEEDED |' "${report}"; then pass 'report records the blocking step'; else fail 'report records the blocking step'; fi
if grep -q '^BLOCKING_STEP=1\\.1$\|^BLOCKING_STEP=1.1$' "${OCR_REPORT_ROOT}/1.21/1.21.3/.state/config.state"; then pass 'resume state records the blocker'; else fail 'resume state records the blocker'; fi

assert_eq '2' "$(run_rc "${SCRIPTS_DIR}/one-click-release.sh" run 1.21.3 --through config)" 'run --through stops at a blocking stage'

export OCR_TEST_GH_SCENARIO=patch_pr
assert_eq '2' "$(run_rc "${SCRIPTS_DIR}/one-click-release.sh" verify 1.21.3 --stage config)" 'patch workflow handoff advances verification to the release-manager PR step'
if grep -q '^BLOCKING_STEP=1\\.2$\|^BLOCKING_STEP=1.2$' "${OCR_REPORT_ROOT}/1.21/1.21.3/.state/config.state"; then pass 'sequential state records step 1.2 after patch dispatch'; else fail 'sequential state records step 1.2 after patch dispatch'; fi
unset OCR_TEST_GH_SCENARIO

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
((FAIL == 0))
