#!/usr/bin/env bash
# Compare Konflux Dockerfile base images with the latest catalog digests.
#
# Usage:
#   verify.sh <X.Y|X.Y.Z> [--component NAME[,NAME...]]
#
# Example:
#   verify.sh 1.24
#   verify.sh 1.24.2 --component tektoncd-pipeline,operator
#
# Reads the minor's downstream components from scripts/common/components.json.
# Checks out release-v<minor>.x in each openshift-pipelines repository and
# compares ARG defaults under .konflux/dockerfiles with the matching minor
# in scripts/common/base-image-map.json. A component key in that minor's map
# uses that component's ARGs. Every other component uses the common ARGs.
#
# Digests are the manifest-list digest of the latest tag on
# https://catalog.redhat.com/en. This command does not push or open pull requests.
#
# Exit 0 when every checked ARG matches.
# Exit 1 when a digest differs, a mapped ARG is missing, or a release branch is missing.
# Exit 2 when the catalog or a repository cannot be read.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
verify.sh — compare Konflux base image digests with the Red Hat catalog

USAGE
  verify.sh <X.Y|X.Y.Z> [--component NAME[,NAME...]]

The version selects the minor release. 1.24 and 1.24.2 both use the 1.24
component list, the 1.24 base image map, and branch release-v1.24.x.

OPTIONS
  --component NAME   Check one component, or a comma-separated list.
                     Repeat the flag to add more components.

EXIT CODES
  0  every present base-image ARG matches the latest catalog digest
  1  a digest differs, a mapped ARG is absent, or the release branch is missing
  2  the catalog request or a repository checkout failed
EOF
}

biu_verify_all() {
  local component index=0 total=${#BIU_SELECTED[@]} dest
  for component in "${BIU_SELECTED[@]}"; do
    index=$((index + 1))
    dest="${BIU_WORK}/src/${component}"
    rm -rf "${dest}"
    printf '%s==>%s %s (%s/%s)\n' "${OCR_CYAN}" "${OCR_RESET}" "${component}" "${index}" "${total}" >&2
    if biu_prepare_checkout "${component}" "${dest}"; then
      if ! biu_scan_checkout scan "${component}" "${dest}"; then
        biu_record "${component}" "SCAN_FAILED" "could not read Dockerfiles"
      fi
    fi
    rm -rf "${dest}"
  done
}

main() {
  local rc=0
  biu_parse_args false "$@" || rc=$?
  if [[ ${rc} -eq 80 ]]; then
    usage
    exit 0
  fi
  if [[ ${rc} -ne 0 ]]; then
    usage >&2
    exit "${rc}"
  fi
  biu_require_tools git curl python3
  biu_init "${REQUESTED_VERSION}"
  biu_load_components
  biu_fetch_digests
  biu_verify_all
  biu_finish verify
}

main "$@"
