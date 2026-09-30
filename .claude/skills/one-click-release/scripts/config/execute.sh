#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -euo pipefail

STAGE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPTS_DIR=$(cd "${STAGE_DIR}/.." && pwd)
# shellcheck source=../lib/common.sh
source "${SCRIPTS_DIR}/lib/common.sh"
# shellcheck source=../lib/report.sh
source "${SCRIPTS_DIR}/lib/report.sh"
# shellcheck source=../lib/stage-runner.sh
source "${SCRIPTS_DIR}/lib/stage-runner.sh"

STAGE_NAME=config
STAGE_STEPS=(1.1 1.2 1.3 1.4 1.5 1.6 1.7 1.8a 1.8b 1.9 1.10 1.11 1.12)

ocr_describe_action() {
  case "$1" in
    1.1) printf 'Dispatch release-new-patch for %s.\n' "${MAJOR_MINOR}" ;;
    1.2) printf 'Merge the open release-manager PR.\n' ;;
    1.3) printf 'Merge the open generated Konflux config PR.\n' ;;
    1.4) printf 'Apply generated Konflux configuration, excluding RBAC resources.\n' ;;
    1.5) printf 'Manual action: create and merge the RPA GitLab MR.\n' ;;
    1.6) printf 'Manual action: create and merge the Pyxis GitLab MR if needed.\n' ;;
    1.7) printf 'Create an operator project.yaml version-bump PR.\n' ;;
    1.8a) printf 'Process open OPC component-version update PRs (merge, rebase, or report).\n' ;;
    1.8b) printf 'Create or update the OPC version-bump PR for version.json.\n' ;;
    1.9) printf 'Synchronize p12n-opc upstream/ with the latest OPC content.\n' ;;
    1.10) printf 'Merge or create the serve-tkn-cli submodule update PR.\n' ;;
    1.11) printf 'Manual action: create the product version GitLab MR.\n' ;;
    1.12) printf 'Manual action: create CDN RP/RPA GitLab resources.\n' ;;
  esac
}

gh_content() { gh api "$1" --jq '.content' | base64 -d; }

execute_1_1() {
  gh workflow run release-new-patch.yaml --repo openshift-pipelines/hack -f "version=${MAJOR_MINOR}"
}

merge_head_pr() {
  local repo=$1 head=$2 number
  number=$(gh pr list --repo "${repo}" --head "${head}" --state open --limit 1 --json number --jq '.[0].number // empty')
  [[ -n "${number}" ]] || {
    printf 'No open PR found for %s:%s.\n' "${repo}" "${head}" >&2
    return 2
  }
  gh pr merge --repo "${repo}" "${number}" --rebase
}

execute_1_2() { merge_head_pr openshift-pipelines/hack "actions/main/new-patch-${MAJOR_MINOR}"; }
execute_1_3() { merge_head_pr openshift-pipelines/hack "actions/update/hack-update-konflux-main-${MAJOR_MINOR}"; }

execute_1_4() {
  ocr_require_konflux || return 2
  ocr_require_command kubectl || return 2
  local temp
  temp=$(mktemp -d)
  trap 'rm -rf "${temp}"' RETURN
  git clone --depth 1 https://github.com/openshift-pipelines/hack.git "${temp}/hack"
  find "${temp}/hack/.konflux/openshift-pipelines/${MM_DASHED}/" -name '*.yaml' \
    ! -name 'role.yaml' ! -name 'service-account.yaml' \
    -exec kubectl apply --server="${KONFLUX_SERVER}" --token="${KONFLUX_TOKEN}" \
    --insecure-skip-tls-verify -n "${KONFLUX_NS}" -f {} + || {
    printf 'kubectl apply failed.\n' >&2
    rm -rf "${temp}"
    trap - RETURN
    return 2
  }
  rm -rf "${temp}"
  trap - RETURN
}

manual_action() {
  printf '%s\n' "$1" >&2
  return 2
}

execute_1_5() {
  ocr_require_gitlab || return 2

  # Re-run filename check to determine if minor-version RPAs exist at all
  local data names
  data=$(ocr_gitlab_get "${GITLAB_URL}/api/v4/projects/releng%2Fkonflux-release-data/repository/tree?path=config/kflux-prd-rh02.0fk9.p1/product/ReleasePlanAdmission/tekton-ecosystem&ref=main&per_page=100") || {
    printf 'Unable to query konflux-release-data.\n' >&2
    return 2
  }
  names=$(jq -r --arg mm "${MM_DASHED}" '.[] | select(.name | contains($mm)) | .name' <<<"${data}")
  if [[ -z "${names}" ]]; then
    # No minor-version RPAs at all — first release, stay MANUAL
    manual_action 'MANUAL: copy RPAs from hack .konflux/ into konflux-release-data via a GitLab MR. Reference: https://gitlab.cee.redhat.com/releng/konflux-release-data/-/merge_requests/10083/diffs'
    return
  fi

  # Minor-version RPAs exist but patch content needs updating
  # Clone main repo, update CDN RPAs and create developer-portal file, open MR
  local temp branch project_id mr_url
  temp=$(mktemp -d)
  trap 'rm -rf "${temp}"' RETURN

  # Clone the main repo directly (contributors have push access)
  printf 'Cloning releng/konflux-release-data...\n'
  git clone --depth 1 "https://oauth2:${GITLAB_TOKEN}@${GITLAB_URL#https://}/releng/konflux-release-data.git" "${temp}/krd" 2>/dev/null || {
    printf 'Unable to clone releng/konflux-release-data.\n' >&2
    rm -rf "${temp}"; trap - RETURN
    manual_action 'MANUAL: update CDN RPA productVersionName and create developer-portal version file via a GitLab MR.'
    return
  }

  branch="openshift-pipelines-${VERSION}-rpa-update"
  (
    cd "${temp}/krd"
    git config user.name "${GITHUB_USER:-One Click Release Bot}"
    git config user.email "${GITHUB_EMAIL:-one-click-release-bot@redhat.com}"
    git checkout -b "${branch}"

    # Update CDN RPA productVersionName in both prod and stage
    local cdn_file prev_version
    for cdn_file in \
      "config/kflux-prd-rh02.0fk9.p1/product/ReleasePlanAdmission/tekton-ecosystem/openshift-pipelines-${MM_DASHED}-core-cdn-prod.yaml" \
      "config/kflux-prd-rh02.0fk9.p1/product/ReleasePlanAdmission/tekton-ecosystem/openshift-pipelines-${MM_DASHED}-core-cdn-stage.yaml"; do
      if [[ -f "${cdn_file}" ]]; then
        prev_version=$(python3 -c "
import sys, yaml
content = yaml.safe_load(open(sys.argv[1]))
print(content.get('spec',{}).get('data',{}).get('mapping',{}).get('components',[{}])[0].get('contentGateway',{}).get('productVersionName',''))
" "${cdn_file}" 2>/dev/null || true)
        sed_i "s/productVersionName: \".*\"/productVersionName: \"${VERSION}\"/" "${cdn_file}"
        printf 'Updated %s: %s → %s\n' "$(basename "${cdn_file}")" "${prev_version}" "${VERSION}"
      fi
    done

    # Prompt for developer-portal release date
    local release_date
    while true; do
      printf 'Enter release date (YYYY-MM-DD): ' >&2
      read -r release_date
      if [[ "${release_date}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        break
      fi
      printf 'Invalid format. Please use YYYY-MM-DD (e.g. 2026-10-15).\n' >&2
    done

    # Create developer-portal version file
    local portal_dir="data/external/developer-portal/openshift-pipelines"
    mkdir -p "${portal_dir}"
    local prev_portal prev_patch
    # Find the most recent existing portal file to copy from
    prev_portal=$(find "${portal_dir}" -maxdepth 1 -name '*.yaml' 2>/dev/null | sort -V | tail -1 || true)
    if [[ -n "${prev_portal}" ]]; then
      cp "${prev_portal}" "${portal_dir}/${VERSION}.yaml"
      sed_i "s/versionName: .*/versionName: \"${VERSION}\"/" "${portal_dir}/${VERSION}.yaml"
      sed_i "s/releaseDate: .*/releaseDate: \"${release_date}\"/" "${portal_dir}/${VERSION}.yaml"
      sed_i "s/ga: .*/ga: true/" "${portal_dir}/${VERSION}.yaml"
    else
      cat > "${portal_dir}/${VERSION}.yaml" <<EOF
# Generated for Konflux Application openshift-pipelines-core by openshift-pipelines/hack. DO NOT EDIT
---
versionName: "${VERSION}"
ga: true
termsAndConditions: "Anonymous Download"
hidden: false
invisible: false
releaseDate: "${release_date}"
EOF
    fi
    printf 'Created developer-portal version file: %s.yaml\n' "${VERSION}"

    git add -A
    git commit -m "Update RPA and developer-portal for openshift-pipelines ${VERSION}"
    git push -f origin "${branch}" 2>/dev/null
  ) || {
    printf 'Failed to prepare and push branch.\n' >&2
    rm -rf "${temp}"; trap - RETURN
    manual_action 'MANUAL: update CDN RPA productVersionName and create developer-portal version file via a GitLab MR.'
    return
  }

  # Open MR via GitLab API — branch was pushed directly to the main repo
  project_id=$(curl -s --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${GITLAB_URL}/api/v4/projects/releng%2Fkonflux-release-data" \
    | jq -r '.id // empty')

  if [[ -n "${project_id}" ]]; then
    mr_url=$(curl -s --request POST --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
      "${GITLAB_URL}/api/v4/projects/${project_id}/merge_requests" \
      --data-urlencode "source_branch=${branch}" \
      --data-urlencode "target_branch=main" \
      --data-urlencode "title=Update RPA and developer-portal for openshift-pipelines ${VERSION}" \
      | jq -r '.web_url // empty')
    if [[ -n "${mr_url}" ]]; then
      printf 'MR opened: %s\n' "${mr_url}"
    else
      printf 'MR creation failed. Push succeeded — create MR manually from branch %s.\n' "${branch}" >&2
    fi
  else
    printf 'Could not determine project ID. Create MR manually from branch %s.\n' "${branch}" >&2
  fi

  rm -rf "${temp}"
  trap - RETURN
}

execute_1_6() {
  # pyxis-repo-configs requires MRs from origin branches, not forks
  if [[ -z "${GITLAB_PYXIS_PUSH_TOKEN:-}" ]]; then
    manual_action 'MANUAL: add Pyxis configuration via a GitLab MR. Note: pyxis-repo-configs requires MRs from origin branches (not forks). Request push access from the repo owner to automate this step.'
    return
  fi

  local temp branch mr_url project_id
  temp=$(mktemp -d)
  trap 'rm -rf "${temp}"' RETURN

  printf 'Cloning pyxis-repo-configs (origin)...\n'
  git clone --depth 1 "https://oauth2:${GITLAB_PYXIS_PUSH_TOKEN}@${GITLAB_URL#https://}/releng/pyxis-repo-configs.git" "${temp}/pyxis" 2>/dev/null || {
    printf 'Unable to clone pyxis-repo-configs with push token.\n' >&2
    rm -rf "${temp}"; trap - RETURN
    manual_action 'MANUAL: add Pyxis configuration via a GitLab MR.'
    return
  }

  branch="openshift-pipelines-pyxis-config-${VERSION}"
  (
    cd "${temp}/pyxis"
    git config user.name "${GITHUB_USER:-One Click Release Bot}"
    git config user.email "${GITHUB_EMAIL:-one-click-release-bot@redhat.com}"
    git checkout -b "${branch}"

    # Copy Pyxis config from hack repo if available
    if [[ -d "${HACK_REPO_PATH:-}" ]] && [[ -d "${HACK_REPO_PATH}/pyxis-repo-configs" ]]; then
      cp -r "${HACK_REPO_PATH}/pyxis-repo-configs/products/openshift-pipelines/" "products/openshift-pipelines/" 2>/dev/null || true
    else
      printf 'Hack repo path not set or pyxis config not found. Creating placeholder.\n' >&2
      mkdir -p "products/openshift-pipelines"
    fi

    git add -A
    if git diff --cached --quiet; then
      printf 'No changes to commit.\n'
      exit 0
    fi
    git commit -m "Add Pyxis configuration for openshift-pipelines ${VERSION}"
    git push origin "${branch}" 2>/dev/null
  ) || {
    printf 'Failed to prepare and push Pyxis config branch.\n' >&2
    rm -rf "${temp}"; trap - RETURN
    manual_action 'MANUAL: add Pyxis configuration via a GitLab MR.'
    return
  }

  project_id=$(curl -s --header "PRIVATE-TOKEN: ${GITLAB_PYXIS_PUSH_TOKEN}" \
    "${GITLAB_URL}/api/v4/projects/releng%2Fpyxis-repo-configs" \
    | jq -r '.id // empty')

  if [[ -n "${project_id}" ]]; then
    mr_url=$(curl -s --request POST --header "PRIVATE-TOKEN: ${GITLAB_PYXIS_PUSH_TOKEN}" \
      "${GITLAB_URL}/api/v4/projects/${project_id}/merge_requests" \
      --data-urlencode "source_branch=${branch}" \
      --data-urlencode "target_branch=main" \
      --data-urlencode "title=Add Pyxis configuration for openshift-pipelines ${VERSION}" \
      | jq -r '.web_url // empty')
    if [[ -n "${mr_url}" ]]; then
      printf 'MR opened: %s\n' "${mr_url}"
    else
      printf 'MR creation failed. Push succeeded — create MR manually from branch %s.\n' "${branch}" >&2
    fi
  else
    printf 'Could not determine project ID. Create MR manually from branch %s.\n' "${branch}" >&2
  fi

  rm -rf "${temp}"
  trap - RETURN
}

execute_1_7() {
  local project current previous temp branch open_url branch_rc
  branch="release/${VERSION}/project-yaml-version-bump"
  open_url=$(gh pr list --repo openshift-pipelines/operator --head "${branch}" --state open --limit 1 --json url --jq '.[0].url // empty')
  if [[ -n "${open_url}" ]]; then
    if pr_checks_ready "${open_url}"; then
      gh pr merge "${open_url}" --rebase
      return
    fi
    printf 'Existing project.yaml version PR is not ready: %s\n' "${open_url}" >&2
    return 2
  fi
  if ocr_remote_branch_matches openshift-pipelines/operator "${RELEASE_BRANCH}" "${branch}" '^project\.yaml$' '^\s*(current|previous):' "^\\s*current: ${VERSION}$"; then
    gh pr create --repo openshift-pipelines/operator --base "${RELEASE_BRANCH}" --head "${branch}" \
      --title "[bot:${MAJOR_MINOR}] Update project.yaml version to ${VERSION}" \
      --body "Resumes the previously pushed project.yaml version bump for ${VERSION}." --label automated
    return
  else
    branch_rc=$?
    ((branch_rc == 1)) || return 2
  fi
  project=$(gh_content "repos/openshift-pipelines/operator/contents/project.yaml?ref=${RELEASE_BRANCH}")
  current=$(awk '/current:/ {print $2; exit}' <<<"${project}")
  previous=$(awk '/previous:/ {print $2; exit}' <<<"${project}")
  temp=$(mktemp -d)
  trap 'rm -rf "${temp}"' RETURN
  git clone --depth 1 -b "${RELEASE_BRANCH}" https://github.com/openshift-pipelines/operator.git "${temp}/operator"
  (
    cd "${temp}/operator"
    sed_i "s/current: ${current}/current: ${VERSION}/" project.yaml
    sed_i "s/previous: ${previous}/previous: ${current}/" project.yaml
    git config user.name "${GITHUB_USER:-One Click Release Bot}"
    git config user.email "${GITHUB_EMAIL:-one-click-release-bot@redhat.com}"
    git checkout -b "${branch}"
    git add project.yaml
    git commit -m "[bot:${MAJOR_MINOR}] Update project.yaml version to ${VERSION}"
    git push origin "${branch}"
  )
  gh pr create --repo openshift-pipelines/operator --base "${RELEASE_BRANCH}" --head "${branch}" \
    --title "[bot:${MAJOR_MINOR}] Update project.yaml version to ${VERSION}" \
    --body "Updates project.yaml current from ${current} to ${VERSION} and previous from ${previous} to ${current}. This must merge before the final image rebuild." \
    --label automated
  rm -rf "${temp}"
  trap - RETURN
}

pr_checks_ready() {
  local url=$1 data failures pending mergeable state
  data=$(gh pr view "${url}" --json mergeable,mergeStateStatus,statusCheckRollup)
  mergeable=$(jq -r '.mergeable' <<<"${data}")
  state=$(jq -r '.mergeStateStatus' <<<"${data}")
  failures=$(jq '[.statusCheckRollup[]? | select((.conclusion // "") != "" and (.conclusion | IN("SUCCESS","NEUTRAL","SKIPPED") | not))] | length' <<<"${data}")
  pending=$(jq '[.statusCheckRollup[]? | select((.status // "") != "COMPLETED")] | length' <<<"${data}")
  [[ "${mergeable}" != CONFLICTING && "${state}" != DIRTY && ${failures} -eq 0 && ${pending} -eq 0 ]]
}

execute_1_8a() {
  local pr_file number url pr_status has_action=false failing_checks
  pr_file="${REPORT_BASE}/.state/opc-component-prs.tsv"
  if [[ ! -s "${pr_file}" ]]; then
    printf 'No open component update PRs to process.\n'
    return
  fi
  while IFS=$'\t' read -r number url pr_status; do
    case "${pr_status}" in
      READY_TO_MERGE)
        printf 'PR #%s is ready — adding labels, approving, enabling auto-merge.\n' "${number}"
        gh pr edit "${url}" --add-label lgtm,approved,one-click-release
        gh pr review --approve "${url}"
        gh pr merge "${url}" -d -r --auto
        has_action=true
        ;;
      BEHIND)
        printf 'PR #%s is behind — rebasing.\n' "${number}"
        gh pr update-branch "${url}" --rebase
        has_action=true
        ;;
      CI_FAILING)
        failing_checks=$(gh pr view "${url}" --json statusCheckRollup \
          --jq '[.statusCheckRollup[]? | select((.conclusion // "") != "" and (.conclusion | IN("SUCCESS","NEUTRAL","SKIPPED") | not)) | .name] | join(", ")')
        printf 'MANUAL: PR #%s has failing CI checks: %s\n' "${number}" "${failing_checks}" >&2
        printf 'Review and fix the failures, then re-run.\n' >&2
        return 1
        ;;
      CI_PENDING)
        printf 'BLOCKED: PR #%s has pending CI checks — wait for completion.\n' "${number}" >&2
        return 2
        ;;
      CONFLICT)
        printf 'MANUAL: PR #%s has merge conflicts — resolve manually.\n' "${number}" >&2
        return 1
        ;;
      *)
        printf 'PR #%s has unknown status %s.\n' "${number}" "${pr_status}" >&2
        return 2
        ;;
    esac
  done <"${pr_file}"
  if [[ "${has_action}" == true ]]; then
    printf 'All open PRs processed.\n'
  fi
}

execute_1_8b() {
  local mismatches non_opc versions current temp branch branch_rc
  if [[ -s "${REPORT_BASE}/.state/opc-version-mismatches" ]]; then
    mismatches=$(<"${REPORT_BASE}/.state/opc-version-mismatches")
  else
    mismatches=''
  fi
  non_opc=$(sed -E 's/[[:space:]]+opc:[^[:space:]]+//g; s/^[[:space:]]+|[[:space:]]+$//g' <<<"${mismatches}")
  if [[ -n "${non_opc}" ]]; then
    printf 'MANUAL: non-OPC component versions are outdated:%s\n' "${non_opc}" >&2
    printf 'For each outdated component, update manually:\n' >&2
    printf '  1. cd <opc-checkout>\n' >&2
    printf '  2. go get <module>@v<latest-version>\n' >&2
    printf '  3. go mod tidy\n' >&2
    printf '  4. go mod vendor\n' >&2
    printf '  5. Commit and create a PR against %s\n' "${RELEASE_BRANCH}" >&2
    return 1
  fi
  versions=$(gh_content "repos/openshift-pipelines/opc/contents/pkg/version.json?ref=${RELEASE_BRANCH}")
  current=$(jq -r '.opc // empty' <<<"${versions}")
  [[ "${current#v}" != "${VERSION}" ]] || {
    printf 'OPC version is already current.\n'
    return
  }
  [[ -n "${GITHUB_USER:-}" && -n "${GITHUB_EMAIL:-}" ]] || {
    printf 'GITHUB_USER and GITHUB_EMAIL are required for the OPC commit.\n' >&2
    return 2
  }
  branch="release/${VERSION}/opc-version-bump"
  if ocr_remote_branch_matches openshift-pipelines/opc "${RELEASE_BRANCH}" "${branch}" '^pkg/version\.json$' '^\s*"opc"\s*:' "^\\s*\"opc\"\\s*:\\s*\"?v?${VERSION}\"?,?$"; then
    gh pr create --repo openshift-pipelines/opc --base "${RELEASE_BRANCH}" --head "${branch}" \
      --title "[bot:${MAJOR_MINOR}] Update OPC version to ${VERSION}" \
      --body "Resumes the previously pushed pkg/version.json OPC version bump for ${VERSION}." --label automated
    return
  else
    branch_rc=$?
    ((branch_rc == 1)) || return 2
  fi
  temp=$(mktemp -d)
  trap 'rm -rf "${temp}"' RETURN
  gh repo clone openshift-pipelines/opc "${temp}/opc" -- -b "${RELEASE_BRANCH}" --depth 1 --quiet
  (
    cd "${temp}/opc"
    git config user.name "${GITHUB_USER}"
    git config user.email "${GITHUB_EMAIL}"
    jq --arg version "${VERSION}" '.opc = $version' pkg/version.json >pkg/version.json.tmp
    mv pkg/version.json.tmp pkg/version.json
    git checkout -b "${branch}"
    git add pkg/version.json
    git commit -m "[bot:${MAJOR_MINOR}] Update OPC version to ${VERSION}" -m "Signed-off-by: ${GITHUB_USER} <${GITHUB_EMAIL}>"
    git push origin "${branch}" --quiet
  )
  gh pr create --repo openshift-pipelines/opc --base "${RELEASE_BRANCH}" --head "${branch}" \
    --title "[bot:${MAJOR_MINOR}] Update OPC version to ${VERSION}" \
    --body "Updates pkg/version.json opc version from ${current} to ${VERSION}. This must merge before CLI binaries are built." \
    --label automated
  rm -rf "${temp}"
  trap - RETURN
}

execute_1_9() {
  local branch open url temp
  branch="release/${VERSION}/p12n-opc-sync"

  # Check for existing open PR
  open=$(gh pr list --repo openshift-pipelines/p12n-opc --head "${branch}" \
    --state open --limit 1 --json url)
  url=$(jq -r '.[0].url // empty' <<<"${open}")
  if [[ -n "${url}" ]]; then
    if pr_checks_ready "${url}"; then
      gh pr merge "${url}" --rebase
      return
    fi
    printf 'Sync PR is not ready to merge: %s\n' "${url}" >&2
    return 2
  fi

  # If the branch exists remotely but no open PR, the prior push succeeded
  # but PR creation failed — resume by opening the PR.
  if ocr_remote_branch_exists openshift-pipelines/p12n-opc "${branch}"; then
    gh pr create --repo openshift-pipelines/p12n-opc --base "${RELEASE_BRANCH}" --head "${branch}" \
      --title "[bot:${MAJOR_MINOR}] Sync upstream with OPC ${VERSION}" \
      --body "Synchronizes p12n-opc upstream/ directory with the latest OPC content from ${RELEASE_BRANCH}." \
      --label automated
    return
  fi

  # Fresh sync required
  [[ -n "${GITHUB_USER:-}" && -n "${GITHUB_EMAIL:-}" ]] || {
    printf 'GITHUB_USER and GITHUB_EMAIL are required.\n' >&2
    return 2
  }

  temp=$(mktemp -d)
  trap 'rm -rf "${temp}"' RETURN

  # Clone OPC (source — depth 1, read-only)
  git clone --depth 1 -b "${RELEASE_BRANCH}" \
    https://github.com/openshift-pipelines/opc.git "${temp}/opc" || {
    printf 'Unable to clone openshift-pipelines/opc.\n' >&2
    rm -rf "${temp}"; trap - RETURN
    manual_action "MANUAL: synchronize p12n-opc upstream/ with OPC ${RELEASE_BRANCH} and create a PR."
    return
  }

  # Clone p12n-opc (target — depth 1, will push new branch)
  git clone --depth 1 -b "${RELEASE_BRANCH}" \
    https://github.com/openshift-pipelines/p12n-opc.git "${temp}/p12n-opc" || {
    printf 'Unable to clone openshift-pipelines/p12n-opc.\n' >&2
    rm -rf "${temp}"; trap - RETURN
    manual_action "MANUAL: synchronize p12n-opc upstream/ with OPC ${RELEASE_BRANCH} and create a PR."
    return
  }

  # Sync OPC content into p12n-opc/upstream/
  rm -rf "${temp}/p12n-opc/upstream"
  cp -a "${temp}/opc" "${temp}/p12n-opc/upstream"
  rm -rf "${temp}/p12n-opc/upstream/.git"

  (
    cd "${temp}/p12n-opc"
    git config user.name "${GITHUB_USER}"
    git config user.email "${GITHUB_EMAIL}"
    git add -A
    if git diff --cached --quiet; then
      printf 'p12n-opc upstream/ is already in sync with OPC.\n'
      exit 0
    fi
    git checkout -b "${branch}"
    git commit -m "[bot:${MAJOR_MINOR}] Sync upstream with OPC ${VERSION}"
    git push origin "${branch}" --quiet
  ) || {
    printf 'Failed to prepare sync branch.\n' >&2
    rm -rf "${temp}"; trap - RETURN
    manual_action "MANUAL: synchronize p12n-opc upstream/ with OPC ${RELEASE_BRANCH} and create a PR."
    return
  }

  # If no branch was pushed (content was already in sync), we are done
  if ! ocr_remote_branch_exists openshift-pipelines/p12n-opc "${branch}"; then
    rm -rf "${temp}"; trap - RETURN
    return
  fi

  gh pr create --repo openshift-pipelines/p12n-opc --base "${RELEASE_BRANCH}" --head "${branch}" \
    --title "[bot:${MAJOR_MINOR}] Sync upstream with OPC ${VERSION}" \
    --body "Synchronizes p12n-opc upstream/ directory with the latest OPC content from ${RELEASE_BRANCH}." \
    --label automated
  rm -rf "${temp}"
  trap - RETURN
}

execute_1_10() {
  local open url temp branch cfg cli_upstream branch_rc
  open=$(gh pr list --repo openshift-pipelines/serve-tkn-cli \
    --head "release/${VERSION}/update-submodules" \
    --state open --limit 1 --json url)
  url=$(jq -r '.[0].url // empty' <<<"${open}")
  if [[ -n "${url}" ]]; then
    if pr_checks_ready "${url}"; then
      gh pr merge "${url}" --rebase
      return
    fi
    printf 'Submodule PR is not ready to merge: %s\n' "${url}" >&2
    return 2
  fi

  cfg=$(gh_content "repos/openshift-pipelines/hack/contents/config/downstream/releases/${MAJOR_MINOR}.yaml")
  cli_upstream=$(awk '$1=="tektoncd-cli:" {f=1; next} f && $1=="upstream:" {print $2; exit}' <<<"${cfg}")
  [[ -n "${cli_upstream}" ]] || {
    printf 'Cannot determine tektoncd-cli upstream branch.\n' >&2
    return 2
  }

  temp=$(mktemp -d)
  branch="release/${VERSION}/update-submodules"

  if ocr_remote_branch_matches openshift-pipelines/serve-tkn-cli "${RELEASE_BRANCH}" "${branch}" \
      '^(\.gitmodules|sources/[^/]+)$' '^(\s*branch\s*=|Subproject commit )' \
      '^(\s*branch\s*=|Subproject commit )'; then
    gh pr create --repo openshift-pipelines/serve-tkn-cli \
      --base "${RELEASE_BRANCH}" --head "${branch}" \
      --title "[bot:${MAJOR_MINOR}] Update submodules to latest upstream" \
      --body 'Resumes the previously pushed submodule update branch.' \
      --label automated
    rm -rf "${temp}"
    return
  else
    branch_rc=$?
    ((branch_rc == 1)) || { rm -rf "${temp}"; return 2; }
  fi

  trap 'rm -rf "${temp}"' RETURN
  git clone -b "${RELEASE_BRANCH}" \
    "https://github.com/openshift-pipelines/serve-tkn-cli.git" \
    "${temp}/serve-tkn-cli"

  (
    cd "${temp}/serve-tkn-cli"
    sed_i "/sources\/cli/,/branch =/s|branch = .*|branch = ${cli_upstream}|" .gitmodules

    # ── Phase 1: capture patch intent, then remove patches ────────
    # Init submodules at CURRENT SHAs to snapshot what each patch
    # changes (base → patched). Then delete patches (clean slate).
    local has_patches=0
    local patches_backup="${temp}/patches_backup"
    mkdir -p "${patches_backup}"

    if compgen -G '.konflux/patches/*.patch' >/dev/null 2>&1; then
      has_patches=1
      git submodule update --init

      local patch patch_files f
      for patch in .konflux/patches/*.patch; do
        [[ -f "${patch}" ]] || continue

        # Back up original patch (need metadata in Phase 3)
        cp "${patch}" "${patches_backup}/"

        patch_files=$(grep '^diff --git a/' "${patch}" | \
          sed 's|diff --git a/\([^ ]*\) .*|\1|')

        # Save base (pre-patch) state
        for f in ${patch_files}; do
          if [[ -f "${f}" ]]; then
            cp "${f}" "${f}.__base__"
          fi
        done

        # Apply patch → save patched state → restore base
        if patch -p1 --no-backup-if-mismatch < "${patch}" >/dev/null 2>&1; then
          for f in ${patch_files}; do
            if [[ -f "${f}" ]]; then
              cp "${f}" "${f}.__patched__"
            fi
          done
          for f in ${patch_files}; do
            if [[ -f "${f}.__base__" ]]; then
              cp "${f}.__base__" "${f}"
            fi
          done
        else
          printf 'Note: %s does not apply to current base — \n' \
            "$(basename "${patch}")" >&2
          printf '  three-way merge unavailable, will try fuzz after update.\n' >&2
        fi
      done

      # ── Clean slate: remove all patches ──
      rm -f .konflux/patches/*.patch
      printf 'Removed existing patches (will regenerate after update).\n' >&2
    fi

    # ── Phase 2: update submodules to latest ──────────────────────
    printf 'Updating submodules to latest remote...\n' >&2
    git submodule update --init --remote --force --checkout

    # ── Phase 3: regenerate patches from scratch ──────────────────
    if ((has_patches)); then
      local regen_failed=0
      local file_diff new_content merge_rc

      for patch in "${patches_backup}"/*.patch; do
        [[ -f "${patch}" ]] || continue
        local patch_name
        patch_name=$(basename "${patch}")

        printf 'Patch no longer applies: %s — regenerating...\n' \
          "${patch_name}" >&2

        patch_files=$(grep '^diff --git a/' "${patch}" | \
          sed 's|diff --git a/\([^ ]*\) .*|\1|')
        local strategy=""

        # ── Strategy A: three-way merge (preferred) ───────────
        local can_merge=1
        for f in ${patch_files}; do
          if ! [[ -f "${f}.__base__" && -f "${f}.__patched__" ]]; then
            can_merge=0
            break
          fi
        done

        if ((can_merge)); then
          new_content=""
          local merge_clean=1

          for f in ${patch_files}; do
            cp "${f}" "${f}.__updated__"

            # Merge patch intent (base→patched) into updated file
            git merge-file "${f}" "${f}.__base__" "${f}.__patched__"
            merge_rc=$?

            if ((merge_rc >= 1)); then
              printf '  %s in %s — falling back to fuzz.\n' \
                "$( ((merge_rc==1)) && echo CONFLICT || echo ERROR)" \
                "${f}" >&2
              cp "${f}.__updated__" "${f}"
              merge_clean=0
              break
            fi

            # Generate fresh patch: diff updated vs merged
            file_diff=$(git diff --no-index -- \
              "${f}.__updated__" "${f}" 2>/dev/null \
              | sed "s|${f}\.__updated__|${f}|g" || true)
            if [[ -n "${file_diff}" ]]; then
              new_content+="${file_diff}"$'\n'
            fi

            # Restore unpatched updated state for commit
            cp "${f}.__updated__" "${f}"
          done

          if ((merge_clean)); then
            if [[ -n "${new_content}" ]]; then
              printf '%s' "${new_content}" > ".konflux/patches/${patch_name}"
              if git apply --check ".konflux/patches/${patch_name}" 2>/dev/null; then
                printf '  ✓ Regenerated (three-way merge): %s\n' "${patch_name}"
                strategy="merge"
              else
                printf '  Merge result fails git apply — trying fuzz.\n' >&2
              fi
            else
              printf '  Patch is now a no-op (upstream includes the change) — skipping: %s\n' \
                "${patch_name}"
              strategy="removed"
            fi
          fi
        fi

        # ── Strategy B: fuzz fallback ─────────────────────────
        if [[ -z "${strategy}" ]]; then
          for f in ${patch_files}; do
            if [[ -f "${f}" ]]; then
              cp "${f}" "${f}.__pre_fuzz__"
            fi
          done

          if patch -p1 --fuzz=3 --no-backup-if-mismatch \
              < "${patch}" >/dev/null 2>&1; then
            new_content=""
            for f in ${patch_files}; do
              if [[ -f "${f}.__pre_fuzz__" && -f "${f}" ]]; then
                file_diff=$(git diff --no-index -- \
                  "${f}.__pre_fuzz__" "${f}" 2>/dev/null \
                  | sed "s|${f}\.__pre_fuzz__|${f}|g" || true)
                if [[ -n "${file_diff}" ]]; then
                  new_content+="${file_diff}"$'\n'
                fi
              fi
            done
            for f in ${patch_files}; do
              if [[ -f "${f}.__pre_fuzz__" ]]; then
                mv "${f}.__pre_fuzz__" "${f}"
              fi
            done

            if [[ -n "${new_content}" ]]; then
              printf '%s' "${new_content}" > ".konflux/patches/${patch_name}"
              if git apply --check ".konflux/patches/${patch_name}" 2>/dev/null; then
                printf '  ✓ Regenerated (fuzz fallback): %s\n' "${patch_name}"
                strategy="fuzz"
              else
                printf '  FATAL: fuzz result fails git apply: %s\n' \
                  "${patch_name}" >&2
                regen_failed=1
              fi
            else
              printf '  FATAL: fuzz produced empty diff: %s\n' \
                "${patch_name}" >&2
              regen_failed=1
            fi
          else
            for f in ${patch_files}; do
              if [[ -f "${f}.__pre_fuzz__" ]]; then
                mv "${f}.__pre_fuzz__" "${f}"
              fi
            done
            printf '  FATAL: cannot auto-regenerate %s\n' "${patch_name}" >&2
            regen_failed=1
          fi
        fi

        # Cleanup temp files for this patch
        for f in ${patch_files}; do
          rm -f "${f}.__base__" "${f}.__patched__" \
            "${f}.__updated__" "${f}.__pre_fuzz__"
        done
      done

      if ((regen_failed)); then
        printf '\nAborting: patch regeneration failed.\n' >&2
        exit 1
      fi
    fi

    git config user.name "${GITHUB_USER:-One Click Release Bot}"
    git config user.email "${GITHUB_EMAIL:-one-click-release-bot@redhat.com}"
    git checkout -b "${branch}"
    git add .gitmodules sources/ .konflux/patches/

    # Guard against empty commit
    if git diff --cached --quiet; then
      printf 'Nothing changed — submodules already at latest.\n' >&2
      exit 0
    fi

    git commit -m "[bot:${MAJOR_MINOR}] Update submodules to latest upstream"
    git push origin "${branch}"
  )

  # Check subshell exit before creating PR
  local subshell_rc=$?
  if ((subshell_rc != 0)); then
    printf 'Submodule update failed (exit %d).\n' "${subshell_rc}" >&2
    rm -rf "${temp}"
    trap - RETURN
    return 2
  fi

  gh pr create --repo openshift-pipelines/serve-tkn-cli \
    --base "${RELEASE_BRANCH}" --head "${branch}" \
    --title "[bot:${MAJOR_MINOR}] Update submodules to latest upstream" \
    --body 'Updates sources/cli, sources/opc, and sources/pac to their tracking branch HEADs and regenerates .konflux/patches as needed.' \
    --label automated
  rm -rf "${temp}"
  trap - RETURN
}

execute_1_11() {
  [[ -n "${GITLAB_TOKEN:-}" ]] || {
    printf 'GITLAB_TOKEN not set — skipping step 1.11.\n'
    return 0
  }

  local gitlab_url="${GITLAB_URL:-https://gitlab.cee.redhat.com}"
  local project="releng%2Fkonflux-release-data"
  local file_path="data/external/developer-portal/openshift-pipelines/${VERSION}.yaml"
  local encoded_file_path
  encoded_file_path=$(printf '%s' "${file_path}" | sed 's|/|%2F|g')
  local branch="osp/product-version-${VERSION}"

  # Check for existing open MR
  local mr_url
  mr_url=$(curl -sf --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${gitlab_url}/api/v4/projects/${project}/merge_requests?state=opened&per_page=50" \
    2>/dev/null \
    | jq -r --arg v "${VERSION}" \
      '[.[] | select(.title | test($v)) | select(.title | test("product version";"i"))] | .[0].web_url // empty' \
    2>/dev/null || true)

  if [[ -n "${mr_url}" ]]; then
    printf 'Product version MR already open: %s\n' "${mr_url}"
    return 0
  fi

  # Check if file already exists on main
  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${gitlab_url}/api/v4/projects/${project}/repository/files/${encoded_file_path}/raw?ref=main")

  if [[ "${http_code}" == "200" ]]; then
    printf 'Product version config already exists for %s.\n' "${VERSION}"
    return 0
  fi

  # Determine ga flag: true for minor releases (x.y.0), false for patches
  local ga="false"
  if [[ "${VERSION##*.}" == "0" ]]; then
    ga="true"
  fi

  local today
  today=$(date +%Y-%m-%d)

  # Create branch + file in a single commit via GitLab commits API
  local commit_payload
  commit_payload=$(jq -n \
    --arg branch "${branch}" \
    --arg msg "[bot:openshift-pipelines] Add product version config for ${VERSION}" \
    --arg path "${file_path}" \
    --arg content "$(cat <<YAML
---
versionName: "${VERSION}"
ga: ${ga}
termsAndConditions: "Anonymous Download"
hidden: false
invisible: false
releaseDate: "${today}"
YAML
)" \
    '{
      branch: $branch,
      start_branch: "main",
      commit_message: $msg,
      actions: [{action: "create", file_path: $path, content: $content}]
    }')

  local commit_resp
  commit_resp=$(curl -sf --request POST \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "${commit_payload}" \
    "${gitlab_url}/api/v4/projects/${project}/repository/commits" 2>&1) || {
    printf 'Failed to create product version commit: %s\n' "${commit_resp}" >&2
    return 2
  }

  # Create MR
  local mr_payload
  mr_payload=$(jq -n \
    --arg src "${branch}" \
    --arg title "[bot:openshift-pipelines] Add product version config for ${VERSION}" \
    '{
      source_branch: $src,
      target_branch: "main",
      title: $title,
      remove_source_branch: true
    }')

  local mr_resp
  mr_resp=$(curl -sf --request POST \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "${mr_payload}" \
    "${gitlab_url}/api/v4/projects/${project}/merge_requests" 2>&1)

  mr_url=$(printf '%s' "${mr_resp}" | jq -r '.web_url // empty')
  if [[ -n "${mr_url}" ]]; then
    printf 'Created product version MR: %s\n' "${mr_url}"
  else
    printf 'Failed to create MR: %s\n' "${mr_resp}" >&2
    return 2
  fi
}

execute_1_12() {
  [[ -n "${GITLAB_TOKEN:-}" ]] || {
    printf 'GITLAB_TOKEN not set — skipping step 1.12.\n'
    return 0
  }

  local gitlab_url="${GITLAB_URL:-https://gitlab.cee.redhat.com}"
  local project="releng%2Fkonflux-release-data"
  local mm_dashed="${MAJOR_MINOR//./-}"
  local branch="osp/cdn-rp-rpa-${mm_dashed}"

  local rpa_dir="config/kflux-prd-rh02.0fk9.p1/product/ReleasePlanAdmission/tekton-ecosystem"
  local rp_dir="tenants-config/cluster/kflux-prd-rh02/tenants/tekton-ecosystem-tenant"

  local rpa_prod="openshift-pipelines-${mm_dashed}-core-cdn-prod.yaml"
  local rpa_stage="openshift-pipelines-${mm_dashed}-core-cdn-stage.yaml"

  # Check for existing open MR
  local mr_url
  mr_url=$(curl -sf --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${gitlab_url}/api/v4/projects/${project}/merge_requests?state=opened&per_page=50" \
    2>/dev/null \
    | jq -r --arg mm "${mm_dashed}" \
      '[.[] | select(.title | test($mm)) | select(.title | test("cdn";"i"))] | .[0].web_url // empty' \
    2>/dev/null || true)

  if [[ -n "${mr_url}" ]]; then
    printf 'CDN RP/RPA MR already open: %s\n' "${mr_url}"
    return 0
  fi

  # Check if RPA files already exist
  local rpa_prod_code rpa_stage_code
  rpa_prod_code=$(curl -s -o /dev/null -w '%{http_code}' \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${gitlab_url}/api/v4/projects/${project}/repository/files/$(printf '%s' "${rpa_dir}/${rpa_prod}" | sed 's|/|%2F|g')/raw?ref=main")
  rpa_stage_code=$(curl -s -o /dev/null -w '%{http_code}' \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${gitlab_url}/api/v4/projects/${project}/repository/files/$(printf '%s' "${rpa_dir}/${rpa_stage}" | sed 's|/|%2F|g')/raw?ref=main")

  # Also check tenant RP files
  local rp_prod_code rp_stage_code
  rp_prod_code=$(curl -s -o /dev/null -w '%{http_code}' \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${gitlab_url}/api/v4/projects/${project}/repository/files/$(printf '%s' "${rp_dir}/${rpa_prod}" | sed 's|/|%2F|g')/raw?ref=main")
  rp_stage_code=$(curl -s -o /dev/null -w '%{http_code}' \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${gitlab_url}/api/v4/projects/${project}/repository/files/$(printf '%s' "${rp_dir}/${rpa_stage}" | sed 's|/|%2F|g')/raw?ref=main")

  if [[ "${rpa_prod_code}" == "200" && "${rpa_stage_code}" == "200" \
     && "${rp_prod_code}" == "200" && "${rp_stage_code}" == "200" ]]; then
    printf 'CDN RP/RPA files already exist for %s.\n' "${mm_dashed}"
    return 0
  fi

  # Find previous minor version's CDN files to copy from
  local major="${MAJOR_MINOR%%.*}"
  local minor="${MAJOR_MINOR#*.}"
  local prev_minor=$((minor - 1))
  local prev_mm_dashed="${major}-${prev_minor}"

  printf 'Looking for previous CDN config from version %s...\n' "${prev_mm_dashed}" >&2

  # Collect files to create: read previous version, replace version references
  local actions="[]"
  local files_created=0

  local src_name dst_name src_path dst_path content
  for suffix in prod stage; do
    src_name="openshift-pipelines-${prev_mm_dashed}-core-cdn-${suffix}.yaml"
    dst_name="openshift-pipelines-${mm_dashed}-core-cdn-${suffix}.yaml"
    src_path="${rpa_dir}/${src_name}"
    dst_path="${rpa_dir}/${dst_name}"

    # Skip if destination already exists
    local dst_code
    dst_code=$(curl -s -o /dev/null -w '%{http_code}' \
      --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
      "${gitlab_url}/api/v4/projects/${project}/repository/files/$(printf '%s' "${dst_path}" | sed 's|/|%2F|g')/raw?ref=main")
    if [[ "${dst_code}" == "200" ]]; then
      printf 'Already exists: %s\n' "${dst_name}"
      continue
    fi

    # Read source file
    content=$(curl -sf --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
      "${gitlab_url}/api/v4/projects/${project}/repository/files/$(printf '%s' "${src_path}" | sed 's|/|%2F|g')/raw?ref=main" \
      2>/dev/null) || {
      printf 'Cannot read previous version file: %s\n' "${src_path}" >&2
      printf 'Manual creation required.\n' >&2
      manual_action "MANUAL: create CDN RP/RPA for openshift-pipelines-${mm_dashed}. Reference: previous version ${prev_mm_dashed}."
      return
    }

    # Replace version references (e.g. 1-22 → 1-23, 1.22 → 1.23)
    content=$(printf '%s' "${content}" | sed \
      -e "s/${prev_mm_dashed}/${mm_dashed}/g" \
      -e "s/${major}\\.${prev_minor}/${MAJOR_MINOR}/g")

    actions=$(printf '%s' "${actions}" | jq \
      --arg path "${dst_path}" \
      --arg content "${content}" \
      '. + [{action: "create", file_path: $path, content: $content}]')
    files_created=$((files_created + 1))
  done

  # Also copy RP files from tenant config
  for suffix in prod stage; do
    src_name="openshift-pipelines-${prev_mm_dashed}-core-cdn-${suffix}.yaml"
    dst_name="openshift-pipelines-${mm_dashed}-core-cdn-${suffix}.yaml"
    src_path="${rp_dir}/${src_name}"
    dst_path="${rp_dir}/${dst_name}"

    local dst_code
    dst_code=$(curl -s -o /dev/null -w '%{http_code}' \
      --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
      "${gitlab_url}/api/v4/projects/${project}/repository/files/$(printf '%s' "${dst_path}" | sed 's|/|%2F|g')/raw?ref=main")
    if [[ "${dst_code}" == "200" ]]; then
      printf 'Already exists: %s\n' "${dst_name}"
      continue
    fi

    content=$(curl -sf --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
      "${gitlab_url}/api/v4/projects/${project}/repository/files/$(printf '%s' "${src_path}" | sed 's|/|%2F|g')/raw?ref=main" \
      2>/dev/null) || {
      # RP files in tenant config may not exist for previous version — skip
      printf 'No previous RP file found: %s — skipping.\n' "${src_path}" >&2
      continue
    }

    content=$(printf '%s' "${content}" | sed \
      -e "s/${prev_mm_dashed}/${mm_dashed}/g" \
      -e "s/${major}\\.${prev_minor}/${MAJOR_MINOR}/g")

    actions=$(printf '%s' "${actions}" | jq \
      --arg path "${dst_path}" \
      --arg content "${content}" \
      '. + [{action: "create", file_path: $path, content: $content}]')
    files_created=$((files_created + 1))
  done

  if ((files_created == 0)); then
    printf 'All CDN RP/RPA files already exist — nothing to do.\n'
    return 0
  fi

  # Create branch + all files in a single commit
  local commit_payload
  commit_payload=$(jq -n \
    --arg branch "${branch}" \
    --arg msg "[bot:openshift-pipelines] Add CDN RP/RPA for ${mm_dashed}" \
    --argjson actions "${actions}" \
    '{
      branch: $branch,
      start_branch: "main",
      commit_message: $msg,
      actions: $actions
    }')

  local commit_resp
  commit_resp=$(curl -sf --request POST \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "${commit_payload}" \
    "${gitlab_url}/api/v4/projects/${project}/repository/commits" 2>&1) || {
    printf 'Failed to create CDN commit: %s\n' "${commit_resp}" >&2
    return 2
  }

  # Create MR
  local mr_payload
  mr_payload=$(jq -n \
    --arg src "${branch}" \
    --arg title "[bot:openshift-pipelines] Add CDN RP/RPA for ${mm_dashed}" \
    '{
      source_branch: $src,
      target_branch: "main",
      title: $title,
      remove_source_branch: true
    }')

  local mr_resp
  mr_resp=$(curl -sf --request POST \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "${mr_payload}" \
    "${gitlab_url}/api/v4/projects/${project}/merge_requests" 2>&1)

  mr_url=$(printf '%s' "${mr_resp}" | jq -r '.web_url // empty')
  if [[ -n "${mr_url}" ]]; then
    printf 'Created CDN RP/RPA MR: %s\n' "${mr_url}"
    printf 'Created %d file(s).\n' "${files_created}"
  else
    printf 'Failed to create MR: %s\n' "${mr_resp}" >&2
    return 2
  fi
}

ocr_execute_step() {
  case "$1" in
    1.1) execute_1_1 ;; 1.2) execute_1_2 ;; 1.3) execute_1_3 ;; 1.4) execute_1_4 ;;
    1.5) execute_1_5 ;; 1.6) execute_1_6 ;; 1.7) execute_1_7 ;;
    1.8a) execute_1_8a ;; 1.8b) execute_1_8b ;;
    1.9) execute_1_9 ;; 1.10) execute_1_10 ;; 1.11) execute_1_11 ;; 1.12) execute_1_12 ;;
  esac
}

ocr_execute_stage "${1:-}" "${2:-}"
