#!/usr/bin/env bash

ocr_latest_snapshot() {
  local app=$1
  ocr_oc_get snapshots \
    -l "pac.test.appstudio.openshift.io/event-type=push,appstudio.openshift.io/application=${app}" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | awk '{print $NF}'
}

ocr_release_condition() {
  local release_name=$1
  ocr_oc_get release "${release_name}" \
    -o jsonpath='Released={.status.conditions[?(@.type=="Released")].status} Reason={.status.conditions[?(@.type=="Released")].reason}'
}

ocr_latest_successful_release_snapshot() {
  local data=$1 kind=$2 environment=$3 exclude=${4:-}
  jq -r --arg mm "${MM_DASHED}" --arg kind "${kind}" --arg env "${environment}" --arg exclude "${exclude}" '
    [.items[] | select(.spec.releasePlan | contains($mm) and contains($kind) and contains($env))
      | select($exclude=="" or (.spec.releasePlan|contains($exclude)|not))
      | select(any(.status.conditions[]?; .type=="Released" and .status=="True"))
      | {snapshot:.spec.snapshot,created:(.metadata.creationTimestamp // "")}]
    | sort_by(.created) | last.snapshot // empty' <<<"${data}"
}

ocr_write_release_manifest() {
  local path=$1 app=$2 release_plan=$3 snapshot=$4
  mkdir -p "$(dirname "${path}")"
  {
    printf 'apiVersion: appstudio.redhat.com/v1alpha1\n'
    printf 'kind: Release\n'
    printf 'metadata:\n'
    printf '  labels:\n'
    printf '    appstudio.openshift.io/application: %s\n' "${app}"
    printf '  generateName: %s-\n' "${release_plan}"
    printf '  namespace: %s\n' "${KONFLUX_NS}"
    printf 'spec:\n'
    printf '  releasePlan: %s\n' "${release_plan}"
    printf '  snapshot: %s\n' "${snapshot}"
  } >"${path}"
}

ocr_create_release_manifest() {
  local path=$1
  local release_name
  release_name=$(ocr_oc_create -f "${path}" -o jsonpath='{.metadata.name}') || return
  printf 'Created release: %s\n' "${release_name}"
  ocr_oc_wait_release "${release_name}" >/dev/null
  ocr_release_condition "${release_name}"
}

execute_code_unfreeze() {
  local temp branch pr open_url branch_rc
  temp=$(mktemp -d)
  branch="release/${VERSION}/code-unfreeze"
  open_url=$(gh pr list --repo openshift-pipelines/hack --head "${branch}" --state open --limit 1 --json url --jq '.[0].url // empty')
  if [[ -n "${open_url}" ]]; then
    if pr_ready "${open_url}"; then
      gh pr merge "${open_url}" --rebase
      rm -rf "${temp}"
      return
    fi
    printf 'Existing code-unfreeze PR is not ready: %s\n' "${open_url}" >&2
    rm -rf "${temp}"
    return 2
  fi
  if ocr_remote_branch_matches openshift-pipelines/hack main "${branch}" "^config/downstream/releases/${MAJOR_MINOR//./\\.}\\.yaml$" '^\s*code-freeze:\s*(false|true)$' '^\s*code-freeze:\s*false$'; then
    gh pr create --repo openshift-pipelines/hack --base main --head "${branch}" \
      --title "[bot:${MAJOR_MINOR}] Remove code freeze for ${VERSION}" \
      --body 'Resumes the previously pushed code-unfreeze branch.' --label automated
    pr=$(gh pr list --repo openshift-pipelines/hack --head "${branch}" --state open --limit 1 --json number --jq '.[0].number')
    gh pr merge --repo openshift-pipelines/hack "${pr}" --rebase
    rm -rf "${temp}"
    return
  else
    branch_rc=$?
    ((branch_rc == 1)) || {
      rm -rf "${temp}"
      return 2
    }
  fi
  git clone --depth 1 https://github.com/openshift-pipelines/hack.git "${temp}/hack"
  (
    cd "${temp}/hack"
    sed_i 's/code-freeze: true/code-freeze: false/' "config/downstream/releases/${MAJOR_MINOR}.yaml"
    git diff --quiet && {
      printf 'code-freeze is already false or field missing.\n'
      exit 0
    }
    git config user.name "${GITHUB_USER:-One Click Release Bot}"
    git config user.email "${GITHUB_EMAIL:-one-click-release-bot@redhat.com}"
    git checkout -b "${branch}"
    git add "config/downstream/releases/${MAJOR_MINOR}.yaml"
    git commit -m "[bot:${MAJOR_MINOR}] Remove code freeze for ${VERSION}"
    git push origin "${branch}"
  )
  gh pr create --repo openshift-pipelines/hack --base main --head "${branch}" \
    --title "[bot:${MAJOR_MINOR}] Remove code freeze for ${VERSION}" \
    --body 'Sets code-freeze: false to lift the code freeze.' --label automated
  pr=$(gh pr list --repo openshift-pipelines/hack --head "${branch}" --state open --limit 1 --json number --jq '.[0].number')
  gh pr merge --repo openshift-pipelines/hack "${pr}" --rebase
  rm -rf "${temp}"
}
