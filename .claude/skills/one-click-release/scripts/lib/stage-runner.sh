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
          printf '%s⚠ BLOCKED:%s step %s — %s\n' "${OCR_YELLOW}${OCR_BOLD}" "${OCR_RESET}" "${step}" "${STEP_DETAILS:-credential unavailable}" >&2
          printf '%sType "s" to skip this step and proceed, or press Enter to stop:%s ' "${OCR_DIM}" "${OCR_RESET}" >&2
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
          printf '%s✖ BLOCKED:%s step %s — %s\n' "${OCR_RED}${OCR_BOLD}" "${OCR_RESET}" "${step}" "${STEP_DETAILS:-verification failed}" >&2
          printf '%sType "s" to skip this step and proceed, or press Enter to stop:%s ' "${OCR_DIM}" "${OCR_RESET}" >&2
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
      printf '%s✖ BLOCKED:%s step %s — %s\n' "${OCR_RED}${OCR_BOLD}" "${OCR_RESET}" "${OCR_BLOCKING_STEP}" "${OCR_BLOCKING_DETAILS}" >&2
    fi
    return 2
  fi
  printf '%s✔ %s stage verified.%s\n' "${OCR_GREEN}${OCR_BOLD}" "${STAGE_NAME}" "${OCR_RESET}"
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

  # Extract manual-only steps from the stage's execute script (if declared).
  # These are skipped in run-through mode without attempting auto-execute.
  local -a _manual_steps=()
  local _manual_line
  _manual_line=$(grep -m1 '^STAGE_RUN_THROUGH_MANUAL_STEPS=' "${scripts_dir}/${stage_name}/execute.sh" 2>/dev/null || true)
  if [[ "${_manual_line}" =~ ^STAGE_RUN_THROUGH_MANUAL_STEPS=\( ]]; then
    eval "_manual_steps=${_manual_line#*=}"
  fi
  eval "${_steps_line}"
  local -a steps=("${STAGE_STEPS[@]}")

  local start_time step_count done_count=0
  local -a result_steps=() result_statuses=()
  local failed=false

  start_time=$(date +%s)
  step_count=${#steps[@]}

  printf '\n%s╔══════════════════════════════════════════════════════════╗%s\n' "${OCR_CYAN}" "${OCR_RESET}"
  printf '%s║%s  %srun-through:%s %s%s%s %s(%d steps)%s\n' \
    "${OCR_CYAN}" "${OCR_RESET}" "${OCR_BOLD}" "${OCR_RESET}" \
    "${OCR_WHITE}" "${stage_name}" "${OCR_RESET}" \
    "${OCR_DIM}" "${step_count}" "${OCR_RESET}"
  printf '%s╚══════════════════════════════════════════════════════════╝%s\n\n' "${OCR_CYAN}" "${OCR_RESET}"

  local step skip skip_match verify_rc exec_rc retry

  for step in "${steps[@]}"; do
    # Check if step should be skipped (respects --skip / OCR_SKIP_STEPS).
    skip_match=false
    if [[ -n "${OCR_SKIP_STEPS:-}" ]]; then
      local _ifs_save="${IFS}"
      IFS=','
      for skip in ${OCR_SKIP_STEPS}; do
        [[ "${skip}" == "${step}" ]] && skip_match=true
      done
      IFS="${_ifs_save}"
    fi

    if [[ "${skip_match}" == true ]]; then
      printf '  %s[%s]%s %sSKIPPED%s %s(by --skip)%s\n' \
        "${OCR_DIM}" "${step}" "${OCR_RESET}" \
        "${OCR_YELLOW}" "${OCR_RESET}" "${OCR_DIM}" "${OCR_RESET}"
      result_steps+=("${step}")
      result_statuses+=("SKIPPED")
      continue
    fi

    # Verify this step.
    verify_rc=0
    OCR_VERIFY_STEP="${step}" OCR_SKIP_PROMPT=1 \
      "${scripts_dir}/${stage_name}/verify.sh" "${version}" >/dev/null 2>&1 || verify_rc=$?

    if [[ ${verify_rc} -eq 0 ]]; then
      printf '  %s[%s]%s %s✔ DONE%s\n' \
        "${OCR_DIM}" "${step}" "${OCR_RESET}" "${OCR_GREEN}" "${OCR_RESET}"
      result_steps+=("${step}")
      result_statuses+=("DONE")
      done_count=$((done_count + 1))
      continue
    fi

    # OCR_RC_SKIPPED (20): step requires credentials or context not available — treat as SKIPPED,
    # never attempt auto-execute or poll (it will never become DONE without external action).
    if [[ ${verify_rc} -eq 20 ]]; then
      printf '  %s[%s]%s %sSKIPPED%s %s(credential/context unavailable)%s\n' \
        "${OCR_DIM}" "${step}" "${OCR_RESET}" \
        "${OCR_YELLOW}" "${OCR_RESET}" "${OCR_DIM}" "${OCR_RESET}"
      result_steps+=("${step}")
      result_statuses+=("SKIPPED")
      continue
    fi

    # Check if this step requires human action and must be skipped in run-through.
    local _is_manual=false _m
    for _m in "${_manual_steps[@]+"${_manual_steps[@]}"}"; do
      [[ "${_m}" == "${step}" ]] && _is_manual=true && break
    done
    if [[ "${_is_manual}" == true ]]; then
      printf '  %s[%s]%s %sSKIPPED%s %s(manual step — handle before running)%s\n' \
        "${OCR_DIM}" "${step}" "${OCR_RESET}" \
        "${OCR_YELLOW}" "${OCR_RESET}" "${OCR_DIM}" "${OCR_RESET}"
      result_steps+=("${step}")
      result_statuses+=("SKIPPED")
      continue
    fi

    # Step is blocked — auto-execute if execute.sh exists (no approval prompt).
    if [[ -x "${scripts_dir}/${stage_name}/execute.sh" ]]; then
      printf '  %s[%s]%s %s⚡ BLOCKED%s — auto-executing...\n' \
        "${OCR_DIM}" "${step}" "${OCR_RESET}" "${OCR_RED}" "${OCR_RESET}"
      exec_rc=0
      OCR_RUN_THROUGH=true OCR_SKIP_PROMPT=1 \
        "${scripts_dir}/${stage_name}/execute.sh" "${version}" "${step}" 2>&1 || exec_rc=$?
      # Exit code 2 from execute means a non-retryable failure (e.g. code freeze still active).
      # Stop immediately rather than polling forever.
      if [[ ${exec_rc} -eq 2 ]]; then
        printf '  %s[%s]%s %s✖ FAILED%s — execute reported a non-retryable failure — stopping run-through\n' \
          "${OCR_DIM}" "${step}" "${OCR_RESET}" "${OCR_RED}${OCR_BOLD}" "${OCR_RESET}" >&2
        result_steps+=("${step}")
        result_statuses+=("FAILED")
        failed=true
        break
      elif [[ ${exec_rc} -ne 0 ]]; then
        printf '  %s[%s]%s execute exited %d — polling for completion\n' \
          "${OCR_DIM}" "${step}" "${OCR_RESET}" "${exec_rc}"
      fi
    else
      printf '  %s[%s]%s %s⚡ BLOCKED%s %s(verify-only)%s — polling for completion\n' \
        "${OCR_DIM}" "${step}" "${OCR_RESET}" \
        "${OCR_RED}" "${OCR_RESET}" "${OCR_DIM}" "${OCR_RESET}"
    fi

    # Polling loop: re-verify until DONE or timeout.
    retry=0
    while true; do
      verify_rc=0
      OCR_VERIFY_STEP="${step}" OCR_SKIP_PROMPT=1 \
        "${scripts_dir}/${stage_name}/verify.sh" "${version}" >/dev/null 2>&1 || verify_rc=$?

      if [[ ${verify_rc} -eq 0 ]]; then
        printf '  %s[%s]%s %s✔ DONE%s %s(after %d retries)%s\n' \
          "${OCR_DIM}" "${step}" "${OCR_RESET}" \
          "${OCR_GREEN}" "${OCR_RESET}" "${OCR_DIM}" "${retry}" "${OCR_RESET}"
        result_steps+=("${step}")
        result_statuses+=("DONE")
        done_count=$((done_count + 1))
        break
      fi
      if [[ ${verify_rc} -eq 20 ]]; then
        printf '  %s[%s]%s %sSKIPPED%s %s(credential/context unavailable after %d retries)%s\n' \
          "${OCR_DIM}" "${step}" "${OCR_RESET}" \
          "${OCR_YELLOW}" "${OCR_RESET}" "${OCR_DIM}" "${retry}" "${OCR_RESET}"
        result_steps+=("${step}")
        result_statuses+=("SKIPPED")
        break
      fi

      retry=$((retry + 1))
      if [[ ${retry} -ge ${max_retries} ]]; then
        printf '  %s[%s]%s %s⏱ TIMED OUT%s after %d retries\n' \
          "${OCR_DIM}" "${step}" "${OCR_RESET}" "${OCR_RED}${OCR_BOLD}" "${OCR_RESET}" "${max_retries}" >&2
        result_steps+=("${step}")
        result_statuses+=("TIMED_OUT")
        failed=true
        break
      fi

      printf '  %s[%s] still blocked — retry %d/%d (waiting %ds)%s\n' \
        "${OCR_DIM}" "${step}" "${retry}" "${max_retries}" "${wait_interval}" "${OCR_RESET}"
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

  printf '\n%s╔══════════════════════════════════════════════════════════╗%s\n' "${OCR_CYAN}" "${OCR_RESET}"
  printf '%s║%s  %s%s — run-through summary%s\n' \
    "${OCR_CYAN}" "${OCR_RESET}" "${OCR_BOLD}" "${stage_name}" "${OCR_RESET}"
  printf '%s╠══════════════════════════════════════════════════════════╣%s\n' "${OCR_CYAN}" "${OCR_RESET}"
  local i status_color status_icon
  for ((i = 0; i < ${#result_steps[@]}; i++)); do
    case "${result_statuses[i]}" in
      DONE)     status_color="${OCR_GREEN}";             status_icon="✔" ;;
      SKIPPED)  status_color="${OCR_YELLOW}";            status_icon="–" ;;
      FAILED)   status_color="${OCR_RED}${OCR_BOLD}";   status_icon="✖" ;;
      TIMED_OUT) status_color="${OCR_RED}${OCR_BOLD}";  status_icon="⏱" ;;
      *)        status_color="${OCR_WHITE}";             status_icon=" " ;;
    esac
    printf '  %s  %-6s%s  %s%s %s%s\n' \
      "${OCR_DIM}" "${result_steps[i]}" "${OCR_RESET}" \
      "${status_color}" "${status_icon}" "${result_statuses[i]}" "${OCR_RESET}"
  done
  printf '%s  ──────────────────────────────────────────────────────%s\n' "${OCR_DIM}" "${OCR_RESET}"
  printf '  %sCompleted:%s %s%d/%d%s\n' \
    "${OCR_DIM}" "${OCR_RESET}" "${OCR_BOLD}" "${done_count}" "${step_count}" "${OCR_RESET}"
  printf '  %sElapsed:  %s %s%dh %dm %ds%s\n' \
    "${OCR_DIM}" "${OCR_RESET}" "${OCR_DIM}" \
    "$((elapsed_s / 3600))" "$(( (elapsed_s % 3600) / 60 ))" "$((elapsed_s % 60))" "${OCR_RESET}"
  printf '%s╚══════════════════════════════════════════════════════════╝%s\n\n' "${OCR_CYAN}" "${OCR_RESET}"

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
      printf '%sRefusing %s mutation: predecessor stage %s is incomplete.%s %s\n' \
        "${OCR_RED}" "${STAGE_NAME}" "${predecessor}" "${OCR_RESET}" \
        "$(ocr_redact "${verify_output}" | tail -1)" >&2
      return 2
    fi
  done

  # --- skip-continuation loop: when the user types 's' at a prompt, the
  #     loop re-verifies to find the NEXT blocking step instead of exiting.
  local _ocr_skip_arg=${2:-}    # original step argument; cleared after first skip
  local _ocr_skipped=''         # comma-separated list of user-skipped steps
  while true; do
    requested_step=${_ocr_skip_arg}
    local _eff_skip="${OCR_SKIP_STEPS:-}"
    [[ -n "${_ocr_skipped}" ]] && _eff_skip="${_eff_skip:+${_eff_skip},}${_ocr_skipped}"

    set +e
    OCR_SKIP_PROMPT=1 OCR_SKIP_STEPS="${_eff_skip}" "${STAGE_DIR}/verify.sh" "${version}" >/dev/null
    verify_rc=$?
    set -e
    if [[ ${verify_rc} -eq 0 ]]; then
      if [[ -n "${OCR_FORCE:-}" && -n "${requested_step}" ]]; then
        printf '%s stage already complete; %s--force%s re-executing step %s.\n' \
          "${STAGE_NAME}" "${OCR_YELLOW}" "${OCR_RESET}" "${requested_step}"
      else
        printf '%s✔ %s stage is already complete; nothing to execute.%s\n' \
          "${OCR_GREEN}" "${STAGE_NAME}" "${OCR_RESET}"
        return 0
      fi
    else
      local blocking_step
      blocking_step=$(ocr_state_blocking_step "${STAGE_NAME}") || {
        printf '%sUnable to determine the blocking step; run verify first.%s\n' "${OCR_RED}" "${OCR_RESET}" >&2
        return 2
      }
      if [[ -z "${requested_step}" ]]; then
        requested_step=${blocking_step}
      elif [[ "${requested_step}" != "${blocking_step}" ]]; then
        if [[ -n "${OCR_FORCE:-}" ]]; then
          printf 'Overriding blocker step %s; %s--force%s re-executing step %s.\n' \
            "${blocking_step}" "${OCR_YELLOW}" "${OCR_RESET}" "${requested_step}"
        else
          printf '%sRefusing step %s: the freshly verified blocker is step %s.%s\n' \
            "${OCR_RED}" "${requested_step}" "${blocking_step}" "${OCR_RESET}" >&2
          return 2
        fi
      fi
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

    ocr_describe_action "${requested_step}"
    if [[ "${OCR_RUN_THROUGH:-}" != true ]]; then
      local expected="execute ${VERSION} ${STAGE_NAME} ${requested_step}"
      local answer=''
      if [[ -z "${OCR_VERIFY_STEP:-}" && -z "${_ocr_skip_arg}" ]]; then
        printf '%sApproval required.%s Type exactly: %s%s%s\n  OR type %s"s"%s to skip, or Enter to stop:\n%s>%s ' \
          "${OCR_YELLOW}${OCR_BOLD}" "${OCR_RESET}" \
          "${OCR_WHITE}" "${expected}" "${OCR_RESET}" \
          "${OCR_CYAN}" "${OCR_RESET}" "${OCR_BOLD}" "${OCR_RESET}" >&2
      else
        printf '%sApproval required.%s Type exactly: %s%s%s\n%s>%s ' \
          "${OCR_YELLOW}${OCR_BOLD}" "${OCR_RESET}" \
          "${OCR_WHITE}" "${expected}" "${OCR_RESET}" \
          "${OCR_BOLD}" "${OCR_RESET}" >&2
      fi
      IFS= read -r answer </dev/tty 2>/dev/null || true
      if [[ "${answer}" == "${expected}" ]]; then
        : # approved — fall through to guard check and execute
      elif [[ "${answer}" == [sS] && -z "${OCR_VERIFY_STEP:-}" && -z "${_ocr_skip_arg}" ]]; then
        _ocr_skipped="${_ocr_skipped:+${_ocr_skipped},}${requested_step}"
        _ocr_skip_arg=''
        continue
      else
        printf '%sExecution approval not granted; no mutation was run.%s\n' "${OCR_RED}" "${OCR_RESET}" >&2
        return 3
      fi
    fi
    if [[ "${guard_rerun}" == true && -f "${mutation_marker}" ]]; then
      printf '%sStep %s was already executed for this release at %s.%s Re-verification still blocks; wait for propagation instead of repeating the mutation.\nRemove %s only after confirming an explicit retry is required.\n' \
        "${OCR_YELLOW}${OCR_BOLD}" "${requested_step}" "$(<"${mutation_marker}")" "${OCR_RESET}" \
        "${mutation_marker}" >&2
      return 2
    fi
    ocr_execute_step "${requested_step}"
    if [[ "${guard_rerun}" == true ]]; then
      date +"${TZ_FMT}" >"${mutation_marker}"
    fi
    local post_verify_rc skip_input
    set +e
    OCR_SKIP_PROMPT=1 OCR_SKIP_STEPS="${_eff_skip}" "${STAGE_DIR}/verify.sh" "${version}"
    post_verify_rc=$?
    set -e
    if [[ ${post_verify_rc} -eq 2 && -z "${_ocr_skip_arg}" ]]; then
      printf '%sType "s" to skip this step and proceed, or press Enter to stop:%s ' "${OCR_DIM}" "${OCR_RESET}" >&2
      IFS= read -r skip_input </dev/tty 2>/dev/null || true
      if [[ "${skip_input}" == [sS] ]]; then
        local _post_blocker
        _post_blocker=$(ocr_state_blocking_step "${STAGE_NAME}") || true
        if [[ -n "${_post_blocker}" ]]; then
          _ocr_skipped="${_ocr_skipped:+${_ocr_skipped},}${_post_blocker}"
        fi
        _ocr_skip_arg=''
        continue
      fi
      return ${post_verify_rc}
    elif [[ ${post_verify_rc} -ne 0 ]]; then
      return ${post_verify_rc}
    fi
    # Step executed and post-verify passed — done
    return 0
  done
}
