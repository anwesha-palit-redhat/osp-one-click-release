# Stage 4: Production Release

Release core, bundle, and index applications to production via Konflux Release CRs. Steps run sequentially — stop at the first step that requires action (unless the user approves execution).

**Inputs:** `VERSION`, `MAJOR_MINOR`, `MM_DASHED`, `RELEASE_BRANCH`, `KONFLUX_NS`, `KONFLUX_SERVER`, `KONFLUX_TOKEN`, `TZ_FMT`, `REPORT_BASE`, `REPORT_TIMESTAMP`

**Constraints:**
- Konflux cluster: **READ-ONLY** for verify commands (`oc get`/`kubectl get` only). Release CRs may be created (`oc create -f`) as execute commands after user approval.
- Release CR YAML files are saved to `${REPORT_BASE}/manifest/prod/` for reference before applying
- Execute commands (GitHub workflows, PR merges, Release CR creation) require explicit user approval before running

**Formatting:**
- PR links: `[#NUM](https://github.com/OWNER/REPO/pull/NUM)`
- SHA links: `[SHORT](https://github.com/OWNER/REPO/commit/FULL)` (12-char short)
- Timestamps: absolute local time with timezone (e.g. `2026-07-08 14:30 IST`)

**Release YAML storage:** All generated Release CR manifests are stored in `${REPORT_BASE}/manifest/prod/`.

---

## Step 4.1: Verify stage releases / identify core snapshot

Production release requires that stage releases have completed successfully. The core snapshot used for stage MUST be reused for production — do NOT pick a different one.

### Verify

Check for existing stage releases:
```bash
oc get releases -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify -o json 2>/dev/null \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
mm = '${MM_DASHED}'
releases = []
for item in data.get('items', []):
    name = item['metadata']['name']
    rp = item.get('spec', {}).get('releasePlan', '')
    snapshot = item.get('spec', {}).get('snapshot', '')
    conditions = item.get('status', {}).get('conditions', [])
    released = next((c for c in conditions if c.get('type') == 'Released'), {})
    status = released.get('status', 'Unknown')
    reason = released.get('reason', '')
    if mm in name and 'stage' in rp:
        releases.append({
            'name': name,
            'releasePlan': rp,
            'snapshot': snapshot,
            'status': status,
            'reason': reason
        })
for r in sorted(releases, key=lambda x: x['releasePlan']):
    print(f\"{r['releasePlan']}: {r['name']} snapshot={r['snapshot']} status={r['status']} reason={r['reason']}\")
"
```

Extract the core snapshot used for stage:
```bash
STAGE_CORE_SNAPSHOT=$(oc get releases -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify -o json 2>/dev/null \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
mm = '${MM_DASHED}'
for item in data.get('items', []):
    rp = item.get('spec', {}).get('releasePlan', '')
    if mm in rp and 'core' in rp and 'stage' in rp:
        conditions = item.get('status', {}).get('conditions', [])
        released = next((c for c in conditions if c.get('type') == 'Released'), {})
        if released.get('status') == 'True':
            print(item['spec']['snapshot'])
            break
")
echo "Stage core snapshot: ${STAGE_CORE_SNAPSHOT}"
```

Report a table:
```
| Application | Release Plan | Snapshot | Status |
|-------------|-------------|----------|--------|
```

**Expected when DONE:** Stage core release exists with status `Succeeded`. Core snapshot extracted.

### If not done

If no stage releases found, the stage release process must complete first. Report:
```
BLOCKER: No stage releases found for ${MM_DASHED}.
Stage releases (core, bundle, index) must succeed before production release can begin.
```

If stage core release failed, report the failure reason and stop.

---

## Step 4.2: Core production release

Reuse the same core snapshot from stage. Create a Release CR targeting the production release plan.

### Verify

Check for an existing production core release:
```bash
oc get releases -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify -o json 2>/dev/null \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
mm = '${MM_DASHED}'
for item in data.get('items', []):
    rp = item.get('spec', {}).get('releasePlan', '')
    if mm in rp and 'core' in rp and 'prod' in rp and 'cdn' not in rp:
        conditions = item.get('status', {}).get('conditions', [])
        released = next((c for c in conditions if c.get('type') == 'Released'), {})
        snapshot = item.get('spec', {}).get('snapshot', '')
        managed = item.get('status', {}).get('managedProcessing', {}).get('pipelineRun', '')
        print(f\"Release: {item['metadata']['name']}\")
        print(f\"ReleasePlan: {rp}\")
        print(f\"Snapshot: {snapshot}\")
        print(f\"Status: {released.get('status', 'Unknown')} ({released.get('reason', '')})\")
        if managed:
            print(f\"PipelineRun: {managed}\")
        break
"
```

**Expected when DONE:** A production core release exists with status `Succeeded`.

### If not done — Execute (requires approval)

Find the core application and production release plan:
```bash
CORE_APP=$(oc get applications.appstudio.redhat.com -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify -o json 2>/dev/null \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
mm = '${MM_DASHED}'
apps = [i['metadata']['name'] for i in data['items'] if 'core' in i['metadata']['name'] and mm in i['metadata']['name']]
print(apps[0] if apps else '')
")

CORE_PROD_RP=$(oc get releaseplans -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify -o json 2>/dev/null \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
app = '${CORE_APP}'
for item in data['items']:
    if item['spec'].get('application') == app and 'prod' in item['metadata']['name'] and 'cdn' not in item['metadata']['name']:
        print(item['metadata']['name'])
        break
")

echo "Application: ${CORE_APP}"
echo "Release Plan: ${CORE_PROD_RP}"
echo "Snapshot: ${STAGE_CORE_SNAPSHOT}"
```

Generate the Release YAML:
```bash
mkdir -p "${REPORT_BASE}/manifest/prod"

cat > "${REPORT_BASE}/manifest/prod/release-${VERSION}-core-prod.yaml" <<EOF
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  labels:
    appstudio.openshift.io/application: ${CORE_APP}
  generateName: ${CORE_PROD_RP}-
  namespace: ${KONFLUX_NS}
spec:
  releasePlan: ${CORE_PROD_RP}
  snapshot: ${STAGE_CORE_SNAPSHOT}
EOF
```

Apply the Release CR (`oc create`, not `oc apply` — uses `generateName`):
```bash
RELEASE_NAME=$(oc create -f ${REPORT_BASE}/manifest/prod/release-${VERSION}-core-prod.yaml \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify \
  -o jsonpath='{.metadata.name}')
echo "Created release: ${RELEASE_NAME}"
```

Wait for the release to complete:
```bash
oc wait release/${RELEASE_NAME} -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify \
  --for=condition=Released --timeout=300s 2>&1 || true
```

Check result:
```bash
oc get release ${RELEASE_NAME} -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify \
  -o jsonpath='Released={.status.conditions[?(@.type=="Released")].status} Reason={.status.conditions[?(@.type=="Released")].reason}'
```

If `Released=True` → DONE, proceed to step 4.3. If still in progress, report the release name — the re-verify will catch it on the next run.

---

## Step 4.3: Production CSV update (operator-update-images)

The `operator-update-images` workflow updates the CSV to point to the production registry. It creates a PR on the operator repo. ALL images in the CSV must point to the production registry — no staging registry references.

**Auto-trigger note:** On release branches, this workflow auto-triggers on `project.yaml` push events. However, push-triggered runs receive an empty `environment` input (defaults to `devel`). For production release, **`workflow_dispatch` with `environment: production` is required** — the auto-triggered run will NOT produce production CSV output.

### Verify

Check for a recent `operator-update-images` workflow run with production environment:
```bash
gh run list --repo openshift-pipelines/operator \
  --workflow=operator-update-images.yaml \
  --limit 10 \
  --json databaseId,headBranch,status,conclusion,createdAt,displayTitle,url \
  | python3 -c "
import sys, json
runs = json.load(sys.stdin)
branch = '${RELEASE_BRANCH}'
for r in runs:
    if branch in r.get('displayTitle', '') or branch in r.get('headBranch', ''):
        print(f\"Run: {r['url']}\")
        print(f\"Title: {r['displayTitle']}\")
        print(f\"Status: {r['status']}/{r.get('conclusion', 'pending')}\")
        print(f\"Created: {r['createdAt']}\")
"
```

Check for the CSV PR:
```bash
gh pr list --repo openshift-pipelines/operator \
  --head "actions/update/operator-update-images-${RELEASE_BRANCH}" \
  --state all --limit 5 \
  --json number,title,state,mergedAt,url
```

**Collect links:** Report the workflow run URL and CSV PR as `operator [#NUM](URL)`.

**Expected when DONE:** A production `operator-update-images` run completed successfully AND the CSV PR has been merged with all images pointing to the production registry.

### If not done — Execute (requires approval)

Trigger the workflow:
```bash
gh workflow run operator-update-images.yaml \
  --repo openshift-pipelines/operator \
  --ref ${RELEASE_BRANCH} \
  -f environment=production
```

After triggering, monitor:
```bash
gh run list --repo openshift-pipelines/operator \
  --workflow=operator-update-images.yaml \
  --limit 3 \
  --json databaseId,status,conclusion,createdAt,displayTitle,url
```

Once the workflow completes, it creates a PR. Proceed to step 4.4 to verify and merge it.

---

## Step 4.4: Merge production CSV PR

The CSV PR from `operator-update-images` must be verified and merged. ALL image references must point to the production registry — any staging registry references are a release blocker.

### Verify

Check the PR status:
```bash
gh pr list --repo openshift-pipelines/operator \
  --head "actions/update/operator-update-images-${RELEASE_BRANCH}" \
  --state open --limit 1 \
  --json number,title,state,url,mergeable,mergeStateStatus
```

If the PR is open, inspect the diff to verify production registry references:
```bash
PR_NUMBER=$(gh pr list --repo openshift-pipelines/operator \
  --head "actions/update/operator-update-images-${RELEASE_BRANCH}" \
  --state open --limit 1 \
  --json number --jq '.[0].number')

gh pr diff --repo openshift-pipelines/operator ${PR_NUMBER} 2>/dev/null \
  | grep -E '^\+.*image:' \
  | head -20
```

Check for staging registry references in the diff (these should NOT be present):
```bash
gh pr diff --repo openshift-pipelines/operator ${PR_NUMBER} 2>/dev/null \
  | grep -E '^\+.*(stage|staging)' \
  | head -10
```

If the PR is already merged:
```bash
gh pr list --repo openshift-pipelines/operator \
  --head "actions/update/operator-update-images-${RELEASE_BRANCH}" \
  --state merged --limit 1 \
  --json number,title,mergedAt,url
```

**Collect links:** Report the PR as `operator [#NUM](URL)`.

**Expected when DONE:** The CSV PR is merged. No staging registry references in the diff.

### If not done — Execute (requires approval)

If the PR exists, has all production registry references, and CI is green:
```bash
PR_NUMBER=$(gh pr list --repo openshift-pipelines/operator \
  --head "actions/update/operator-update-images-${RELEASE_BRANCH}" \
  --state open --limit 1 \
  --json number --jq '.[0].number')

gh pr edit --repo openshift-pipelines/operator ${PR_NUMBER} --add-label "lgtm,approved,one-click-release"
gh pr review --approve --repo openshift-pipelines/operator ${PR_NUMBER}
gh pr merge --repo openshift-pipelines/operator ${PR_NUMBER} -d -r --auto
```

If staging registry references are found in the diff:
```
BLOCKER: CSV PR contains staging registry references.
The operator-update-images workflow may have been run with the wrong environment.
Re-trigger with environment=production (step 4.3).
```

After merging, wait for the bundle to rebuild before proceeding to step 4.5.

**WARNING — auto-triggered devel render:** Merging the CSV PR pushes changes to `olm/` which auto-triggers `render-olm-catalog` with empty environment (defaults to `devel`). This devel run will write devel registry references into the catalog JSONs and can trigger bad FBC index builds. This is expected — the production `render-olm-catalog` dispatch in step 4.7 will overwrite the catalogs after the bundle is ready. Do NOT dispatch render-olm-catalog with production yet — the bundle must be built first (steps 4.5–4.6).

---

## Step 4.5: Wait for bundle snapshot

After the production CSV PR merges, the bundle image rebuilds with production image references. Verify the latest bundle snapshot reflects the merged CSV changes.

**Requires:** `KONFLUX_SERVER` and `KONFLUX_TOKEN`. If missing, SKIP this step.

### Verify

Get the bundle application and latest snapshot:
```bash
BUNDLE_APP=$(oc get applications.appstudio.redhat.com -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify -o json 2>/dev/null \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
mm = '${MM_DASHED}'
apps = [i['metadata']['name'] for i in data['items'] if 'bundle' in i['metadata']['name'] and mm in i['metadata']['name']]
print(apps[0] if apps else '')
")

LATEST_BUNDLE=$(oc get snapshots -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify \
  -l "pac.test.appstudio.openshift.io/event-type=push,appstudio.openshift.io/application=${BUNDLE_APP}" \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | awk '{print $NF}')

echo "Bundle app: ${BUNDLE_APP}"
echo "Latest bundle snapshot: ${LATEST_BUNDLE}"
```

Compare the bundle snapshot revision against operator HEAD:
```bash
BUNDLE_REV=$(oc get snapshot ${LATEST_BUNDLE} -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify \
  -o jsonpath='{.spec.components[0].source.git.revision}' 2>/dev/null)

OPERATOR_HEAD=$(git ls-remote "https://github.com/openshift-pipelines/operator.git" \
  "refs/heads/${RELEASE_BRANCH}" | awk '{print $1}')

echo "Bundle revision: ${BUNDLE_REV:0:12}"
echo "Operator HEAD:   ${OPERATOR_HEAD:0:12}"
```

If the revisions don't match, check the commits between them:
```bash
gh api repos/openshift-pipelines/operator/compare/${BUNDLE_REV}...${OPERATOR_HEAD} \
  --jq '.commits[] | "\(.sha[:12]) \(.commit.message | split("\n")[0])"'
```

The bundle snapshot must include the production CSV merge commit. If all intervening commits after the CSV merge are automated (catalog/bot), the bundle is acceptable.

**Collect links:** Report the bundle snapshot name and creation timestamp.

**Expected when DONE:** Bundle snapshot revision includes the production CSV merge commit (or only automated commits follow it).

### If not done — Execute (requires approval)

If the bundle is stale (doesn't include the production CSV merge), push a placeholder to trigger a rebuild:
```bash
TMP_DIR=$(mktemp -d)
gh repo clone "openshift-pipelines/operator" "${TMP_DIR}" -- -b "${RELEASE_BRANCH}" --depth 1 --quiet
cd "${TMP_DIR}"
mkdir -p .konflux/olm-catalog/bundle/
echo "Forced production bundle rebuild at $(date)" > .konflux/olm-catalog/bundle/.placeholder
git config user.name "One Click Release Bot"
git config user.email "one-click-release-bot@redhat.com"
git add .
git commit -m "One Click Release: rebuild bundle for production" --quiet
git push origin "${RELEASE_BRANCH}" --quiet
cd -
rm -rf "${TMP_DIR}"
```

After pushing, wait for the Konflux pipeline to complete, then re-verify the snapshot.

---

## Step 4.6: Bundle production release

Use the latest bundle snapshot (which now includes production CSV). Create a Release CR targeting the production bundle release plan.

### Verify

Check for an existing production bundle release:
```bash
oc get releases -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify -o json 2>/dev/null \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
mm = '${MM_DASHED}'
for item in data.get('items', []):
    rp = item.get('spec', {}).get('releasePlan', '')
    if mm in rp and 'bundle' in rp and 'prod' in rp:
        conditions = item.get('status', {}).get('conditions', [])
        released = next((c for c in conditions if c.get('type') == 'Released'), {})
        snapshot = item.get('spec', {}).get('snapshot', '')
        managed = item.get('status', {}).get('managedProcessing', {}).get('pipelineRun', '')
        print(f\"Release: {item['metadata']['name']}\")
        print(f\"ReleasePlan: {rp}\")
        print(f\"Snapshot: {snapshot}\")
        print(f\"Status: {released.get('status', 'Unknown')} ({released.get('reason', '')})\")
        if managed:
            print(f\"PipelineRun: {managed}\")
        break
"
```

**Expected when DONE:** A production bundle release exists with status `Succeeded`.

### If not done — Execute (requires approval)

Find the bundle application and production release plan:
```bash
BUNDLE_APP=$(oc get applications.appstudio.redhat.com -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify -o json 2>/dev/null \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
mm = '${MM_DASHED}'
apps = [i['metadata']['name'] for i in data['items'] if 'bundle' in i['metadata']['name'] and mm in i['metadata']['name']]
print(apps[0] if apps else '')
")

BUNDLE_PROD_RP=$(oc get releaseplans -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify -o json 2>/dev/null \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
app = '${BUNDLE_APP}'
for item in data['items']:
    if item['spec'].get('application') == app and 'prod' in item['metadata']['name']:
        print(item['metadata']['name'])
        break
")

LATEST_BUNDLE=$(oc get snapshots -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify \
  -l "pac.test.appstudio.openshift.io/event-type=push,appstudio.openshift.io/application=${BUNDLE_APP}" \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | awk '{print $NF}')

echo "Application: ${BUNDLE_APP}"
echo "Release Plan: ${BUNDLE_PROD_RP}"
echo "Snapshot: ${LATEST_BUNDLE}"
```

Generate the Release YAML:
```bash
mkdir -p "${REPORT_BASE}/manifest/prod"

cat > "${REPORT_BASE}/manifest/prod/release-${VERSION}-bundle-prod.yaml" <<EOF
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  labels:
    appstudio.openshift.io/application: ${BUNDLE_APP}
  generateName: ${BUNDLE_PROD_RP}-
  namespace: ${KONFLUX_NS}
spec:
  releasePlan: ${BUNDLE_PROD_RP}
  snapshot: ${LATEST_BUNDLE}
EOF
```

Apply the Release CR (`oc create`, not `oc apply` — uses `generateName`):
```bash
RELEASE_NAME=$(oc create -f ${REPORT_BASE}/manifest/prod/release-${VERSION}-bundle-prod.yaml \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify \
  -o jsonpath='{.metadata.name}')
echo "Created release: ${RELEASE_NAME}"
```

Wait for the release to complete:
```bash
oc wait release/${RELEASE_NAME} -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify \
  --for=condition=Released --timeout=300s 2>&1 || true
```

Check result:
```bash
oc get release ${RELEASE_NAME} -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify \
  -o jsonpath='Released={.status.conditions[?(@.type=="Released")].status} Reason={.status.conditions[?(@.type=="Released")].reason}'
```

If `Released=True` → DONE, proceed to step 4.7. If still in progress, report the release name — the re-verify will catch it on the next run.

---

## Step 4.7: Production OLM catalog render + wait for index snapshots

Trigger `render-olm-catalog` with `Environment: production` to update catalog JSONs for the production registry. After the render completes, wait for index images to rebuild.

**Auto-trigger hazard:** On release branches, `render-olm-catalog` auto-triggers when `bundle.yaml` or `olm/**` files are pushed. Merging the production CSV PR (step 4.4) auto-triggers a devel run (empty `environment` input → defaults to `devel`). This devel run writes devel registry references into the catalog JSONs and triggers FBC index builds with wrong catalogs. The production dispatch here overwrites those catalogs and triggers correct index builds — but only if the devel run finishes first. **Always wait for any in-progress devel runs to complete, then dispatch production.**

### Verify

Check for in-progress or recent `render-olm-catalog` runs on the release branch:
```bash
gh run list --repo openshift-pipelines/operator \
  --workflow=render-olm-catalog.yaml \
  --limit 10 \
  --json databaseId,headBranch,status,conclusion,createdAt,displayTitle,url,event \
  | python3 -c "
import sys, json
runs = json.load(sys.stdin)
branch = '${RELEASE_BRANCH}'
for r in runs:
    if branch in r.get('displayTitle', '') or branch in r.get('headBranch', ''):
        event = r.get('event', 'unknown')
        env_label = 'workflow_dispatch' if event == 'workflow_dispatch' else f'auto-trigger ({event})'
        print(f\"Run: {r['url']}\")
        print(f\"Title: {r['displayTitle']}\")
        print(f\"Trigger: {env_label}\")
        print(f\"Status: {r['status']}/{r.get('conclusion', 'pending')}\")
        print(f\"Created: {r['createdAt']}\")
        print()
"
```

If any run has `status: in_progress` or `status: queued`, report it and wait — do NOT dispatch production until it finishes.

Check for catalog JSON commits on the release branch after the production CSV merge:
```bash
gh api repos/openshift-pipelines/operator/commits?sha=${RELEASE_BRANCH}\&per_page=10 \
  --jq '.[] | select(.commit.message | test("catalog|render|OCP catalog")) | "\(.sha[:12]) \(.commit.message | split("\n")[0])"'
```

Check index snapshots:
```bash
INDEX_APPS=$(oc get applications.appstudio.redhat.com -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify -o json 2>/dev/null \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
mm = '${MM_DASHED}'
apps = sorted([i['metadata']['name'] for i in data['items'] if 'index' in i['metadata']['name'] and mm in i['metadata']['name']])
for a in apps:
    print(a)
")
```

For each index app, get its latest snapshot and compare against operator HEAD:
```bash
OPERATOR_HEAD=$(git ls-remote "https://github.com/openshift-pipelines/operator.git" \
  "refs/heads/${RELEASE_BRANCH}" | awk '{print $1}')

for INDEX_APP in ${INDEX_APPS}; do
  LATEST_INDEX=$(oc get snapshots -n ${KONFLUX_NS} \
    --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
    --insecure-skip-tls-verify \
    -l "pac.test.appstudio.openshift.io/event-type=push,appstudio.openshift.io/application=${INDEX_APP}" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | awk '{print $NF}')

  if [ -z "${LATEST_INDEX}" ]; then
    echo "${INDEX_APP}: NO SNAPSHOT (no components or not applicable)"
    continue
  fi

  INDEX_REV=$(oc get snapshot ${LATEST_INDEX} -n ${KONFLUX_NS} \
    --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
    --insecure-skip-tls-verify \
    -o jsonpath='{.spec.components[0].source.git.revision}' 2>/dev/null)

  CREATED=$(oc get snapshot ${LATEST_INDEX} -n ${KONFLUX_NS} \
    --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
    --insecure-skip-tls-verify \
    -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)

  if [ "${INDEX_REV}" = "${OPERATOR_HEAD}" ]; then
    STATUS="CURRENT"
  else
    STATUS="STALE"
  fi

  echo "${INDEX_APP}: ${LATEST_INDEX} rev=${INDEX_REV:0:12} ${STATUS} (created ${CREATED})"
done
```

Report a table:
```
| Index App | Snapshot | Revision | Status | Created |
|-----------|----------|----------|--------|---------|
```

**Collect links:** Report the render-olm-catalog workflow run URL and index snapshot statuses.

**Expected when DONE:** A `render-olm-catalog` `workflow_dispatch` run (not an auto-triggered push run) completed successfully with production environment after the bundle release. The exact generated catalog PR is recorded, contains only `registry.redhat.io/openshift-pipelines/` digest references, and is merged after that run. All index snapshots with non-empty config descend from that merge, were built afterward, and retain `olm/release-stage.txt=production` at their source revision.

### If not done — Execute (requires approval)

**First:** Check for any in-progress devel auto-triggered runs. If one is running, wait for it to complete before dispatching production — otherwise the devel run may commit on top of the production catalogs.

```bash
DEVEL_RUN_ID=$(gh run list --repo openshift-pipelines/operator \
  --workflow=render-olm-catalog.yaml \
  --limit 5 \
  --json databaseId,status,event \
  --jq '[.[] | select(.status == "in_progress" or .status == "queued")] | .[0].databaseId // empty')

if [ -n "${DEVEL_RUN_ID}" ]; then
  echo "Waiting for in-progress run ${DEVEL_RUN_ID} to complete..."
  gh run watch --repo openshift-pipelines/operator ${DEVEL_RUN_ID}
fi
```

Then dispatch the production render:
```bash
gh workflow run render-olm-catalog.yaml \
  --repo openshift-pipelines/operator \
  -f branch=${RELEASE_BRANCH} \
  -f environment=production
```

The production run overwrites the generated branch with production registry references. The executable records the exact generated PR head, validates and merges that PR, and then binds fresh FBC snapshots to its merge commit. Wait for the PR and snapshots to complete — index images built from earlier devel catalogs are never accepted as production evidence.

If index snapshots are stale after the production catalog render, push a placeholder to trigger index rebuilds:
```bash
TMP_DIR=$(mktemp -d)
gh repo clone "openshift-pipelines/operator" "${TMP_DIR}" -- -b "${RELEASE_BRANCH}" --depth 1 --quiet
cd "${TMP_DIR}"
mkdir -p .konflux/olm-catalog/index/
echo "Forced production index rebuild at $(date)" > .konflux/olm-catalog/index/.placeholder
git config user.name "One Click Release Bot"
git config user.email "one-click-release-bot@redhat.com"
git add .
git commit -m "One Click Release: rebuild index images for production" --quiet
git push origin "${RELEASE_BRANCH}" --quiet
cd -
rm -rf "${TMP_DIR}"
```

After pushing, wait for Konflux pipelines to complete, then re-verify snapshots.

---

## Step 4.8: Index production releases

For each index application with a valid snapshot, create a Release CR targeting the production FBC release plan.

### Verify

Check for existing production FBC/index releases:
```bash
oc get releases -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify -o json 2>/dev/null \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
mm = '${MM_DASHED}'
releases = []
for item in data.get('items', []):
    rp = item.get('spec', {}).get('releasePlan', '')
    if mm in rp and ('fbc' in rp or 'index' in rp) and 'prod' in rp:
        conditions = item.get('status', {}).get('conditions', [])
        released = next((c for c in conditions if c.get('type') == 'Released'), {})
        releases.append({
            'name': item['metadata']['name'],
            'releasePlan': rp,
            'snapshot': item.get('spec', {}).get('snapshot', ''),
            'status': released.get('status', 'Unknown'),
            'reason': released.get('reason', '')
        })
for r in sorted(releases, key=lambda x: x['releasePlan']):
    print(f\"{r['releasePlan']}: {r['name']} snapshot={r['snapshot']} status={r['status']} reason={r['reason']}\")
"
```

Report a table:
```
| Index App | Release Plan | Snapshot | Status |
|-----------|-------------|----------|--------|
```

**Expected when DONE:** All index applications with valid snapshots have production releases with status `Succeeded`.

### If not done — Execute (requires approval)

For each index app that needs a production release, find the application, release plan, and latest snapshot:

```bash
INDEX_APPS=$(oc get applications.appstudio.redhat.com -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify -o json 2>/dev/null \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
mm = '${MM_DASHED}'
apps = sorted([i['metadata']['name'] for i in data['items'] if 'index' in i['metadata']['name'] and mm in i['metadata']['name']])
for a in apps:
    print(a)
")
```

For each index app, generate a Release YAML:
```bash
mkdir -p "${REPORT_BASE}/manifest/prod"

for INDEX_APP in ${INDEX_APPS}; do
  LATEST_SNAPSHOT=$(oc get snapshots -n ${KONFLUX_NS} \
    --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
    --insecure-skip-tls-verify \
    -l "pac.test.appstudio.openshift.io/event-type=push,appstudio.openshift.io/application=${INDEX_APP}" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | awk '{print $NF}')

  if [ -z "${LATEST_SNAPSHOT}" ]; then
    echo "Skipping ${INDEX_APP}: no snapshot"
    continue
  fi

  INDEX_PROD_RP=$(oc get releaseplans -n ${KONFLUX_NS} \
    --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
    --insecure-skip-tls-verify -o json 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
app = '${INDEX_APP}'
for item in data['items']:
    if item['spec'].get('application') == app and 'prod' in item['metadata']['name']:
        print(item['metadata']['name'])
        break
")

  if [ -z "${INDEX_PROD_RP}" ]; then
    echo "Skipping ${INDEX_APP}: no prod release plan found"
    continue
  fi

  # Derive OCP version from app name for filename
  OCP_VERSION=$(echo "${INDEX_APP}" | sed "s/openshift-pipelines-index-//" | sed "s/-${MM_DASHED}//")

  cat > "${REPORT_BASE}/manifest/prod/release-${VERSION}-index-${OCP_VERSION}-prod.yaml" <<EOF
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  labels:
    appstudio.openshift.io/application: ${INDEX_APP}
  generateName: ${INDEX_PROD_RP}-
  namespace: ${KONFLUX_NS}
spec:
  releasePlan: ${INDEX_PROD_RP}
  snapshot: ${LATEST_SNAPSHOT}
EOF

  echo "Generated: ${REPORT_BASE}/manifest/prod/release-${VERSION}-index-${OCP_VERSION}-prod.yaml (${INDEX_APP} → ${INDEX_PROD_RP})"
done
```

Apply all index Release CRs (`oc create`, not `oc apply` — uses `generateName`):
```bash
RELEASE_NAMES=""
for f in ${REPORT_BASE}/manifest/prod/release-${VERSION}-index-*-prod.yaml; do
  RNAME=$(oc create -f "$f" \
    --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
    --insecure-skip-tls-verify \
    -o jsonpath='{.metadata.name}')
  echo "Created release: ${RNAME}"
  RELEASE_NAMES="${RELEASE_NAMES} ${RNAME}"
done
```

Wait for all index releases to complete:
```bash
for RNAME in ${RELEASE_NAMES}; do
  echo "Waiting for ${RNAME}..."
  oc wait release/${RNAME} -n ${KONFLUX_NS} \
    --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
    --insecure-skip-tls-verify \
    --for=condition=Released --timeout=300s 2>&1 || true
done
```

Check results:
```bash
for RNAME in ${RELEASE_NAMES}; do
  echo -n "${RNAME}: "
  oc get release ${RNAME} -n ${KONFLUX_NS} \
    --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
    --insecure-skip-tls-verify \
    -o jsonpath='Released={.status.conditions[?(@.type=="Released")].status} Reason={.status.conditions[?(@.type=="Released")].reason}'
  echo
done
```

If all `Released=True` → DONE. If any are still in progress, report which ones — the re-verify will catch them on the next run.

---

## Step 4.9: CDN production release

After the core production release succeeds (step 4.2), CLI binaries can be released to CDN. This step creates a Konflux Release CR targeting the CDN production release plan, using the snapshot from the succeeded core production release.

Stage release of the binaries requires manual product version configuration in stage CDN, so go directly to production release while keeping the `invisible` flag set to `true` in the product version YAML.

**Requires:** `KONFLUX_SERVER` and `KONFLUX_TOKEN`. If missing, SKIP this step.

### Verify

Check for existing CDN releases:
```bash
oc get releases -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify 2>&1 | grep -E "${MM_DASHED}.*(cdn-prod)"
```

If a CDN release exists, check its status (look for `Succeeded` vs `Failed`).

Get the snapshot from the succeeded core production release (step 4.2):
```bash
PROD_CORE_SNAPSHOT=$(oc get releases -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify -o json 2>/dev/null \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
mm = '${MM_DASHED}'
for item in data.get('items', []):
    rp = item.get('spec', {}).get('releasePlan', '')
    if mm in rp and 'core' in rp and 'prod' in rp and 'cdn' not in rp:
        conditions = item.get('status', {}).get('conditions', [])
        released = next((c for c in conditions if c.get('type') == 'Released'), {})
        if released.get('status') == 'True':
            print(item['spec']['snapshot'])
            break
")
echo "Core prod snapshot: ${PROD_CORE_SNAPSHOT}"
```

**Collect links:** Report the snapshot name and any existing CDN release status.

**Expected when DONE:** A CDN production release exists with status `Succeeded`.

### If not done — Execute (requires approval)

Write the Release YAML to `${REPORT_BASE}/manifest/prod/release-${VERSION}-cdn-prod.yaml`:
```bash
mkdir -p "${REPORT_BASE}/manifest/prod"

cat > "${REPORT_BASE}/manifest/prod/release-${VERSION}-cdn-prod.yaml" <<EOF
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  labels:
    appstudio.openshift.io/application: openshift-pipelines-core-${MM_DASHED}
  generateName: openshift-pipelines-${MM_DASHED}-core-cdn-prod-release-
  namespace: ${KONFLUX_NS}
spec:
  data:
  gracePeriodDays: 10
  releasePlan: openshift-pipelines-${MM_DASHED}-core-cdn-prod
  snapshot: ${PROD_CORE_SNAPSHOT}
EOF
```

Apply the Release CR (`oc create`, not `oc apply` — uses `generateName`):
```bash
RELEASE_NAME=$(oc create -f ${REPORT_BASE}/manifest/prod/release-${VERSION}-cdn-prod.yaml \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify \
  -o jsonpath='{.metadata.name}')
echo "Created release: ${RELEASE_NAME}"
```

Wait for the release to complete:
```bash
oc wait release/${RELEASE_NAME} -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify \
  --for=condition=Released --timeout=300s 2>&1 || true
```

Check result:
```bash
oc get release ${RELEASE_NAME} -n ${KONFLUX_NS} \
  --server="$KONFLUX_SERVER" --token="$KONFLUX_TOKEN" \
  --insecure-skip-tls-verify \
  -o jsonpath='Released={.status.conditions[?(@.type=="Released")].status} Reason={.status.conditions[?(@.type=="Released")].reason}'
```

If `Released=True` → DONE. If still in progress (condition not yet set or `Unknown`), report the release name and move on — the re-verify will catch it on the next run.

After the release succeeds, update the product version YAML to set `invisible: false`.

---

## Report Output

After processing all steps, write the stage report to `${REPORT_BASE}/release/report_${REPORT_TIMESTAMP}.md`.

**Report format:**

```markdown
# Production Release Stage Report — ${VERSION}

**Generated:** ${REPORT_TIMESTAMP}
**Release:** ${VERSION} (${MAJOR_MINOR})
**Branch:** ${RELEASE_BRANCH}

## Summary

| Step | Title | Status | Details | Links |
|------|-------|--------|---------|-------|
| 4.1 | Verify stage releases | {status} | {details} | {links} |
| 4.2 | Core production release | {status} | {details} | {links} |
| 4.3 | Production CSV update | {status} | {details} | {links} |
| 4.4 | Merge production CSV PR | {status} | {details} | {links} |
| 4.5 | Wait for bundle snapshot | {status} | {details} | {links} |
| 4.6 | Bundle production release | {status} | {details} | {links} |
| 4.7 | OLM catalog render + index snapshots | {status} | {details} | {links} |
| 4.8 | Index production releases | {status} | {details} | {links} |
| 4.9 | CDN production release | {status} | {details} | {links} |

## Release Manifests

All generated Release CR YAMLs:

| File | Application | Release Plan | Snapshot |
|------|-------------|-------------|----------|
| release-${VERSION}-core-prod.yaml | {app} | {rp} | {snapshot} |
| release-${VERSION}-bundle-prod.yaml | {app} | {rp} | {snapshot} |
| release-${VERSION}-index-{ocp}-prod.yaml | {app} | {rp} | {snapshot} |
| release-${VERSION}-cdn-prod.yaml | openshift-pipelines-core-${MM_DASHED} | openshift-pipelines-${MM_DASHED}-core-cdn-prod | {snapshot} |

## Step Details

### Step 4.1: Verify stage releases
- **Status:** {DONE | BLOCKER}
- **Stage releases:**

| Application | Release Plan | Snapshot | Status |
|-------------|-------------|----------|--------|
| {app} | {rp} | {snapshot} | {Succeeded/Failed} |

- **Core snapshot for production:** {snapshot_name}

### Step 4.2: Core production release
- **Status:** {DONE | ACTION NEEDED | SKIPPED}
- **Release:** {name} — {Succeeded/Failed/not found}
- **Release Plan:** {rp}
- **Snapshot:** {snapshot} (reused from stage)
- **Manifest:** release-${VERSION}-core-prod.yaml

### Step 4.3: Production CSV update
- **Status:** {DONE | ACTION NEEDED | SKIPPED}
- **Workflow:** [{workflow-name}]({url}) ({status}/{conclusion}, {timestamp})

### Step 4.4: Merge production CSV PR
- **Status:** {DONE | ACTION NEEDED | SKIPPED}
- **PR:** operator [#{number}]({url}) — {state}
- **Registry check:** {all production / staging refs found}

### Step 4.5: Wait for bundle snapshot
- **Status:** {DONE | ACTION NEEDED | SKIPPED}
- **Snapshot:** {name} (created {timestamp})
- **Bundle revision:** [{short}]({url})
- **Operator HEAD:** [{short}]({url})

### Step 4.6: Bundle production release
- **Status:** {DONE | ACTION NEEDED | SKIPPED}
- **Release:** {name} — {Succeeded/Failed/not found}
- **Release Plan:** {rp}
- **Snapshot:** {snapshot}
- **Manifest:** release-${VERSION}-bundle-prod.yaml

### Step 4.7: OLM catalog render + index snapshots
- **Status:** {DONE | ACTION NEEDED | SKIPPED}
- **Workflow:** [{workflow-name}]({url}) ({status}/{conclusion}, {timestamp})
- **Index snapshots:**

| Index App | Snapshot | Revision | Status | Created |
|-----------|----------|----------|--------|---------|
| {app} | {snapshot} | [{short}]({url}) | {CURRENT/STALE/NO SNAPSHOT} | {timestamp} |

### Step 4.8: Index production releases
- **Status:** {DONE | ACTION NEEDED | SKIPPED}
- **Releases:**

| Index App | Release Plan | Snapshot | Status |
|-----------|-------------|----------|--------|
| {app} | {rp} | {snapshot} | {Succeeded/Failed/not found} |

- **Manifests:** release-${VERSION}-index-*-prod.yaml

### Step 4.9: CDN production release
- **Status:** {DONE | ACTION NEEDED | SKIPPED}
- **Release:** {name} — {Succeeded/Failed/not found}
- **Release Plan:** openshift-pipelines-${MM_DASHED}-core-cdn-prod
- **Snapshot:** {snapshot} (from core prod release)
- **Manifest:** release-${VERSION}-cdn-prod.yaml

{...include details for each step checked...}

## Blocking Step

{If stopped early, show which step blocked and why. Omit if all steps DONE.}
```

**Column values:**

- **Status:** `DONE`, `ACTION NEEDED`, `SKIPPED`
- **Details:** one-line summary (e.g. `core Succeeded`, `bundle stale`, `7/7 index releases Succeeded`)
- **Links:** all links collected for that step:
  - GitHub PRs: `operator [#NUM](URL)`
  - Workflow runs: `[workflow-name](URL)`
  - Snapshot names (no URL — cluster resource)
  - Multiple links separated by `, `
  - No links: `—`

Write the report file and print the path to the user:
```
Report written to: reports/${MAJOR_MINOR}/${VERSION}/release/report_${REPORT_TIMESTAMP}.md
```
