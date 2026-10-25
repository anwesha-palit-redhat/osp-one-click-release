#!/usr/bin/env bash

ocr_latest_snapshot() {
  local app=$1
  ocr_oc_get snapshots \
    -l "pac.test.appstudio.openshift.io/event-type=push,appstudio.openshift.io/application=${app}" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | awk '{print $NF}'
}

ocr_snapshot_component_image() {
  local snapshot=$1
  ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components[0].containerImage}'
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
  local release_name condition
  release_name=$(ocr_oc_create -f "${path}" -o jsonpath='{.metadata.name}') || return
  printf 'Created release: %s\n' "${release_name}"
  ocr_oc_wait_release "${release_name}" >/dev/null
  condition=$(ocr_release_condition "${release_name}")
  printf '%s\n' "${condition}"
  # Fail if the release explicitly failed so callers can avoid pinning a bad snapshot
  if [[ "${condition}" == *"Released=False"* && "${condition}" == *"Reason=Failed"* ]]; then
    printf 'Release %s failed.\n' "${release_name}" >&2
    return 2
  fi
}

compare_bundle_core_digests() {
  # Compare all OSP image digests between a bundle snapshot's CSV relatedImages
  # and the core snapshot components. Returns 0 if all match, 1 if mismatches found.
  # Usage: compare_bundle_core_digests <bundle_snapshot> <core_snapshot>
  local bundle_snapshot=$1 core_snapshot=$2
  local bundle_image core_json csv_dir result

  bundle_image=$(ocr_oc_get snapshot "${bundle_snapshot}" \
    -o jsonpath='{.spec.components[0].containerImage}' 2>/dev/null) || return 1
  [[ -n "${bundle_image}" ]] || return 1

  core_json=$(ocr_oc_get snapshot "${core_snapshot}" \
    -o jsonpath='{.spec.components}' 2>/dev/null) || return 1
  [[ -n "${core_json}" ]] || return 1

  csv_dir=$(mktemp -d)
  oc image extract "${bundle_image}" \
    --path "/manifests/openshift-pipelines-operator-rh.clusterserviceversion.yaml:${csv_dir}/" \
    --confirm 2>/dev/null || {
    rm -rf "${csv_dir}"
    return 1
  }

  result=$(python3 - "${core_json}" "${csv_dir}/openshift-pipelines-operator-rh.clusterserviceversion.yaml" <<'PY'
import json, sys, re

core_components = json.loads(sys.argv[1])
csv_path = sys.argv[2]

# Build core digest map: digest -> component name
core_map = {}
for c in core_components:
    img = c.get("containerImage", "")
    if "@sha256:" in img:
        digest = img.split("@sha256:")[1]
        core_map[digest] = c["name"]

# Parse relatedImages from CSV
with open(csv_path) as f:
    lines = f.readlines()

start = None
for i, line in enumerate(lines):
    if line.strip() == "relatedImages:":
        start = i + 1
        break

entries = []
current = {}
if start:
    for i in range(start, len(lines)):
        stripped = lines[i].strip()
        if not stripped.startswith("-") and not stripped.startswith("name:") \
                and not stripped.startswith("image:") and stripped \
                and not lines[i].startswith("    "):
            break
        if stripped.startswith("- image:"):
            if current: entries.append(current)
            current = {"image": stripped[len("- image:"):].strip()}
        elif stripped.startswith("image:"):
            current["image"] = stripped[len("image:"):].strip()
        elif stripped.startswith("name:"):
            current["name"] = stripped[len("name:"):].strip()
        elif stripped.startswith("- name:"):
            if current: entries.append(current)
            current = {"name": stripped[len("- name:"):].strip()}
    if current: entries.append(current)

# Deduplicate by digest
bundle_by_digest = {}
for e in entries:
    img = e.get("image", "")
    name = e.get("name", "UNKNOWN")
    if "@sha256:" in img:
        digest = img.split("@sha256:")[1]
        if digest not in bundle_by_digest:
            bundle_by_digest[digest] = {"name": name, "image": img}

matched = 0
mismatched = []
for digest, info in sorted(bundle_by_digest.items(), key=lambda x: x[1]["name"]):
    is_osp = "openshift-pipelines/" in info["image"]
    if digest in core_map:
        matched += 1
    elif is_osp:
        mismatched.append(f"  {info['name']}: bundle={digest[:16]}... (not in core)")

print(f"matched={matched} mismatched={len(mismatched)}")
for line in mismatched:
    print(line)
# Exit code: 0 if no mismatches, 1 otherwise
sys.exit(0 if len(mismatched) == 0 else 1)
PY
  )
  local rc=$?
  rm -rf "${csv_dir}"
  printf '%s\n' "${result}"
  return "${rc}"
}

execute_code_unfreeze() {
  local temp branch pr open_url branch_rc
  temp=$(mktemp -d)
  branch="release/${VERSION}/code-unfreeze"
  open_url=$(gh pr list --repo openshift-pipelines/hack --head "${branch}" --state open --limit 1 --json url --jq '.[0].url // empty')
  if [[ -n "${open_url}" ]]; then
    if pr_ready "${open_url}"; then
      gh pr merge "${open_url}" -d --rebase
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
    gh pr merge --repo openshift-pipelines/hack "${pr}" -d --rebase
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
  gh pr merge --repo openshift-pipelines/hack "${pr}" -d --rebase
  rm -rf "${temp}"
}
