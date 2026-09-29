# Stage 1: Config

Everything needed before builds can start. Steps run sequentially — stop at the first step that requires action (unless the user approves execution).

**Inputs:** `VERSION`, `MAJOR_MINOR`, `MM_DASHED`, `RELEASE_BRANCH`, `CURRENT_RELEASE_TAG`, `KONFLUX_NS`, `KONFLUX_SERVER`, `KONFLUX_TOKEN`, `GITLAB_URL`, `GITLAB_TOKEN`, `TZ_FMT`

**Constraints:**
- Konflux cluster: **READ-ONLY** for verify commands (`oc get`/`kubectl get` only)
- GitLab: **READ-ONLY** for verify commands (`GET` requests only)
- Execute commands require explicit user approval before running

**Formatting:**
- PR links: `[#NUM](https://github.com/OWNER/REPO/pull/NUM)`
- SHA links: `[SHORT](https://github.com/OWNER/REPO/commit/FULL)` (12-char short)
- Timestamps: absolute local time with timezone (e.g. `2026-07-08 14:30 IST`)

---

## Step 1.1: Create new patch version

The hack repo's `release-tag` field must match `VERSION`. The `create-new-patch` function increments the last number (e.g. `1.21.2` → `1.21.3`) and resets `code-freeze: false`.

**Verify:**
```bash
CURRENT_RELEASE_TAG=$(gh api repos/openshift-pipelines/hack/contents/config/downstream/releases/${MAJOR_MINOR}.yaml \
  --jq '.content' | base64 -d | grep 'release-tag:' | awk '{print $2}')
echo "release-tag: ${CURRENT_RELEASE_TAG} (expected: ${VERSION})"
```

**Collect links:**
```bash
gh run list --repo openshift-pipelines/hack \
  --workflow=release-new-patch.yaml \
  --limit 3 \
  --json databaseId,status,conclusion,createdAt,displayTitle,url \
  | python3 -c "
import sys, json
runs = json.load(sys.stdin)
for r in runs:
    if '${MAJOR_MINOR}' in r.get('displayTitle',''):
        print(f\"Workflow: {r['url']}  ({r['status']}/{r.get('conclusion','pending')})\")
        break
else:
    if runs:
        print(f\"Latest run: {runs[0]['url']}  ({runs[0]['status']}/{runs[0].get('conclusion','pending')})\")
    else:
        print('No workflow runs found')
"
```

Report the workflow run URL in the summary.

**Expected when DONE:** `release-tag` equals `VERSION`.

**If not done — Execute (requires approval):**
```bash
gh workflow run release-new-patch.yaml \
  --repo openshift-pipelines/hack \
  -f version=${MAJOR_MINOR}
```

This triggers the `release-new-patch` workflow which creates a PR on branch `actions/main/new-patch-${MAJOR_MINOR}` with label `automated`. The PR must be merged (step 1.2) before proceeding.

---

## Step 1.2: Merge release-manager PR

The `release-new-patch` workflow creates a PR titled `[bot: ${MAJOR_MINOR}] Release Action: new-patch`.

**Verify:**
```bash
gh pr list --repo openshift-pipelines/hack \
  --head "actions/main/new-patch-${MAJOR_MINOR}" \
  --state all --limit 5 \
  --json number,title,state,mergedAt,url
```

**Collect links:** Extract the PR URL from the verify output. Report as `[#NUM](URL)` in the summary. The PR is on `openshift-pipelines/hack`.

**Expected when DONE:** Most recent PR has `state: "MERGED"`. Show merge time:
```bash
MERGED_AT=$(gh pr list --repo openshift-pipelines/hack \
  --head "actions/main/new-patch-${MAJOR_MINOR}" \
  --state merged --limit 1 \
  --json mergedAt --jq '.[0].mergedAt')
date -d "${MERGED_AT}" +"${TZ_FMT}"
```

**If PR is open — Execute (requires approval):**
```bash
PR_NUMBER=$(gh pr list --repo openshift-pipelines/hack \
  --head "actions/main/new-patch-${MAJOR_MINOR}" \
  --state open --limit 1 \
  --json number --jq '.[0].number')
gh pr merge --repo openshift-pipelines/hack ${PR_NUMBER} --rebase
```

**If no PR exists:** The workflow from step 1.1 may still be running or hasn't been triggered. Wait or re-trigger step 1.1.

---

## Step 1.3: Konflux config PR merged

After the release-manager PR merges (step 1.2), the `generate-konflux` workflow runs automatically on push to main. It creates a PR for Konflux config updates.

**Verify:**
```bash
gh pr list --repo openshift-pipelines/hack \
  --head "actions/update/hack-update-konflux-main-${MAJOR_MINOR}" \
  --state all --limit 3 \
  --json number,title,state,mergedAt,url
```

**Collect links:** Extract the PR URL from the verify output. Report as `[#NUM](URL)` in the summary. Also collect the `generate-konflux` workflow run:
```bash
gh run list --repo openshift-pipelines/hack \
  --workflow=generate-konflux.yaml \
  --limit 3 \
  --json databaseId,status,conclusion,createdAt,displayTitle,url \
  | python3 -c "
import sys, json
runs = json.load(sys.stdin)
for r in runs:
    if '${MAJOR_MINOR}' in r.get('displayTitle','') or r.get('status') in ('completed','in_progress'):
        print(f\"Workflow: {r['url']}  ({r['status']}/{r.get('conclusion','pending')})\")
        break
"
```

Report both the PR link and the workflow run URL in the summary.

**Expected when DONE:** Most recent PR has `state: "MERGED"`.

**If PR is open — Execute (requires approval):**

The `merge-hack-pull-requests` workflow runs hourly and auto-merges PRs with the `hack` label. To merge immediately:
```bash
PR_NUMBER=$(gh pr list --repo openshift-pipelines/hack \
  --head "actions/update/hack-update-konflux-main-${MAJOR_MINOR}" \
  --state open --limit 1 \
  --json number --jq '.[0].number')
gh pr merge --repo openshift-pipelines/hack ${PR_NUMBER} --rebase
```

**If no PR exists:** The `generate-konflux` workflow may still be running. Check:
```bash
gh run list --repo openshift-pipelines/hack \
  --workflow=generate-konflux.yaml \
  --limit 5 \
  --json databaseId,status,conclusion,createdAt,displayTitle,url
```

---

## Step 1.4: Konflux config applied on cluster

The generated configuration from the hack repo must be applied to the Konflux cluster. This step verifies that Applications and Components on the cluster match what the hack repo generated.

### 1.4a: Compare Applications

**Verify:**
```bash
# Expected applications from hack repo
EXPECTED_APPS=$(gh api repos/openshift-pipelines/hack/contents/.konflux/openshift-pipelines/${MM_DASHED} \
  --jq '[.[] | select(.type == "dir") | .name] | sort[]')
echo "Expected applications:"
echo "$EXPECTED_APPS"

# Actual applications on cluster
ACTUAL_APPS=$(oc get applications.appstudio.redhat.com -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify -o json 2>/dev/null \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
mm = '${MM_DASHED}'
apps = sorted([i['metadata']['name'] for i in data['items'] if mm in i['metadata']['name']])
for a in apps:
    print(a)
")
echo "Actual applications on cluster:"
echo "$ACTUAL_APPS"
```

**Expected when DONE:** Every hack repo directory has a matching cluster application (dots in OCP versions become dashes: `index-4.17` → `index-4-17`).

### 1.4b: Compare Components per Application

**Verify:**

For each application directory in hack repo:
```bash
APP_DIR="<application-directory-name>"
CLUSTER_APP_NAME="<cluster-application-name>"

# Expected components from hack repo
gh api repos/openshift-pipelines/hack/contents/.konflux/openshift-pipelines/${MM_DASHED}/${APP_DIR} \
  --jq '[.[] | select(.type == "dir") | .name] | sort[]'

# Actual components on cluster for this application
oc get components -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify -o json 2>/dev/null \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
app = '${CLUSTER_APP_NAME}'
comps = sorted([i['metadata']['name'] for i in data['items']
    if i['spec'].get('application','') == app])
for c in comps:
    print(c)
"
```

Report as table:
```
| Application | Hack Repo Components | Cluster Components | Status |
|-------------|---------------------|--------------------|--------|
```

Status values: `OK`, `DRIFT` (wrong assignment), `MISSING` (not on cluster).

**Collect links:** No PRs or workflows for this step. Report the overall status (OK / DRIFT count / MISSING count) in the summary.

**If DRIFT or MISSING — Execute (requires approval):**

```bash
# Clone hack repo and apply config (excluding RBAC resources)
git clone --depth 1 https://github.com/openshift-pipelines/hack.git /tmp/hack-config
cd /tmp/hack-config

# Apply a specific drifted application:
find .konflux/openshift-pipelines/${MM_DASHED}/${DRIFTED_APP_DIR}/ -name '*.yaml' \
  ! -name 'role.yaml' ! -name 'service-account.yaml' \
  -exec kubectl apply --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify -n ${KONFLUX_NS} -f {} +

# Or apply ALL config for this release:
find .konflux/openshift-pipelines/${MM_DASHED}/ -name '*.yaml' \
  ! -name 'role.yaml' ! -name 'service-account.yaml' \
  -exec kubectl apply --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify -n ${KONFLUX_NS} -f {} +

rm -rf /tmp/hack-config
```

`role.yaml` and `service-account.yaml` are excluded — they require elevated RBAC and are one-time admin resources.

**IMPORTANT:** Do NOT merge component PRs in downstream repos (step 2.1) before this config is applied — pipelines triggered by those PRs will fail without it.

---

## Step 1.5: RPA in konflux-release-data

ReleasePlanAdmission YAML files must exist in the `konflux-release-data` GitLab repo for this version. Expected RPAs: core, bundle, fbc, cdn (each for stage + prod).

**Verify:**
```bash
curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/projects/releng%2Fkonflux-release-data/repository/tree?path=config/kflux-prd-rh02.0fk9.p1/product/ReleasePlanAdmission/tekton-ecosystem&ref=main&per_page=100" \
  2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
mm = '${MM_DASHED}'
if isinstance(data, list):
    matches = sorted([f['name'] for f in data if mm in f['name']])
    if matches:
        for m in matches:
            print(m)
    else:
        print('NO_RPA_FOUND')
else:
    print('ERROR: unexpected response')
"
```

**Verify (patch version):**

Check 1 — CDN RPA `productVersionName` matches `VERSION`:
```bash
curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/projects/releng%2Fkonflux-release-data/repository/files/config%2Fkflux-prd-rh02.0fk9.p1%2Fproduct%2FReleasePlanAdmission%2Ftekton-ecosystem%2Fopenshift-pipelines-${MM_DASHED}-core-cdn-prod.yaml/raw?ref=main" \
  2>/dev/null | python3 -c "
import sys, yaml
content = yaml.safe_load(sys.stdin)
expected = '${VERSION}'
actual = content.get('spec',{}).get('data',{}).get('productVersionName','')
if actual == expected:
    print(f'CDN RPA productVersionName: {actual} ✓')
else:
    print(f'CDN_RPA_PATCH_MISMATCH: expected {expected}, found {actual}')
"
```

Check 2 — Developer-portal version file exists:
```bash
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/projects/releng%2Fkonflux-release-data/repository/files/data%2Fexternal%2Fdeveloper-portal%2Fopenshift-pipelines%2F${VERSION}.yaml/raw?ref=main" \
  2>/dev/null)
if [ "$HTTP_CODE" = "200" ]; then
    echo "Developer-portal version file: ${VERSION}.yaml ✓"
else
    echo "DEV_PORTAL_FILE_MISSING: ${VERSION}.yaml (HTTP ${HTTP_CODE})"
fi
```

**Fallback if no GitLab token:**
```bash
gh search code "openshift-pipelines" \
  --repo redhat-appstudio/konflux-release-data \
  --json path --limit 20 2>/dev/null | python3 -c "
import sys, json
results = json.load(sys.stdin)
mm = '${MM_DASHED}'
matches = [r['path'] for r in results if mm in r['path']]
for m in sorted(matches):
    print(m)
"
```

**Expected when DONE:** RPA files exist for core, bundle, fbc, cdn. CDN RPAs have correct `productVersionName`. Developer-portal version file exists.

**Collect links:** If RPA files exist, report as DONE with the count. If a GitLab MR was used, capture its URL:
```bash
curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/projects/releng%2Fkonflux-release-data/merge_requests?state=merged&search=openshift-pipelines+${MM_DASHED}&per_page=5" \
  2>/dev/null | python3 -c "
import sys, json
mrs = json.load(sys.stdin)
mm = '${MM_DASHED}'
if isinstance(mrs, list):
    for mr in mrs:
        if mm in mr.get('title',''):
            print(f\"MR: {mr['web_url']}  ({mr['state']})\")
    if not any(mm in mr.get('title','') for mr in mrs):
        print('No matching MR found')
else:
    print('ERROR: unexpected response')
"
```

Report the GitLab MR URL (if found) in the summary.

**If `NO_RPA_FOUND` (first minor version release) — Execute:** MANUAL. Copy RPAs from hack repo `.konflux/` directory to konflux-release-data GitLab repo via merge request.

Reference MR: `https://gitlab.cee.redhat.com/releng/konflux-release-data/-/merge_requests/10083/diffs`

**If `CDN_RPA_PATCH_MISMATCH` or `DEV_PORTAL_FILE_MISSING` — Execute (requires approval):**

1. Fork `releng/konflux-release-data` on GitLab (or use existing fork)
2. Create branch: `openshift-pipelines-${VERSION}-rpa-update`
3. Update `productVersionName` in both CDN RPA files:
   - `openshift-pipelines-${MM_DASHED}-core-cdn-prod.yaml`
   - `openshift-pipelines-${MM_DASHED}-core-cdn-stage.yaml`
   Change: `productVersionName: "${PREVIOUS_VERSION}"` → `productVersionName: "${VERSION}"`
4. Create `data/external/developer-portal/openshift-pipelines/${VERSION}.yaml`:
   Copy previous patch's file, update `versionName` to `"${VERSION}"` and `releaseDate` to today's date
5. Commit: `Update RPA and developer-portal for openshift-pipelines ${VERSION}`
6. Push to fork, open MR to `releng/konflux-release-data` main branch via GitLab API:
```bash
curl -s --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/projects/${FORK_PROJECT_ID}/merge_requests" \
  --data-urlencode "source_branch=openshift-pipelines-${VERSION}-rpa-update" \
  --data-urlencode "target_branch=main" \
  --data-urlencode "target_project_id=${TARGET_PROJECT_ID}" \
  --data-urlencode "title=Update RPA and developer-portal for openshift-pipelines ${VERSION}"
```

---

## Step 1.6: Pyxis config

Pyxis repo configs must exist for `openshift-pipelines` images. Only needed if new component images are being shipped (not required for most patch releases).

**Verify:**
```bash
curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/projects/releng%2Fpyxis-repo-configs/search?scope=blobs&search=openshift-pipelines&per_page=5" \
  2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
if isinstance(data, list) and len(data) > 0:
    print(f'Found {len(data)} Pyxis config entries')
    for d in data[:3]:
        print(f'  {d.get(\"filename\", \"unknown\")}')
else:
    print('NO_PYXIS_CONFIG_FOUND')
"
```

**Expected when DONE:** Config exists under `products/openshift-pipelines/`. For patch releases, existing config is sufficient.

**Collect links:** If a GitLab MR was used, capture its URL:
```bash
curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/projects/releng%2Fpyxis-repo-configs/merge_requests?state=merged&search=openshift-pipelines&per_page=5" \
  2>/dev/null | python3 -c "
import sys, json
mrs = json.load(sys.stdin)
if isinstance(mrs, list):
    for mr in mrs:
        if 'openshift-pipelines' in mr.get('title','').lower():
            print(f\"MR: {mr['web_url']}  ({mr['state']})\")
            break
    else:
        print('No matching MR found (may not be needed for patch releases)')
else:
    print('ERROR: unexpected response')
"
```

Report the GitLab MR URL (if found) in the summary.

**If `NO_PYXIS_CONFIG_FOUND` — Execute (requires approval):**

> **Note:** `pyxis-repo-configs` requires MRs from origin branches (not forks). This requires a GitLab token with push access to `releng/pyxis-repo-configs`.

If push access is available:
1. Clone `releng/pyxis-repo-configs`
2. Create branch: `openshift-pipelines-pyxis-config`
3. Copy Pyxis config from hack repo to `products/openshift-pipelines/`
4. Commit, push to origin branch
5. Open MR via GitLab API

If no push access:
   MANUAL. Copy Pyxis configuration from hack repo to `https://gitlab.cee.redhat.com/releng/pyxis-repo-configs/`.
   Request push access from the repo owner to automate this step in future.

---

## Step 1.7: Operator project.yaml version

The operator's `project.yaml` on the release branch has `versions.current` which must match `VERSION` before images are built — otherwise the operator image ships with the wrong version string.

**Verify:**
```bash
PROJECT_YAML=$(gh api repos/openshift-pipelines/operator/contents/project.yaml?ref=${RELEASE_BRANCH} \
  --jq '.content' | base64 -d)
CURRENT_VERSION=$(echo "$PROJECT_YAML" | grep 'current:' | head -1 | awk '{print $2}')
PREVIOUS_VERSION_FIELD=$(echo "$PROJECT_YAML" | grep 'previous:' | head -1 | awk '{print $2}')
echo "current: ${CURRENT_VERSION} (expected: ${VERSION})"
echo "previous: ${PREVIOUS_VERSION_FIELD}"
```

**Expected when DONE:** `current` equals `VERSION`.

**Collect links:** Check for an existing or merged PR for this version bump:
```bash
gh pr list --repo openshift-pipelines/operator \
  --base ${RELEASE_BRANCH} \
  --search "project.yaml version ${VERSION} in:title" \
  --state all --limit 3 \
  --json number,title,state,mergedAt,url
```

Report the PR as `[#NUM](URL)` in the summary. If no PR exists and the version already matches, report as "already set".

**If not done — Execute (requires approval):**

Determine the correct previous version (the current `current` becomes `previous`):
```bash
NEW_PREVIOUS=${CURRENT_VERSION}
```

```bash
git clone --depth 1 -b ${RELEASE_BRANCH} \
  https://github.com/openshift-pipelines/operator.git /tmp/operator-version-bump
cd /tmp/operator-version-bump

# Update project.yaml
sed -i "s/current: ${CURRENT_VERSION}/current: ${VERSION}/" project.yaml
sed -i "s/previous: ${PREVIOUS_VERSION_FIELD}/previous: ${NEW_PREVIOUS}/" project.yaml

git checkout -b "release/${VERSION}/project-yaml-version-bump"
git add project.yaml
git commit -m "[bot:${MAJOR_MINOR}] Update project.yaml version to ${VERSION}"
git push origin "release/${VERSION}/project-yaml-version-bump"

gh pr create --repo openshift-pipelines/operator \
  --base ${RELEASE_BRANCH} \
  --head "release/${VERSION}/project-yaml-version-bump" \
  --title "[bot:${MAJOR_MINOR}] Update project.yaml version to ${VERSION}" \
  --body "Updates project.yaml versions:
  current: ${CURRENT_VERSION} → ${VERSION}
  previous: ${PREVIOUS_VERSION_FIELD} → ${NEW_PREVIOUS}

This must be merged BEFORE triggering the final image rebuild." \
  --label automated

rm -rf /tmp/operator-version-bump
```

**This step must complete before build validation.** Any images built with the wrong version will ship incorrect version strings.

---

## Step 1.8: OPC version.json

The OPC `pkg/version.json` on the release branch tracks upstream CLI component versions (pac, tkn, results, manualapprovalgate, assist) and the OPC version itself. All must be current before CLI binaries are built.

### Step 1.8a: Check for open component update PRs

Component updates may be automated, so check for existing open PRs with title pattern `[release-vX.Y.x] Update component versions` before creating new ones.

**Verify:**
```bash
gh pr list --repo openshift-pipelines/opc \
  --base ${RELEASE_BRANCH} \
  --state open \
  --search "Update component versions in:title" \
  --json number,title,labels,mergeable,mergeStateStatus,url
```

This searches for PRs with titles like `[release-v1.20.x] Update component versions`.

For each open PR, check CI status:
```bash
gh pr view "${PR_URL}" --json mergeable,mergeStateStatus,statusCheckRollup
```

Classify each PR:
- `mergeable: CONFLICTING` or `mergeStateStatus: DIRTY` → **CONFLICT**
- `mergeStateStatus: BEHIND` → **BEHIND** (needs rebase)
- CI checks failing → **CI FAILING**
- CI checks pending → **CI PENDING**
- All checks pass and mergeable → **READY TO MERGE**

**Collect links:** Report each PR as `opc [#NUM](URL)` with its status.

**If PRs are READY TO MERGE — Execute (requires approval):**
```bash
gh pr edit "${PR_URL}" --add-label "lgtm,approved,one-click-release"
gh pr review --approve "${PR_URL}"
gh pr merge "${PR_URL}" -d -r --auto
```

**If PRs are BEHIND — Execute (requires approval):**
```bash
gh pr update-branch "${PR_URL}" --rebase
```

**If PRs have CI FAILING:** Report the failing checks. The user must investigate.

**If PRs have CI PENDING:** Wait and re-check after a few minutes.

After merging any PRs, wait a moment for branch to update, then proceed to verify version.json.

### Step 1.8b: Verify version.json

**Verify:**
```bash
OPC_VERSIONS=$(gh api repos/openshift-pipelines/opc/contents/pkg/version.json?ref=${RELEASE_BRANCH} \
  --jq '.content' | base64 -d)
echo "$OPC_VERSIONS"
```

For each component, find the tracking branch from hack repo release config, then get the latest release in that series:

```bash
# Get tracking branches from hack repo config
RELEASE_CFG=$(gh api repos/openshift-pipelines/hack/contents/config/downstream/releases/${MAJOR_MINOR}.yaml \
  --jq '.content' | base64 -d)

# Extract upstream branches for each component
PAC_BRANCH=$(echo "$RELEASE_CFG" | grep -A1 'pipelines-as-code:' | grep 'upstream:' | awk '{print $2}')
TKN_BRANCH=$(echo "$RELEASE_CFG" | grep -A1 'tektoncd-cli:' | grep 'upstream:' | awk '{print $2}')
RESULTS_BRANCH=$(echo "$RELEASE_CFG" | grep -A1 'tektoncd-results:' | grep 'upstream:' | awk '{print $2}')
MAG_BRANCH=$(echo "$RELEASE_CFG" | grep -A1 'manual-approval-gate:' | grep 'upstream:' | awk '{print $2}')

# For each component, find latest version matching the tracked series (major.minor)
# Check both releases AND tags since some versions may be tagged but not yet released
# Example: if tracking release-v0.27.x, find latest v0.27.* version
get_latest_in_series() {
  local repo=$1
  local series_prefix=$2  # e.g. "0.27" extracted from "release-v0.27.x"
  
  # Try releases first (includes published releases)
  local latest_release=$(gh api "repos/${repo}/releases?per_page=100" 2>/dev/null \
    | jq -r "[.[] | select(.tag_name | startswith(\"v${series_prefix}.\"))] | .[0].tag_name // \"\"" \
    | sed 's/^v//')
  
  # Also check tags (may include unreleased tagged versions)
  local latest_tag=$(gh api "repos/${repo}/git/refs/tags" --paginate 2>/dev/null \
    | jq -r "[.[] | select(.ref | contains(\"${series_prefix}.\")) | .ref] | sort | .[-1] // \"\"" \
    | sed 's|refs/tags/v||' | sed 's|refs/tags/||')
  
  # Use the newer of the two (semver comparison)
  if [ -z "$latest_release" ]; then
    echo "$latest_tag"
  elif [ -z "$latest_tag" ]; then
    echo "$latest_release"
  else
    # Simple version comparison - take the one that sorts last
    printf "%s\n%s" "$latest_release" "$latest_tag" | sort -V | tail -1
  fi
}

# Extract series prefix from each tracked branch
PAC_SERIES=$(echo "$PAC_BRANCH" | sed 's/release-v//' | sed 's/\.x$//')
TKN_SERIES=$(echo "$TKN_BRANCH" | sed 's/release-v//' | sed 's/\.x$//')
RESULTS_SERIES=$(echo "$RESULTS_BRANCH" | sed 's/release-v//' | sed 's/\.x$//')
MAG_SERIES=$(echo "$MAG_BRANCH" | sed 's/release-v//' | sed 's/\.x$//')

PAC_LATEST=$(get_latest_in_series "openshift-pipelines/pipelines-as-code" "$PAC_SERIES")
TKN_LATEST=$(get_latest_in_series "tektoncd/cli" "$TKN_SERIES")
RESULTS_LATEST=$(get_latest_in_series "tektoncd/results" "$RESULTS_SERIES")
MAG_LATEST=$(get_latest_in_series "openshift-pipelines/manual-approval-gate" "$MAG_SERIES")

echo "Latest in tracked series:"
echo "  pac (${PAC_BRANCH}): ${PAC_LATEST}"
echo "  tkn (${TKN_BRANCH}): ${TKN_LATEST}"
echo "  results (${RESULTS_BRANCH}): ${RESULTS_LATEST}"
echo "  manualapprovalgate (${MAG_BRANCH}): ${MAG_LATEST}"
```

Parse version.json and compare each field against the latest in its tracked series. Strip `v` prefix before comparison.

Report a table:
```
| Component | Tracked Series | version.json | Latest in Series | Status |
|-----------|---------------|--------------|------------------|--------|
```

Status values:
- **CURRENT**: version.json matches latest released version in the tracked series
- **AHEAD**: version.json is newer than latest release (unreleased version, acceptable if intentional)
- **OUTDATED**: newer patch version available in the same series that should be adopted
- **UNKNOWN**: could not determine latest in series (check manually)

**Collect links:** Report any open PRs from step 1.8a, and check for recently merged PRs:
```bash
gh pr list --repo openshift-pipelines/opc \
  --base ${RELEASE_BRANCH} \
  --state merged --limit 5 \
  --json number,title,mergedAt,url
```

**Expected when DONE:** No open PRs requiring action (step 1.8a), all components are CURRENT (matching latest in their tracked series), and `opc` field equals `VERSION`.

**If not done — Execute (requires approval):**

If only the `opc` field needs updating, create an automated PR:

```bash
TMP_DIR=$(mktemp -d)
gh repo clone openshift-pipelines/opc "${TMP_DIR}" -- -b ${RELEASE_BRANCH} --depth 1 --quiet
cd "${TMP_DIR}"

# Get user git credentials from .env
source "${OLDPWD}/.env"
GIT_USER="${GITHUB_USER}"
GIT_EMAIL="${GITHUB_EMAIL}"

if [ -z "${GIT_USER}" ] || [ -z "${GIT_EMAIL}" ]; then
  echo "ERROR: GITHUB_USER and GITHUB_EMAIL must be set in .env"
  exit 1
fi

git config user.name "${GIT_USER}"
git config user.email "${GIT_EMAIL}"

# Update the opc version in pkg/version.json
CURRENT_OPC_VERSION=$(jq -r '.opc' pkg/version.json)
jq --arg version "${VERSION}" '.opc = $version' pkg/version.json > pkg/version.json.tmp
mv pkg/version.json.tmp pkg/version.json

git checkout -b "release/${VERSION}/opc-version-bump"
git add pkg/version.json
git commit -m "[bot:${MAJOR_MINOR}] Update OPC version to ${VERSION}

Signed-off-by: ${GIT_USER} <${GIT_EMAIL}>"
git push origin "release/${VERSION}/opc-version-bump" --quiet

gh pr create --repo openshift-pipelines/opc \
  --base ${RELEASE_BRANCH} \
  --head "release/${VERSION}/opc-version-bump" \
  --title "[bot:${MAJOR_MINOR}] Update OPC version to ${VERSION}" \
  --body "Updates pkg/version.json opc version from ${CURRENT_OPC_VERSION} to ${VERSION}.

This must be merged before CLI binaries are built." \
  --label automated

cd -
rm -rf "${TMP_DIR}"
```

**If component versions are OUTDATED:**

Report the mismatches to the user and provide manual update instructions:

```
ACTION NEEDED: Component versions need manual update.

The following components need updating to the latest in their tracked series:
- pac (tracking ${PAC_BRANCH}): ${CURRENT_PAC} → ${PAC_LATEST}
- tkn (tracking ${TKN_BRANCH}): ${CURRENT_TKN} → ${TKN_LATEST}
- results (tracking ${RESULTS_BRANCH}): ${CURRENT_RESULTS} → ${RESULTS_LATEST}
- manualapprovalgate (tracking ${MAG_BRANCH}): ${CURRENT_MAG} → ${MAG_LATEST}
- assist: ${CURRENT_ASSIST} → ${ASSIST_LATEST}

Manual steps required:
1. Clone the repo:
   git clone -b ${RELEASE_BRANCH} https://github.com/openshift-pipelines/opc.git /tmp/opc-update
   cd /tmp/opc-update

2. Update pkg/version.json with the new component versions

3. Update go.mod dependencies:
   go get github.com/openshift-pipelines/pipelines-as-code@v${PAC_LATEST}
   go get github.com/tektoncd/cli@v${TKN_LATEST}
   go get github.com/tektoncd/results@v${RESULTS_LATEST}
   go get github.com/openshift-pipelines/manual-approval-gate@v${MAG_LATEST}
   go get github.com/openshift-pipelines/tekton-assist@v${ASSIST_LATEST}

4. Tidy and vendor:
   go mod tidy
   go mod vendor

5. Create PR:
   git checkout -b "release/${VERSION}/component-version-bump"
   git add pkg/version.json go.mod go.sum vendor/
   git commit -m "[bot:${MAJOR_MINOR}] Update component versions for ${VERSION}"
   git push origin "release/${VERSION}/component-version-bump"
   gh pr create --base ${RELEASE_BRANCH} --title "[bot:${MAJOR_MINOR}] Update component versions for ${VERSION}"

Repository: https://github.com/openshift-pipelines/opc/tree/${RELEASE_BRANCH}/pkg
```

**Note:** Component version updates require updating go.mod dependencies and running `go mod vendor`. The automated PR only handles the `opc` version field. User git credentials (`GITHUB_USER` and `GITHUB_EMAIL`) are sourced from `.env` for commit authorship.

---

## Step 1.9: p12n-opc sync

The `p12n-opc` repo mirrors OPC under its `upstream/` directory. The `upstream/pkg/version.json` must match OPC's `pkg/version.json` on the release branch.

**Verify:**
```bash
OPC_VERSION=$(gh api repos/openshift-pipelines/opc/contents/pkg/version.json?ref=${RELEASE_BRANCH} \
  --jq '.content' | base64 -d)
P12N_VERSION=$(gh api repos/openshift-pipelines/p12n-opc/contents/upstream/pkg/version.json?ref=${RELEASE_BRANCH} \
  --jq '.content' | base64 -d)
echo "OPC version.json: ${OPC_VERSION}"
echo "p12n-opc version.json: ${P12N_VERSION}"
```

Compare HEADs:
```bash
OPC_HEAD=$(gh api repos/openshift-pipelines/opc/commits/${RELEASE_BRANCH} --jq '.sha')
P12N_OPC_HEAD=$(gh api repos/openshift-pipelines/p12n-opc/commits/${RELEASE_BRANCH} --jq '.sha')
echo "OPC HEAD: ${OPC_HEAD:0:12}"
echo "p12n-opc HEAD: ${P12N_OPC_HEAD:0:12}"
```

**Collect links:**
```bash
gh pr list --repo openshift-pipelines/p12n-opc \
  --base "${RELEASE_BRANCH}" \
  --state all --limit 5 \
  --json number,title,state,mergedAt,url
```

**Expected when DONE:** `version.json` files match.

**If not done — Execute:** MANUAL. Sync the `upstream/` directory in p12n-opc to match OPC on `${RELEASE_BRANCH}`. Create a PR targeting `${RELEASE_BRANCH}`.

Repository: `https://github.com/openshift-pipelines/p12n-opc/tree/${RELEASE_BRANCH}`

---

## Step 1.10: serve-tkn-cli submodules

The `serve-tkn-cli` repo uses git submodules under `sources/` to track upstream repos. Each submodule's SHA must match the HEAD of its tracking branch.

**Verify:**

Fetch `.gitmodules` to get tracking branches:
```bash
gh api repos/openshift-pipelines/serve-tkn-cli/contents/.gitmodules?ref=${RELEASE_BRANCH} \
  --jq '.content' | base64 -d
```

Fetch actual submodule SHAs:
```bash
gh api repos/openshift-pipelines/serve-tkn-cli/contents/sources?ref=${RELEASE_BRANCH} \
  --jq '.[] | "\(.name) \(.sha)"'
```

For each submodule, compare against its tracking branch HEAD. Use the repo URL from `.gitmodules` (PAC points to downstream `openshift-pipelines/pipelines-as-code`, not upstream):
```bash
# sources/cli → tektoncd/cli
CLI_HEAD=$(gh api repos/tektoncd/cli/commits/${CLI_BRANCH} --jq '.sha' 2>/dev/null)

# sources/opc → openshift-pipelines/opc
OPC_HEAD=$(gh api repos/openshift-pipelines/opc/commits/${RELEASE_BRANCH} --jq '.sha' 2>/dev/null)

# sources/pac → openshift-pipelines/pipelines-as-code (downstream)
PAC_HEAD=$(gh api repos/openshift-pipelines/pipelines-as-code/commits/${PAC_BRANCH} --jq '.sha' 2>/dev/null)
```

Report a table:
```
| Submodule | Repo | Branch | Submodule SHA | Branch HEAD | Status |
|-----------|------|--------|---------------|-------------|--------|
```

**Collect links:**
```bash
gh pr list --repo openshift-pipelines/serve-tkn-cli \
  --base "${RELEASE_BRANCH}" \
  --state all --limit 5 \
  --json number,title,state,mergedAt,url
```

**Expected when DONE:** All submodules are CURRENT.

**If PR is open — check CI before merging:**

```bash
PR_URL=$(gh pr list --repo openshift-pipelines/serve-tkn-cli \
  --head "release/${VERSION}/update-submodules" \
  --state open --limit 1 \
  --json url --jq '.[0].url')
gh pr view "${PR_URL}" --json mergeable,mergeStateStatus,statusCheckRollup
```

Classify:
- All checks pass and mergeable → **READY TO MERGE**
- CI checks with `bucket: pending` → **CI PENDING** — report and wait, re-check later
- CI checks with `bucket: fail` → **CI FAILING** — report failing checks, do not merge
- `mergeStateStatus: BEHIND` → **BEHIND** — rebase with `gh pr update-branch "${PR_URL}" --rebase`

**If READY TO MERGE — Execute (requires approval):**
```bash
PR_NUMBER=$(gh pr list --repo openshift-pipelines/serve-tkn-cli \
  --head "release/${VERSION}/update-submodules" \
  --state open --limit 1 \
  --json number --jq '.[0].number')
gh pr merge --repo openshift-pipelines/serve-tkn-cli ${PR_NUMBER} --rebase
```

**If no PR exists — Execute (requires approval):**

Note: plain `git submodule update` checks out the currently recorded SHA (yields "already up to date"). The `--remote --force --checkout` flags fetch from the tracking branch and force-checkout the new HEAD.

```bash
git clone -b ${RELEASE_BRANCH} \
  https://github.com/openshift-pipelines/serve-tkn-cli.git /tmp/serve-tkn-cli-submodule-update
cd /tmp/serve-tkn-cli-submodule-update

# Ensure .gitmodules tracking branches use the .x format (not pinned versions).
# Compare each branch against the hack repo config and fix mismatches.
RELEASE_CFG=$(gh api repos/openshift-pipelines/hack/contents/config/downstream/releases/${MAJOR_MINOR}.yaml \
  --jq '.content' | base64 -d)

# Fix cli branch: hack config has the canonical upstream branch
CLI_UPSTREAM=$(echo "$RELEASE_CFG" | python3 -c "
import sys, yaml
cfg = yaml.safe_load(sys.stdin)
print(cfg['branches']['tektoncd-cli']['upstream'])
")
sed -i "/sources\/cli/,/branch =/{s|branch = .*|branch = ${CLI_UPSTREAM}|}" .gitmodules

git submodule update --init --remote --force --checkout

git checkout -b "release/${VERSION}/update-submodules"
git add .gitmodules sources/
git commit -m "[bot:${MAJOR_MINOR}] Update submodules to latest upstream"
git push origin "release/${VERSION}/update-submodules"

gh pr create --repo openshift-pipelines/serve-tkn-cli \
  --base ${RELEASE_BRANCH} \
  --head "release/${VERSION}/update-submodules" \
  --title "[bot:${MAJOR_MINOR}] Update submodules to latest upstream" \
  --body "Updates git submodules to their latest tracking branch HEADs:
- sources/cli
- sources/opc
- sources/pac

Also fixes .gitmodules tracking branches to use the .x format per hack repo config." \
  --label automated

cd -
rm -rf /tmp/serve-tkn-cli-submodule-update
```

---

## Step 1.11: CLI product version config

The product version configuration must exist in the `konflux-release-data` GitLab repo before CDN RP/RPA can be created (step 1.12).

**Verify:**
```bash
curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/projects/releng%2Fkonflux-release-data/repository/files/data%2Fexternal%2Fdeveloper-portal%2Fopenshift-pipelines%2F${VERSION}.yaml/raw?ref=main" \
  2>/dev/null
```

If the file exists, validate:
- `versionName` matches `VERSION`
- `ga` — report value (`false` for patches, `true` for minor releases and patches on latest minor)
- `hidden` — should be `false`
- `invisible` — should be `false`
- `releaseDate` — report value

**Collect links:**
```bash
curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/projects/releng%2Fkonflux-release-data/merge_requests?state=merged&search=openshift-pipelines+${VERSION}&per_page=5" \
  2>/dev/null | python3 -c "
import sys, json
mrs = json.load(sys.stdin)
if isinstance(mrs, list):
    for mr in mrs:
        if '${VERSION}' in mr.get('title',''):
            print(f\"MR: {mr['web_url']}  ({mr['state']})\")
"
```

**Expected when DONE:** File exists with correct `versionName`.

**If not done — Execute:** MANUAL. Create a GitLab MR to add the product version YAML:

File path: `data/external/developer-portal/openshift-pipelines/${VERSION}.yaml`

Content:
```yaml
---
versionName: "${VERSION}"
ga: false
termsAndConditions: "Anonymous Download"
hidden: false
invisible: false
releaseDate: "${TODAY}"
```

Notes:
- `ga`: `false` for patch versions, `true` for minor releases and patches on latest minor
- `releaseDate`: set to actual release date

Reference MR: `https://gitlab.cee.redhat.com/releng/konflux-release-data/-/merge_requests/20810`

**IMPORTANT:** This PR must be merged BEFORE creating the RP/RPA in step 1.12.

If `GITLAB_TOKEN` is not set, SKIP this step.

---

## Step 1.12: CLI CDN RP/RPA

CDN releases require dedicated ReleasePlanAdmission and ReleasePlan resources in the `konflux-release-data` GitLab repo, separate from the image-based ones used in the main pipeline.

**Verify:**

Check ReleasePlanAdmission:
```bash
curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/projects/releng%2Fkonflux-release-data/repository/tree?path=config/kflux-prd-rh02.0fk9.p1/product/ReleasePlanAdmission/tekton-ecosystem&ref=main&per_page=100" \
  2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
if isinstance(data, list):
    matches = [f['name'] for f in data if '${MM_DASHED}' in f['name'] and 'cdn' in f['name']]
    for m in sorted(matches):
        print(m)
    if not matches:
        print('NO_CDN_RPA_FOUND')
"
```

Check ReleasePlan (tenant config):
```bash
curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/projects/releng%2Fkonflux-release-data/repository/tree?path=tenants-config/cluster/kflux-prd-rh02/tenants/tekton-ecosystem-tenant&ref=main&per_page=100" \
  2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
if isinstance(data, list):
    matches = [f['name'] for f in data if '${MM_DASHED}' in f['name'] and 'cdn' in f['name']]
    for m in sorted(matches):
        print(m)
    if not matches:
        print('NO_CDN_RP_FOUND')
"
```

Check auto-generated ReleasePlan:
```bash
curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/projects/releng%2Fkonflux-release-data/repository/tree?path=tenants-config/auto-generated/cluster/kflux-prd-rh02/tenants/tekton-ecosystem-tenant&ref=main&per_page=100" \
  2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
if isinstance(data, list):
    matches = [f['name'] for f in data if '${MM_DASHED}' in f['name'] and 'cdn' in f['name']]
    for m in sorted(matches):
        print(m)
    if not matches:
        print('NO_AUTO_GEN_CDN_RP_FOUND')
"
```

Expected CDN RPAs: `openshift-pipelines-${MM_DASHED}-core-cdn-prod.yaml`, `openshift-pipelines-${MM_DASHED}-core-cdn-stage.yaml`

Report a table:
```
| Resource | Type | File | Status |
|----------|------|------|--------|
```

**Collect links:**
```bash
curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/projects/releng%2Fkonflux-release-data/merge_requests?state=merged&search=openshift-pipelines+cdn+${MM_DASHED}&per_page=5" \
  2>/dev/null | python3 -c "
import sys, json
mrs = json.load(sys.stdin)
if isinstance(mrs, list):
    for mr in mrs:
        if '${MM_DASHED}' in mr.get('title','') or 'cdn' in mr.get('title','').lower():
            print(f\"MR: {mr['web_url']}  ({mr['state']})\")
"
```

**Expected when DONE:** All required CDN RP/RPA files exist.

**If not done — Execute:** MANUAL. Copy RP/RPA from a previous version and update version numbers.

Reference MR: `https://gitlab.cee.redhat.com/releng/konflux-release-data/-/merge_requests/14754/diffs`

**IMPORTANT:** The product version configuration (step 1.11) must be merged first — ReleasePlanAdmission cannot reference a version that is not defined.

If `GITLAB_TOKEN` is not set, SKIP this step.

---

## Report Output

After processing all steps, write the stage report to `${REPORT_BASE}/config/report_${REPORT_TIMESTAMP}.md`.

**Report format:**

```markdown
# Config Stage Report — ${VERSION}

**Generated:** ${REPORT_TIMESTAMP}
**Release:** ${VERSION} (${MAJOR_MINOR})
**Branch:** ${RELEASE_BRANCH}

## Summary

| Step | Title | Status | Details | Links |
|------|-------|--------|---------|-------|
| 1.1 | Create new patch version | {status} | {details} | {links} |
| 1.2 | Merge release-manager PR | {status} | {details} | {links} |
| 1.3 | Konflux config PR merged | {status} | {details} | {links} |
| 1.4 | Konflux config on cluster | {status} | {details} | {links} |
| 1.5 | RPA in konflux-release-data | {status} | {details} | {links} |
| 1.6 | Pyxis config | {status} | {details} | {links} |
| 1.7 | Operator project.yaml version | {status} | {details} | {links} |
| 1.8 | OPC version.json | {status} | {details} | {links} |
| 1.9 | p12n-opc sync | {status} | {details} | {links} |
| 1.10 | serve-tkn-cli submodules | {status} | {details} | {links} |
| 1.11 | CLI product version config | {status} | {details} | {links} |
| 1.12 | CLI CDN RP/RPA | {status} | {details} | {links} |

## Step Details

### Step 1.1: Create new patch version
- **Status:** {DONE | ACTION NEEDED | SKIPPED}
- **release-tag:** {value}
- **Workflow:** [{workflow-name}]({url}) ({status}/{conclusion})

### Step 1.2: Merge release-manager PR
- **Status:** {DONE | ACTION NEEDED | SKIPPED}
- **PR:** hack [#{number}]({url}) — {state}
- **Merged:** {timestamp}

### Step 1.8: OPC version.json
- **Status:** {DONE | ACTION NEEDED | SKIPPED}
- **Version comparison:**

| Component | version.json | Latest upstream | Status |
|-----------|-------------|-----------------|--------|
| {component} | {version} | {latest} | {CURRENT/OUTDATED/REVIEW} |

### Step 1.9: p12n-opc sync
- **Status:** {DONE | ACTION NEEDED | SKIPPED}
- **OPC HEAD:** [{short}]({url})
- **p12n-opc HEAD:** [{short}]({url})

### Step 1.10: serve-tkn-cli submodules
- **Status:** {DONE | ACTION NEEDED | SKIPPED}
- **Submodule comparison:**

| Submodule | Repo | Branch | Submodule SHA | Branch HEAD | Status |
|-----------|------|--------|---------------|-------------|--------|
| {submodule} | {repo} | {branch} | [{short}]({url}) | [{short}]({url}) | {CURRENT/OUTDATED} |

### Step 1.11: CLI product version config
- **Status:** {DONE | ACTION NEEDED | SKIPPED}
- **versionName:** {value}
- **ga:** {value}
- **releaseDate:** {value}

### Step 1.12: CLI CDN RP/RPA
- **Status:** {DONE | ACTION NEEDED | SKIPPED}
- **CDN RPAs:** {count} found
- **CDN RPs:** {count} found

{...repeat for each step checked...}

## Blocking Step

{If stopped early, show which step blocked and why. Omit if all steps DONE.}
```

**Column values:**

- **Status:** `DONE`, `ACTION NEEDED`, `SKIPPED`
- **Details:** one-line summary (e.g. `release-tag: 1.21.3`, `merged 2026-07-08 10:30 IST`, `5 apps OK`)
- **Links:** all links collected for that step:
  - GitHub PRs: `hack [#NUM](URL)`, `operator [#NUM](URL)`
  - Workflow runs: `[workflow-name](URL)`
  - GitLab MRs: `[MR](URL)`
  - Multiple links separated by `, `
  - No links: `—`

Write the report file and print the path to the user:
```
Report written to: reports/${MAJOR_MINOR}/${VERSION}/config/report_${REPORT_TIMESTAMP}.md
```
