#!/usr/bin/env bash
set -e

BASE_BRANCH="release-v1.21.x"
#BASE_BRANCH="main"
ORG="openshift-pipelines"
SEARCH_LABEL="automated"
LABELS_TO_ADD="lgtm,approved,release-pipeline"

# 1. Search for PRs and save to JSON
gh search prs --owner "$ORG" \
  --base "$BASE_BRANCH" \
  --label "$SEARCH_LABEL" \
  --state open \
  --json repository,url >pr_list.json

PR_JSON=$(cat pr_list.json)
echo "Extracting PRs from JSON..."

# 2. Extract REPO_NAME (needed for checking labels) and URL (used for all PR actions)
echo "$PR_JSON" | jq -r '.[] | "\(.repository.nameWithOwner) \(.url)"' >extracted_prs.txt

declare -a FAILING_PRS=()
declare -a SUCCESS_PRS=()
declare -a PENDING_PRS=() # Now we only need to store the URL!

while read -r REPO_NAME URL; do
  echo "------------------------------------------------"
  echo "🚀 Processing PR: $URL"

  PR_DATA=$(gh pr view "$URL" --json mergeable,mergeStateStatus)
  MERGEABLE=$(echo "$PR_DATA" | jq -r '.mergeable')
  MERGE_STATE=$(echo "$PR_DATA" | jq -r '.mergeStateStatus')

  echo "MERGE_STATE: $MERGE_STATE"

  # --- SCENARIO 1: MERGE CONFLICTS ---
  if [[ "$MERGEABLE" == "CONFLICTING" || "$MERGE_STATE" == "DIRTY" ]]; then
    echo "⚠️ SKIP: PR has merge conflicts."
    FAILING_PRS+=("$URL")
    continue
  fi

  # --- SCENARIO 2: REBASE / OUT-OF-DATE ISSUE ---
  if [[ "$MERGE_STATE" == "BEHIND" ]]; then
    echo "⚠️ PR is behind the base branch."
    echo "Attempting to update branch..."
    if ! gh pr update-branch "$URL" --rebase; then
      echo "❌ SKIP: Failed to REBASE branch automatically."
      FAILING_PRS+=("$URL")
      continue
    fi
    PENDING_PRS+=("$URL")
    continue
  fi

  # --- SCENARIO 3: CHECK AND CREATE MISSING LABELS ---
  echo "🔍 Verifying repository labels..."
  IFS=',' read -ra LABEL_ARRAY <<<"$LABELS_TO_ADD"
  for LABEL in "${LABEL_ARRAY[@]}"; do
    LABEL=$(echo "$LABEL" | xargs)
    LABEL_EXISTS=$(gh label list --repo "$REPO_NAME" --search "$LABEL" --json name -q ".[] | select(.name == \"$LABEL\") | .name")

    if [[ -z "$LABEL_EXISTS" ]]; then
      echo "   ➡️ Label '$LABEL' is missing. Creating it..."
      gh label create "$LABEL" --repo "$REPO_NAME" --color "0E8A16" --description "Auto-created by pipeline"
    else
      echo "   ✅ Label '$LABEL' verified."
    fi
  done

  echo "🏷️ Applying labels ($LABELS_TO_ADD)..."
  gh pr edit "$URL" --add-label "$LABELS_TO_ADD"

  # --- SCENARIO 4: WORKFLOWS FAILING/PENDING ---
  echo "⏳ Checking workflows..."
  CHECKS_JSON=$(gh pr checks "$URL" --json name,bucket,link 2>&1 | grep -v "no checks reported" || true)

  if [[ -n "$CHECKS_JSON" ]]; then
    FAILING_COUNT=$(echo "$CHECKS_JSON" | jq '[.[] | select(.bucket == "fail")] | length')
    if [[ "$FAILING_COUNT" -gt 0 ]]; then
      echo "❌ SKIP: PR already has $FAILING_COUNT failing workflow(s)."
      gh pr comment "$URL" --body "/retest"
      FAILING_PRS+=("$URL")
      continue
    fi

    PENDING_COUNT=$(echo "$CHECKS_JSON" | jq '[.[] | select(.bucket == "pending")] | length')
    if [[ "$PENDING_COUNT" -gt 0 ]]; then
      echo "⏳ SKIP: PR has $PENDING_COUNT pending workflow(s)."
      echo "   📜 Live logs for pending checks:"
      echo "$CHECKS_JSON" | jq -r '.[] | select(.bucket == "pending") | "      - \(.name): \(.link)"'

      PENDING_PRS+=("$URL") # Add just the URL to the array
      continue
    fi
  fi

  # --- SCENARIO 5: Merge PRs ---
  echo "🚢 Merging PR..."
  gh pr review --approve "$URL"
  gh pr merge "$URL" -d -r --auto || true #FIXME  Handle the scneario when merging fails
  SUCCESS_PRS+=("$URL")

done <extracted_prs.txt

# ==============================================================================
# --- SCENARIO 6: RETRY LOOP FOR PENDING PRs ---
# ==============================================================================

MAX_WAIT_MINUTES=60
CURRENT_WAIT=0
if [[ ${#PENDING_PRS[@]} -gt 0 ]]; then
  echo ""
  echo "================================================"
  echo "🔄 Entering Retry Loop for Pending PRs..."
  echo "================================================"
fi

while [[ ${#PENDING_PRS[@]} -gt 0 ]]; do
  if [[ "$CURRENT_WAIT" -ge "$MAX_WAIT_MINUTES" ]]; then
    echo "⏰ TIMEOUT REACHED: Waited for $MAX_WAIT_MINUTES minutes."
    echo "Exiting loop. Remaining PRs will be logged as pending."
    break
  fi

  declare -a STILL_PENDING=()

  for URL in "${PENDING_PRS[@]}"; do
    echo "------------------------------------------------"
    echo "🔍 Re-checking PR: $URL"

    CHECKS_JSON=$(gh pr checks "$URL" --json name,bucket,link 2>&1 | grep -v "no checks reported" || true)

    if [[ -n "$CHECKS_JSON" ]]; then
      FAILING_COUNT=$(echo "$CHECKS_JSON" | jq '[.[] | select(.bucket == "fail")] | length')
      if [[ "$FAILING_COUNT" -gt 0 ]]; then
        echo "❌ UPDATE: PR now has failing workflows."
        FAILING_PRS+=("$URL")
        continue
      fi

      PENDING_COUNT=$(echo "$CHECKS_JSON" | jq '[.[] | select(.bucket == "pending")] | length')
      if [[ "$PENDING_COUNT" -gt 0 ]]; then
        echo "⏳ STILL PENDING: PR has $PENDING_COUNT workflows running."
        STILL_PENDING+=("$URL")
        continue
      fi
    fi

    # If it makes it past the checks without triggering 'fail' or 'pending', it's ready!
    echo "🚢 Checks complete! Merging PR..."
    gh pr merge "$URL" -d -r --auto
    SUCCESS_PRS+=("$URL")

  done

  # Overwrite the pending list with ONLY the ones that are still pending
  PENDING_PRS=("${STILL_PENDING[@]}")
  if [[ ${#PENDING_PRS[@]} -gt 0 ]]; then
    echo "💤 Waiting 60 seconds before re-evaluating ${#PENDING_PRS[@]} pending PR(s)... (Minute $((CURRENT_WAIT + 1))/$MAX_WAIT_MINUTES)"
    sleep 60
    CURRENT_WAIT=$((CURRENT_WAIT + 1))
  fi

done

# ==============================================================================
# --- FINAL SUMMARY ---
# ==============================================================================

echo ""
echo "================================================"
echo "✅ Pipeline Complete!"
echo "================================================"
echo "✅ Successful PRs: ${SUCCESS_PRS[*]}"
echo "❌ Failed PRs:     ${FAILING_PRS[*]}"
if [[ ${#PENDING_PRS[@]} -gt 0 ]]; then
  echo "⏳ Pending PRs:    ${PENDING_PRS[*]}"
fi
