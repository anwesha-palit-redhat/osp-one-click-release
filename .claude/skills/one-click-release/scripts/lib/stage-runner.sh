#!/usr/bin/env bash

ocr_step_is_skipped() {
  local step=$1 skip
  local IFS=','
  for skip in ${OCR_SKIP_STEPS:-}; do
    [[ "${skip}" == "${step}" ]] && return 0
  done
  return 1
}

ocr_verify_stage() {
  local version=$1
  ocr_init_context "${version}" || return 64
  ocr_report_init "${STAGE_NAME}" "${STAGE_REPORT_TITLE}" "${STAGE_REPORT_DIR}"

  local blocked=false prompt_shown=false step title rc skip_input
  for step in "${STAGE_STEPS[@]}"; do
    # --step: skip steps that aren't the requested one
    if [[ -n "${OCR_VERIFY_STEP:-}" && "${step}" != "${OCR_VERIFY_STEP}" ]]; then
      continue
    fi
    title=$(ocr_step_title "${step}")
    if ocr_step_is_skipped "${step}"; then
      ocr_report_add "${step}" "${title}" 'SKIPPED' 'skipped by user' '—'
      continue
    fi
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
        if [[ -z "${OCR_VERIFY_STEP:-}" && -z "${OCR_SKIP_PROMPT:-}" ]]; then
          printf 'BLOCKED: step %s — %s\n' "${step}" "${STEP_DETAILS:-credential unavailable}" >&2
          printf 'Type "s" to skip this step and proceed, or press Enter to stop: ' >&2
          IFS= read -r skip_input </dev/tty 2>/dev/null || true
          if [[ "${skip_input}" == [sS] ]]; then
            continue
          fi
          prompt_shown=true
        fi
        OCR_BLOCKING_STEP=${step}
        OCR_BLOCKING_DETAILS=${STEP_DETAILS:-credential unavailable}
        blocked=true
        ;;
      10 | *)
        ocr_report_add "${step}" "${title}" 'ACTION NEEDED' "${STEP_DETAILS:-verification failed}" "${STEP_LINKS:-—}"
        if [[ -z "${OCR_VERIFY_STEP:-}" && -z "${OCR_SKIP_PROMPT:-}" ]]; then
          printf 'BLOCKED: step %s — %s\n' "${step}" "${STEP_DETAILS:-verification failed}" >&2
          printf 'Type "s" to skip this step and proceed, or press Enter to stop: ' >&2
          IFS= read -r skip_input </dev/tty 2>/dev/null || true
          if [[ "${skip_input}" == [sS] ]]; then
            continue
          fi
          prompt_shown=true
        fi
        OCR_BLOCKING_STEP=${step}
        OCR_BLOCKING_DETAILS=${STEP_DETAILS:-verification failed}
        blocked=true
        ;;
    esac
  done

  ocr_report_write
  if [[ "${blocked}" == true ]]; then
    if [[ "${prompt_shown}" != true ]]; then
      printf 'BLOCKED: step %s — %s\n' "${OCR_BLOCKING_STEP}" "${OCR_BLOCKING_DETAILS}" >&2
    fi
    return 2
  fi
  printf '%s stage verified.\n' "${STAGE_NAME}"
}

ocr_run_through_stage() {
  local version=$1
  local stage_name=$2
  local scripts_dir=$3
  local wait_interval=${OCR_WAIT_INTERVAL:-300}
  local max_retries=${OCR_MAX_RETRIES:-60}

  # Extract step list from the stage's verify script.
  local _steps_line
  _steps_line=$(grep -m1 '^STAGE_STEPS=' "${scripts_dir}/${stage_name}/verify.sh")
  if [[ ! "${_steps_line}" =~ ^STAGE_STEPS=\( ]]; then
    printf 'Cannot parse STAGE_STEPS from %s/verify.sh\n' "${stage_name}" >&2
    return 64
  fi
  eval "${_steps_line}"
  local -a steps=("${STAGE_STEPS[@]}")

  local start_time step_count done_count=0
  local -a result_steps=() result_statuses=()
  local failed=false

  start_time=$(date +%s)
  step_count=${#steps[@]}

  printf '\n══════════════════════════════════════════════════════════\n'
  printf '  run-through: %s (%d steps)\n' "${stage_name}" "${step_count}"
  printf '══════════════════════════════════════════════════════════\n\n'

  local step skip skip_match verify_rc exec_rc retry

  for step in "${steps[@]}"; do
    # Check if step should be skipped (respects --skip / OCR_SKIP_STEPS).
    skip_match=false
    if [[ -n "${OCR_SKIP_STEPS:-}" ]]; then
      local IFS=','
      for skip in ${OCR_SKIP_STEPS}; do
        [[ "${skip}" == "${step}" ]] && skip_match=true
      done
      unset IFS
    fi

    if [[ "${skip_match}" == true ]]; then
      printf '  [%s] SKIPPED (by --skip)\n' "${step}"
      result_steps+=("${step}")
      result_statuses+=("SKIPPED")
      continue
    fi

    # Verify this step.
    verify_rc=0
    OCR_VERIFY_STEP="${step}" OCR_SKIP_PROMPT=1 \
      "${scripts_dir}/${stage_name}/verify.sh" "${version}" >/dev/null 2>&1 || verify_rc=$?

    if [[ ${verify_rc} -eq 0 ]]; then
      printf '  [%s] DONE\n' "${step}"
      result_steps+=("${step}")
      result_statuses+=("DONE")
      done_count=$((done_count + 1))
      continue
    fi

    # Step is blocked — auto-execute if execute.sh exists (no approval prompt).
    if [[ -x "${scripts_dir}/${stage_name}/execute.sh" ]]; then
      printf '  [%s] BLOCKED — auto-executing...\n' "${step}"
      exec_rc=0
      OCR_RUN_THROUGH=true OCR_SKIP_PROMPT=1 \
        "${scripts_dir}/${stage_name}/execute.sh" "${version}" "${step}" 2>&1 || exec_rc=$?
      if [[ ${exec_rc} -ne 0 ]]; then
        printf '  [%s] execute exited %d — polling for completion\n' "${step}" "${exec_rc}"
      fi
    else
      printf '  [%s] BLOCKED (verify-only) — polling for completion\n' "${step}"
    fi

    # Polling loop: re-verify until DONE or timeout.
    retry=0
    while true; do
      verify_rc=0
      OCR_VERIFY_STEP="${step}" OCR_SKIP_PROMPT=1 \
        "${scripts_dir}/${stage_name}/verify.sh" "${version}" >/dev/null 2>&1 || verify_rc=$?

      if [[ ${verify_rc} -eq 0 ]]; then
        printf '  [%s] DONE (after %d retries)\n' "${step}" "${retry}"
        result_steps+=("${step}")
        result_statuses+=("DONE")
        done_count=$((done_count + 1))
        break
      fi

      retry=$((retry + 1))
      if [[ ${retry} -ge ${max_retries} ]]; then
        printf '  [%s] TIMED OUT after %d retries\n' "${step}" "${max_retries}" >&2
        result_steps+=("${step}")
        result_statuses+=("TIMED_OUT")
        failed=true
        break
      fi

      printf '  [%s] still blocked — retry %d/%d (waiting %ds)\n' \
        "${step}" "${retry}" "${max_retries}" "${wait_interval}"
      sleep "${wait_interval}"
    done

    if [[ "${failed}" == true ]]; then
      break
    fi
  done

  # Summary report.
  local end_time elapsed_s
  end_time=$(date +%s)
  elapsed_s=$((end_time - start_time))

  printf '\n══════════════════════════════════════════════════════════\n'
  printf '  %s — run-through summary\n' "${stage_name}"
  printf '══════════════════════════════════════════════════════════\n'
  local i
  for ((i = 0; i < ${#result_steps[@]}; i++)); do
    printf '    [%-5s] %s\n' "${result_steps[i]}" "${result_statuses[i]}"
  done
  printf '  ────────────────────────────────────────────────────────\n'
  printf '    Completed: %d/%d\n' "${done_count}" "${step_count}"
  printf '    Elapsed:   %dh %dm %ds\n' \
    "$((elapsed_s / 3600))" "$(( (elapsed_s % 3600) / 60 ))" "$((elapsed_s % 60))"
  printf '══════════════════════════════════════════════════════════\n\n'

  [[ "${failed}" == true ]] && return 1
  return 0
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

  if [[ -n "${requested_step}" ]]; then
    # --step mode: verify only the requested step, skip sequential blocker pass
    set +e
    OCR_VERIFY_STEP="${requested_step}" OCR_SKIP_PROMPT=1 \
      "${STAGE_DIR}/verify.sh" "${version}" >/dev/null
    local verify_rc=$?
    set -e
    if [[ ${verify_rc} -eq 0 ]]; then
      if [[ -n "${OCR_FORCE:-}" ]]; then
        printf '%s step %s already done; --force re-executing.\n' "${STAGE_NAME}" "${requested_step}"
      else
        printf '%s step %s is already complete; nothing to execute.\n' "${STAGE_NAME}" "${requested_step}"
        return 0
      fi
    fi
  else
    # No --step: full sequential verify to find the next blocking step
    set +e
    OCR_SKIP_PROMPT=1 "${STAGE_DIR}/verify.sh" "${version}" >/dev/null
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
    requested_step=${blocking_step}
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
  if ! ocr_confirm_action "${STAGE_NAME}" "${requested_step}"; then
    if [[ -z "${2:-}" && -z "${OCR_RUN_THROUGH:-}" ]]; then
      local skip_input
      printf 'Type "s" to skip this step and proceed, or press Enter to stop: ' >&2
      IFS= read -r skip_input </dev/tty 2>/dev/null || true
      if [[ "${skip_input}" == [sS] ]]; then
        return 0
      fi
    fi
    return 3
  fi
  ocr_execute_step "${requested_step}"
  if [[ "${guard_rerun}" == true ]]; then
    date +"${TZ_FMT}" >"${mutation_marker}"
  fi
  local post_verify_rc skip_input
  set +e
  OCR_SKIP_PROMPT=1 "${STAGE_DIR}/verify.sh" "${version}"
  post_verify_rc=$?
  set -e
  if [[ ${post_verify_rc} -eq 2 && -z "${2:-}" ]]; then
    printf 'Type "s" to skip this step and proceed, or press Enter to stop: ' >&2
    IFS= read -r skip_input </dev/tty 2>/dev/null || true
    if [[ "${skip_input}" == [sS] ]]; then
      return 0
    fi
    return ${post_verify_rc}
  elif [[ ${post_verify_rc} -ne 0 ]]; then
    return ${post_verify_rc}
  fi
}
