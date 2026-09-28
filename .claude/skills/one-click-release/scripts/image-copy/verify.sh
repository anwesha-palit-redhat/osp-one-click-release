#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -euo pipefail

STAGE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPTS_DIR=$(cd "${STAGE_DIR}/.." && pwd)
source "${SCRIPTS_DIR}/lib/common.sh"
source "${SCRIPTS_DIR}/lib/report.sh"
source "${SCRIPTS_DIR}/lib/stage-runner.sh"

STAGE_NAME='image-copy'
STAGE_REPORT_TITLE='Image Copy Stage Report'
STAGE_REPORT_DIR='image-copy'
STAGE_STEPS=(3.1 3.2)

ocr_step_title() {
  case "$1" in
    3.1) printf '%s' 'Extract IIB image digests' ;;
    3.2) printf '%s' 'Copy IIB index images to quay.io' ;;
  esac
}

image_state_file() { printf '%s/.state/image-copy-images.tsv' "${REPORT_BASE}"; }

verify_3_1() {
  ocr_require_konflux || return $?
  local releases state count bad releases_file
  releases=$(ocr_oc_get releases -o json 2>/dev/null) || {
    STEP_DETAILS='unable to query stage release CRs'
    return "${OCR_RC_BLOCKED}"
  }
  state=$(image_state_file)
  releases_file=$(mktemp)
  printf '%s\n' "${releases}" >"${releases_file}"
  python3 - "${MM_DASHED}" "${VERSION}" "${releases_file}" >"${state}" <<'PY'
import json,re,sys
mm,version,path=sys.argv[1:]
data=json.load(open(path))
for item in sorted(data.get('items',[]),key=lambda x:x['metadata']['name']):
    rp=item.get('spec',{}).get('releasePlan','')
    if mm not in rp or 'stage' not in rp or not ('fbc' in rp or 'index' in rp): continue
    cond=next((c for c in item.get('status',{}).get('conditions',[]) if c.get('type')=='Released'),{})
    art=item.get('status',{}).get('artifacts',{})
    image=(art.get('indexImageResolved') or art.get('indexImage') or
           art.get('iibIndexImageResolved') or art.get('index_image_resolved') or '')
    m=re.search(r'index-(.+?)-'+re.escape(mm)+r'-stage',rp)
    ocp=(m.group(1).replace('-','.',1) if m else 'unknown')
    target=f'quay.io/openshift-pipeline/pipelines-index-{ocp}:v{version}-stage'
    print('\t'.join([item['metadata']['name'],rp,cond.get('status','Unknown'),image,ocp,target]))
PY
  rm -f "${releases_file}"
  count=$(wc -l <"${state}" | tr -d ' ')
  bad=$(awk -F'\t' '$3 != "True" || $4 !~ /^registry-proxy\.engineering\.redhat\.com\/rh-osbs\/iib@sha256:/ {n++} END {print n+0}' "${state}")
  STEP_DETAILS="${count} index stage releases; ${bad} failed or missing IIB digest"
  ((count > 0 && bad == 0)) || return "${OCR_RC_BLOCKED}"
}

verify_3_2() {
  local state source_digest target inspected target_digest bad=0 count=0
  state=$(image_state_file)
  [[ -s "${state}" ]] || {
    STEP_DETAILS='no extracted IIB image state; complete step 3.1'
    return "${OCR_RC_BLOCKED}"
  }
  if ! command -v skopeo >/dev/null 2>&1; then
    STEP_DETAILS='skopeo not installed; approved execution can generate a copy script'
    return "${OCR_RC_BLOCKED}"
  fi
  while IFS=$'\t' read -r _release _rp _status image _ocp target; do
    ((count += 1))
    source_digest=${image##*@}
    inspected=$(skopeo inspect --no-tags "docker://${target}" 2>/dev/null || true)
    target_digest=$(jq -r '.Digest // empty' <<<"${inspected:-{}}" 2>/dev/null || true)
    [[ "${target_digest}" == "${source_digest}" ]] || ((bad += 1))
  done <"${state}"
  STEP_DETAILS="$((count - bad))/${count} quay index images match IIB digests"
  ((count > 0 && bad == 0)) || return "${OCR_RC_BLOCKED}"
}

ocr_verify_step() { case "$1" in 3.1) verify_3_1 ;; 3.2) verify_3_2 ;; esac }
ocr_verify_stage "${1:-}"
