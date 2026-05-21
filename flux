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

  local -a keys=()
  while IFS= read -r line; do [[ -n "$line" ]] && keys+=("$line"); done \
    < <(_flux_registry_read git_config)
  if (( ${#keys[@]} == 0 )); then
    keys=(flux.r2-folder dvc-router.size-cap-mb dvc-router.verbose)
  fi
  local removed=0
  for key in "${keys[@]}"; do
    if git config --unset "$key" 2>/dev/null; then
      _flux_registry_delete git_config "$key"
      (( removed++ )) || true
    fi
  done
  (( removed > 0 )) && ok "Git config entries removed (${removed})." || warn "No flux git config entries found."

  if [[ ! -f "${HOOKS_DIR}/pre-commit" ]] && (( removed == 0 )); then
    echo -e "${RED}✘${NC} Not a flux-managed project."
  fi
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
  local -a ptrs=()
  while IFS= read -r line; do [[ -n "$line" ]] && ptrs+=("$line"); done \
    < <(find . -type f -name "*.dvc" -not -path "./.git/*" -not -path "./.dvc/*" 2>/dev/null)
  if (( ${#ptrs[@]} > 0 )); then
    git rm --cached -q "${ptrs[@]}" 2>/dev/null || true
    rm -f "${ptrs[@]}"
    ok "Removed ${#ptrs[@]} .dvc pointer file(s)."
  fi

  # Remove .dvcignore files from git index and disk
  local -a dvcignores=()
  while IFS= read -r line; do [[ -n "$line" ]] && dvcignores+=("$line"); done \
    < <(find . -type f -name ".dvcignore" -not -path "./.git/*" -not -path "./.dvc/*" 2>/dev/null)
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
    local -a entries=()
    while IFS= read -r line; do [[ -n "$line" ]] && entries+=("$line"); done \
      < <(_flux_registry_read gitignore)
    local removed_gi=0
    if (( ${#entries[@]} > 0 )); then
      for entry in "${entries[@]}"; do
        if grep -qxF "$entry" .gitignore 2>/dev/null; then
          local tmp; tmp=$(mktemp)
          grep -vxF "$entry" .gitignore > "$tmp" || true
          mv "$tmp" .gitignore
          _flux_registry_delete gitignore "$entry"
          (( removed_gi++ )) || true
        fi
      done
    fi
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
      [[ -d ".dvc" ]] \
        || fail "Not a flux-managed project (no .dvc/ found). Run 'flux add' to initialise."
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

  _flux_sync_summary
  ok "Pulling from Git remote..."; git pull
  ok "Pulling DVC data from R2..."; "$DVC" pull
  ok "Pushing to Git remote...";   git push
  ok "Pushing DVC data to R2...";  "$DVC" push
}

_flux_sync_summary() {
  local git_count=0 git_bytes=0 dvc_count=0 dvc_bytes=0

  local all_files
  all_files=$(git ls-files 2>/dev/null || true)

  while IFS= read -r file; do
    [[ -z "$file" || "$file" == *.dvc ]] && continue
    [[ ! -f "$file" ]] && continue
    local sz; sz=$(wc -c < "$file" | tr -d ' ')
    git_bytes=$(( git_bytes + sz ))
    git_count=$(( git_count + 1 ))
  done <<< "$all_files"

  local dvc_pointers
  dvc_pointers=$(git ls-files "*.dvc" 2>/dev/null || true)

  while IFS= read -r ptr; do
    [[ -z "$ptr" || ! -f "$ptr" ]] && continue
    local sz
    sz=$(grep -m1 'size:' "$ptr" 2>/dev/null | awk '{print $2}')
    [[ -z "$sz" || ! "$sz" =~ ^[0-9]+$ ]] && sz=0
    dvc_bytes=$(( dvc_bytes + sz ))
    dvc_count=$(( dvc_count + 1 ))
  done <<< "$dvc_pointers"

  (( git_count == 0 && dvc_count == 0 )) && return 0

  echo ""
  echo "  flux sync — repository contents"
  echo ""

  local count_digits=1 max_c
  max_c=$(( git_count > dvc_count ? git_count : dvc_count ))
  while (( max_c >= 10 )); do count_digits=$(( count_digits + 1 )); max_c=$(( max_c / 10 )); done

  (( git_count > 0 )) && printf "  Git   %*d file(s)   %s\n" "$count_digits" "$git_count" "$(_flux_size_unit "$git_bytes")"
  (( dvc_count > 0 )) && printf "  DVC   %*d file(s)   %s\n" "$count_digits" "$dvc_count" "$(_flux_size_unit "$dvc_bytes")"
  echo ""
}

# ---------------------------------------------------------------------------
# Histogram helpers for dry-run size distribution
# ---------------------------------------------------------------------------

_flux_size_unit() {
  local bytes=$1
  if   (( bytes >= 1073741824 )); then printf '%d GB' $(( bytes / 1073741824 ))
  elif (( bytes >= 1048576 ));    then printf '%d MB' $(( bytes / 1048576 ))
  elif (( bytes >= 1024 ));       then printf '%d KB' $(( bytes / 1024 ))
  else                                 printf '%d B'  "$bytes"
  fi
}

_flux_dry_run_histogram() {
  local cap_bytes=$1
  local BAR_WIDTH=20

  local all_tracked
  all_tracked=$(git ls-files 2>/dev/null || true)
  [[ -z "$all_tracked" ]] && return 0

  # Fixed log-scale boundaries, with cap inserted as a dynamic boundary
  local fixed_thresholds=(1024 10240 102400 1048576 10485760 104857600 1073741824)
  local boundaries=(0) cap_added=false t last_idx

  for t in "${fixed_thresholds[@]}"; do
    if [[ "$cap_added" == "false" ]] && (( cap_bytes <= t )); then
      last_idx=$(( ${#boundaries[@]} - 1 ))
      if (( cap_bytes > boundaries[last_idx] )); then
        boundaries+=("$cap_bytes")
      fi
      cap_added=true
    fi
    last_idx=$(( ${#boundaries[@]} - 1 ))
    if (( t != boundaries[last_idx] )); then
      boundaries+=("$t")
    fi
  done

  if [[ "$cap_added" == "false" ]]; then
    last_idx=$(( ${#boundaries[@]} - 1 ))
    if (( cap_bytes > boundaries[last_idx] )); then
      boundaries+=("$cap_bytes")
    fi
  fi
  boundaries+=(0)  # 0 = infinity sentinel

  local nbrackets=$(( ${#boundaries[@]} - 1 ))

  local i
  local counts=()
  local sizes=()
  for (( i=0; i<nbrackets; i++ )); do
    counts+=( 0 )
    sizes+=( 0 )
  done

  # Count all tracked files per bracket and accumulate sizes
  local file sz lo hi
  while IFS= read -r file; do
    [[ ! -f "$file" ]] && continue
    sz=$(wc -c < "$file" | tr -d ' ')
    for (( i=0; i<nbrackets; i++ )); do
      lo="${boundaries[$i]}"
      hi="${boundaries[$((i+1))]}"
      if (( sz >= lo )) && (( hi == 0 || sz < hi )); then
        counts[$i]=$(( counts[$i] + 1 ))
        sizes[$i]=$(( sizes[$i] + sz ))
        break
      fi
    done
  done <<< "$all_tracked"

  # Only display when files span more than one bracket
  local non_empty=0
  for (( i=0; i<nbrackets; i++ )); do
    if (( counts[$i] > 0 )); then non_empty=$(( non_empty + 1 )); fi
  done
  if (( non_empty <= 1 )); then return 0; fi

  # Find separator position (bracket whose upper bound == cap_bytes)
  local sep_after=-1
  for (( i=0; i<nbrackets; i++ )); do
    if (( boundaries[$((i+1))] == cap_bytes )); then sep_after=$i; break; fi
  done

  # Trim DVC side: show at least the first DVC bucket; stop at last non-empty one
  local dvc_first dvc_last display_last
  if (( sep_after >= 0 )); then
    dvc_first=$(( sep_after + 1 ))
    dvc_last=$dvc_first
    for (( i=dvc_first; i<nbrackets; i++ )); do
      if (( counts[$i] > 0 )); then dvc_last=$i; fi
    done
    display_last=$dvc_last
  else
    display_last=$(( nbrackets - 1 ))
  fi

  # Max count across displayed range (for bar scaling)
  local max_count=0
  for (( i=0; i<=display_last; i++ )); do
    if (( counts[$i] > max_count )); then max_count=${counts[$i]}; fi
  done

  # Width of the count column (right-aligned)
  local count_digits=${#max_count}

  # Two-column label alignment:
  #   left col  (max_lo_width)  : lo value, right-aligned; empty for "< hi" and "> lo"
  #   separator (3 chars)       : " - " / " < " / " > "
  #   right col (max_right_width): hi value for ranges; lo value for "> lo"; hi for "< hi"
  local max_lo_width=0 max_right_width=0 lw rw lo_str hi_str
  for (( i=0; i<=display_last; i++ )); do
    lo="${boundaries[$i]}"
    hi="${boundaries[$((i+1))]}"
    if (( lo != 0 && hi != 0 )); then
      lo_str=$(_flux_size_unit "$lo"); hi_str=$(_flux_size_unit "$hi")
      lw=${#lo_str}; rw=${#hi_str}
      if (( lw > max_lo_width ));    then max_lo_width=$lw;    fi
      if (( rw > max_right_width )); then max_right_width=$rw; fi
    elif (( lo == 0 )); then
      hi_str=$(_flux_size_unit "$hi"); rw=${#hi_str}
      if (( rw > max_right_width )); then max_right_width=$rw; fi
    else
      lo_str=$(_flux_size_unit "$lo"); lw=${#lo_str}
      if (( lw > max_right_width )); then max_right_width=$lw; fi
    fi
  done

  local label_width=$(( max_lo_width + 3 + max_right_width ))
  local sep_width=$(( label_width + 2 + BAR_WIDTH ))

  echo ""
  echo "  Size distribution  (all tracked files)"
  echo ""

  local bar bar_len bar_pad j count size_str
  for (( i=0; i<=display_last; i++ )); do
    lo="${boundaries[$i]}"
    hi="${boundaries[$((i+1))]}"
    count="${counts[$i]}"

    # Label: right-aligned lo, fixed-width separator, left-aligned right value
    if (( lo == 0 )); then
      printf "    %*s < %-*s" "$max_lo_width" "" "$max_right_width" "$(_flux_size_unit "$hi")"
    elif (( hi == 0 )); then
      printf "    %*s > %-*s" "$max_lo_width" "" "$max_right_width" "$(_flux_size_unit "$lo")"
    else
      printf "    %*s - %-*s" "$max_lo_width" "$(_flux_size_unit "$lo")" "$max_right_width" "$(_flux_size_unit "$hi")"
    fi

    # Bar: build blocks then pad explicitly in display columns (█ is multi-byte,
    # so %-*s byte-based padding would misalign counts for partial bars)
    bar=""; bar_len=0
    if (( count > 0 && max_count > 0 )); then
      bar_len=$(( count * BAR_WIDTH / max_count ))
      if (( bar_len < 1 )); then bar_len=1; fi
      for (( j=0; j<bar_len; j++ )); do bar="${bar}█"; done
    fi
    bar_pad=""; for (( j=bar_len; j<BAR_WIDTH; j++ )); do bar_pad="${bar_pad} "; done

    # Size annotation shown only when bucket is non-empty
    if (( count > 0 )); then
      size_str="  ($(_flux_size_unit "${sizes[$i]}"))"
    else
      size_str=""
    fi

    printf "  %s%s  %*d%s\n" "$bar" "$bar_pad" "$count_digits" "$count" "$size_str"

    if (( i == sep_after )); then
      local sep_line=""
      for (( j=0; j<sep_width; j++ )); do sep_line="${sep_line}─"; done
      printf "    %s  cap: %s\n" "$sep_line" "$(_flux_size_unit "$cap_bytes")"
    fi
  done
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
  echo ""

  (( ${#git_files[@]} > 0 )) \
    && printf "  → Git     %d file(s)    %s\n" "${#git_files[@]}" "$(_flux_format_size "$git_bytes")"
  if (( ${#dvc_files[@]} > 0 )); then
    local migrating_note=""
    (( ${#dvc_migrating[@]} > 0 )) && migrating_note="    (${#dvc_migrating[@]} migrating from Git)"
    printf "  → DVC     %d file(s)    %s%s\n" "${#dvc_files[@]}" "$(_flux_format_size "$dvc_bytes")" "$migrating_note"
  fi
  printf "  ↷ Skip    %d file(s)    already in DVC\n" "${#skip_files[@]}"

  _flux_dry_run_histogram "$SIZE_CAP_BYTES"

  local show_details=false
  if [[ -t 0 && -t 1 ]]; then
    echo ""
    local answer
    read -r -p "  Show file details? [y/N] " answer
    case "$answer" in y|Y|yes|YES|Yes) show_details=true ;; esac
  fi

  if [[ "$show_details" == "true" ]]; then
    if (( ${#git_files[@]} > 0 )); then
      echo ""
      printf "  Git files:\n"
      for f in "${git_files[@]}"; do
        local sz; sz=$(wc -c < "$f" | tr -d ' ')
        printf "    ·  %-42s %s\n" "$f" "$(_flux_format_size "$sz")"
      done
    fi

    if (( ${#dvc_files[@]} > 0 )); then
      echo ""
      printf "  DVC files:\n"
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
      printf "  Skipped (already in DVC):\n"
      for f in "${skip_files[@]}"; do
        printf "    ·  %s\n" "$f"
      done
    fi
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

  [[ $# -gt 1 ]] && fail "Too many arguments. Usage: flux cap [N|--reset]"

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
