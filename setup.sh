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

HOOK_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pre-commit"
POST_MERGE_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/post-merge"
VERSION="0.0.1"

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
echo "   flux v${VERSION}"
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
if ! python3 -c "import dvc_s3" 2>/dev/null; then
  echo "   Installing dvc-s3 (S3/R2 storage plugin)..."
  pip3 install --quiet dvc-s3 2>/dev/null || \
    pip3 install --quiet dvc-s3 --break-system-packages 2>/dev/null || \
    "$BREW" install python && pip3 install --quiet dvc-s3
fi
ok "dvc-s3 plugin ready."

# ---------------------------------------------------------------------------
# Cross-platform secret store
#
# Priority for reads:  env vars  →  platform secret store  →  empty
# Priority for writes: platform secret store (skipped if none available)
#
# Supported stores:
#   macOS   — Keychain via `security`
#   Linux   — Secret Service via `secret-tool` (GNOME Keyring / KWallet)
#   Headless/CI — no persistent store; use FLUX_R2_* env vars instead
# ---------------------------------------------------------------------------
_SECRET_SERVICE="dvc-r2"

_detect_secret_store() {
  if [[ "$(uname)" == "Darwin" ]] && command -v security &>/dev/null; then
    echo "keychain"
  elif command -v secret-tool &>/dev/null; then
    echo "secret-tool"
  else
    echo "none"
  fi
}

SECRET_STORE=$(_detect_secret_store)

case "$SECRET_STORE" in
  keychain)    SECRET_STORE_LABEL="macOS Keychain" ;;
  secret-tool) SECRET_STORE_LABEL="Linux secret service" ;;
  *)           SECRET_STORE_LABEL="none" ;;
esac

secret_get() {
  local account="$1"
  case "$SECRET_STORE" in
    keychain)
      security find-generic-password -s "$_SECRET_SERVICE" -a "$account" -w 2>/dev/null || true
      ;;
    secret-tool)
      secret-tool lookup service "$_SECRET_SERVICE" account "$account" 2>/dev/null || true
      ;;
  esac
}

secret_set() {
  local account="$1" value="$2"
  case "$SECRET_STORE" in
    keychain)
      security delete-generic-password -s "$_SECRET_SERVICE" -a "$account" &>/dev/null || true
      security add-generic-password -s "$_SECRET_SERVICE" -a "$account" -w "$value"
      ;;
    secret-tool)
      printf '%s' "$value" | secret-tool store \
        --label="flux R2 ${account}" \
        service "$_SECRET_SERVICE" account "$account" 2>/dev/null || true
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Detect repo name from Git remote URL
# ---------------------------------------------------------------------------
detect_repo_name() {
  local url
  url=$(git remote get-url origin 2>/dev/null) || true
  if [[ -n "$url" ]]; then
    echo "$url" | sed 's/\.git$//' | sed 's/.*\///'
  fi
}

# ---------------------------------------------------------------------------
# 3. Collect Cloudflare R2 credentials
#
# Resolution order:
#   1. FLUX_R2_* environment variables  (CI / automation)
#   2. Platform secret store            (macOS Keychain, Linux secret service)
#   3. Interactive prompt               (first-time setup or headless fallback)
# ---------------------------------------------------------------------------
echo ""
echo "── Cloudflare R2 Configuration ──"

R2_BUCKET="" R2_ACCOUNT_ID="" R2_ACCESS_KEY_ID="" R2_SECRET_ACCESS_KEY=""

# 1. Environment variables (highest priority — no prompts, no storage needed)
if [[ -n "${FLUX_R2_BUCKET:-}"         && -n "${FLUX_R2_ACCOUNT_ID:-}" && \
      -n "${FLUX_R2_ACCESS_KEY_ID:-}"  && -n "${FLUX_R2_SECRET_KEY:-}" ]]; then
  R2_BUCKET="$FLUX_R2_BUCKET"
  R2_ACCOUNT_ID="$FLUX_R2_ACCOUNT_ID"
  R2_ACCESS_KEY_ID="$FLUX_R2_ACCESS_KEY_ID"
  R2_SECRET_ACCESS_KEY="$FLUX_R2_SECRET_KEY"
  ok "Using credentials from FLUX_R2_* environment variables."
else
  # 2. Platform secret store
  KC_BUCKET=$(secret_get "r2-bucket")
  KC_ACCOUNT_ID=$(secret_get "r2-account-id")
  KC_ACCESS_KEY_ID=$(secret_get "r2-access-key-id")
  KC_SECRET=$(secret_get "r2-secret-key")

  USE_STORED="y"

  if [[ -n "$KC_BUCKET" && -n "$KC_ACCOUNT_ID" && -n "$KC_ACCESS_KEY_ID" && -n "$KC_SECRET" ]]; then
    echo ""
    ok "Found R2 credentials in ${SECRET_STORE_LABEL}:"
    echo "   Bucket:     $KC_BUCKET"
    echo "   Account ID: $KC_ACCOUNT_ID"
    echo "   Key ID:     $KC_ACCESS_KEY_ID"
    echo "   Secret:     ********"
    ask "Use these credentials? (Y/n)"
    read -r USE_STORED
    if [[ ! "$USE_STORED" =~ ^[Nn]$ ]]; then
      R2_BUCKET="$KC_BUCKET"
      R2_ACCOUNT_ID="$KC_ACCOUNT_ID"
      R2_ACCESS_KEY_ID="$KC_ACCESS_KEY_ID"
      R2_SECRET_ACCESS_KEY="$KC_SECRET"
      ok "Using stored credentials."
    fi
  fi

  # 3. Interactive prompt (first run, or user declined stored credentials)
  if [[ -z "$R2_BUCKET" ]]; then
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

    if [[ "$SECRET_STORE" != "none" ]]; then
      secret_set "r2-bucket"        "$R2_BUCKET"
      secret_set "r2-account-id"    "$R2_ACCOUNT_ID"
      secret_set "r2-access-key-id" "$R2_ACCESS_KEY_ID"
      secret_set "r2-secret-key"    "$R2_SECRET_ACCESS_KEY"
      ok "Credentials saved to ${SECRET_STORE_LABEL} (won't be asked again)."
    else
      warn "No secret store available on this system — credentials not saved."
      echo "   To avoid prompts on future repos, set these environment variables:"
      echo "     export FLUX_R2_BUCKET='${R2_BUCKET}'"
      echo "     export FLUX_R2_ACCOUNT_ID='${R2_ACCOUNT_ID}'"
      echo "     export FLUX_R2_ACCESS_KEY_ID='${R2_ACCESS_KEY_ID}'"
      echo "     export FLUX_R2_SECRET_KEY='<your-secret>'"
    fi
  fi
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
warn "Secret key written to .dvc/config.local (git-ignored). Source of truth is ${SECRET_STORE_LABEL}."

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
echo "   flux-doctor   diagnose the flux setup in the current repo"
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
# flux — unified Git + DVC workflow
# Functions (not aliases) so they can check for a flux setup gracefully.
_flux_check() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "flux: not inside a Git repository."; return 1
  }
  if [[ ! -d "${root}/.dvc" ]]; then
    echo "flux: no flux setup in this repo."
    echo "      Run ./setup.sh from the repo root to initialise."
    return 1
  fi
}
flux-commit() { _flux_check || return 1; git add . && git commit "$@"; }
flux-push()   { _flux_check || return 1; git push && dvc push; }
flux-pull()   { _flux_check || return 1; git pull && dvc pull; }
flux-sync()   { _flux_check || return 1; git add . && git commit "$@" && git push && dvc push; }
flux-status() { _flux_check || return 1; git status && echo "--- DVC ---" && dvc status; }
flux-doctor() {
  local root ok_count=0 fail_count=0
  local GREEN='"'"'\033[0;32m'"'"' RED='"'"'\033[0;31m'"'"' YELLOW='"'"'\033[1;33m'"'"' NC='"'"'\033[0m'"'"'
  _fd_ok()   { echo -e "${GREEN}✔${NC} $*"; (( ok_count++   || true )); }
  _fd_fail() { echo -e "${RED}✘${NC}  $*"; (( fail_count++ || true )); }
  _fd_warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
  echo ""
  echo "── flux doctor ──"
  echo ""
  root=$(git rev-parse --show-toplevel 2>/dev/null) || { _fd_fail "Not inside a git repository"; return 1; }
  _fd_ok "Git repository: $root"
  [[ -d "${root}/.dvc" ]] && _fd_ok ".dvc/ directory found" || _fd_fail ".dvc/ not found — run setup.sh"
  local dvc_bin
  for _p in /opt/homebrew/bin/dvc /usr/local/bin/dvc \
            "${HOME}/.homebrew/bin/dvc" "${HOME}/homebrew/bin/dvc" \
            "${HOME}/.linuxbrew/bin/dvc"; do
    [[ -x "$_p" ]] && { dvc_bin="$_p"; break; }
  done
  [[ -z "${dvc_bin:-}" ]] && dvc_bin=$(command -v dvc 2>/dev/null || true)
  if [[ -n "${dvc_bin:-}" ]]; then
    _fd_ok "DVC: $dvc_bin ($("$dvc_bin" version 2>/dev/null | head -1 || echo "version unknown"))"
  else
    _fd_fail "DVC not found — brew install dvc"
  fi
  python3 -c "import dvc_s3" 2>/dev/null \
    && _fd_ok "dvc-s3 plugin available" \
    || _fd_fail "dvc-s3 not found — pip install dvc-s3"
  [[ -x "${root}/.git/hooks/pre-commit" ]]  && _fd_ok "pre-commit hook installed"  || _fd_fail "pre-commit hook missing — run setup.sh"
  [[ -x "${root}/.git/hooks/post-merge" ]]  && _fd_ok "post-merge hook installed"  || _fd_fail "post-merge hook missing — run setup.sh"
  if [[ -n "${dvc_bin:-}" ]]; then
    local remote
    remote=$("$dvc_bin" remote list 2>/dev/null | head -1 || true)
    [[ -n "$remote" ]] && _fd_ok "DVC remote: $remote" || _fd_fail "No DVC remote — run setup.sh"
  fi
  if [[ "$(uname)" == "Darwin" ]] && command -v security &>/dev/null; then
    _fd_ok "Secret store: macOS Keychain"
  elif command -v secret-tool &>/dev/null; then
    _fd_ok "Secret store: Linux secret service (secret-tool)"
  else
    _fd_warn "No persistent secret store — set FLUX_R2_* env vars to skip prompts on each new repo"
  fi
  local ver
  ver=$(grep '"'"'^VERSION='"'"' "${root}/setup.sh" 2>/dev/null | head -1 | cut -d'"'"'"'"'"' -f2 || true)
  [[ -n "$ver" ]] && _fd_ok "flux version: $ver" || _fd_warn "VERSION not found in setup.sh"
  echo ""
  echo "────────────────────────────────"
  if (( fail_count == 0 )); then
    echo -e "${GREEN}All checks passed.${NC}"
  else
    echo -e "${RED}${fail_count} check(s) failed.${NC}"
    return 1
  fi
}'

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
# 8. Install git hooks (pre-commit and post-merge)
# ---------------------------------------------------------------------------
echo ""
echo "── Installing git hooks ──"

HOOKS_DIR="$(git rev-parse --git-dir)/hooks"

if [[ ! -f "$HOOK_SOURCE" ]]; then
  fail "pre-commit not found at: $HOOK_SOURCE"
fi
cp "$HOOK_SOURCE" "${HOOKS_DIR}/pre-commit"
chmod +x "${HOOKS_DIR}/pre-commit"
ok "pre-commit hook installed."

if [[ ! -f "$POST_MERGE_SOURCE" ]]; then
  fail "post-merge not found at: $POST_MERGE_SOURCE"
fi
cp "$POST_MERGE_SOURCE" "${HOOKS_DIR}/post-merge"
chmod +x "${HOOKS_DIR}/post-merge"
ok "post-merge hook installed."

# ---------------------------------------------------------------------------
# 9. Update .gitignore
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
# 10. Commit initial DVC config
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
