#!/usr/bin/env bash
# =============================================================================
# setup.sh — one-time setup for DVC + Cloudflare R2 + Git remote routing
#
# Run this once inside your Git repository:
#   chmod +x setup.sh && ./setup.sh
#
# Prerequisites:
#   - Homebrew (system or user-local — both are detected automatically)
#   - A Cloudflare R2 bucket already created
#   - A Git remote already configured (git remote add origin ...)
# =============================================================================

set -euo pipefail

HOOK_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hooks/pre-commit"

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
fail() { echo -e "${RED}✘${NC} $*"; exit 1; }
ask()  { echo -e "\n${YELLOW}▶${NC} $*"; }

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   DVC + Cloudflare R2 + Git Setup        ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ---------------------------------------------------------------------------
# Locate Homebrew — checks system and user-local install locations
# ---------------------------------------------------------------------------
find_brew() {
  local candidates=(
    "/opt/homebrew/bin/brew"          # system Homebrew, Apple Silicon
    "/usr/local/bin/brew"             # system Homebrew, Intel
    "${HOME}/.homebrew/bin/brew"      # user-local Homebrew (common)
    "${HOME}/homebrew/bin/brew"       # user-local Homebrew (alternative)
    "${HOME}/.linuxbrew/bin/brew"     # Linuxbrew, just in case
  )

  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  # Last resort: whatever is in PATH
  if command -v brew &>/dev/null; then
    command -v brew
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# Locate DVC — checks all common Homebrew install locations before PATH
# ---------------------------------------------------------------------------
find_dvc() {
  local candidates=(
    "/opt/homebrew/bin/dvc"          # system Homebrew, Apple Silicon
    "/usr/local/bin/dvc"             # system Homebrew, Intel
    "${HOME}/.homebrew/bin/dvc"      # user-local Homebrew (common)
    "${HOME}/homebrew/bin/dvc"       # user-local Homebrew (alternative)
    "${HOME}/.linuxbrew/bin/dvc"     # Linuxbrew, just in case
  )

  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  # Last resort: whatever is in PATH (e.g. pip-installed, conda, etc.)
  if command -v dvc &>/dev/null; then
    command -v dvc
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# 1. Verify we're inside a Git repo
# ---------------------------------------------------------------------------
if ! git rev-parse --git-dir &>/dev/null; then
  fail "Not inside a Git repository. Run 'git init' first."
fi
ok "Git repository found."

# ---------------------------------------------------------------------------
# 2. Install DVC via Homebrew (+ dvc-s3 via pip for S3/R2 support)
# ---------------------------------------------------------------------------
echo ""
echo "── Installing DVC ──"

BREW=$(find_brew) || fail "Homebrew not found. Install from https://brew.sh"
ok "Found Homebrew at: $BREW"

if find_dvc &>/dev/null; then
  ok "DVC already installed at: $(find_dvc)"
else
  echo "   Installing dvc via Homebrew..."
  "$BREW" install dvc
  ok "DVC installed."
fi

DVC=$(find_dvc)

# dvc-s3 provides S3-compatible storage support (required for Cloudflare R2)
# It's a small pip package regardless of how DVC itself was installed
if ! "$DVC" remote list 2>/dev/null | grep -q . || ! python3 -c "import dvc_s3" 2>/dev/null; then
  echo "   Installing dvc-s3 (S3/R2 storage plugin)..."
  pip3 install --quiet dvc-s3 2>/dev/null || \
    pip3 install --quiet dvc-s3 --break-system-packages 2>/dev/null || \
    "$BREW" install python && pip3 install --quiet dvc-s3
fi
ok "dvc-s3 plugin ready."

# ---------------------------------------------------------------------------
# Keychain helpers (macOS security command)
# ---------------------------------------------------------------------------
KEYCHAIN_SERVICE="dvc-r2"

keychain_get() {
  local account="$1"
  security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$account" -w 2>/dev/null || true
}

keychain_set() {
  local account="$1"
  local value="$2"
  # Delete existing entry silently, then add fresh
  security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$account" &>/dev/null || true
  security add-generic-password -s "$KEYCHAIN_SERVICE" -a "$account" -w "$value"
}

# ---------------------------------------------------------------------------
# Detect repo name from Git remote URL
# ---------------------------------------------------------------------------
detect_repo_name() {
  local url
  url=$(git remote get-url origin 2>/dev/null) || true
  if [[ -n "$url" ]]; then
    # Strip trailing .git, then take the last path component
    echo "$url" | sed 's/\.git$//' | sed 's/.*\///'
  fi
}

# ---------------------------------------------------------------------------
# 3. Collect Cloudflare R2 credentials (Keychain-aware)
# ---------------------------------------------------------------------------
echo ""
echo "── Cloudflare R2 Configuration ──"

# Read whatever is already stored in Keychain
KC_BUCKET=$(keychain_get "r2-bucket")
KC_ACCOUNT_ID=$(keychain_get "r2-account-id")
KC_ACCESS_KEY_ID=$(keychain_get "r2-access-key-id")
KC_SECRET=$(keychain_get "r2-secret-key")

USE_KC="y"   # default; only matters if credentials are found in Keychain

if [[ -n "$KC_BUCKET" && -n "$KC_ACCOUNT_ID" && -n "$KC_ACCESS_KEY_ID" && -n "$KC_SECRET" ]]; then
  echo ""
  ok "Found R2 credentials in macOS Keychain:"
  echo "   Bucket:     $KC_BUCKET"
  echo "   Account ID: $KC_ACCOUNT_ID"
  echo "   Key ID:     $KC_ACCESS_KEY_ID"
  echo "   Secret:     ********"
  ask "Use these credentials? (Y/n)"
  read -r USE_KC
  if [[ ! "$USE_KC" =~ ^[Nn]$ ]]; then
    R2_BUCKET="$KC_BUCKET"
    R2_ACCOUNT_ID="$KC_ACCOUNT_ID"
    R2_ACCESS_KEY_ID="$KC_ACCESS_KEY_ID"
    R2_SECRET_ACCESS_KEY="$KC_SECRET"
    ok "Using credentials from Keychain."
  else
    KC_BUCKET=""   # fall through to prompt below
  fi
fi

if [[ -z "$KC_BUCKET" || "$USE_KC" =~ ^[Nn]$ ]]; then
  echo ""
  echo "Find these in your Cloudflare dashboard:"
  echo "  R2 → Manage R2 API Tokens → Create API Token"
  echo ""

  ask "R2 Bucket name:"
  read -r R2_BUCKET

  ask "R2 Account ID (from R2 overview page):"
  read -r R2_ACCOUNT_ID

  ask "R2 Access Key ID:"
  read -r R2_ACCESS_KEY_ID

  ask "R2 Secret Access Key:"
  read -rs R2_SECRET_ACCESS_KEY
  echo ""

  # Store all four in Keychain for future repos
  keychain_set "r2-bucket"       "$R2_BUCKET"
  keychain_set "r2-account-id"   "$R2_ACCOUNT_ID"
  keychain_set "r2-access-key-id" "$R2_ACCESS_KEY_ID"
  keychain_set "r2-secret-key"   "$R2_SECRET_ACCESS_KEY"
  ok "Credentials saved to macOS Keychain (won't be asked again)."
fi

R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

# ---------------------------------------------------------------------------
# 3b. Determine R2 folder — auto-detect from Git remote, ask to confirm
# ---------------------------------------------------------------------------
DETECTED_REPO=$(detect_repo_name)

echo ""
if [[ -n "$DETECTED_REPO" ]]; then
  ask "R2 folder name inside bucket (detected: '$DETECTED_REPO' — press Enter to confirm, or type a different name):"
  read -r R2_FOLDER
  R2_FOLDER="${R2_FOLDER:-$DETECTED_REPO}"
else
  ask "R2 folder name inside bucket (e.g. 'my-project', leave blank for bucket root):"
  read -r R2_FOLDER
fi

if [[ -n "$R2_FOLDER" ]]; then
  R2_PATH="s3://${R2_BUCKET}/${R2_FOLDER}"
else
  R2_PATH="s3://${R2_BUCKET}"
fi

# ---------------------------------------------------------------------------
# 4. Configure DVC remote
# ---------------------------------------------------------------------------
echo ""
echo "── Configuring DVC ──"

"$DVC" init --no-scm 2>/dev/null || "$DVC" init 2>/dev/null || true

"$DVC" remote add -f r2remote "$R2_PATH"
"$DVC" remote modify r2remote endpointurl "$R2_ENDPOINT"
"$DVC" remote modify r2remote access_key_id "$R2_ACCESS_KEY_ID"
"$DVC" remote modify --local r2remote secret_access_key "$R2_SECRET_ACCESS_KEY"
"$DVC" remote default r2remote

ok "DVC remote 'r2remote' configured → $R2_PATH"
warn "Secret key written to .dvc/config.local (git-ignored). Source of truth is macOS Keychain."

# ---------------------------------------------------------------------------
# 5. Configure size threshold
# ---------------------------------------------------------------------------
echo ""
ask "File size threshold in MB (files larger than this go to R2). Default: 5"
read -r SIZE_MB
SIZE_MB=${SIZE_MB:-5}
git config dvc-router.size-threshold-mb "$SIZE_MB"
ok "Size threshold set to ${SIZE_MB} MB."

# ---------------------------------------------------------------------------
# 6. Optional: enable verbose hook output
# ---------------------------------------------------------------------------
ask "Enable verbose hook output? (y/N)"
read -r VERBOSE_CHOICE
if [[ "$VERBOSE_CHOICE" =~ ^[Yy]$ ]]; then
  git config dvc-router.verbose true
  ok "Verbose mode enabled."
else
  git config dvc-router.verbose false
fi

# ---------------------------------------------------------------------------
# 7. Optional: install flux shell aliases
# ---------------------------------------------------------------------------
echo ""
echo "── Flux aliases (optional) ──"
echo "   flux-commit   git add . && git commit"
echo "   flux-push     git push && dvc push"
echo "   flux-pull     git pull && dvc pull"
echo "   flux-sync     git add . && git commit && git push && dvc push"
echo "   flux-status   git status + dvc status"
echo ""
ask "Install flux aliases into your shell profile? (y/N)"
read -r ALIAS_CHOICE

if [[ "$ALIAS_CHOICE" =~ ^[Yy]$ ]]; then
  # Detect shell profile file
  case "${SHELL##*/}" in
    zsh)  SHELL_PROFILE="${HOME}/.zshrc" ;;
    bash) SHELL_PROFILE="${HOME}/.bash_profile" ;;
    *)    SHELL_PROFILE="${HOME}/.profile" ;;
  esac

  ALIAS_BLOCK='
# flux — unified Git + DVC workflow aliases
alias flux-commit="git add . && git commit"
alias flux-push="git push && dvc push"
alias flux-pull="git pull && dvc pull"
alias flux-sync="git add . && git commit && git push && dvc push"
alias flux-status="git status && echo '"'"'--- DVC ---'"'"' && dvc status"'

  if grep -qF "flux-commit" "$SHELL_PROFILE" 2>/dev/null; then
    warn "Flux aliases already present in $SHELL_PROFILE — skipping."
  else
    echo "$ALIAS_BLOCK" >> "$SHELL_PROFILE"
    ok "Flux aliases added to $SHELL_PROFILE"
    warn "Run 'source $SHELL_PROFILE' or open a new terminal to activate them."
  fi
else
  ok "Skipped. Add aliases manually anytime — see README for the snippet."
fi

# ---------------------------------------------------------------------------
# 7. Install the pre-commit hook
# ---------------------------------------------------------------------------
echo ""
echo "── Installing pre-commit hook ──"

HOOKS_DIR="$(git rev-parse --git-dir)/hooks"
HOOK_DEST="${HOOKS_DIR}/pre-commit"

if [[ ! -f "$HOOK_SOURCE" ]]; then
  fail "hooks/pre-commit not found at: $HOOK_SOURCE"
fi

cp "$HOOK_SOURCE" "$HOOK_DEST"
chmod +x "$HOOK_DEST"
ok "pre-commit hook installed at: $HOOK_DEST"

# ---------------------------------------------------------------------------
# 8. Update .gitignore
# ---------------------------------------------------------------------------
echo ""
echo "── Updating .gitignore ──"

GITIGNORE=".gitignore"
touch "$GITIGNORE"

entries=(
  ".dvc/config.local"   # contains secrets
  ".dvc/tmp/"
  ".dvc/cache/"
)

for entry in "${entries[@]}"; do
  if ! grep -qF "$entry" "$GITIGNORE" 2>/dev/null; then
    echo "$entry" >> "$GITIGNORE"
    ok "Added to .gitignore: $entry"
  fi
done

# ---------------------------------------------------------------------------
# 9. Commit initial DVC config
# ---------------------------------------------------------------------------
echo ""
echo "── Committing DVC configuration ──"

git add .dvc/config .gitignore 2>/dev/null || true
if ! git diff --cached --quiet 2>/dev/null; then
  git commit -m "chore: initialise DVC with Cloudflare R2 remote" --no-verify
  ok "Initial DVC config committed."
else
  warn "Nothing new to commit (DVC may already have been configured)."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Setup complete! Your workflow is now:              ║"
echo "║                                                      ║"
echo "║   flux-commit -m 'your message'                      ║"
echo "║   flux-push               → GitLab/GitHub + R2       ║"
echo "║   flux-pull               ← GitLab/GitHub + R2       ║"
echo "║                                                      ║"
echo "║   (or: flux-sync -m 'msg' for all in one step)       ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "On the other machine, after cloning:"
echo "  git clone <your-remote-url>"
echo "  dvc pull          ← fetches large/binary files from R2"
echo ""
