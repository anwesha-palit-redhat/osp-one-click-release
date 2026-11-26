#!/usr/bin/env bash
# Add the lgtm label and merge open automated+hack pull requests for one minor
# release after every reported CI check has passed.
#
# Downstream repositories are the keys under that minor in
# .claude/skills/one-click-release/scripts/common/components.json. Each key is
# the repository name in the openshift-pipelines org. The branch field in that
# file is the upstream branch, so pull requests are selected by the downstream
# release branch release-v<minor>.x.
#
# The script prints the pull requests it can merge and waits for one
# confirmation before adding lgtm and merging that whole set. The scheduled
# hack workflow skips these branches while code-freeze is on. This script does
# not.
set -euo pipefail

ORG="openshift-pipelines"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
COMPONENTS_FILE="${REPO_ROOT}/.claude/skills/one-click-release/scripts/common/components.json"

DRY_RUN=false
ALLOW_NO_CHECKS=true

usage() {
  cat <<'EOF'
Add lgtm and merge open automated+hack pull requests once CI has passed.

USAGE
  merge-hack-prs.sh <X.Y|X.Y.Z> [--dry-run] [--require-checks]

The version selects the minor release. 1.23 and 1.23.5 both use the 1.23
component list and branch release-v1.23.x.

For each downstream repository, the script lists open pull requests that
target that branch and carry both the automated and hack labels. A pull
request is ready when every reported check conclusion is SUCCESS, NEUTRAL,
or SKIPPED. A pull request with no checks is ready. Pending checks, failing
checks, drafts, hold labels, and merge conflicts are left unchanged.

The script prints the ready pull requests and asks once. After confirmation
it adds the lgtm label and merges each of them with a rebase, deleting the
head branch. --dry-run prints the same list and does not ask or merge.

OPTIONS
  --dry-run           Print the pull requests that would be merged
  --allow-no-checks   Treat a pull request with no CI checks as ready (default)
  --require-checks    Skip pull requests that have no CI checks
  -h, --help          Show this help

EXIT STATUS
  0  The ready pull requests were merged, the run was a dry run, or the merge was declined
  1  A repository query, label update, or merge failed
  2  No pull request was ready to merge
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

parse_args() {
  VERSION=""
  while (($#)); do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --allow-no-checks)
        ALLOW_NO_CHECKS=true
        shift
        ;;
      --require-checks)
        ALLOW_NO_CHECKS=false
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        [[ -z "${VERSION}" ]] || die "Unexpected argument: $1"
        VERSION=$1
        shift
        ;;
    esac
  done
  [[ -n "${VERSION}" ]] || {
    usage >&2
    die "Version is required."
  }
}

normalize_minor() {
  local version=$1
  if [[ "${version}" =~ ^([0-9]+)\.([0-9]+)(\.[0-9]+)?$ ]]; then
    printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

# Read one pull-request JSON object on stdin. Print "<status>\t<detail>".
# Status is ready, hold, conflict, draft, pending, failing, or no-checks.
# An existing lgtm label does not change the status; the caller still merges it.
pr_decision() {
  local allow_no_checks=$1
  jq -r --argjson allow_no_checks "${allow_no_checks}" '
    def check_state:
      if ((.status // "") != "" and .status != "COMPLETED") then "PENDING"
      elif ((.conclusion // "") != "") then (.conclusion | ascii_upcase)
      elif ((.state // "") != "") then (.state | ascii_upcase)
      else "PENDING"
      end;
    def passed($state):
      $state == "SUCCESS" or $state == "NEUTRAL" or $state == "SKIPPED";
    def check_name:
      .name // .context // "check";
    def has_label($name):
      any(.labels[]?; .name == $name);

    if .isDraft == true then
      {status: "draft", detail: "draft pull request"}
    elif has_label("hold") or has_label("do-not-merge/hold") then
      {status: "hold", detail: "hold label is set"}
    elif .mergeable == "CONFLICTING" or .mergeStateStatus == "DIRTY" then
      {status: "conflict", detail: "merge conflict"}
    else
      ([.statusCheckRollup[]? | check_state]) as $states
      | if ($states | length) == 0 then
          if $allow_no_checks then
            {status: "ready", detail: "no CI checks reported"}
          else
            {status: "no-checks", detail: "no CI checks reported"}
          end
        elif any($states[]; . == "PENDING") then
          {status: "pending", detail: (["CI pending:", ([.statusCheckRollup[]? | select(check_state == "PENDING") | check_name] | unique | join(", "))] | join(" "))}
        elif any($states[]; passed(.) | not) then
          {status: "failing", detail: (["CI failing:", ([.statusCheckRollup[]? | select(check_state as $s | passed($s) | not) | check_name] | unique | join(", "))] | join(" "))}
        else
          {status: "ready", detail: "\($states | length) checks passed"}
        end
    end
    | "\(.status)\t\(.detail)"
  '
}

append_record() {
  local file=$1
  shift
  jq -nc "$@" >>"${file}"
}

process_repo() {
  local name=$1 base_branch=$2 allow_json=$3
  local repo="${ORG}/${name}" pr_lines pr_json decision status detail
  local number url title has_lgtm

  if ! pr_lines=$(gh pr list \
    --repo "${repo}" \
    --state open \
    --base "${base_branch}" \
    --label automated \
    --label hack \
    --limit 100 \
    --json number,url,title,labels,isDraft,mergeable,mergeStateStatus,statusCheckRollup \
    --jq '.[] | select(any(.labels[]?; .name == "automated") and any(.labels[]?; .name == "hack"))'); then
    printf 'ERROR: could not list pull requests for %s\n' "${repo}" >&2
    errors=$((errors + 1))
    return
  fi

  if [[ -z "${pr_lines}" ]]; then
    none_repos+=("${name}")
    return
  fi

  while IFS= read -r pr_json || [[ -n "${pr_json}" ]]; do
    [[ -n "${pr_json}" ]] || continue
    number=$(jq -r '.number' <<<"${pr_json}")
    url=$(jq -r '.url' <<<"${pr_json}")
    title=$(jq -r '.title' <<<"${pr_json}")
    if jq -e 'any(.labels[]?; .name == "lgtm")' <<<"${pr_json}" >/dev/null; then
      has_lgtm=true
    else
      has_lgtm=false
    fi
    if ! decision=$(pr_decision "${allow_json}" <<<"${pr_json}"); then
      printf 'ERROR: could not classify %s\n' "${url}" >&2
      errors=$((errors + 1))
      continue
    fi
    status=${decision%%$'\t'*}
    detail=${decision#*$'\t'}

    if [[ "${status}" == "ready" ]]; then
      append_record "${READY_FILE}" \
        --arg repo "${repo}" \
        --arg number "${number}" \
        --arg url "${url}" \
        --arg title "${title}" \
        --arg detail "${detail}" \
        --arg has_lgtm "${has_lgtm}" \
        '{repo:$repo, number:$number, url:$url, title:$title, detail:$detail, has_lgtm:($has_lgtm == "true")}'
      continue
    fi

    if [[ "${status}" == "no-checks" ]]; then
      no_checks=$((no_checks + 1))
    fi
    append_record "${SKIP_FILE}" \
      --arg repo "${repo}" \
      --arg number "${number}" \
      --arg url "${url}" \
      --arg title "${title}" \
      --arg detail "${detail}" \
      '{repo:$repo, number:$number, url:$url, title:$title, detail:$detail}'
    skipped=$((skipped + 1))
  done <<<"${pr_lines}"
}

print_records() {
  local file=$1
  [[ -s "${file}" ]] || return 0
  jq -r '"\(.repo) #\(.number)  (\(.detail))\n  \(.title)\n  \(.url)\n"' "${file}"
}

confirm_merge() {
  local count=$1 reply
  if [[ ! -r /dev/tty ]]; then
    die "A terminal is required to confirm the merge."
  fi
  printf 'Add lgtm and merge these %s pull requests? [y/N] ' "${count}"
  IFS= read -r reply </dev/tty || reply=""
  [[ "${reply}" == "y" || "${reply}" == "Y" || "${reply}" == "yes" || "${reply}" == "YES" ]]
}

merge_ready() {
  local row repo number url has_lgtm
  while IFS= read -r row || [[ -n "${row}" ]]; do
    [[ -n "${row}" ]] || continue
    repo=$(jq -r '.repo' <<<"${row}")
    number=$(jq -r '.number' <<<"${row}")
    url=$(jq -r '.url' <<<"${row}")
    has_lgtm=$(jq -r '.has_lgtm' <<<"${row}")
    printf 'Merging %s #%s\n' "${repo}" "${number}"
    printf '  %s\n' "${url}"
    if [[ "${has_lgtm}" != "true" ]]; then
      if ! gh pr edit "${number}" --repo "${repo}" --add-label lgtm; then
        printf 'ERROR: failed to add lgtm to %s #%s\n' "${repo}" "${number}" >&2
        errors=$((errors + 1))
        continue
      fi
      printf '  added lgtm\n'
    fi
    if gh pr merge "${number}" --repo "${repo}" --rebase --delete-branch; then
      printf '  merged\n'
      merged=$((merged + 1))
    else
      printf 'ERROR: failed to merge %s #%s\n' "${repo}" "${number}" >&2
      errors=$((errors + 1))
    fi
  done <"${READY_FILE}"
}

main() {
  parse_args "$@"

  command -v gh >/dev/null 2>&1 || die "gh is required."
  command -v jq >/dev/null 2>&1 || die "jq is required."
  [[ -f "${COMPONENTS_FILE}" ]] || die "Component list not found: ${COMPONENTS_FILE}"

  local minor base_branch allow_json names name ready_count
  minor=$(normalize_minor "${VERSION}") || die "Invalid version ${VERSION}; expected X.Y or X.Y.Z."
  base_branch="release-v${minor}.x"
  if [[ "${ALLOW_NO_CHECKS}" == true ]]; then
    allow_json=true
  else
    allow_json=false
  fi

  if ! jq -e --arg minor "${minor}" 'has($minor)' "${COMPONENTS_FILE}" >/dev/null; then
    die "No component list for ${minor}. Known minors: $(jq -r 'keys | join(", ")' "${COMPONENTS_FILE}")"
  fi

  names=$(jq -r --arg minor "${minor}" '.[$minor] | keys[]' "${COMPONENTS_FILE}")
  [[ -n "${names}" ]] || die "Component list for ${minor} is empty."

  READY_FILE=$(mktemp)
  SKIP_FILE=$(mktemp)
  trap 'rm -f "${READY_FILE}" "${SKIP_FILE}"' EXIT
  none_repos=()
  skipped=0
  no_checks=0
  errors=0
  merged=0

  printf 'Minor %s, base %s, %s repositories\n\n' \
    "${minor}" "${base_branch}" "$(wc -l <<<"${names}" | tr -d ' ')"

  while IFS= read -r name || [[ -n "${name}" ]]; do
    [[ -n "${name}" ]] || continue
    process_repo "${name}" "${base_branch}" "${allow_json}"
  done <<<"${names}"

  ready_count=$(jq -s 'length' "${READY_FILE}")
  printf 'Pull requests to merge (%s):\n\n' "${ready_count}"
  if ((ready_count == 0)); then
    printf '  none\n\n'
  else
    print_records "${READY_FILE}"
  fi

  if ((skipped > 0)); then
    printf 'Skipped (%s):\n\n' "${skipped}"
    print_records "${SKIP_FILE}"
  fi
  if ((${#none_repos[@]} > 0)); then
    local missing
    printf -v missing '%s, ' "${none_repos[@]}"
    missing=${missing%, }
    printf 'No open automated+hack pull request on %s: %s\n\n' "${base_branch}" "${missing}"
  fi
  if ((no_checks > 0)); then
    printf '%s skipped pull request(s) have no CI checks. Omit --require-checks to include them.\n\n' "${no_checks}"
  fi

  if ((errors > 0)); then
    printf 'Not merging because a repository query failed.\n'
    exit 1
  fi
  if ((ready_count == 0)); then
    exit 2
  fi
  if [[ "${DRY_RUN}" == true ]]; then
    printf 'Dry run: would add lgtm and merge these %s pull requests.\n' "${ready_count}"
    exit 0
  fi
  if ! confirm_merge "${ready_count}"; then
    printf 'Merge cancelled.\n'
    exit 0
  fi

  printf '\n'
  merge_ready
  printf '\nMerged: %s\n' "${merged}"
  printf 'Skipped: %s\n' "${skipped}"
  printf 'Errors: %s\n' "${errors}"
  if ((errors > 0)); then
    exit 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
