#!/bin/bash

NAMESPACE="openshift-pipeline"
PREFIX="pipelines-index-"
TAG="v1.22.1"

# Function to fetch digest for a single repo (called in parallel)
fetch_digest() {
  local namespace="$1"
  local repo_name="$2"
  local tag="$3"

  DIGEST=$(curl -s "https://quay.io/api/v1/repository/${namespace}/${repo_name}/tag/?specificTag=${tag}" | jq -r '.tags[0].manifest_digest // empty')

  if [ -n "$DIGEST" ]; then
    echo "quay.io/${namespace}/${repo_name}:${tag}@${DIGEST}"
    echo "quay.io/${namespace}/${repo_name}:${tag}"
    echo
  fi
}
export -f fetch_digest

echo "Discovering all repositories starting with '${PREFIX}'..."

RAW_REPOS=""
NEXT_PAGE=""

# 1. Handle Pagination to gather all repositories
while :; do
  if [ -z "$NEXT_PAGE" ]; then
    URL="https://quay.io/api/v1/repository?public=true&namespace=${NAMESPACE}"
  else
    URL="https://quay.io/api/v1/repository?public=true&namespace=${NAMESPACE}&next_page=${NEXT_PAGE}"
  fi

  RESPONSE=$(curl -s "$URL")
  PAGE_REPOS=$(echo "$RESPONSE" | jq -r '.repositories[].name' | grep "^${PREFIX}")

  if [ -n "$PAGE_REPOS" ]; then
    RAW_REPOS="${RAW_REPOS}${PAGE_REPOS}"$'\n'
  fi

  NEXT_PAGE=$(echo "$RESPONSE" | jq -r '.next_page // empty')
  if [ -z "$NEXT_PAGE" ]; then
    break
  fi
done

# 2. Sort the complete list of repositories alphabetically
SORTED_REPOS=$(echo -n "$RAW_REPOS" | sort -V)

if [ -z "$SORTED_REPOS" ]; then
  echo "No repositories found matching prefix '${PREFIX}'."
  exit 0
fi

echo "Fetching digests for tag '${TAG}' in sorted order..."
echo "-----------------------------------------------------------------------"

# 3. Process the sorted list in parallel (up to 10 simultaneous API calls)
echo "$SORTED_REPOS" | xargs -I {} bash -c "fetch_digest '$NAMESPACE' '{}' '$TAG'"

echo "-----------------------------------------------------------------------"
echo "Done."
