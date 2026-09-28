#!/usr/bin/env bash

ocr_verify_stage() {
  local version=$1
  ocr_init_context "${version}" || return 64
  ocr_report_init "${STAGE_NAME}" "${STAGE_REPORT_TITLE}" "${STAGE_REPORT_DIR}"

  local blocked=false step title rc
  for step in "${STAGE_STEPS[@]}"; do
    title=$(ocr_step_title "${step}")
    if [[ "${blocked}" == true ]]; then
      ocr_report_add "${step}" "${title}" 'SKIPPED' 'not checked after blocking step' '—'
      continue
    fi

    STEP_DETAILS=''
    STEP_LINKS='—'
    set +e
    ocr_verify_step "${step}"
    rc=$?
    set -e
    case ${rc} in
      0)
        ocr_report_add "${step}" "${title}" 'DONE' "${STEP_DETAILS:-verified}" "${STEP_LINKS:-—}"
        ;;
      20)
        ocr_report_add "${step}" "${title}" 'SKIPPED' "${STEP_DETAILS:-credential unavailable}" "${STEP_LINKS:-—}"
        OCR_BLOCKING_STEP=${step}
        OCR_BLOCKING_DETAILS=${STEP_DETAILS:-credential unavailable}
        blocked=true
        ;;
      10 | *)
        ocr_report_add "${step}" "${title}" 'ACTION NEEDED' "${STEP_DETAILS:-verification failed}" "${STEP_LINKS:-—}"
        OCR_BLOCKING_STEP=${step}
        OCR_BLOCKING_DETAILS=${STEP_DETAILS:-verification failed}
        blocked=true
        ;;
    esac
  done

  ocr_report_write
  if [[ "${blocked}" == true ]]; then
    printf 'BLOCKED: step %s — %s\n' "${OCR_BLOCKING_STEP}" "${OCR_BLOCKING_DETAILS}" >&2
    return 2
  fi
  printf '%s stage verified.\n' "${STAGE_NAME}"
}

ocr_execute_stage() {
  local version=$1 requested_step=${2:-}
  ocr_init_context "${version}" || return 64

  if [[ "${STAGE_NAME}" == production-release ]]; then
    ocr_confirm_production || return 3
  fi

  local predecessor verify_output verify_rc
  case "${STAGE_NAME}" in
    config) ;;
    build) predecessor=config ;;
    image-copy) predecessor='config build' ;;
    production-release) predecessor='config build image-copy' ;;
  esac
  for predecessor in ${predecessor:-}; do
    set +e
    verify_output=$("${SCRIPTS_DIR}/${predecessor}/verify.sh" "${version}" 2>&1)
    verify_rc=$?
    set -e
    if ((verify_rc != 0)); then
      printf 'Refusing %s mutation: predecessor stage %s is incomplete. %s\n' \
        "${STAGE_NAME}" "${predecessor}" "$(ocr_redact "${verify_output}" | tail -1)" >&2
      return 2
    fi
  done

  set +e
  "${STAGE_DIR}/verify.sh" "${version}" >/dev/null
  local verify_rc=$?
  set -e
  if [[ ${verify_rc} -eq 0 ]]; then
    printf '%s stage is already complete; nothing to execute.\n' "${STAGE_NAME}"
    return 0
  fi
  local blocking_step
  blocking_step=$(ocr_state_blocking_step "${STAGE_NAME}") || {
    printf 'Unable to determine the blocking step; run verify first.\n' >&2
    return 2
  }
  if [[ -z "${requested_step}" ]]; then
    requested_step=${blocking_step}
  elif [[ "${requested_step}" != "${blocking_step}" ]]; then
    printf 'Refusing step %s: the freshly verified blocker is step %s.\n' "${requested_step}" "${blocking_step}" >&2
    return 2
  fi

  local valid=false step
  for step in "${STAGE_STEPS[@]}"; do
    [[ "${step}" == "${requested_step}" ]] && valid=true
  done
  [[ "${valid}" == true ]] || {
    printf 'Step %s does not belong to stage %s.\n' "${requested_step}" "${STAGE_NAME}" >&2
    return 64
  }

  local mutation_marker="${REPORT_BASE}/.state/executed-${STAGE_NAME}-${requested_step}"
  local guard_rerun=false
  case "${STAGE_NAME}:${requested_step}" in
    config:1.1 | build:2.2 | build:2.6 | production-release:4.5 | production-release:4.7) guard_rerun=true ;;
  esac
  if [[ "${guard_rerun}" == true && -f "${mutation_marker}" ]]; then
    printf 'Step %s was already executed for this release at %s. Re-verification still blocks; wait for propagation instead of repeating the mutation. Remove %s only after confirming an explicit retry is required.\n' \
      "${requested_step}" "$(<"${mutation_marker}")" "${mutation_marker}" >&2
    return 2
  fi

  ocr_describe_action "${requested_step}"
  ocr_confirm_action "${STAGE_NAME}" "${requested_step}" || return 3
  ocr_execute_step "${requested_step}"
  if [[ "${guard_rerun}" == true ]]; then
    date +"${TZ_FMT}" >"${mutation_marker}"
  fi
  "${STAGE_DIR}/verify.sh" "${version}"
}
