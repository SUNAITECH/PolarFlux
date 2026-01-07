#!/bin/zsh

# PolarFlux One-Click Release Tool
# This script triggers a GitHub Action release by pushing a version tag.

set -e

# --- UI Colors ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo "${BLUE}==>${NC} ${BOLD}$1${NC}"; }
success() { echo "${GREEN}✔${NC} ${BOLD}$1${NC}"; }
warn() { echo "${YELLOW}⚠${NC} ${BOLD}$1${NC}"; }
error() { echo "${RED}✘${NC} ${BOLD}$1${NC}"; exit 1; }

# --- Header ---
echo -e "${BOLD}PolarFlux Release Orchestrator${NC}"
echo "-------------------------------"

# 1. Environment Check
log "Checking git status..."
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    error "Not a git repository."
fi

if [[ -n $(git status --porcelain) ]]; then
    warn "You have uncommitted changes. It's recommended to commit them before releasing."
    read -q "REPLY?Continue anyway? (y/N) "
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# 2. Get Version Input
# Suggest a version based on today's date (CalVer)
DEFAULT_VERSION=$(date +%Y.%m.%d)
echo -n -e "${BOLD}Enter version number (default: $DEFAULT_VERSION): ${NC}"
read VERSION
VERSION=${VERSION:-$DEFAULT_VERSION}

# Simple validation: expect YYYY.MM.DD or X.Y.Z
if [[ ! $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    error "Invalid version format. Use CalVer (YYYY.MM.DD) or SemVer (X.Y.Z)."
fi

TAG="v$VERSION"

# 3. Conflict Check
log "Checking for tag conflicts..."
if git rev-parse "$TAG" >/dev/null 2>&1; then
    error "Tag $TAG already exists locally."
fi

if git ls-remote --tags origin | grep -q "refs/tags/$TAG"; then
    error "Tag $TAG already exists on remote 'origin'."
fi

# 4. Confirmation
echo -e "\n${BOLD}Release Summary:${NC}"
echo "  Version: ${GREEN}$VERSION${NC}"
echo "  Git Tag: ${GREEN}$TAG${NC}"
echo "  Target:  ${BLUE}origin/main${NC}"
echo -e "\nThis will push a tag to GitHub, which triggers the automated Build & Release workflow."
read -q "REPLY?Are you sure you want to proceed? (y/N) "
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Release cancelled."
    exit 0
fi

# 5. Execution
log "Creating local tag $TAG..."
git tag -a "$TAG" -m "Release $TAG"

log "Pushing tag to origin..."
if git push origin "$TAG"; then
    echo
    success "Successfully triggered release for $TAG!"
    log "You can monitor the progress at:"
    REPO_URL=$(git config --get remote.origin.url | sed 's/\.git$//' | sed 's/git@github.com:/https:\/\/github.com\//')
    echo -e "${BLUE}$REPO_URL/actions${NC}"
else
    git tag -d "$TAG"
    error "Failed to push tag. Local tag has been deleted."
fi
