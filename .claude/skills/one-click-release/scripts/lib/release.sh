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
