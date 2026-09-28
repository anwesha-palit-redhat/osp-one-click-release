#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2153
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
STAGE_REPORT_TITLE='Config Stage Report'
STAGE_REPORT_DIR=config
STAGE_STEPS=(1.1 1.2 1.3 1.4 1.5 1.6 1.7 1.8 1.9 1.10 1.11 1.12)

ocr_step_title() {
  case "$1" in
    1.1) printf '%s' 'Create new patch version' ;;
    1.2) printf '%s' 'Merge release-manager PR' ;;
    1.3) printf '%s' 'Konflux config PR merged' ;;
    1.4) printf '%s' 'Konflux config on cluster' ;;
    1.5) printf '%s' 'RPA in konflux-release-data' ;;
    1.6) printf '%s' 'Pyxis config' ;;
    1.7) printf '%s' 'Operator project.yaml version' ;;
    1.8) printf '%s' 'OPC version.json' ;;
    1.9) printf '%s' 'p12n-opc sync' ;;
    1.10) printf '%s' 'serve-tkn-cli submodules' ;;
    1.11) printf '%s' 'CLI product version config' ;;
    1.12) printf '%s' 'CLI CDN RP/RPA' ;;
  esac
}

gh_content() {
  gh api "$1" --jq '.content' | base64 -d
}

verify_1_1() {
  local cfg current runs url prs pr_number pr_url
  cfg=$(gh_content "repos/openshift-pipelines/hack/contents/config/downstream/releases/${MAJOR_MINOR}.yaml") || {
    STEP_DETAILS="release config for ${MAJOR_MINOR} not found"
    return "${OCR_RC_BLOCKED}"
  }
  current=$(awk '/release-tag:/ {print $2; exit}' <<<"${cfg}")
  runs=$(gh run list --repo openshift-pipelines/hack --workflow=release-new-patch.yaml --limit 3 \
    --json status,conclusion,createdAt,displayTitle,url 2>/dev/null || printf '[]')
  url=$(jq -r --arg mm "${MAJOR_MINOR}" '[.[] | select(.displayTitle | contains($mm))][0].url // .[0].url // empty' <<<"${runs}")
  [[ -n "${url}" ]] && STEP_LINKS="[release-new-patch](${url})"
  STEP_DETAILS="release-tag: ${current:-missing} (expected ${VERSION})"
  if [[ -n "${url}" ]]; then
    STEP_DETAILS+="; workflow $(jq -r --arg url "${url}" '.[] | select(.url==$url) | "\(.status)/\(.conclusion) at \(.createdAt)"' <<<"${runs}" | head -1)"
  fi
  if [[ "${current}" != "${VERSION}" ]]; then
    prs=$(gh pr list --repo openshift-pipelines/hack --head "actions/main/new-patch-${MAJOR_MINOR}" \
      --state open --limit 1 --json number,url 2>/dev/null || printf '[]')
    pr_number=$(jq -r '.[0].number // empty' <<<"${prs}")
    pr_url=$(jq -r '.[0].url // empty' <<<"${prs}")
    if [[ -n "${pr_number}" ]]; then
      STEP_DETAILS+="; workflow dispatched and PR #${pr_number} awaits step 1.2"
      STEP_LINKS="${STEP_LINKS:-—}, hack [#${pr_number}](${pr_url})"
      return 0
    fi
    return "${OCR_RC_BLOCKED}"
  fi
}

verify_1_2() {
  local prs state number url merged
  prs=$(gh pr list --repo openshift-pipelines/hack --head "actions/main/new-patch-${MAJOR_MINOR}" \
    --state all --limit 5 --json number,state,mergedAt,url)
  state=$(jq -r '.[0].state // empty' <<<"${prs}")
  number=$(jq -r '.[0].number // empty' <<<"${prs}")
  url=$(jq -r '.[0].url // empty' <<<"${prs}")
  merged=$(jq -r '.[0].mergedAt // empty' <<<"${prs}")
  [[ -n "${number}" ]] && STEP_LINKS="hack [#${number}](${url})"
  STEP_DETAILS="latest PR: ${state:-not found}"
  [[ -n "${merged}" ]] && STEP_DETAILS+="; merged $(ocr_abs_time "${merged}")"
  [[ "${state}" == MERGED ]] || return "${OCR_RC_BLOCKED}"
}

verify_1_3() {
  local prs state number url runs run_url
  prs=$(gh pr list --repo openshift-pipelines/hack \
    --head "actions/update/hack-update-konflux-main-${MAJOR_MINOR}" \
    --state all --limit 3 --json number,state,mergedAt,url)
  state=$(jq -r '.[0].state // empty' <<<"${prs}")
  number=$(jq -r '.[0].number // empty' <<<"${prs}")
  url=$(jq -r '.[0].url // empty' <<<"${prs}")
  runs=$(gh run list --repo openshift-pipelines/hack --workflow=generate-konflux.yaml --limit 3 \
    --json status,conclusion,createdAt,displayTitle,url 2>/dev/null || printf '[]')
  run_url=$(jq -r '.[0].url // empty' <<<"${runs}")
  STEP_LINKS='—'
  [[ -n "${number}" ]] && STEP_LINKS="hack [#${number}](${url})"
  [[ -n "${run_url}" ]] && STEP_LINKS+="${STEP_LINKS:+, }[generate-konflux](${run_url})"
  STEP_DETAILS="Konflux config PR: ${state:-not found}"
  if [[ -n "${run_url}" ]]; then
    STEP_DETAILS+="; workflow $(jq -r --arg url "${run_url}" '.[] | select(.url==$url) | "\(.status)/\(.conclusion) at \(.createdAt)"' <<<"${runs}" | head -1)"
  fi
  [[ "${state}" == MERGED ]] || return "${OCR_RC_BLOCKED}"
}

verify_1_4() {
  ocr_require_konflux || return $?
  local expected apps components temp result
  expected=$(gh api "repos/openshift-pipelines/hack/contents/.konflux/openshift-pipelines/${MM_DASHED}" \
    --jq '[.[] | select(.type == "dir") | .name] | sort[]') || {
    STEP_DETAILS='unable to list expected Konflux applications'
    return "${OCR_RC_BLOCKED}"
  }
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json 2>/dev/null) || {
    STEP_DETAILS='unable to query Konflux applications'
    return "${OCR_RC_BLOCKED}"
  }
  components=$(ocr_oc_get components -o json 2>/dev/null) || {
    STEP_DETAILS='unable to query Konflux components'
    return "${OCR_RC_BLOCKED}"
  }
  temp=$(mktemp -d)
  printf '%s\n' "${apps}" >"${temp}/apps.json"
  printf '%s\n' "${components}" >"${temp}/components.json"
  : >"${temp}/expected.tsv"
  local dir cluster_app expected_components
  while IFS= read -r dir; do
    [[ -n "${dir}" ]] || continue
    cluster_app="openshift-pipelines-${dir//./-}-${MM_DASHED}"
    expected_components=$(gh api "repos/openshift-pipelines/hack/contents/.konflux/openshift-pipelines/${MM_DASHED}/${dir}" \
      --jq '[.[] | select(.type == "dir") | .name] | sort[]' 2>/dev/null || true)
    printf '%s\t%s\t%s\n' "${dir}" "${cluster_app}" "$(paste -sd, <<<"${expected_components}")" >>"${temp}/expected.tsv"
  done <<<"${expected}"
  result=$(
    python3 - "${temp}" "${REPORT_BASE}/.state/config-applications.tsv" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
apps = {i['metadata']['name'] for i in json.load(open(p/'apps.json'))['items']}
components = json.load(open(p/'components.json'))['items']
bad=[]; count=0; rows=[]
for line in open(p/'expected.tsv'):
    directory, app, expected = line.rstrip('\n').split('\t')
    count += 1
    if app not in apps:
        bad.append(f'{directory}:MISSING_APP')
        rows.append((directory, expected, '', 'MISSING'))
        continue
    want={x for x in expected.split(',') if x}
    have={i['metadata']['name'] for i in components if i.get('spec',{}).get('application') == app}
    if want != have:
        bad.append(f'{directory}:DRIFT({len(want)} expected/{len(have)} actual)')
        rows.append((directory, ','.join(sorted(want)), ','.join(sorted(have)), 'DRIFT'))
    else:
        rows.append((directory, ','.join(sorted(want)), ','.join(sorted(have)), 'OK'))
with open(sys.argv[2], 'w') as out:
    for row in rows: out.write('\t'.join(row)+'\n')
print(f'{count}|'+','.join(bad))
PY
  )
  rm -rf "${temp}"
  local count=${result%%|*} bad=${result#*|}
  STEP_DETAILS="${count} applications checked"
  if [[ -n "${bad}" ]]; then
    STEP_DETAILS+="; ${bad}"
    return "${OCR_RC_BLOCKED}"
  fi
}

verify_1_5() {
  local data names missing=''
  if [[ -n "${GITLAB_URL:-}" && -n "${GITLAB_TOKEN:-}" ]]; then
    data=$(ocr_gitlab_get "${GITLAB_URL}/api/v4/projects/releng%2Fkonflux-release-data/repository/tree?path=config/kflux-prd-rh02.0fk9.p1/product/ReleasePlanAdmission/tekton-ecosystem&ref=main&per_page=100") || {
      STEP_DETAILS='unable to query konflux-release-data'
      return "${OCR_RC_BLOCKED}"
    }
    names=$(jq -r --arg mm "${MM_DASHED}" '.[] | select(.name | contains($mm)) | .name' <<<"${data}")
  else
    data=$(gh search code openshift-pipelines --repo redhat-appstudio/konflux-release-data --json path --limit 100 2>/dev/null || printf '[]')
    names=$(jq -r --arg mm "${MM_DASHED}" '.[] | select(.path | contains($mm)) | .path' <<<"${data}")
  fi
  local word env
  for word in core bundle fbc cdn; do
    for env in stage prod; do
      grep -q "${word}.*${env}\|${env}.*${word}" <<<"${names}" || missing+=" ${word}-${env}"
    done
  done
  STEP_DETAILS="$(grep -c . <<<"${names}" 2>/dev/null || true) matching RPA files"
  if [[ -n "${missing}" ]]; then
    STEP_DETAILS+="; missing:${missing}"
    return "${OCR_RC_BLOCKED}"
  fi
}

verify_1_6() {
  ocr_require_gitlab || return $?
  local data count
  data=$(ocr_gitlab_get "${GITLAB_URL}/api/v4/projects/releng%2Fpyxis-repo-configs/search?scope=blobs&search=openshift-pipelines&per_page=5") || {
    STEP_DETAILS='unable to query Pyxis configuration'
    return "${OCR_RC_BLOCKED}"
  }
  count=$(jq 'if type == "array" then length else 0 end' <<<"${data}")
  STEP_DETAILS="${count} Pyxis config entries found"
  ((count > 0)) || return "${OCR_RC_BLOCKED}"
}

verify_1_7() {
  local project current previous prs number url
  project=$(gh_content "repos/openshift-pipelines/operator/contents/project.yaml?ref=${RELEASE_BRANCH}") || {
    STEP_DETAILS='unable to fetch operator project.yaml'
    return "${OCR_RC_BLOCKED}"
  }
  current=$(awk '/current:/ {print $2; exit}' <<<"${project}")
  previous=$(awk '/previous:/ {print $2; exit}' <<<"${project}")
  prs=$(gh pr list --repo openshift-pipelines/operator --base "${RELEASE_BRANCH}" \
    --search "project.yaml version ${VERSION} in:title" --state all --limit 3 --json number,url 2>/dev/null || printf '[]')
  number=$(jq -r '.[0].number // empty' <<<"${prs}")
  url=$(jq -r '.[0].url // empty' <<<"${prs}")
  [[ -n "${number}" ]] && STEP_LINKS="operator [#${number}](${url})"
  STEP_DETAILS="current: ${current:-missing}; previous: ${previous:-missing}"
  [[ "${current}" == "${VERSION}" ]] || return "${OCR_RC_BLOCKED}"
}

release_branch_value() {
  local cfg=$1 key=$2
  awk -v key="${key}:" '$1 == key {found=1; next} found && $1 == "upstream:" {print $2; exit}' <<<"${cfg}"
}

latest_in_series() {
  local repo=$1 series=$2 releases tags
  releases=$(gh api "repos/${repo}/releases?per_page=100" 2>/dev/null |
    jq -r --arg p "v${series}." '[.[] | select(.tag_name | startswith($p)) | .tag_name] | .[]' |
    sed 's/^v//' || true)
  tags=$(gh api "repos/${repo}/git/refs/tags" --paginate 2>/dev/null |
    jq -r --arg p "${series}." '.[] | .ref | select(contains($p))' |
    sed -E 's#refs/tags/v?##' || true)
  printf '%s\n%s\n' "${releases}" "${tags}" | sed '/^$/d' | sort -Vu | tail -1
}

verify_1_8() {
  local open versions cfg count mismatches='' component key repo branch series current latest cmp
  : >"${REPORT_BASE}/.state/opc-version-mismatches"
  : >"${REPORT_BASE}/.state/opc-version-comparison.tsv"
  open=$(gh pr list --repo openshift-pipelines/opc --base "${RELEASE_BRANCH}" --state open \
    --search 'Update component versions in:title' --json number,url,mergeable,mergeStateStatus)
  local opc_bump
  opc_bump=$(gh pr list --repo openshift-pipelines/opc --head "release/${VERSION}/opc-version-bump" --state open \
    --json number,url,mergeable,mergeStateStatus)
  open=$(jq -s 'add | unique_by(.number)' <(printf '%s\n' "${open}") <(printf '%s\n' "${opc_bump}"))
  count=$(jq length <<<"${open}")
  if ((count > 0)); then
    STEP_DETAILS="${count} component update PR(s) still open"
    STEP_LINKS=$(jq -r 'map("opc [#\(.number)](\(.url))") | join(", ")' <<<"${open}")
    return "${OCR_RC_BLOCKED}"
  fi
  versions=$(gh_content "repos/openshift-pipelines/opc/contents/pkg/version.json?ref=${RELEASE_BRANCH}") || {
    STEP_DETAILS='unable to fetch OPC version.json'
    return "${OCR_RC_BLOCKED}"
  }
  cfg=$(gh_content "repos/openshift-pipelines/hack/contents/config/downstream/releases/${MAJOR_MINOR}.yaml")
  while IFS='|' read -r component key repo; do
    current=$(jq -r --arg k "${component}" '.[$k] // empty' <<<"${versions}" | sed 's/^v//')
    branch=$(release_branch_value "${cfg}" "${key}")
    [[ -n "${branch}" ]] || {
      if [[ "${component}" == assist && "${current}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        series=${current%.*}
      else
        mismatches+=" ${component}:UNKNOWN"
        continue
      fi
    }
    if [[ -n "${branch}" ]]; then
      series=${branch#release-v}
      series=${series%.x}
    fi
    latest=$(latest_in_series "${repo}" "${series}")
    printf '%s\t%s\t%s\t%s\t%s\n' "${component}" "${series}" "${current:-missing}" "${latest:-unknown}" "$([[ -n "${current}" && "${current}" == "${latest}" ]] && echo CURRENT || echo CHECK)" >>"${REPORT_BASE}/.state/opc-version-comparison.tsv"
    if [[ -z "${current}" || -z "${latest}" ]]; then
      mismatches+=" ${component}:UNKNOWN"
    elif [[ "${current}" != "${latest}" ]]; then
      cmp=$(printf '%s\n%s\n' "${current}" "${latest}" | sort -V | tail -1)
      [[ "${cmp}" == "${current}" ]] || mismatches+=" ${component}:${current}->${latest}"
    fi
  done <<'EOF'
pac|pipelines-as-code|openshift-pipelines/pipelines-as-code
tkn|tektoncd-cli|tektoncd/cli
results|tektoncd-results|tektoncd/results
manualapprovalgate|manual-approval-gate|openshift-pipelines/manual-approval-gate
assist|tekton-assist|openshift-pipelines/tekton-assist
EOF
  current=$(jq -r '.opc // empty' <<<"${versions}" | sed 's/^v//')
  [[ "${current}" == "${VERSION}" ]] || mismatches+=" opc:${current:-missing}->${VERSION}"
  STEP_DETAILS='all OPC component versions current'
  if [[ -n "${mismatches}" ]]; then
    printf '%s\n' "${mismatches}" >"${REPORT_BASE}/.state/opc-version-mismatches"
    STEP_DETAILS="version mismatches:${mismatches}"
    return "${OCR_RC_BLOCKED}"
  fi
}

verify_1_9() {
  local opc p12n prs number url
  opc=$(gh_content "repos/openshift-pipelines/opc/contents/pkg/version.json?ref=${RELEASE_BRANCH}") || return "${OCR_RC_BLOCKED}"
  p12n=$(gh_content "repos/openshift-pipelines/p12n-opc/contents/upstream/pkg/version.json?ref=${RELEASE_BRANCH}") || return "${OCR_RC_BLOCKED}"
  prs=$(gh pr list --repo openshift-pipelines/p12n-opc --base "${RELEASE_BRANCH}" --state all --limit 5 --json number,url 2>/dev/null || printf '[]')
  number=$(jq -r '.[0].number // empty' <<<"${prs}")
  url=$(jq -r '.[0].url // empty' <<<"${prs}")
  [[ -n "${number}" ]] && STEP_LINKS="p12n-opc [#${number}](${url})"
  STEP_DETAILS='OPC and p12n-opc version.json match'
  if [[ "$(jq -S . <<<"${opc}")" != "$(jq -S . <<<"${p12n}")" ]]; then
    STEP_DETAILS='p12n-opc upstream/pkg/version.json differs from OPC'
    return "${OCR_RC_BLOCKED}"
  fi
}

verify_1_10() {
  local modules sources temp path url branch repo actual expected mismatches=''
  modules=$(gh_content "repos/openshift-pipelines/serve-tkn-cli/contents/.gitmodules?ref=${RELEASE_BRANCH}") || {
    STEP_DETAILS='unable to fetch serve-tkn-cli .gitmodules'
    return "${OCR_RC_BLOCKED}"
  }
  sources=$(gh api "repos/openshift-pipelines/serve-tkn-cli/contents/sources?ref=${RELEASE_BRANCH}") || return "${OCR_RC_BLOCKED}"
  temp=$(mktemp)
  : >"${REPORT_BASE}/.state/submodule-comparison.tsv"
  printf '%s\n' "${modules}" >"${temp}"
  while IFS= read -r path; do
    url=$(git config -f "${temp}" --get-regexp '\.path$' | awk -v p="${path}" '$2==p {sub(/\.path$/, ".url", $1); print $1}' | xargs -r git config -f "${temp}" --get)
    branch=$(git config -f "${temp}" --get-regexp '\.path$' | awk -v p="${path}" '$2==p {sub(/\.path$/, ".branch", $1); print $1}' | xargs -r git config -f "${temp}" --get)
    repo=${url#https://github.com/}
    repo=${repo%.git}
    repo=${repo#git@github.com:}
    actual=$(jq -r --arg n "${path#sources/}" '.[] | select(.name==$n) | .sha' <<<"${sources}")
    expected=$(gh api "repos/${repo}/commits/${branch}" --jq '.sha' 2>/dev/null || true)
    printf '%s\t%s\t%s\t%s\n' "${path}" "${actual}" "${expected}" "$([[ -n "${actual}" && "${actual}" == "${expected}" ]] && echo CURRENT || echo STALE)" >>"${REPORT_BASE}/.state/submodule-comparison.tsv"
    [[ -n "${actual}" && "${actual}" == "${expected}" ]] || mismatches+=" ${path}"
  done < <(git config -f "${temp}" --get-regexp '\.path$' | awk '{print $2}')
  rm -f "${temp}"
  STEP_DETAILS='all serve-tkn-cli submodules current'
  if [[ -n "${mismatches}" ]]; then
    STEP_DETAILS="outdated submodules:${mismatches}"
    return "${OCR_RC_BLOCKED}"
  fi
}

verify_1_11() {
  ocr_require_gitlab || return $?
  local body
  body=$(ocr_gitlab_get "${GITLAB_URL}/api/v4/projects/releng%2Fkonflux-release-data/repository/files/data%2Fexternal%2Fdeveloper-portal%2Fopenshift-pipelines%2F${VERSION}.yaml/raw?ref=main") || {
    STEP_DETAILS="product version YAML ${VERSION}.yaml not found"
    return "${OCR_RC_BLOCKED}"
  }
  local found ga hidden invisible release_date
  found=$(awk -F: '/versionName:/ {print $2; exit}' <<<"${body}" | tr -d ' "' | tr -d "'")
  ga=$(awk -F: '/^[[:space:]]*ga:/ {print $2; exit}' <<<"${body}" | tr -d ' "' | tr -d "'")
  hidden=$(awk -F: '/^[[:space:]]*hidden:/ {print $2; exit}' <<<"${body}" | tr -d ' "' | tr -d "'")
  invisible=$(awk -F: '/^[[:space:]]*invisible:/ {print $2; exit}' <<<"${body}" | tr -d ' "' | tr -d "'")
  release_date=$(awk '/^[[:space:]]*releaseDate:/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' <<<"${body}" | tr -d "\"'")
  printf '%s\t%s\t%s\t%s\t%s\n' "${found}" "${ga}" "${hidden}" "${invisible}" "${release_date}" >"${REPORT_BASE}/.state/product-version-metadata.tsv"
  STEP_DETAILS="versionName=${found:-missing}; ga=${ga:-missing}; hidden=${hidden:-missing}; invisible=${invisible:-missing}; releaseDate=${release_date:-missing}; config says invisible=false while CDN step requires true until release, so both booleans are reported and accepted here"
  [[ "${found}" == "${VERSION}" && "${ga}" =~ ^(true|false)$ && "${hidden}" == false && "${invisible}" =~ ^(true|false)$ && "${release_date}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return "${OCR_RC_BLOCKED}"
}

verify_1_12() {
  ocr_require_gitlab || return $?
  local base rpa rp auto rpa_count rp_count auto_count
  base="${GITLAB_URL}/api/v4/projects/releng%2Fkonflux-release-data/repository/tree"
  rpa=$(ocr_gitlab_get "${base}?path=config/kflux-prd-rh02.0fk9.p1/product/ReleasePlanAdmission/tekton-ecosystem&ref=main&per_page=100") || return "${OCR_RC_BLOCKED}"
  rp=$(ocr_gitlab_get "${base}?path=tenants-config/cluster/kflux-prd-rh02/tenants/tekton-ecosystem-tenant&ref=main&per_page=100") || return "${OCR_RC_BLOCKED}"
  auto=$(ocr_gitlab_get "${base}?path=tenants-config/auto-generated/cluster/kflux-prd-rh02/tenants/tekton-ecosystem-tenant&ref=main&per_page=100") || return "${OCR_RC_BLOCKED}"
  rpa_count=$(jq --arg mm "${MM_DASHED}" '[.[] | select(.name | contains($mm) and contains("cdn"))] | length' <<<"${rpa}")
  rp_count=$(jq --arg mm "${MM_DASHED}" '[.[] | select(.name | contains($mm) and contains("cdn"))] | length' <<<"${rp}")
  auto_count=$(jq --arg mm "${MM_DASHED}" '[.[] | select(.name | contains($mm) and contains("cdn"))] | length' <<<"${auto}")
  STEP_DETAILS="CDN RPAs: ${rpa_count}; tenant RPs: ${rp_count}; auto-generated RPs: ${auto_count}"
  ((rpa_count >= 2 && rp_count >= 1 && auto_count >= 1)) || return "${OCR_RC_BLOCKED}"
}

ocr_verify_step() {
  case "$1" in
    1.1) verify_1_1 ;; 1.2) verify_1_2 ;; 1.3) verify_1_3 ;; 1.4) verify_1_4 ;;
    1.5) verify_1_5 ;; 1.6) verify_1_6 ;; 1.7) verify_1_7 ;; 1.8) verify_1_8 ;;
    1.9) verify_1_9 ;; 1.10) verify_1_10 ;; 1.11) verify_1_11 ;; 1.12) verify_1_12 ;;
  esac
}

ocr_report_stage_details() {
  local file
  file="${REPORT_BASE}/.state/config-applications.tsv"
  if [[ -s "${file}" ]]; then
    printf '\n## Application and Component Parity\n\n| Application | Hack Repo Components | Cluster Components | Status |\n|-------------|----------------------|--------------------|--------|\n'
    while IFS=$'\t' read -r app expected actual status; do printf '| %s | %s | %s | %s |\n' "${app}" "${expected:-—}" "${actual:-—}" "${status}"; done <"${file}"
  fi
  file="${REPORT_BASE}/.state/opc-version-comparison.tsv"
  if [[ -s "${file}" ]]; then
    printf '\n## Component Version Comparison\n\n| Component | Tracked Series | version.json | Latest Upstream | Status |\n|-----------|----------------|--------------|-----------------|--------|\n'
    while IFS=$'\t' read -r component series current latest status; do printf '| %s | %s | %s | %s | %s |\n' "${component}" "${series}" "${current}" "${latest}" "${status}"; done <"${file}"
  fi
  file="${REPORT_BASE}/.state/submodule-comparison.tsv"
  if [[ -s "${file}" ]]; then
    printf '\n## Submodule SHA Comparison\n\n| Source | Current SHA | Expected SHA | Status |\n|--------|-------------|--------------|--------|\n'
    while IFS=$'\t' read -r path actual expected status; do printf '| %s | %s | %s | %s |\n' "${path}" "${actual:0:12}" "${expected:0:12}" "${status}"; done <"${file}"
  fi
  file="${REPORT_BASE}/.state/product-version-metadata.tsv"
  if [[ -s "${file}" ]]; then
    local version ga hidden invisible release_date
    IFS=$'\t' read -r version ga hidden invisible release_date <"${file}"
    printf '\n## Product Version Metadata\n\n- **versionName:** %s\n- **ga:** %s\n- **hidden:** %s\n- **invisible:** %s\n- **releaseDate:** %s\n' "${version}" "${ga}" "${hidden}" "${invisible}" "${release_date}"
  fi
}

ocr_verify_stage "${1:-}"
