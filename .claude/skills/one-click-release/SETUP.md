# Setup

Shared setup for the one-click-release skill.

**Input:** A version string argument matching `X.Y.Z` (e.g. `1.21.3`).

## Parse Version

Parse the version argument. It must match `X.Y.Z` (patch) or `X.Y.0` (minor).

Derive:
- `VERSION` — e.g. `1.21.3`
- `MAJOR_MINOR` — e.g. `1.21`
- `MM_DASHED` — e.g. `1-21`
- `RELEASE_BRANCH` — `release-v${MAJOR_MINOR}.x`
- `RELEASE_TAG` — `v${VERSION}`
- `IS_PATCH` — true if Z > 0
- `KONFLUX_NS` — always `tekton-ecosystem-tenant`

## Source Credentials

The executable reads `.env` as declarative data. It accepts only the credential and
identity variables listed below; it does not evaluate shell commands, expansions,
functions, approval variables, path changes, or release-target overrides. Quoted and
unquoted single-line values are supported.

Required variables and what they gate:

| Variable | Required For |
|----------|-------------|
| `GITHUB_TOKEN` or `gh auth` | All steps — GitHub API |
| `GITHUB_USER` + `GITHUB_EMAIL` | Git commit authorship for automated PRs (Step 1.9: OPC version.json) |
| `KONFLUX_SERVER` + `KONFLUX_TOKEN` | Steps that query Konflux cluster |
| `GITLAB_URL` + `GITLAB_TOKEN` | Steps that query GitLab (RPA, Pyxis) |
| `JIRA_URL` + `JIRA_EMAIL` + `JIRA_TOKEN` | Audit and Jira steps |

If a credential is missing, note which steps will be skipped.

If a GitHub workflow dispatch returns an ambiguous client error, the executable retains
`reports/{MAJOR_MINOR}/{VERSION}/.state/workflow-*.pending` and retries discovery without
redispatching. Only after GitHub confirms the request was rejected and no run exists
after the timestamp recorded in that file, obtain explicit approval and remove that
single pending file to permit a new dispatch. Do not clear it merely because a run is
slow to appear.

## Time Formatting

```bash
LOCAL_TZ=$(date +%Z)
TZ_FMT='%Y-%m-%d %H:%M %Z'
```

All timestamps in output MUST use absolute local time. Convert API timestamps:
```bash
date -d "${TIMESTAMP}" +"${TZ_FMT}"
```

Never use relative times ("3 min ago", "6d5h").

## Fetch Release Config

```bash
RELEASE_CFG=$(gh api repos/openshift-pipelines/hack/contents/config/downstream/releases/${MAJOR_MINOR}.yaml --jq '.content' | base64 -d)
```

Parse:
```bash
CURRENT_RELEASE_TAG=$(echo "$RELEASE_CFG" | grep 'release-tag:' | awk '{print $2}')
CODE_FREEZE=$(echo "$RELEASE_CFG" | grep 'code-freeze:' | awk '{print $2}')
```

If the release config doesn't exist, stop: "Release config for ${MAJOR_MINOR} not found in hack repo."

## Report Paths

Each stage writes its own report file under a version-scoped directory:

```bash
REPORT_BASE="reports/${MAJOR_MINOR}/${VERSION}"
REPORT_TIMESTAMP=$(date +'%Y-%m-%d_%H-%M-%S_%Z')
```

Stage report paths (created by each stage file):
- Config: `${REPORT_BASE}/config/report_${REPORT_TIMESTAMP}.md`
- Build: `${REPORT_BASE}/build/report_${REPORT_TIMESTAMP}.md`
- Image Copy: `${REPORT_BASE}/image-copy/report_${REPORT_TIMESTAMP}.md`
- Release: `${REPORT_BASE}/release/report_${REPORT_TIMESTAMP}.md`
- Manifests: `${REPORT_BASE}/manifest/stage/` and `${REPORT_BASE}/manifest/prod/`

Create the directories at setup time:
```bash
mkdir -p "${REPORT_BASE}/config" "${REPORT_BASE}/build" "${REPORT_BASE}/image-copy" "${REPORT_BASE}/release" "${REPORT_BASE}/manifest/stage" "${REPORT_BASE}/manifest/prod"
```

## Return

All variables above are available for use by the calling stage files.
