#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2317
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPTS_DIR=$(cd "${TEST_DIR}/.." && pwd)
CHECKOUT_ROOT=$(cd "${SCRIPTS_DIR}/../../../.." && pwd)
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

required_env=(
  GITHUB_TOKEN GH_TOKEN GITHUB_USER GITHUB_EMAIL
  KONFLUX_SERVER KONFLUX_TOKEN
  GITLAB_URL GITLAB_TOKEN
  JIRA_URL JIRA_EMAIL JIRA_TOKEN
  JIRA_RN_TEXT_FIELD JIRA_RN_TYPE_FIELD JIRA_RN_STATUS_FIELD
  QUAY_USER QUAY_PASSWORD
)
if bash -euo pipefail -c '
  source "$1"
  shift
  for name in "$@"; do [[ -n "${!name}" ]]; done
  [[ "${KONFLUX_SERVER}" == https://*.example.invalid ]]
  [[ "${GITLAB_URL}" == https://*.example.invalid ]]
  [[ "${JIRA_URL}" == https://*.example.invalid ]]
' _ "${CHECKOUT_ROOT}/.env.example" "${required_env[@]}"; then
  pass '.env.example is sourceable and defines every external variable with dummy values'
else
  fail '.env.example is sourceable and defines every external variable with dummy values'
fi
if grep -Eq '^(VERSION|RELEASE_BRANCH|KONFLUX_NS|OCR_[A-Z0-9_]*)=' "${CHECKOUT_ROOT}/.env.example"; then
  fail '.env.example excludes release targeting and authorization internals'
else
  pass '.env.example excludes release targeting and authorization internals'
fi
if git -C "${CHECKOUT_ROOT}" check-ignore -q .env && git -C "${CHECKOUT_ROOT}" check-ignore -q reports/example/report.md; then
  pass '.gitignore excludes local credentials and generated reports'
else
  fail '.gitignore excludes local credentials and generated reports'
fi
if git -C "${CHECKOUT_ROOT}" check-ignore -q .env.example; then
  fail '.env.example remains trackable'
else
  pass '.env.example remains trackable'
fi

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

printf '%s\n' \
  "OCR_ACTION_APPROVAL='execute 1.21.3 config 1.1'" \
  "OCR_PRODUCTION_APPROVAL='start production-release 1.21.3'" \
  "VERSION='9.9.9'" \
  "KONFLUX_NS='wrong-namespace'" \
  "OCR_KONFLUX_NS='attacker-namespace'" \
  "OCR_RC_BLOCKED='0'" \
  "OCR_RC_SKIPPED='0'" \
  'ocr_confirm_action() { return 0; }' \
  "GITHUB_TOKEN='\$(touch ${tmp}/env-command-ran)'" \
  >"${OCR_REPO_ROOT}/.env"
ocr_init_context 1.21.3
assert_eq '1.21.3|tekton-ecosystem-tenant' "${VERSION}|${KONFLUX_NS}" '.env cannot retarget the release version or fixed namespace'
assert_eq '10|20' "${OCR_RC_BLOCKED}|${OCR_RC_SKIPPED}" '.env cannot turn blocked or skipped gates into success'
if [[ -e "${tmp}/env-command-ran" ]]; then fail '.env is parsed as data without command execution'; else pass '.env is parsed as data without command execution'; fi
: >"${OCR_TEST_COMMAND_LOG}"
assert_eq '3' "$(run_rc "${SCRIPTS_DIR}/one-click-release.sh" execute 1.21.3 --stage config --step 1.1)" 'execute rejects missing exact action approval'
if grep -q 'workflow run\|pr merge\|git push\|oc create\|skopeo copy' "${OCR_TEST_COMMAND_LOG}"; then
  fail '.env helper injection cannot bypass invocation-scoped approval'
else
  pass '.env helper injection cannot bypass invocation-scoped approval'
fi
if grep -q 'source.*\.env' "${SCRIPTS_DIR}/image-copy/execute.sh"; then fail 'deferred copy script does not execute .env as shell code'; else pass 'deferred copy script does not execute .env as shell code'; fi

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

: >"${OCR_TEST_COMMAND_LOG}"
export OCR_TEST_GH_SCENARIO=config_match
export OCR_TEST_OC_SCENARIO=config_match
assert_eq '2' "$(run_rc "${SCRIPTS_DIR}/config/verify.sh" 1.21.3)" 'matching Step 1.4 fixture advances beyond the application comparison'
config_report="${OCR_REPORT_ROOT}/1.21/1.21.3/config/report_2026-09-28_12-00-00_UTC.md"
if grep -Fq '| 1.4 | Konflux config on cluster | DONE | 2 applications checked |' "${config_report}" &&
  grep -Fq $'openshift-pipelines-core\tcontroller,webhook\tcontroller,webhook\tOK' "${OCR_REPORT_ROOT}/1.21/1.21.3/.state/config-applications.tsv" &&
  grep -Fq $'openshift-pipelines-index-4.14\tindex\tindex\tOK' "${OCR_REPORT_ROOT}/1.21/1.21.3/.state/config-applications.tsv"; then
  pass 'Step 1.4 accepts exactly matching application names and components'
else
  fail 'Step 1.4 accepts exactly matching application names and components'
fi
if grep -Fxq 'paste -sd, -' "${OCR_TEST_COMMAND_LOG}"; then
  pass 'Step 1.4 uses strict BSD-compatible paste stdin syntax'
else
  fail 'Step 1.4 uses strict BSD-compatible paste stdin syntax'
fi

: >"${OCR_TEST_COMMAND_LOG}"
export OCR_TEST_GH_SCENARIO=config_missing_app
export OCR_TEST_OC_SCENARIO=config_missing_app
assert_eq '2' "$(run_rc "${SCRIPTS_DIR}/config/verify.sh" 1.21.3)" 'missing Step 1.4 index application fails closed'
if grep -Fq '| 1.4 | Konflux config on cluster | ACTION NEEDED | 2 applications checked; openshift-pipelines-index-4.14:MISSING_APP |' "${config_report}" &&
  grep -Fq $'openshift-pipelines-core\tcontroller,webhook\tcontroller,webhook\tOK' "${OCR_REPORT_ROOT}/1.21/1.21.3/.state/config-applications.tsv" &&
  grep -Fq $'openshift-pipelines-index-4.14\tindex\t\tMISSING' "${OCR_REPORT_ROOT}/1.21/1.21.3/.state/config-applications.tsv"; then
  pass 'Step 1.4 reports an omitted index application as MISSING_APP'
else
  fail 'Step 1.4 reports an omitted index application as MISSING_APP'
fi

export OCR_TEST_GH_SCENARIO=config_component_api_fail
export OCR_TEST_OC_SCENARIO=config_component_api_fail
assert_eq '2' "$(run_rc "${SCRIPTS_DIR}/config/verify.sh" 1.21.3)" 'Step 1.4 blocks when an expected component listing fails'
if grep -Fq '| 1.4 | Konflux config on cluster | ACTION NEEDED | unable to list expected components for openshift-pipelines-index-4.14 |' "${config_report}" &&
  [[ ! -s "${OCR_REPORT_ROOT}/1.21/1.21.3/.state/config-applications.tsv" ]]; then
  pass 'Step 1.4 fails closed without retaining stale component parity state'
else
  fail 'Step 1.4 fails closed without retaining stale component parity state'
fi
unset OCR_TEST_GH_SCENARIO OCR_TEST_OC_SCENARIO

assert_eq '[REDACTED] and [REDACTED]' "$(GITHUB_TOKEN=github-secret KONFLUX_TOKEN=cluster-secret ocr_redact 'github-secret and cluster-secret')" 'secret redaction removes credential values'
assert_eq 'prefix [REDACTED] [REDACTED] suffix' "$(GITHUB_TOKEN='a[b]c' KONFLUX_TOKEN='a\b' ocr_redact 'prefix a[b]c a\b suffix')" 'secret redaction treats glob and escape characters literally'
assert_eq 'token=[REDACTED]' "$(GITHUB_TOKEN=abc GH_TOKEN=abc123 ocr_redact 'token=abc123')" 'secret redaction handles overlapping values longest-first'

for conclusion in timed_out action_required startup_failure stale skipped cancelled failure ''; do
  if ocr_workflow_succeeded "${conclusion}"; then fail "production rejects non-success workflow conclusion ${conclusion:-missing}"; else pass "production rejects non-success workflow conclusion ${conclusion:-missing}"; fi
done
if ocr_workflow_succeeded success; then pass 'production accepts only a successful workflow conclusion'; else fail 'production accepts only a successful workflow conclusion'; fi

production_diff=$'+olm/release-stage.txt\n+production\n+  image: registry.redhat.io/openshift-pipelines/pipelines-controller@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
mixed_diff="${production_diff}"$'\n+  image: quay.io/openshift-pipeline/pipelines-webhook@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
unknown_diff="${production_diff}"$'\n+  image: images.example.com/team/unknown@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
tagged_diff="${production_diff}"$'\n+  image: quay.io/attacker/evil:latest'
prod_tag_diff=$'+ image: registry.redhat.io/openshift-pipelines/controller:latest'
pullspec_diff="${production_diff}"$'\n+ pullspec: images.example.com/team/evil:latest'
if ocr_diff_has_only_production_images "${production_diff}"; then pass 'production diff requires exact production-registry evidence'; else fail 'production diff requires exact production-registry evidence'; fi
if ocr_diff_has_only_production_images "${mixed_diff}"; then fail 'production diff rejects mixed-registry evidence'; else pass 'production diff rejects mixed-registry evidence'; fi
if ocr_diff_has_only_production_images "${unknown_diff}"; then fail 'production diff rejects unknown registry evidence'; else pass 'production diff rejects unknown registry evidence'; fi
if ocr_diff_has_only_production_images "${tagged_diff}"; then fail 'production diff rejects mutable non-production tags'; else pass 'production diff rejects mutable non-production tags'; fi
if ocr_diff_has_only_production_images "${prod_tag_diff}"; then fail 'production diff requires immutable production digests'; else pass 'production diff requires immutable production digests'; fi
if ocr_diff_has_only_production_images "${pullspec_diff}"; then fail 'production diff rejects alternate non-production pullspec keys'; else pass 'production diff rejects alternate non-production pullspec keys'; fi
if ocr_diff_has_only_production_images '+production'; then fail 'production diff rejects missing image evidence'; else pass 'production diff rejects missing image evidence'; fi

release_retry_history='{"items":[{"metadata":{"name":"old-failed","creationTimestamp":"2026-09-28T10:00:00Z"},"spec":{"releasePlan":"rp","snapshot":"snap"},"status":{"conditions":[{"type":"Released","status":"False"}]}},{"metadata":{"name":"new-success","creationTimestamp":"2026-09-28T11:00:00Z"},"spec":{"releasePlan":"rp","snapshot":"snap"},"status":{"conditions":[{"type":"Released","status":"True"}]}}]}'
retry_lookup=$(
  source "${SCRIPTS_DIR}/production-release/execute.sh"
  ocr_oc_get() { printf '%s\n' "${release_retry_history}"; }
  existing_release_for_snapshot rp snap
)
assert_eq 'new-success|True' "${retry_lookup}" 'Release retry lookup selects the newest existing attempt without jq failure'

if (
  git() { return 0; }
  ocr_remote_branch_exists owner/repo release/branch
); then pass 'partial retry detects an already-pushed remote branch'; else fail 'partial retry detects an already-pushed remote branch'; fi
if (
  git() { return 0; }
  gh() { printf '%s\n' '{"status":"ahead","files":[{"filename":"project.yaml","patch":"-current: 1.2.2\n+current: 1.2.3"}]}'; }
  ocr_remote_branch_matches owner/repo base branch '^project\.yaml$' '^current:' '^current: 1\.2\.3$'
); then pass 'partial retry validates the existing branch mutation scope'; else fail 'partial retry validates the existing branch mutation scope'; fi
assert_eq '2' "$(run_rc bash -c 'source "$1"; git() { return 0; }; gh() { printf "%s\n" '\''{"status":"ahead","files":[{"filename":"unexpected.sh","patch":"+bad"}]}'\''; }; ocr_remote_branch_matches owner/repo base branch "^project\\.yaml$" "^current:" "^current: 1\\.2\\.3$"' _ "${SCRIPTS_DIR}/lib/common.sh")" 'partial retry rejects an unexpected existing branch diff'
assert_eq '2' "$(run_rc bash -c 'source "$1"; git() { return 0; }; gh() { printf "%s\n" '\''{"status":"ahead","files":[{"filename":"project.yaml","patch":"+malicious: true"}]}'\''; }; ocr_remote_branch_matches owner/repo base branch "^project\\.yaml$" "^current:" "^current: 1\\.2\\.3$"' _ "${SCRIPTS_DIR}/lib/common.sh")" 'partial retry rejects an unexpected semantic change in an allowed file'
assert_eq '1' "$(run_rc bash -c 'source "$1"; git() { return 2; }; ocr_remote_branch_exists owner/repo release/branch' _ "${SCRIPTS_DIR}/lib/common.sh")" 'partial retry distinguishes an absent remote branch'
assert_eq '2' "$(run_rc bash -c 'source "$1"; git() { return 128; }; ocr_remote_branch_exists owner/repo release/branch' _ "${SCRIPTS_DIR}/lib/common.sh")" 'partial retry fails closed when remote branch lookup fails'
recovery_count=$(grep -Rhc 'ocr_remote_branch_matches' "${SCRIPTS_DIR}/config/execute.sh" "${SCRIPTS_DIR}/build/execute.sh" | awk '{n+=$1} END {print n}')
if ((recovery_count >= 5)); then pass 'all fixed-branch PR mutations include partial-push recovery'; else fail 'all fixed-branch PR mutations include partial-push recovery'; fi

assert_eq '0' "$(run_rc bash -c 'source "$1"; gh() { printf "%s\n" cHJvZHVjdGlvbgo=; }; ocr_operator_release_stage_at abc' _ "${SCRIPTS_DIR}/lib/common.sh")" 'snapshot evidence identifies a proven production catalog'
assert_eq '1' "$(run_rc bash -c 'source "$1"; gh() { printf "%s\n" ZGV2ZWwK; }; ocr_operator_release_stage_at abc' _ "${SCRIPTS_DIR}/lib/common.sh")" 'snapshot evidence distinguishes a proven non-production catalog'
assert_eq '2' "$(run_rc bash -c 'source "$1"; gh() { return 1; }; ocr_operator_release_stage_at abc' _ "${SCRIPTS_DIR}/lib/common.sh")" 'snapshot evidence distinguishes an API failure from non-production state'
if grep -q 'retaining the pre-dispatch baseline' "${SCRIPTS_DIR}/production-release/execute.sh" && grep -q 'single pending file' "${SCRIPTS_DIR}/../SETUP.md"; then pass 'ambiguous dispatch recovery retains and documents its invocation state'; else fail 'ambiguous dispatch recovery retains and documents its invocation state'; fi
if grep -q 'commit.committer.date' "${SCRIPTS_DIR}/production-release/execute.sh" && grep -q 'recorded_commit_at' "${SCRIPTS_DIR}/production-release/verify.sh"; then pass 'catalog PR head commit is correlated to the production workflow run'; else fail 'catalog PR head commit is correlated to the production workflow run'; fi

export OCR_TEST_GH_SCENARIO=run_list_fail
if (
  source "${SCRIPTS_DIR}/build/execute.sh"
  wait_in_progress_runs render-olm-catalog.yaml
); then fail 'workflow-list API failure blocks duplicate dispatch'; else pass 'workflow-list API failure blocks duplicate dispatch'; fi
unset OCR_TEST_GH_SCENARIO

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
