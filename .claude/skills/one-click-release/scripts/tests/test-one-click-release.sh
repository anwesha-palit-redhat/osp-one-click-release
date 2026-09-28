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

run_rc_input() {
  local input=$1
  shift
  set +e
  printf '%s\n' "${input}" | "$@" >/tmp/ocr-test.out 2>/tmp/ocr-test.err
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
# shellcheck source=../lib/report.sh
source "${SCRIPTS_DIR}/lib/report.sh"

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

printf '%s\n' "OCR_ACTION_APPROVAL='execute 1.21.3 config 1.1'" "OCR_PRODUCTION_APPROVAL='start production-release 1.21.3'" "VERSION='9.9.9'" "KONFLUX_NS='wrong-namespace'" >"${OCR_REPO_ROOT}/.env"
ocr_init_context 1.21.3
assert_eq '1.21.3|tekton-ecosystem-tenant' "${VERSION}|${KONFLUX_NS}" '.env cannot retarget the release version or fixed namespace'
: >"${OCR_TEST_COMMAND_LOG}"
assert_eq '3' "$(run_rc "${SCRIPTS_DIR}/one-click-release.sh" execute 1.21.3 --stage config --step 1.1)" 'execute rejects missing exact action approval'
if grep -q 'workflow run\|pr merge\|git push\|oc create\|skopeo copy' "${OCR_TEST_COMMAND_LOG}"; then
  fail 'rejected execute runs no mutation'
else
  pass 'rejected execute runs no mutation'
fi

: >"${OCR_TEST_COMMAND_LOG}"
assert_eq '2' "$(run_rc_input 'execute 1.21.3 config 1.1' "${SCRIPTS_DIR}/one-click-release.sh" execute 1.21.3 --stage config --step 1.1)" 'current-invocation approval mutates then returns the re-verification blocker'
if grep -q 'workflow run release-new-patch.yaml' "${OCR_TEST_COMMAND_LOG}"; then pass 'approved execute invokes the intended mutation'; else fail 'approved execute invokes the intended mutation'; fi
: >"${OCR_TEST_COMMAND_LOG}"
assert_eq '2' "$(run_rc_input 'execute 1.21.3 config 1.1' "${SCRIPTS_DIR}/one-click-release.sh" execute 1.21.3 --stage config --step 1.1)" 'safe rerun refuses to repeat a mutation while the same step still blocks'
if grep -q 'workflow run release-new-patch.yaml' "${OCR_TEST_COMMAND_LOG}"; then fail 'safe rerun avoids duplicate mutation'; else pass 'safe rerun avoids duplicate mutation'; fi

assert_eq '3' "$(run_rc "${SCRIPTS_DIR}/one-click-release.sh" verify 1.21.3 --stage production-release)" 'production stage rejects missing distinct production approval'

export KONFLUX_SERVER='https://konflux.invalid'
export KONFLUX_TOKEN='placeholder-token-value'
assert_eq '2' "$(run_rc_input 'start production-release 1.21.3' "${SCRIPTS_DIR}/one-click-release.sh" verify 1.21.3 --stage production-release)" 'current-invocation production approval opens read-only verification and preserves blocker exit'

export OCR_TEST_OC_SCENARIO=image
assert_eq '0' "$(run_rc "${SCRIPTS_DIR}/one-click-release.sh" verify 1.21.3 --stage image-copy)" 'image-copy verification parses IIB release artifacts and matching quay digests'
assert_file "${OCR_REPORT_ROOT}/1.21/1.21.3/.state/image-copy-images.tsv" 'image-copy verification persists resumable digest state'
assert_eq 'index-stage-retry' "$(cut -f1 "${OCR_REPORT_ROOT}/1.21/1.21.3/.state/image-copy-images.tsv")" 'successful Release retry supersedes the historical failed CR'
if grep -q -- '--token\|placeholder-token-value' "${OCR_TEST_COMMAND_LOG}"; then fail 'Konflux token is absent from process arguments'; else pass 'Konflux token is absent from process arguments'; fi
unset OCR_TEST_OC_SCENARIO

assert_eq '[REDACTED] and [REDACTED]' "$(GITHUB_TOKEN=github-secret KONFLUX_TOKEN=cluster-secret ocr_redact 'github-secret and cluster-secret')" 'secret redaction removes credential values'

ocr_record_workflow_run production-proof render-olm-catalog.yaml production "${RELEASE_BRANCH}" 12345 2026-09-28T12:00:00Z
ocr_load_workflow_run production-proof
assert_eq 'production|release-v1.21.x|12345' "${ENVIRONMENT}|${BRANCH}|${RUN_ID}" 'workflow provenance binds environment, branch, and exact run ID'
if ocr_workflow_log_has_environment 12345 production; then pass 'production workflow evidence verifies the actual logged environment input'; else fail 'production workflow evidence verifies the actual logged environment input'; fi
ocr_record_workflow_run staging-proof render-olm-catalog.yaml staging "${RELEASE_BRANCH}" 12346 2026-09-28T12:01:00Z
if ocr_workflow_provenance_matches staging-proof render-olm-catalog.yaml production "${RELEASE_BRANCH}"; then fail 'production provenance rejects staging evidence'; else pass 'production provenance rejects staging evidence'; fi
if ocr_workflow_log_has_environment 12346 production; then fail 'production workflow evidence rejects a logged staging input'; else pass 'production workflow evidence rejects a logged staging input'; fi

release_history='{"items":[{"metadata":{"creationTimestamp":"2026-09-28T12:00:00Z"},"spec":{"releasePlan":"openshift-pipelines-1-21-core-stage-rp","snapshot":"new-snapshot"},"status":{"conditions":[{"type":"Released","status":"True"}]}},{"metadata":{"creationTimestamp":"2026-09-27T12:00:00Z"},"spec":{"releasePlan":"openshift-pipelines-1-21-core-stage-rp","snapshot":"old-snapshot"},"status":{"conditions":[{"type":"Released","status":"True"}]}}]}'
assert_eq 'new-snapshot' "$(ocr_latest_successful_release_snapshot "${release_history}" core stage cdn)" 'successful snapshot selection is deterministic by creation timestamp'

export OCR_TEST_GH_SCENARIO=generated_good
if ocr_operator_revision_is_generated old new; then pass 'bot actor plus generated-path provenance allows an automated revision gap'; else fail 'bot actor plus generated-path provenance allows an automated revision gap'; fi
export OCR_TEST_GH_SCENARIO=generated_bad
if ocr_operator_revision_is_generated old new; then fail 'human substantive commits cannot be classified as an automated gap'; else pass 'human substantive commits cannot be classified as an automated gap'; fi
unset OCR_TEST_GH_SCENARIO

ocr_mark_mutation compound-first-action
if ocr_mutation_done compound-first-action; then pass 'per-mutation progress marker survives a partial compound step'; else fail 'per-mutation progress marker survives a partial compound step'; fi

: >"${OCR_TEST_COMMAND_LOG}"
assert_eq '2' "$(run_rc "${SCRIPTS_DIR}/one-click-release.sh" execute 1.21.3 --stage build --step 2.1)" 'direct build mutation refuses to bypass incomplete config stage'
if grep -q 'pr merge\|pr review\|pr edit' "${OCR_TEST_COMMAND_LOG}"; then fail 'predecessor rejection runs no downstream mutation'; else pass 'predecessor rejection runs no downstream mutation'; fi

export OCR_TEST_GH_SCENARIO=api_fail
export GH_TOKEN=fixture-secret
assert_eq '2' "$(run_rc "${SCRIPTS_DIR}/one-click-release.sh" verify 1.21.3 --stage build)" 'GitHub API failure blocks instead of becoming an empty PR result'
if grep -q 'fixture-secret' /tmp/ocr-test.err; then fail 'captured GitHub errors are redacted'; else pass 'captured GitHub errors are redacted'; fi
unset OCR_TEST_GH_SCENARIO
unset GH_TOKEN

GITHUB_TOKEN='report-secret'
export GITHUB_TOKEN
ocr_report_init config 'Redaction Test' config
ocr_report_add 1.1 'Secret-bearing error' 'ACTION NEEDED' 'API rejected report-secret' '—'
ocr_report_write >/dev/null
if grep -R 'report-secret' "${OCR_REPORT_ROOT}/1.21/1.21.3/config"; then fail 'runtime report path redacts secrets'; else pass 'runtime report path redacts secrets'; fi
unset GITHUB_TOKEN

if grep -q 'assist|tekton-assist|openshift-pipelines/tekton-assist' "${SCRIPTS_DIR}/config/verify.sh" && grep -q 'Product Version Metadata' "${SCRIPTS_DIR}/config/verify.sh"; then pass 'config parity covers assist and all product metadata'; else fail 'config parity covers assist and all product metadata'; fi
if grep -q 'stage-core-snapshot' "${SCRIPTS_DIR}/production-release/execute.sh" && grep -q 'no locally recorded production CSV dispatch' "${SCRIPTS_DIR}/production-release/verify.sh"; then pass 'production uses pinned stage snapshot and recorded production-only evidence'; else fail 'production uses pinned stage snapshot and recorded production-only evidence'; fi
if grep -q "manifest/\${manifest_dir}" "${SCRIPTS_DIR}/lib/report.sh" && grep -q 'Index Image Evidence' "${SCRIPTS_DIR}/lib/report.sh"; then pass 'reports retain scoped manifest metadata and image source/target evidence'; else fail 'reports retain scoped manifest metadata and image source/target evidence'; fi

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
