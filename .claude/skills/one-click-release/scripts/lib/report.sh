#!/usr/bin/env bash

ocr_report_init() {
  local stage=$1 title=$2 report_dir=$3
  OCR_STAGE=${stage}
  OCR_STAGE_TITLE=${title}
  OCR_REPORT_FILE="${REPORT_BASE}/${report_dir}/report_${REPORT_TIMESTAMP}.md"
  OCR_REPORT_ROWS=$(mktemp)
  OCR_STATE_FILE="${REPORT_BASE}/.state/${stage}.state"
  OCR_BLOCKING_STEP=''
  OCR_BLOCKING_DETAILS=''
}

ocr_md_cell() {
  local value=${1:-—}
  value=${value//$'\n'/<br>}
  value=${value//|/\\|}
  printf '%s' "${value}"
}

ocr_report_add() {
  local step=$1 title=$2 status=$3 details=${4:-—} links=${5:-—}
  details=$(ocr_redact "${details}")
  links=$(ocr_redact "${links}")
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "${step}" "${title}" "${status}" \
    "$(ocr_md_cell "${details}")" "$(ocr_md_cell "${links}")" \
    >>"${OCR_REPORT_ROWS}"
}

ocr_report_write() {
  {
    printf '# %s — %s\n\n' "${OCR_STAGE_TITLE}" "${VERSION}"
    printf '**Generated:** %s  \n' "${REPORT_TIMESTAMP}"
    printf '**Release:** %s (%s)  \n' "${VERSION}" "${MAJOR_MINOR}"
    printf '**Branch:** %s\n\n' "${RELEASE_BRANCH}"
    printf '## Summary\n\n'
    printf '| Step | Title | Status | Details | Links |\n'
    printf '|------|-------|--------|---------|-------|\n'
    while IFS=$'\t' read -r step title status details links; do
      printf '| %s | %s | %s | %s | %s |\n' "${step}" "${title}" "${status}" "${details}" "${links}"
    done <"${OCR_REPORT_ROWS}"
    printf '\n## Step Details\n'
    while IFS=$'\t' read -r step title status details links; do
      printf '\n### Step %s: %s\n\n' "${step}" "${title}"
      printf -- '- **Status:** %s\n' "${status}"
      printf -- '- **Details:** %s\n' "${details}"
      printf -- '- **Links:** %s\n' "${links}"
    done <"${OCR_REPORT_ROWS}"
    if [[ "${OCR_STAGE}" == build || "${OCR_STAGE}" == production-release ]]; then
      printf '\n## Release Manifests\n\n'
      printf '| File | Application | Release Plan | Snapshot |\n'
      printf '|------|-------------|--------------|----------|\n'
      local manifest found=false manifest_dir
      if [[ "${OCR_STAGE}" == build ]]; then manifest_dir=stage; else manifest_dir=prod; fi
      while IFS= read -r manifest; do
        found=true
        local app rp snapshot
        app=$(awk '/appstudio.openshift.io\/application:/ {print $2; exit}' "${manifest}")
        rp=$(awk '/^  releasePlan:/ {print $2; exit}' "${manifest}")
        snapshot=$(awk '/^  snapshot:/ {print $2; exit}' "${manifest}")
        printf '| %s | %s | %s | %s |\n' "${manifest#"${REPORT_BASE}"/}" "${app:-—}" "${rp:-—}" "${snapshot:-—}"
      done < <(find "${REPORT_BASE}/manifest/${manifest_dir}" -type f -name "release-${VERSION}-*.yaml" -print | sort)
      [[ "${found}" == true ]] || printf '| — | — | — | — |\n'
    fi
    if [[ "${OCR_STAGE}" == image-copy && -s "${REPORT_BASE}/.state/image-copy-images.tsv" ]]; then
      printf '\n## Index Image Evidence\n\n'
      printf '| Release | Release Plan | Snapshot | IIB Source | OCP Version | Quay Target |\n'
      printf '|---------|--------------|----------|------------|-------------|-------------|\n'
      while IFS=$'\t' read -r release rp _status image ocp target snapshot; do
        printf '| %s | %s | %s | %s | %s | %s |\n' "${release}" "${rp}" "${snapshot:-—}" "${image}" "${ocp}" "${target}"
      done <"${REPORT_BASE}/.state/image-copy-images.tsv"
    fi
    local workflow_state workflow_found=false
    for workflow_state in "${REPORT_BASE}"/.state/workflow-*.state; do
      [[ -f "${workflow_state}" ]] || continue
      if [[ "${workflow_found}" == false ]]; then
        printf '\n## Workflow Provenance\n\n| Workflow | Environment | Branch | Run ID | Created |\n|----------|-------------|--------|--------|---------|\n'
        workflow_found=true
      fi
      WORKFLOW='' ENVIRONMENT='' BRANCH='' RUN_ID='' CREATED_AT=''
      # shellcheck disable=SC1090
      source "${workflow_state}"
      printf '| %s | %s | %s | %s | %s |\n' "${WORKFLOW}" "${ENVIRONMENT}" "${BRANCH}" "${RUN_ID}" "$(ocr_abs_time "${CREATED_AT}")"
    done
    if declare -F ocr_report_stage_details >/dev/null; then
      ocr_report_stage_details || true
    fi
    if [[ -n "${OCR_BLOCKING_STEP}" ]]; then
      printf '\n## Blocking Step\n\n'
      printf '**Step %s:** %s\n' "${OCR_BLOCKING_STEP}" "$(ocr_md_cell "${OCR_BLOCKING_DETAILS}")"
    fi
  } >"${OCR_REPORT_FILE}"

  {
    printf 'VERSION=%q\n' "${VERSION}"
    printf 'STAGE=%q\n' "${OCR_STAGE}"
    printf 'BLOCKING_STEP=%q\n' "${OCR_BLOCKING_STEP}"
    printf 'BLOCKING_DETAILS=%q\n' "${OCR_BLOCKING_DETAILS}"
    printf 'REPORT_FILE=%q\n' "${OCR_REPORT_FILE}"
  } >"${OCR_STATE_FILE}"

  printf 'Report written to: %s\n' "$(ocr_report_path_display "${OCR_REPORT_FILE}")"
  rm -f "${OCR_REPORT_ROWS}"
}

ocr_state_blocking_step() {
  local stage=$1
  local state_file="${REPORT_BASE}/.state/${stage}.state"
  [[ -f "${state_file}" ]] || return 1
  local blocking_step
  blocking_step=$(sed -n 's/^BLOCKING_STEP=//p' "${state_file}")
  [[ "${blocking_step}" =~ ^[1-4]\.[0-9]+[a-z]?$ ]] || return 1
  printf '%s\n' "${blocking_step}"
}
