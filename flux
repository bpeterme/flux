#!/usr/bin/env bash
# flux — Git + DVC auto-router for Cloudflare R2
# Requires macOS — credentials are stored in macOS Keychain.
# Install via Homebrew:
#   brew tap bpeterme/flux && brew install bpeterme/flux/flux

set -euo pipefail

VERSION="dev"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
fail() { echo -e "${RED}✘${NC} $*"; exit 1; }

FLUX_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/flux/flux.env"

# ---------------------------------------------------------------------------
# macOS guard
# ---------------------------------------------------------------------------

_flux_require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || fail "flux requires macOS."
}

# ---------------------------------------------------------------------------
# Keychain helpers
# ---------------------------------------------------------------------------

_kc_get() {
  security find-generic-password -a "${USER:-$(id -un)}" -s "flux.$1" -w 2>/dev/null || true
}

_kc_set() {
  security add-generic-password -U -a "${USER:-$(id -un)}" -s "flux.$1" -w "$2" \
    -l "flux: $1" 2>/dev/null \
    || fail "Failed to write 'flux.$1' to Keychain."
}

_kc_del() {
  security delete-generic-password -a "${USER:-$(id -un)}" -s "flux.$1" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Write non-sensitive global config to flux.env
# ---------------------------------------------------------------------------

_flux_write_config() {
  local bucket="$1" account_id="$2" threshold="$3" verbose="$4"
  mkdir -p "$(dirname "$FLUX_CONFIG")"
  cat > "$FLUX_CONFIG" << EOF
# flux configuration — managed by 'flux config'.

# ── cloudflare R2 ─────────────────────────────────────────────────────────────
FLUX_R2_BUCKET="${bucket}"
FLUX_R2_ACCOUNT_ID="${account_id}"

# ── routing ───────────────────────────────────────────────────────────────────
FLUX_SIZE_THRESHOLD_MB=${threshold}
FLUX_VERBOSE=${verbose}
EOF
  chmod 600 "$FLUX_CONFIG"
}

# ---------------------------------------------------------------------------
# Prompt for a value, showing current as default. Sets global FLUX_VALUE.
# secret=true → hidden input, shows "****" hint.
# ---------------------------------------------------------------------------

_flux_prompt_value() {
  local label="$1" current="${2:-}" secret="${3:-false}"
  local hint value

  if [[ -n "$current" ]]; then
    [[ "$secret" == "true" ]] \
      && hint=" [current: ****]" \
      || hint=" [current: $current]"
  else
    hint=""
  fi

  if [[ "$secret" == "true" ]]; then
    read -rsp "  ${label}${hint}: " value || true; echo
  else
    read -rp  "  ${label}${hint}: " value || true
  fi

  [[ -z "$value" ]] && value="$current"
  FLUX_VALUE="$value"
}

# ---------------------------------------------------------------------------
# Return 0 if flux is fully configured, 1 otherwise.
# Sources flux.env into the current shell as a side effect on success,
# making FLUX_R2_BUCKET etc. available to the caller.
# ---------------------------------------------------------------------------

_flux_is_configured() {
  [[ -f "$FLUX_CONFIG" ]] || return 1
  # shellcheck source=/dev/null
  source "$FLUX_CONFIG" 2>/dev/null || return 1
  [[ -n "${FLUX_R2_BUCKET:-}" && -n "${FLUX_R2_ACCOUNT_ID:-}" ]] || return 1
  [[ -n "$(_kc_get 'r2.access-key-id')" ]] || return 1
  [[ -n "$(_kc_get 'r2.secret-key')" ]]    || return 1
}

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------

_flux_help() {
  cat <<'EOF'
flux - Git + DVC auto-router for Cloudflare R2

Usage:
  flux                  Sync both ways (pull then push)
  flux add              Opt current project into sync
  flux remove           Stop syncing current project
  flux pull             Download the latest (git pull + dvc pull)

Maintenance:
  flux config           Configure flux (set up or manage global settings)
  flux doctor           Run environment diagnostics
  flux version          Show version

Help:
  flux help
  flux --help
  flux -h

Companion tools:
  cbox                  claudebox — Claude Code container runtime
  cdot                  claudedot — Config + history sync across machines
EOF
}

# ---------------------------------------------------------------------------
# config — smart: set up if unconfigured, show + manage if configured
# ---------------------------------------------------------------------------

_flux_config() {
  _flux_require_macos

  # Always pre-load whatever partial config exists before deciding which branch.
  local bucket="" account_id="" threshold="5" verbose="false"
  if [[ -f "$FLUX_CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$FLUX_CONFIG" 2>/dev/null || true
    bucket="${FLUX_R2_BUCKET:-}"
    account_id="${FLUX_R2_ACCOUNT_ID:-}"
    threshold="${FLUX_SIZE_THRESHOLD_MB:-5}"
    verbose="${FLUX_VERBOSE:-false}"
  fi
  local access_key_id secret_key
  access_key_id=$(_kc_get "r2.access-key-id")
  secret_key=$(_kc_get "r2.secret-key")

  local configured=false
  [[ -n "$bucket" && -n "$account_id" && -n "$access_key_id" && -n "$secret_key" ]] \
    && configured=true

  if [[ "$configured" == "false" ]]; then

    # ── not configured: guide through full setup ─────────────────────────────
    echo ""
    echo "  flux is not configured. Let's set it up:"
    echo ""

    _flux_prompt_value "R2 Bucket"         "$bucket"        false; bucket="$FLUX_VALUE"
    _flux_prompt_value "Account ID"        "$account_id"    false; account_id="$FLUX_VALUE"
    _flux_prompt_value "Access Key ID"     "$access_key_id" false; access_key_id="$FLUX_VALUE"
    _flux_prompt_value "Secret Key"        "$secret_key"    true;  secret_key="$FLUX_VALUE"
    _flux_prompt_value "Size threshold MB" "$threshold"     false; threshold="$FLUX_VALUE"
    _flux_prompt_value "Verbose"           "$verbose"       false; verbose="$FLUX_VALUE"

    echo ""
    [[ -n "$bucket" ]]        || fail "R2 bucket is required."
    [[ -n "$account_id" ]]    || fail "R2 account ID is required."
    [[ -n "$access_key_id" ]] || fail "R2 access key ID is required."
    [[ -n "$secret_key" ]]    || fail "R2 secret key is required."

    _flux_write_config "$bucket" "$account_id" "$threshold" "$verbose"
    ok "Config saved: $FLUX_CONFIG"

    _kc_set "r2.access-key-id" "$access_key_id"
    _kc_set "r2.secret-key"    "$secret_key"
    ok "Credentials stored in macOS Keychain."
    echo ""

  else

    # ── configured: show current settings and offer to update or remove ──────
    echo ""
    echo "  flux config  —  ${FLUX_CONFIG}"
    echo ""
    printf "  %-22s %s\n" "R2 Bucket:"      "$bucket"
    printf "  %-22s %s\n" "Account ID:"     "$account_id"
    printf "  %-22s %s\n" "Access Key ID:"  "$access_key_id"
    printf "  %-22s %s\n" "Secret Key:"     "****  (Keychain)"
    printf "  %-22s %s\n" "Size Threshold:" "${threshold} MB"
    printf "  %-22s %s\n" "Verbose:"        "$verbose"
    echo ""

    local choice
    read -rp "  [u] Update   [r] Remove   Enter to exit: " choice || true
    echo ""

    case "${choice:-}" in
      u|U)
        _flux_prompt_value "R2 Bucket"         "$bucket"        false; bucket="$FLUX_VALUE"
        _flux_prompt_value "Account ID"        "$account_id"    false; account_id="$FLUX_VALUE"
        _flux_prompt_value "Access Key ID"     "$access_key_id" false; access_key_id="$FLUX_VALUE"
        _flux_prompt_value "Secret Key"        "$secret_key"    true;  secret_key="$FLUX_VALUE"
        _flux_prompt_value "Size threshold MB" "$threshold"     false; threshold="$FLUX_VALUE"
        _flux_prompt_value "Verbose"           "$verbose"       false; verbose="$FLUX_VALUE"
        echo ""
        _flux_write_config "$bucket" "$account_id" "$threshold" "$verbose"
        ok "Config saved: $FLUX_CONFIG"
        _kc_set "r2.access-key-id" "$access_key_id"
        _kc_set "r2.secret-key"    "$secret_key"
        ok "Credentials updated in Keychain."
        echo ""
        ;;
      r|R)
        local confirm
        read -rp "  Remove flux config and credentials? [y/N]: " confirm || true
        if [[ "${confirm:-}" =~ ^[Yy]$ ]]; then
          rm -f "$FLUX_CONFIG"
          _kc_del "r2.access-key-id"
          _kc_del "r2.secret-key"
          ok "Config and credentials removed."
        else
          echo "  Cancelled."
        fi
        echo ""
        ;;
    esac

  fi
}

# ---------------------------------------------------------------------------
# add — add flux to the current repository
# ---------------------------------------------------------------------------

_flux_add() {
  _flux_require_macos

  echo ""
  echo "  flux ${VERSION} — add"
  echo ""

  command -v dvc >/dev/null || fail 'dvc is not installed. Run: pip install "dvc[s3]"'

  _flux_is_configured \
    || fail "Not configured. Run 'flux config' to set up."

  # Values available after _flux_is_configured sourced flux.env
  local bucket="${FLUX_R2_BUCKET:-}"
  local account_id="${FLUX_R2_ACCOUNT_ID:-}"
  local threshold="${FLUX_SIZE_THRESHOLD_MB:-5}"
  local verbose="${FLUX_VERBOSE:-false}"
  local access_key_id secret_key
  access_key_id=$(_kc_get "r2.access-key-id")
  secret_key=$(_kc_get "r2.secret-key")

  ok "Config: $FLUX_CONFIG"
  ok "Credentials: Keychain"

  git rev-parse --git-dir &>/dev/null \
    || fail "Not inside a Git repository — run 'git init' first."
  ok "Git repository found."

  if [[ ! -d .dvc ]]; then
    dvc init --quiet
    ok "DVC initialised."
  else
    ok "DVC already initialised."
  fi

  local FLUX_R2_FOLDER
  FLUX_R2_FOLDER=$(git config --get flux.r2-folder 2>/dev/null || true)
  if [[ -z "$FLUX_R2_FOLDER" ]]; then
    FLUX_R2_FOLDER=$(git remote get-url origin 2>/dev/null \
      | sed 's/\.git$//' | sed 's/.*\///' || true)
  fi
  [[ -n "$FLUX_R2_FOLDER" ]] \
    || fail "Cannot derive R2 folder — run: git config flux.r2-folder <name>"
  ok "R2 folder: ${FLUX_R2_FOLDER}"

  local R2_ENDPOINT="https://${account_id}.r2.cloudflarestorage.com"
  dvc remote add    -f      r2remote "s3://${bucket}/${FLUX_R2_FOLDER}" --quiet
  dvc remote modify         r2remote endpointurl "$R2_ENDPOINT"         --quiet
  dvc remote modify         r2remote region      auto                   --quiet
  dvc remote modify --local r2remote access_key_id     "$access_key_id" --quiet
  dvc remote modify --local r2remote secret_access_key "$secret_key"    --quiet
  ok "DVC remote: s3://${bucket}/${FLUX_R2_FOLDER}"

  git config dvc-router.size-threshold-mb "$threshold"
  git config dvc-router.verbose           "$verbose"
  git config flux.r2-folder              "$FLUX_R2_FOLDER"

  local HOOKS_DIR _script_dir HOOK_SOURCE
  HOOKS_DIR="$(git rev-parse --git-dir)/hooks"
  _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  HOOK_SOURCE="${_script_dir}/../share/flux/pre-commit"
  [[ -f "$HOOK_SOURCE" ]] || HOOK_SOURCE="${_script_dir}/pre-commit"
  [[ -f "$HOOK_SOURCE" ]] || fail "pre-commit hook not found (expected at $HOOK_SOURCE)."
  cp "$HOOK_SOURCE" "${HOOKS_DIR}/pre-commit"
  chmod +x "${HOOKS_DIR}/pre-commit"
  ok "Pre-commit hook installed."

  touch .gitignore
  for entry in ".dvc/config.local" ".dvc/tmp/" ".dvc/cache/"; do
    grep -qF "$entry" .gitignore || echo "$entry" >> .gitignore
  done
  ok ".gitignore updated."

  git add .dvc/config .gitignore 2>/dev/null || true
  if ! git diff --cached --quiet 2>/dev/null; then
    git commit -m "chore: initialise DVC with Cloudflare R2 remote" --no-verify
    ok "Initial DVC config committed."
  else
    ok "Nothing new to commit."
  fi

  echo ""
  echo "  flux added. Your workflow:"
  echo ""
  echo "    git commit -m 'your message'   # hook routes files automatically"
  echo "    flux sync                       # sync everything"
  echo "    flux pull                       # download the latest"
  echo ""
}

# ---------------------------------------------------------------------------
# remove — detach flux from the current repository
# ---------------------------------------------------------------------------

_flux_remove() {
  git rev-parse --git-dir &>/dev/null || fail "Not inside a Git repository."

  local HOOKS_DIR
  HOOKS_DIR="$(git rev-parse --git-dir)/hooks"

  if [[ -f "${HOOKS_DIR}/pre-commit" ]]; then
    rm "${HOOKS_DIR}/pre-commit"
    ok "Pre-commit hook removed."
  else
    warn "No pre-commit hook found."
  fi

  if [[ -f ".dvc/config.local" ]]; then
    rm ".dvc/config.local"
    ok ".dvc/config.local removed."
  fi

  dvc remote remove r2remote 2>/dev/null && ok "DVC remote removed." || true

  git config --unset flux.r2-folder               2>/dev/null || true
  git config --unset dvc-router.size-threshold-mb  2>/dev/null || true
  git config --unset dvc-router.verbose            2>/dev/null || true

  echo ""
  warn "Global config and credentials were not touched."
  warn "Run 'flux config' and choose [r] to remove those."
  echo ""
}

# ---------------------------------------------------------------------------
# sync — pull then push (git + dvc)
# ---------------------------------------------------------------------------

_flux_sync() {
  git pull && dvc pull && git push && dvc push
}

# ---------------------------------------------------------------------------
# doctor — environment diagnostics
# ---------------------------------------------------------------------------

_flux_doctor() {
  _flux_require_macos

  local pass=true

  echo ""
  echo "  flux doctor"
  echo ""

  # Global config
  if [[ -f "$FLUX_CONFIG" ]]; then
    ok "Config file: $FLUX_CONFIG"
    # shellcheck source=/dev/null
    source "$FLUX_CONFIG" 2>/dev/null || true
    if [[ -n "${FLUX_R2_BUCKET:-}" ]]; then
      ok "R2 bucket: $FLUX_R2_BUCKET"
    else
      warn "FLUX_R2_BUCKET not set — run: flux config"
      pass=false
    fi
    if [[ -n "${FLUX_R2_ACCOUNT_ID:-}" ]]; then
      ok "R2 account ID: $FLUX_R2_ACCOUNT_ID"
    else
      warn "FLUX_R2_ACCOUNT_ID not set — run: flux config"
      pass=false
    fi
  else
    warn "Config file not found: $FLUX_CONFIG"
    warn "  Run: flux config"
    pass=false
  fi

  # Keychain credentials
  local access_key_id secret_key
  access_key_id=$(_kc_get "r2.access-key-id")
  secret_key=$(_kc_get "r2.secret-key")

  if [[ -n "$access_key_id" ]]; then
    ok "Keychain: access key ID present"
  else
    warn "Keychain: access key ID missing — run: flux config"
    pass=false
  fi
  if [[ -n "$secret_key" ]]; then
    ok "Keychain: secret key present"
  else
    warn "Keychain: secret key missing — run: flux config"
    pass=false
  fi

  # DVC
  if command -v dvc >/dev/null; then
    local dvc_ver
    dvc_ver=$(dvc version 2>/dev/null | head -1 || true)
    ok "DVC: ${dvc_ver:-found}"
  else
    warn "DVC not found — run: pip install \"dvc[s3]\""
    pass=false
  fi

  # Per-repo checks (only if inside a git repo)
  if git rev-parse --git-dir &>/dev/null; then
    local hook
    hook="$(git rev-parse --git-dir)/hooks/pre-commit"
    if [[ -x "$hook" ]]; then
      ok "Pre-commit hook: installed"
    elif [[ -f "$hook" ]]; then
      warn "Pre-commit hook: not executable — run: chmod +x $hook"
      pass=false
    else
      warn "Pre-commit hook: missing — run: flux add"
      pass=false
    fi

    if grep -q 'r2remote' .dvc/config 2>/dev/null; then
      ok "DVC remote: r2remote configured"
    else
      warn "DVC remote 'r2remote' not configured — run: flux add"
      pass=false
    fi
  else
    warn "Not inside a Git repository — per-repo checks skipped"
  fi

  echo ""
  if [[ "$pass" == "true" ]]; then
    ok "All checks passed."
  else
    warn "Some checks failed — see above."
  fi
  echo ""
}

# ---------------------------------------------------------------------------
# dispatcher
# ---------------------------------------------------------------------------

flux() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    add)               _flux_add ;;
    remove)            _flux_remove ;;
    sync|"")           _flux_sync ;;
    pull)              git pull "$@" && dvc pull ;;
    config)            _flux_config ;;
    doctor)            _flux_doctor ;;
    version)           echo "flux ${VERSION}" ;;
    help|--help|-h)    _flux_help ;;
    cbox)
      if command -v cbox >/dev/null 2>&1; then
        cbox help
      else
        echo "claudebox is not installed."
        echo "Install: brew tap bpeterme/claudebox && brew install bpeterme/claudebox/claudebox"
        return 1
      fi
      ;;
    cdot)
      if command -v cdot >/dev/null 2>&1; then
        cdot help
      else
        echo "claudedot is not installed."
        echo "Install: brew tap bpeterme/claudedot && brew install bpeterme/claudedot/claudedot"
        return 1
      fi
      ;;
    *)
      echo "Unknown command: $cmd"
      echo
      _flux_help
      exit 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  flux "$@"
fi
