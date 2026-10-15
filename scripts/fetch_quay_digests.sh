#!/bin/bash

# ── Colors & styles ────────────────────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
WHITE='\033[0;37m'

# ── Helpers ────────────────────────────────────────────────────────────────────
info()    { echo -e "  ${CYAN}ℹ${RESET}  $*"; }
success() { echo -e "  ${GREEN}✔${RESET}  $*"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
error()   { echo -e "  ${RED}✖${RESET}  $*"; }
step()    { echo -e "\n${BOLD}${BLUE}▸${RESET} ${BOLD}$*${RESET}"; }
divider() { echo -e "${DIM}  ──────────────────────────────────────────────────────${RESET}"; }
header()  {
  echo
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${CYAN}║${RESET}  ${BOLD}$*${RESET}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${RESET}"
}

# ── Config ─────────────────────────────────────────────────────────────────────
NAMESPACE="openshift-pipeline"
PREFIX="pipelines-index-"
TAG="v1.22.1"

header "Quay Digest Fetcher"
echo -e "  ${DIM}namespace:${RESET} ${WHITE}${NAMESPACE}${RESET}"
echo -e "  ${DIM}prefix:   ${RESET} ${WHITE}${PREFIX}${RESET}"
echo -e "  ${DIM}tag:      ${RESET} ${WHITE}${TAG}${RESET}"

# ── Function to fetch digest for a single repo (called in parallel) ─────────────
fetch_digest() {
  local namespace="$1"
  local repo_name="$2"
  local tag="$3"

  DIGEST=$(curl -s "https://quay.io/api/v1/repository/${namespace}/${repo_name}/tag/?specificTag=${tag}" \
    | jq -r '.tags[0].manifest_digest // empty')

  if [ -n "$DIGEST" ]; then
    printf "    \033[0;32m%-60s\033[0m\n" "quay.io/${namespace}/${repo_name}:${tag}@${DIGEST}"
    printf "    \033[2m%-60s\033[0m\n"    "quay.io/${namespace}/${repo_name}:${tag}"
    echo
  fi
}
export -f fetch_digest

# ── Step 1: Discover repositories ─────────────────────────────────────────────
step "Discovering repositories matching '${PREFIX}*'"

RAW_REPOS=""
NEXT_PAGE=""
PAGE=1

while :; do
  if [ -z "$NEXT_PAGE" ]; then
    URL="https://quay.io/api/v1/repository?public=true&namespace=${NAMESPACE}"
  else
    URL="https://quay.io/api/v1/repository?public=true&namespace=${NAMESPACE}&next_page=${NEXT_PAGE}"
  fi

  info "Fetching page ${PAGE}..."
  RESPONSE=$(curl -s "$URL")
  PAGE_REPOS=$(echo "$RESPONSE" | jq -r '.repositories[].name' | grep "^${PREFIX}")

  if [ -n "$PAGE_REPOS" ]; then
    COUNT=$(echo "$PAGE_REPOS" | wc -l | tr -d ' ')
    success "Found ${COUNT} matching repo(s) on page ${PAGE}"
    RAW_REPOS="${RAW_REPOS}${PAGE_REPOS}"$'\n'
  fi

  NEXT_PAGE=$(echo "$RESPONSE" | jq -r '.next_page // empty')
  if [ -z "$NEXT_PAGE" ]; then
    break
  fi
  PAGE=$((PAGE + 1))
done

# ── Step 2: Sort ───────────────────────────────────────────────────────────────
SORTED_REPOS=$(echo -n "$RAW_REPOS" | sort -V)

if [ -z "$SORTED_REPOS" ]; then
  warn "No repositories found matching prefix '${PREFIX}'."
  exit 0
fi

TOTAL=$(echo "$SORTED_REPOS" | grep -c .)
success "Total repositories found: ${BOLD}${TOTAL}${RESET}"

# ── Step 3: Fetch digests in parallel ─────────────────────────────────────────
step "Fetching digests for tag '${YELLOW}${TAG}${RESET}'"
divider

echo "$SORTED_REPOS" | xargs -P 10 -I {} bash -c "fetch_digest '$NAMESPACE' '{}' '$TAG'"

divider
echo -e "\n  ${GREEN}${BOLD}Done.${RESET} Fetched digests for ${TOTAL} repositories.\n"
