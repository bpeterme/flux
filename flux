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
# Locate DVC — checks all common Homebrew install locations before PATH
# ---------------------------------------------------------------------------

_flux_find_dvc() {
  local candidates=(
    "/opt/homebrew/bin/dvc"      # system Homebrew, Apple Silicon
    "/usr/local/bin/dvc"         # system Homebrew, Intel
    "${HOME}/.homebrew/bin/dvc"  # user-local Homebrew (common)
    "${HOME}/homebrew/bin/dvc"   # user-local Homebrew (alternative)
  )
  for candidate in "${candidates[@]}"; do
    [[ -x "$candidate" ]] && echo "$candidate" && return 0
  done
  command -v dvc &>/dev/null && command -v dvc && return 0
  return 1
}

_flux_require_dvc() {
  DVC=$(_flux_find_dvc) \
    || fail 'dvc not found. Install: pip install "dvc[s3]"  or  uv tool install "dvc[s3]"'
}

_flux_require_dvc_repo() {
  [[ -d ".dvc" ]] \
    || fail "Not a flux-managed project. Run 'flux add' to initialise."
}

# ---------------------------------------------------------------------------
# Registry — tracks what flux has written to this repo for clean removal
# Location: .git/flux-registry (not tracked by git, local to repo)
# Format:   one "key:value" per line
# ---------------------------------------------------------------------------

_flux_registry_path() {
  git rev-parse --git-dir 2>/dev/null && return 0
  echo ""
}

_flux_registry_write() {
  local key="$1" value="$2"
  local reg; reg="$(git rev-parse --git-dir 2>/dev/null)/flux-registry"
  [[ -z "$reg" ]] && return 0
  grep -qxF "${key}:${value}" "$reg" 2>/dev/null || echo "${key}:${value}" >> "$reg"
}

_flux_registry_read() {
  local key="$1"
  local reg; reg="$(git rev-parse --git-dir 2>/dev/null)/flux-registry"
  [[ -f "$reg" ]] || return 0
  grep "^${key}:" "$reg" | sed "s/^${key}://"
}

_flux_registry_delete() {
  local key="$1" value="$2"
  local reg; reg="$(git rev-parse --git-dir 2>/dev/null)/flux-registry"
  [[ -f "$reg" ]] || return 0
  local tmp; tmp=$(mktemp)
  grep -vxF "${key}:${value}" "$reg" > "$tmp" || true
  mv "$tmp" "$reg"
}

_flux_format_size() {
  local bytes=$1
  if   (( bytes >= 1024*1024 )); then printf '%d MB' $(( bytes / 1024 / 1024 ))
  elif (( bytes >= 1024 ));      then printf '%d KB' $(( bytes / 1024 ))
  else                                printf '%d B'  "$bytes"
  fi
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
  local bucket="$1" account_id="$2" cap="$3" verbose="$4"
  mkdir -p "$(dirname "$FLUX_CONFIG")"
  local tmp
  tmp=$(mktemp)
  cat > "$tmp" << EOF
# flux configuration — managed by 'flux config'.

# ── cloudflare R2 ─────────────────────────────────────────────────────────────
FLUX_R2_BUCKET="${bucket}"
FLUX_R2_ACCOUNT_ID="${account_id}"

# ── routing ───────────────────────────────────────────────────────────────────
FLUX_SIZE_CAP_MB=${cap}
FLUX_VERBOSE=${verbose}
EOF
  chmod 600 "$tmp"
  # cp follows symlinks — writes to the real file, preserving any symlink at $FLUX_CONFIG
  cp "$tmp" "$FLUX_CONFIG"
  rm -f "$tmp"
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

_flux_require_git_remote() {
  git rev-parse --abbrev-ref --symbolic-full-name '@{u}' &>/dev/null \
    || fail "No upstream branch configured. Run 'git push -u origin <branch>' first."
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
  flux remove           Full detach (git + DVC)
  flux remove git       Remove hook and git config only
  flux remove dvc       Remove all DVC traces (pointer files, .dvc/)
  flux pull             Download the latest (git pull + dvc pull)
  flux dry-run          Preview routing (staged files, or all tracked if none staged)
  flux cap [N|--reset]  Show, reset or set per-project size cap to [N] (MB)

Maintenance:
  flux config           Configure flux (set up or manage global settings)
  flux doctor           Run environment diagnostics
  flux version          Show version

Companion tools:
  cbox                  claudebox — Claude Code container runtime
  cdot                  claudedot — Config + history sync across machines

Help:
  flux help
  flux --help
  flux -h
EOF
}

# ---------------------------------------------------------------------------
# config — smart: set up if unconfigured, show + manage if configured
# ---------------------------------------------------------------------------

_flux_config() {
  _flux_require_macos

  # Always pre-load whatever partial config exists before deciding which branch.
  local bucket="" account_id="" cap="5" verbose="false"
  if [[ -f "$FLUX_CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$FLUX_CONFIG" 2>/dev/null || true
    bucket="${FLUX_R2_BUCKET:-}"
    account_id="${FLUX_R2_ACCOUNT_ID:-}"
    cap="${FLUX_SIZE_CAP_MB:-5}"
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
    _flux_prompt_value "Size cap MB"        "$cap"           false; cap="$FLUX_VALUE"
    _flux_prompt_value "Verbose"           "$verbose"       false; verbose="$FLUX_VALUE"

    echo ""
    [[ -n "$bucket" ]]        || fail "R2 bucket is required."
    [[ -n "$account_id" ]]    || fail "R2 account ID is required."
    [[ -n "$access_key_id" ]] || fail "R2 access key ID is required."
    [[ -n "$secret_key" ]]    || fail "R2 secret key is required."

    _flux_write_config "$bucket" "$account_id" "$cap" "$verbose"
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
    printf "  %-22s %s\n" "Size Cap:"       "${cap} MB"
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
        _flux_prompt_value "Size cap MB"        "$cap"           false; cap="$FLUX_VALUE"
        _flux_prompt_value "Verbose"           "$verbose"       false; verbose="$FLUX_VALUE"
        echo ""
        _flux_write_config "$bucket" "$account_id" "$cap" "$verbose"
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

  local DVC; _flux_require_dvc

  _flux_is_configured \
    || fail "Not configured. Run 'flux config' to set up."

  # Values available after _flux_is_configured sourced flux.env
  local bucket="${FLUX_R2_BUCKET:-}"
  local account_id="${FLUX_R2_ACCOUNT_ID:-}"
  local cap="${FLUX_SIZE_CAP_MB:-5}"
  local verbose="${FLUX_VERBOSE:-false}"
  local access_key_id secret_key
  access_key_id=$(_kc_get "r2.access-key-id")
  secret_key=$(_kc_get "r2.secret-key")

  ok "Config: $FLUX_CONFIG"
  ok "Credentials: Keychain"

  if ! git rev-parse --git-dir &>/dev/null; then
    local nested
    nested=$(find . -mindepth 2 -maxdepth 3 -name ".git" -type d 2>/dev/null | head -1)
    [[ -n "$nested" ]] \
      && fail "Nested Git repositories detected (e.g. ${nested%/.git}) — run 'git init' manually after confirming the correct directory."
    git init --quiet
    ok "Git repository initialised."
  else
    ok "Git repository found."
  fi

  if [[ ! -d .dvc ]]; then
    "$DVC" init --quiet
    _flux_registry_write dvc_initialized true
    ok "DVC initialised."
  else
    _flux_registry_write dvc_initialized true
    ok "DVC already initialised."
  fi

  local FLUX_R2_FOLDER
  FLUX_R2_FOLDER=$(git config --get flux.r2-folder 2>/dev/null || true)
  if [[ -z "$FLUX_R2_FOLDER" ]]; then
    local derived
    derived=$(git remote get-url origin 2>/dev/null \
      | sed 's/\.git$//' | sed 's/.*\///' \
      | tr -cd '[:alnum:]._-' || true)
    local override
    read -rp "  R2 folder${derived:+ [${derived}]}: " override || true
    FLUX_R2_FOLDER="${override:-$derived}"
  fi
  [[ -n "$FLUX_R2_FOLDER" ]] \
    || fail "Cannot derive R2 folder — run: git config flux.r2-folder <name>"
  ok "R2 folder: ${FLUX_R2_FOLDER}"

  local R2_ENDPOINT="https://${account_id}.r2.cloudflarestorage.com"
  local remote_verb="added"
  grep -q 'r2remote' .dvc/config 2>/dev/null && remote_verb="updated"
  "$DVC" remote add    -f      r2remote "s3://${bucket}/${FLUX_R2_FOLDER}" --quiet
  "$DVC" remote modify         r2remote endpointurl "$R2_ENDPOINT"         --quiet
  "$DVC" remote modify         r2remote region      auto                   --quiet
  "$DVC" remote modify --local r2remote access_key_id     "$access_key_id" --quiet
  "$DVC" remote modify --local r2remote secret_access_key "$secret_key"    --quiet
  _flux_registry_write dvc_remote r2remote
  ok "DVC remote ${remote_verb}: s3://${bucket}/${FLUX_R2_FOLDER}"

  local existing_project_cap
  existing_project_cap=$(git config --get dvc-router.size-cap-mb 2>/dev/null || true)
  if [[ -z "$existing_project_cap" ]]; then
    git config dvc-router.size-cap-mb "$cap"
    _flux_registry_write git_config dvc-router.size-cap-mb
  else
    cap="$existing_project_cap"
  fi
  git config dvc-router.verbose "$verbose"
  git config flux.r2-folder    "$FLUX_R2_FOLDER"
  _flux_registry_write git_config dvc-router.verbose
  _flux_registry_write git_config flux.r2-folder

  touch .gitignore
  for entry in ".dvc/config.local" ".dvc/tmp/" ".dvc/cache/"; do
    if ! grep -qF "$entry" .gitignore; then
      echo "$entry" >> .gitignore
    fi
    _flux_registry_write gitignore "$entry"
  done
  ok ".gitignore updated."

  git add .dvc/config .gitignore 2>/dev/null || true
  if ! git diff --cached --quiet 2>/dev/null; then
    echo ""
    warn "flux needs to commit the following files to your repository:"
    git diff --cached --name-only | sed 's/^/    /'
    echo ""
    local confirm
    read -rp "  Commit with message 'chore: initialise DVC with Cloudflare R2 remote'? [Y/n]: " confirm || true
    if [[ "${confirm:-Y}" =~ ^[Yy]?$ ]]; then
      git commit -m "chore: initialise DVC with Cloudflare R2 remote"
      ok "Initial DVC config committed."
    else
      git restore --staged .dvc/config .gitignore 2>/dev/null || true
      warn "Skipped commit — stage and commit .dvc/config and .gitignore manually before using flux."
    fi
  else
    ok "Nothing new to commit."
  fi

  local HOOKS_DIR _script_dir HOOK_SOURCE
  HOOKS_DIR="$(git rev-parse --git-dir)/hooks"
  _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  HOOK_SOURCE="${_script_dir}/../share/flux/pre-commit"
  [[ -f "$HOOK_SOURCE" ]] || HOOK_SOURCE="${_script_dir}/pre-commit"
  [[ -f "$HOOK_SOURCE" ]] || fail "pre-commit hook not found (expected at $HOOK_SOURCE)."

  if [[ -f "${HOOKS_DIR}/pre-commit" ]]; then
    if grep -q 'dvc-router\|flux' "${HOOKS_DIR}/pre-commit" 2>/dev/null; then
      cp "$HOOK_SOURCE" "${HOOKS_DIR}/pre-commit"
      chmod +x "${HOOKS_DIR}/pre-commit"
      ok "Pre-commit hook updated."
    else
      warn "A pre-commit hook already exists and does not belong to flux."
      warn "  Inspect: ${HOOKS_DIR}/pre-commit"
      fail "Aborting — remove or merge the existing hook manually, then re-run 'flux add'."
    fi
  else
    cp "$HOOK_SOURCE" "${HOOKS_DIR}/pre-commit"
    chmod +x "${HOOKS_DIR}/pre-commit"
    ok "Pre-commit hook installed."
  fi
  _flux_registry_write hook pre-commit

  echo ""
  echo "  flux added. Your workflow:"
  echo ""
  echo "    git commit -m 'your message'   # hook routes files automatically"
  echo "    flux                            # sync everything"
  echo "    flux pull                       # download the latest"
  echo ""
}

# ---------------------------------------------------------------------------
# remove git — remove flux's git integration (hook + git config keys)
# ---------------------------------------------------------------------------

_flux_remove_git() {
  git rev-parse --git-dir &>/dev/null || fail "Not inside a Git repository."

  local HOOKS_DIR
  HOOKS_DIR="$(git rev-parse --git-dir)/hooks"

  if [[ -f "${HOOKS_DIR}/pre-commit" ]]; then
    if grep -q 'dvc-router\|flux' "${HOOKS_DIR}/pre-commit" 2>/dev/null; then
      rm "${HOOKS_DIR}/pre-commit"
      _flux_registry_delete hook pre-commit
      ok "Pre-commit hook removed."
    else
      warn "Pre-commit hook exists but does not appear to belong to flux — not removed."
      warn "  Inspect and remove manually: ${HOOKS_DIR}/pre-commit"
    fi
  else
    warn "No pre-commit hook found."
  fi

  local keys removed=0
  mapfile -t keys < <(_flux_registry_read git_config)
  if (( ${#keys[@]} == 0 )); then
    keys=(flux.r2-folder dvc-router.size-cap-mb dvc-router.verbose)
  fi
  for key in "${keys[@]}"; do
    if git config --unset "$key" 2>/dev/null; then
      _flux_registry_delete git_config "$key"
      (( removed++ )) || true
    fi
  done
  (( removed > 0 )) && ok "Git config entries removed (${removed})." || warn "No flux git config entries found."
}

# ---------------------------------------------------------------------------
# remove dvc — thoroughly remove all DVC traces from the current repo
# ---------------------------------------------------------------------------

_flux_remove_dvc() {
  git rev-parse --git-dir &>/dev/null || fail "Not inside a Git repository."
  local force="${1:-}"

  if [[ ! -d ".dvc" ]]; then
    warn "No .dvc/ directory found — nothing to remove."
    return 0
  fi

  local DVC; _flux_require_dvc

  # Guard: non-flux DVC remotes
  local other_remotes
  other_remotes=$(grep '^\[remote "' .dvc/config 2>/dev/null \
    | grep -v '"r2remote"' | sed 's/.*"\(.*\)".*/\1/' || true)
  if [[ -n "$other_remotes" ]] && [[ "$force" != "--force" ]]; then
    warn "Other DVC remotes are configured (not managed by flux):"
    echo "$other_remotes" | sed 's/^/    /'
    warn "Removing .dvc/ would destroy these too. Pass --force to proceed anyway."
    return 1
  fi

  # Guard: DVC-tracked files whose data is not on disk
  local missing_data=()
  while IFS= read -r -d '' ptr; do
    local data_file="${ptr%.dvc}"
    [[ -e "$data_file" ]] || missing_data+=("$ptr")
  done < <(find . -type f -name "*.dvc" -not -path "./.git/*" -not -path "./.dvc/*" -print0 2>/dev/null)

  if (( ${#missing_data[@]} > 0 )); then
    warn "The following DVC-tracked files are not present on disk."
    warn "Run 'dvc pull' first, or their data will only exist on R2:"
    for f in "${missing_data[@]}"; do printf "    %s\n" "$f"; done
    echo ""
    local confirm
    read -rp "  Continue anyway? [y/N]: " confirm || true
    [[ "${confirm:-N}" =~ ^[Yy]$ ]] || return 1
  fi

  # Remove DVC remote and local config
  "$DVC" remote remove r2remote 2>/dev/null && ok "DVC remote 'r2remote' removed." || true
  if [[ -f ".dvc/config.local" ]]; then
    rm ".dvc/config.local"
    ok ".dvc/config.local removed."
  fi
  _flux_registry_delete dvc_remote r2remote

  # Remove *.dvc pointer files from git index and disk
  local ptrs=()
  mapfile -t ptrs < <(find . -type f -name "*.dvc" -not -path "./.git/*" -not -path "./.dvc/*" 2>/dev/null || true)
  if (( ${#ptrs[@]} > 0 )); then
    git rm --cached -q "${ptrs[@]}" 2>/dev/null || true
    rm -f "${ptrs[@]}"
    ok "Removed ${#ptrs[@]} .dvc pointer file(s)."
  fi

  # Remove .dvcignore files from git index and disk
  local dvcignores=()
  mapfile -t dvcignores < <(find . -type f -name ".dvcignore" -not -path "./.git/*" -not -path "./.dvc/*" 2>/dev/null || true)
  if (( ${#dvcignores[@]} > 0 )); then
    git rm --cached -q "${dvcignores[@]}" 2>/dev/null || true
    rm -f "${dvcignores[@]}"
    ok "Removed ${#dvcignores[@]} .dvcignore file(s)."
  fi

  # Remove .dvc/ directory from git index and disk
  git rm -r --cached -q .dvc/ 2>/dev/null || true
  rm -rf .dvc/
  _flux_registry_delete dvc_initialized true
  ok ".dvc/ directory removed."

  # Clean flux-written .gitignore entries
  if [[ -f ".gitignore" ]]; then
    local entries removed_gi=0
    mapfile -t entries < <(_flux_registry_read gitignore)
    for entry in "${entries[@]}"; do
      if grep -qxF "$entry" .gitignore 2>/dev/null; then
        local tmp; tmp=$(mktemp)
        grep -vxF "$entry" .gitignore > "$tmp" || true
        mv "$tmp" .gitignore
        _flux_registry_delete gitignore "$entry"
        (( removed_gi++ )) || true
      fi
    done
    (( removed_gi > 0 )) && ok "Removed ${removed_gi} flux .gitignore entr(ies)." || true
  fi
}

# ---------------------------------------------------------------------------
# remove — detach flux from the current repository (git + dvc)
# ---------------------------------------------------------------------------

_flux_remove() {
  local sub="${1:-}"

  case "$sub" in
    git)   _flux_remove_git ;;
    dvc)   shift || true; _flux_remove_dvc "$@" ;;
    "")
      git rev-parse --git-dir &>/dev/null || fail "Not inside a Git repository."
      echo ""
      echo "  flux remove — full detach"
      echo ""
      _flux_remove_dvc "$@"
      echo ""
      _flux_remove_git
      echo ""
      warn "Global config and credentials were not touched."
      warn "Run 'flux config' and choose [r] to remove those."
      echo ""
      ;;
    *)
      fail "Unknown remove target '${sub}'. Usage: flux remove [git|dvc]"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# pull — download the latest (git pull + dvc pull)
# ---------------------------------------------------------------------------

_flux_pull() {
  git rev-parse --git-dir &>/dev/null \
    || fail "Not inside a Git repository."
  _flux_require_dvc_repo
  _flux_require_git_remote
  _flux_is_configured \
    || fail "Not configured. Run 'flux config' to set up."
  local DVC; _flux_require_dvc

  ok "Pulling from Git remote..."; git pull "$@"
  ok "Pulling DVC data from R2..."; "$DVC" pull
}

# ---------------------------------------------------------------------------
# sync — pull then push (git + dvc)
# ---------------------------------------------------------------------------

_flux_sync() {
  git rev-parse --git-dir &>/dev/null \
    || fail "Not inside a Git repository."
  _flux_require_dvc_repo
  _flux_require_git_remote
  _flux_is_configured \
    || fail "Not configured. Run 'flux config' to set up."
  local DVC; _flux_require_dvc

  if ! git diff --quiet || ! git diff --cached --quiet; then
    fail "You have uncommitted changes. Commit or stash them before syncing."
  fi

  ok "Pulling from Git remote..."; git pull
  ok "Pulling DVC data from R2..."; "$DVC" pull
  ok "Pushing to Git remote...";   git push
  ok "Pushing DVC data to R2...";  "$DVC" push
}

# ---------------------------------------------------------------------------
# dry-run — preview staged file routing without executing any changes
# ---------------------------------------------------------------------------

_flux_dry_run() {
  git rev-parse --git-dir &>/dev/null \
    || fail "Not inside a Git repository."

  local SIZE_CAP_MB SIZE_CAP_BYTES
  SIZE_CAP_MB=$(git config --get dvc-router.size-cap-mb 2>/dev/null || echo "5")
  SIZE_CAP_BYTES=$(( SIZE_CAP_MB * 1024 * 1024 ))

  local staged_files scan_mode
  staged_files=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)

  if [[ -z "$staged_files" ]]; then
    staged_files=$(git ls-files 2>/dev/null || true)
    scan_mode="all tracked files"
  else
    scan_mode="staged files"
  fi

  if [[ -z "$staged_files" ]]; then
    echo ""
    echo "  No files to preview."
    echo ""
    return 0
  fi

  local git_files=() git_bytes=0
  local dvc_files=() dvc_bytes=0 dvc_migrating=()
  local skip_files=()

  while IFS= read -r file; do
    [[ ! -f "$file" ]] && continue

    if [[ -f "${file}.dvc" ]]; then
      skip_files+=("$file")
      continue
    fi

    local is_binary=false
    grep -qI . "$file" 2>/dev/null || is_binary=true
    local file_size
    file_size=$(wc -c < "$file" | tr -d ' ')

    if [[ "$is_binary" == "true" ]] || (( file_size > SIZE_CAP_BYTES )); then
      dvc_files+=("$file")
      dvc_bytes=$(( dvc_bytes + file_size ))
      if git ls-files --error-unmatch "$file" &>/dev/null 2>&1; then
        dvc_migrating+=("$file")
      fi
    else
      git_files+=("$file")
      git_bytes=$(( git_bytes + file_size ))
    fi
  done <<< "$staged_files"

  echo ""
  echo "  flux dry-run — routing preview (${scan_mode}, cap: ${SIZE_CAP_MB} MB)"

  if (( ${#git_files[@]} > 0 )); then
    echo ""
    printf "  → Git  (%d file(s), %s)\n" "${#git_files[@]}" "$(_flux_format_size "$git_bytes")"
    for f in "${git_files[@]}"; do
      local sz; sz=$(wc -c < "$f" | tr -d ' ')
      printf "    ·  %-42s %s\n" "$f" "$(_flux_format_size "$sz")"
    done
  fi

  if (( ${#dvc_files[@]} > 0 )); then
    echo ""
    printf "  → DVC / R2  (%d file(s), %s)\n" "${#dvc_files[@]}" "$(_flux_format_size "$dvc_bytes")"
    for f in "${dvc_files[@]}"; do
      local sz; sz=$(wc -c < "$f" | tr -d ' ')
      local note=""
      for m in "${dvc_migrating[@]+"${dvc_migrating[@]}"}"; do
        [[ "$m" == "$f" ]] && note="   [migrating from Git]" && break
      done
      printf "    ✦  %-42s %s%s\n" "$f" "$(_flux_format_size "$sz")" "$note"
    done
  fi

  if (( ${#skip_files[@]} > 0 )); then
    echo ""
    printf "  ↷  Already in DVC  (%d file(s), skipped)\n" "${#skip_files[@]}"
    for f in "${skip_files[@]}"; do
      printf "    ·  %s\n" "$f"
    done
  fi

  echo ""
}

# ---------------------------------------------------------------------------
# cap — show or set the per-project file size cap
# ---------------------------------------------------------------------------

_flux_cap() {
  git rev-parse --git-dir &>/dev/null \
    || fail "Not inside a Git repository."

  _flux_is_configured \
    || fail "Not configured. Run 'flux config' to set up."

  local global_cap="${FLUX_SIZE_CAP_MB:-5}"
  local project_cap
  project_cap=$(git config --get dvc-router.size-cap-mb 2>/dev/null || true)

  local arg="${1:-}"

  if [[ -z "$arg" ]]; then
    echo ""
    if [[ -n "$project_cap" ]]; then
      printf "  %-18s %s MB\n"       "Global default:" "$global_cap"
      printf "  %-18s %s MB  ← active\n" "Per-project:" "$project_cap"
    else
      printf "  %-18s %s MB  ← active\n" "Global default:" "$global_cap"
      printf "  %-18s %s\n"          "Per-project:" "(not set)"
    fi
    echo ""
    return 0
  fi

  if [[ "$arg" == "--reset" ]]; then
    git config --unset dvc-router.size-cap-mb 2>/dev/null || true
    ok "Per-project cap removed — global default (${global_cap} MB) is now active."
    return 0
  fi

  if ! [[ "$arg" =~ ^[1-9][0-9]*$ ]]; then
    fail "Invalid value '${arg}' — provide a positive integer (MB), e.g.: flux cap 20"
  fi

  git config dvc-router.size-cap-mb "$arg"
  ok "Per-project cap set to ${arg} MB."
  if [[ ! -d ".dvc" ]]; then
    ok "Will take effect when 'flux add' initialises this project."
  else
    ok "Takes effect on the next commit."
  fi
}

# ---------------------------------------------------------------------------
# _flux_doctor_inline — single-line status for embedding in other tools
# ---------------------------------------------------------------------------

_flux_doctor_inline() {
  if _flux_is_configured 2>/dev/null; then
    echo "✔ flux configured (bucket: ${FLUX_R2_BUCKET})"
  else
    echo "✘ flux not configured — run: flux config"
  fi
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
  local dvc_path
  if dvc_path=$(_flux_find_dvc 2>/dev/null); then
    local dvc_ver
    dvc_ver=$("$dvc_path" version 2>/dev/null | head -1 || true)
    ok "DVC: ${dvc_ver:-found} ($dvc_path)"
  else
    warn "DVC not found — run: pip install \"dvc[s3]\"  or  uv tool install \"dvc[s3]\""
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
  echo "  [cbox]"
  if command -v cbox >/dev/null 2>&1; then
    cbox _doctor | sed 's/^/  /'
  else
    echo "  ℹ cbox not installed"
    echo "    Install: brew tap bpeterme/claudebox && brew install bpeterme/claudebox/claudebox"
  fi

  echo ""
  echo "  [cdot]"
  if command -v cdot >/dev/null 2>&1; then
    cdot _doctor | sed 's/^/  /'
  else
    echo "  ℹ cdot not installed"
    echo "    Install: brew tap bpeterme/claudedot && brew install bpeterme/claudedot/claudedot"
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
    remove)            _flux_remove "$@" ;;
    sync|"")           _flux_sync ;;
    _api-version)      echo "1" ;;
    _pull)             _flux_require_dvc_repo; local DVC; _flux_require_dvc; git pull && "$DVC" pull ;;
    _push)             _flux_require_dvc_repo; local DVC; _flux_require_dvc; "$DVC" push && git push ;;
    _doctor)           _flux_doctor_inline ;;
    pull)              _flux_pull "$@" ;;
    dry-run)           _flux_dry_run ;;
    cap)               _flux_cap "$@" ;;
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
