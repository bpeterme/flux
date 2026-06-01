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
fail() { _flux_spin_stop 2>/dev/null; echo -e "${RED}✘${NC} $*"; exit 1; }

_FLUX_SPINNER_PID=""
_flux_spin_start() {
  [[ -t 1 ]] || return 0
  local msg="${1:-flux syncing...}"
  ( local f=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) i=0
    while true; do
      printf "\r  %s %s" "${f[$i]}" "$msg"
      i=$(( (i+1) % 10 ))
      sleep 0.1
    done ) &
  _FLUX_SPINNER_PID=$!
}
_flux_spin_stop() {
  [[ -n "${_FLUX_SPINNER_PID:-}" ]] || return 0
  kill "$_FLUX_SPINNER_PID" 2>/dev/null || true
  wait "$_FLUX_SPINNER_PID" 2>/dev/null || true
  printf "\r\033[K"
  _FLUX_SPINNER_PID=""
}

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

_flux_is_repo_initialized() {
  git rev-parse --git-dir &>/dev/null || return 1
  [[ -d ".dvc" ]] || return 1
  [[ -n "$(git config --get flux.r2-folder 2>/dev/null)" ]] || return 1
  local _hook; _hook="$(git rev-parse --git-dir)/hooks/pre-commit"
  [[ -f "$_hook" ]] && grep -q 'dvc-router\|flux' "$_hook" 2>/dev/null || return 1
  grep -q 'r2remote' .dvc/config 2>/dev/null || return 1
}

# ---------------------------------------------------------------------------
# Registry — tracks what flux has written to this repo for clean removal
# Location: .git/flux-registry (not tracked by git, local to repo)
# Format:   one "key:value" per line
# ---------------------------------------------------------------------------

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
  grep "^${key}:" "$reg" | sed "s/^${key}://" || true
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

# Returns 0 if FILE starts with any of the directory paths passed as arguments.
# "." matches all files; paths are normalised by stripping trailing slashes.
_flux_in_dir_override() {
  local file="$1"; shift
  local dir
  for dir in "$@"; do
    [[ "$dir" == "." ]] && return 0
    local prefix="${dir%/}/"
    [[ "$file" == "$prefix"* || "$file" == "${dir%/}" ]] && return 0
  done
  return 1
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

_kc_get_dvc() {
  security find-generic-password -a "${USER:-$(id -un)}" -s "flux.dvc.$1.$2" -w 2>/dev/null || true
}

_kc_set_dvc() {
  security add-generic-password -U -a "${USER:-$(id -un)}" -s "flux.dvc.$1.$2" -w "$3" \
    -l "flux: dvc $1 $2" 2>/dev/null \
    || fail "Failed to write 'flux.dvc.$1.$2' to Keychain."
}

_kc_del_dvc() {
  security delete-generic-password -a "${USER:-$(id -un)}" -s "flux.dvc.$1.$2" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# DVC credential-process helpers
# ---------------------------------------------------------------------------

# Called by boto3 via credential_process — reads Keychain and outputs JSON.
# Must run inside a flux-managed project (needs git config flux.dvc-remote-bucket).
_flux_credential_helper() {
  local _bucket
  _bucket=$(git config --get flux.dvc-remote-bucket 2>/dev/null || true)
  if [[ -z "$_bucket" ]]; then
    echo "flux _credential-helper: not inside a flux-managed project" >&2
    exit 1
  fi
  local _ak _sk
  _ak=$(_kc_get_dvc "$_bucket" "access-key-id")
  _sk=$(_kc_get_dvc "$_bucket" "secret-key")
  if [[ -z "$_ak" || -z "$_sk" ]]; then
    echo "flux _credential-helper: no credentials for bucket '${_bucket}' — run: flux config" >&2
    exit 1
  fi
  printf '{"Version":1,"AccessKeyId":"%s","SecretAccessKey":"%s"}\n' "$_ak" "$_sk"
}

# Write (or update) the [profile flux-dvc] credential_process entry in the
# AWS config file. Idempotent: fast-paths when already correct, otherwise
# removes the stale section and appends a fresh one. Uses FLUX_AWS_CONFIG_FILE
# when set, otherwise the default ~/.aws/config.
_flux_setup_aws_credential_process() {
  local _cfg_file="${FLUX_AWS_CONFIG_FILE:-$HOME/.aws/config}"
  local _flux_bin
  _flux_bin=$(command -v flux 2>/dev/null || true)
  [[ -z "$_flux_bin" ]] \
    && _flux_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  local _cred_line="credential_process = ${_flux_bin} _credential-helper"

  mkdir -p "$(dirname "$_cfg_file")"
  [[ -f "$_cfg_file" ]] || touch "$_cfg_file"

  # Fast path: section already has the correct credential_process line
  if grep -qF '[profile flux-dvc]' "$_cfg_file" 2>/dev/null \
  && grep -qF "$_cred_line"        "$_cfg_file" 2>/dev/null; then
    return 0
  fi

  # Remove existing [profile flux-dvc] section (if any), then append fresh one.
  local _tmp; _tmp=$(mktemp)
  awk '/^\[profile flux-dvc\]/{skip=1;next} skip && /^\[/{skip=0} !skip{print}' \
    "$_cfg_file" > "$_tmp" || true
  printf '\n[profile flux-dvc]\n%s\n' "$_cred_line" >> "$_tmp"
  cp "$_tmp" "$_cfg_file"
  rm -f "$_tmp"
}

# Point .dvc/config.local at the flux-dvc AWS profile instead of storing
# plaintext credentials. Also removes legacy credential lines from older flux
# versions. Calls _flux_setup_aws_credential_process to ensure the profile
# exists in the AWS config file before DVC tries to use it.
_flux_apply_dvc_profile() {
  local _dvc="${1:-}"
  [[ -n "$_dvc" ]] || _dvc=$(_flux_find_dvc 2>/dev/null || true)
  [[ -x "$_dvc" ]] || return 0
  _flux_setup_aws_credential_process
  "$_dvc" remote modify --local r2remote profile flux-dvc --quiet 2>/dev/null || true
  # Strip legacy plaintext credentials written by older flux versions
  local _cfg=".dvc/config.local"
  if [[ -f "$_cfg" ]]; then
    local _tmp; _tmp=$(mktemp)
    grep -vE '^\s*(access_key_id|secret_access_key)\s*=' "$_cfg" > "$_tmp" || true
    mv "$_tmp" "$_cfg"
  fi
}

# ---------------------------------------------------------------------------
# Write non-sensitive global config to flux.env
# ---------------------------------------------------------------------------

_flux_write_config() {
  # $1: newline-separated "bucket:account_id" DVC remote entries
  # $2: size cap MB
  # $3: verbose
  # $4: newline-separated "proto:host:account" git account entries
  # $5: primary DVC remote bucket name
  # $6: FLUX_AWS_CONFIG_FILE value (empty = leave commented out)
  local dvc_str="$1" cap="$2" verbose="$3" git_str="$4" primary_dvc="${5:-}" aws_cfg="${6:-}"
  mkdir -p "$(dirname "$FLUX_CONFIG")"
  local tmp; tmp=$(mktemp)
  {
    echo "# flux configuration"
    echo "# This file is managed by 'flux config' — you normally don't edit it by hand."
    echo "# Sensitive credentials (access key, secret key) are stored in macOS Keychain,"
    echo "# keyed per bucket as flux.dvc.{bucket}.{access-key-id|secret-key}."
    echo ""
    echo "# ── DVC remotes ───────────────────────────────────────────────────────────────"
    echo "# One or more Cloudflare R2 accounts. Format: \"bucket:account_id\""
    echo "# Credentials are stored in Keychain — not here."
    echo "FLUX_DVC_REMOTES=("
    if [[ -n "$dvc_str" ]]; then
      while IFS= read -r entry; do
        [[ -n "$entry" ]] && printf '  "%s"\n' "$entry"
      done <<< "$dvc_str"
    fi
    echo ")"
    echo "FLUX_PRIMARY_DVC_REMOTE=${primary_dvc}  # active remote bucket; must match an entry in FLUX_DVC_REMOTES"
    echo ""
    echo "# ── routing ───────────────────────────────────────────────────────────────────"
    echo "FLUX_SIZE_CAP_MB=${cap}        # files larger than this go to R2; smaller stay in Git"
    echo "FLUX_VERBOSE=${verbose}        # verbose hook output (true/false)"
    echo ""
    echo "# ── DVC credential process ────────────────────────────────────────────────────"
    echo "# AWS config file that holds the [profile flux-dvc] credential_process entry."
    echo "# Leave commented to use the default ~/.aws/config; uncomment and set a custom"
    echo "# path to keep flux credentials isolated from your personal AWS setup."
    if [[ -n "$aws_cfg" ]]; then
      echo "FLUX_AWS_CONFIG_FILE=${aws_cfg}"
    else
      echo "# FLUX_AWS_CONFIG_FILE=~/.config/flux/aws.conf"
    fi
    echo ""
    echo "# ── git accounts ──────────────────────────────────────────────────────────────"
    echo "# One or more hosting accounts used to propose git remote URLs during 'flux add'."
    echo "# Format: \"protocol:host:account\"  (protocol: ssh or https)"
    echo "FLUX_GIT_ACCOUNTS=("
    if [[ -n "$git_str" ]]; then
      while IFS= read -r entry; do
        [[ -n "$entry" ]] && printf '  "%s"\n' "$entry"
      done <<< "$git_str"
    fi
    echo ")"
    echo ""
    echo "# ─── companion tools ──────────────────────────────────────────────────────────"
    echo ""
    echo "# claudebox — Claude Code container runtime"
    echo "# Install: brew tap bpeterme/claudebox && brew install bpeterme/claudebox/claudebox"
    echo "# Set up:  cbox build"
    echo ""
    echo "# claudedot — cross-machine config + history sync via git"
    echo "# Install: brew tap bpeterme/claudedot && brew install bpeterme/claudedot/claudedot"
    echo "# Set up:  cdot config"
  } > "$tmp"
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
# Sources flux.env as a side effect, making FLUX_DVC_REMOTES, FLUX_GIT_ACCOUNTS
# etc. available to the caller.
# ---------------------------------------------------------------------------

_flux_is_configured() {
  [[ -f "$FLUX_CONFIG" ]] || return 1
  FLUX_DVC_REMOTES=()
  FLUX_GIT_ACCOUNTS=()
  FLUX_PRIMARY_DVC_REMOTE=""
  # shellcheck source=/dev/null
  source "$FLUX_CONFIG" 2>/dev/null || return 1
  [[ "${#FLUX_DVC_REMOTES[@]}" -gt 0 ]] || return 1
  local _bucket
  if [[ -n "$FLUX_PRIMARY_DVC_REMOTE" ]]; then
    _bucket="$FLUX_PRIMARY_DVC_REMOTE"
  else
    _bucket="${FLUX_DVC_REMOTES[0]%%:*}"
  fi
  [[ -n "$(_kc_get_dvc "$_bucket" 'access-key-id')" ]] || return 1
  [[ -n "$(_kc_get_dvc "$_bucket" 'secret-key')" ]]    || return 1
}

_flux_require_git_remote() {
  git remote get-url origin &>/dev/null \
    || fail "No git remote configured. Run: git remote add origin <url>"
  git rev-parse --abbrev-ref --symbolic-full-name '@{u}' &>/dev/null \
    || fail "No upstream branch set. Run: git push -u origin $(git branch --show-current 2>/dev/null || echo '<branch>')"
}

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------

_flux_help() {
  clear 2>/dev/null || true
  cat <<'EOF'
flux - Git + DVC auto-router for Cloudflare R2

Usage:
  flux                         Sync both ways (pull then push)
  flux add                     Opt current project into sync
  flux list                    List flux projects; shows pins when inside a project
  flux clone <git-url>         Clone a flux-managed repo and wire up DVC + credentials
  flux remove [git|dvc]        Remove all flux traces, or only git config, or only DVC
  flux pull                    Download the latest (git pull + dvc pull)
  flux dry-run                 Preview routing (staged files, or all tracked if none staged)
  flux cap [N|--reset]         Show, reset or set per-project size cap to [N] (MB)
  flux pin [dvc|git|reset]     Pin current directory to dvc or git; reset removes pin
  flux pin reset --all         Clear all directory pins

Maintenance:
  flux config           Configure flux (set up or manage global settings)
  flux doctor           Run environment diagnostics
  flux version          Show version

Companion tools:
  cbox help             claudebox — Claude Code container runtime
  cdot help             claudedot — Config + history sync across machines

Help:
  flux help
  flux --help
  flux -h
EOF
}

# ---------------------------------------------------------------------------
# Sanitize a folder name into a valid git repo name
# ---------------------------------------------------------------------------

_flux_sanitize_repo_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]._-'
}

# ---------------------------------------------------------------------------
# config — set up if unconfigured, manage if configured
# ---------------------------------------------------------------------------

_flux_config() {
  _flux_require_macos
  clear 2>/dev/null || true

  # ── helpers (defined globally when _flux_config runs) ─────────────────────

  _cfg_dvc_str() {
    local _s=""
    for _e in "${FLUX_DVC_REMOTES[@]}"; do _s+="${_e}"$'\n'; done
    echo "$_s"
  }

  _cfg_git_str() {
    local _s=""
    for _e in "${FLUX_GIT_ACCOUNTS[@]}"; do _s+="${_e}"$'\n'; done
    echo "$_s"
  }

  _cfg_save() {
    if [[ -z "$FLUX_PRIMARY_DVC_REMOTE" ]] && [[ "${#FLUX_DVC_REMOTES[@]}" -gt 0 ]]; then
      FLUX_PRIMARY_DVC_REMOTE="${FLUX_DVC_REMOTES[0]%%:*}"
    fi
    _flux_write_config "$(_cfg_dvc_str)" "${FLUX_SIZE_CAP_MB:-5}" "${FLUX_VERBOSE:-false}" "$(_cfg_git_str)" "$FLUX_PRIMARY_DVC_REMOTE" "${FLUX_AWS_CONFIG_FILE:-}"
    ok "Config saved: $FLUX_CONFIG"
  }

  _cfg_show_dvc() {
    echo "  DVC remotes:"
    if [[ "${#FLUX_DVC_REMOTES[@]}" -eq 0 ]]; then
      echo "    (none)"
    else
      local _i=1
      for _e in "${FLUX_DVC_REMOTES[@]}"; do
        local _b="${_e%%:*}" _cred_badge _primary_mark=""
        local _ak _sk
        _ak=$(_kc_get_dvc "$_b" "access-key-id")
        _sk=$(_kc_get_dvc "$_b" "secret-key")
        if [[ -n "$_ak" && -n "$_sk" ]]; then
          _cred_badge="${GREEN}[✔]${NC}"
        else
          _cred_badge="${YELLOW}[✘ credentials missing]${NC}"
        fi
        if [[ "${#FLUX_DVC_REMOTES[@]}" -gt 1 ]] && \
           { [[ "$_b" == "$FLUX_PRIMARY_DVC_REMOTE" ]] || \
             [[ -z "$FLUX_PRIMARY_DVC_REMOTE" && $_i -eq 1 ]]; }; then
          _primary_mark="  [← primary]"
        fi
        printf "    %d. %s  " "$_i" "$_e"
        echo -e "${_cred_badge}${_primary_mark}"
        (( _i++ ))
      done
    fi
  }

  _cfg_show_git() {
    echo "  Git accounts:"
    if [[ "${#FLUX_GIT_ACCOUNTS[@]}" -eq 0 ]]; then
      echo "    (none)"
    else
      local _i=1
      for _e in "${FLUX_GIT_ACCOUNTS[@]}"; do
        local _proto="${_e%%:*}" _rest="${_e#*:}"
        local _host="${_rest%%:*}" _account="${_rest#*:}"
        local _badge
        if [[ ( "$_proto" == "ssh" || "$_proto" == "https" ) && \
              -n "$_host" && -n "$_account" ]]; then
          _badge="${GREEN}[✔]${NC}"
        else
          _badge="${YELLOW}[✘ incomplete]${NC}"
        fi
        printf "    %d. %s  " "$_i" "$_e"
        echo -e "${_badge}"
        (( _i++ ))
      done
    fi
  }

  _cfg_prompt_dvc() {
    # Prompts for a DVC remote entry. Uses $1 $2 as current bucket/account_id.
    # Sets globals: _DVC_BUCKET _DVC_ACCOUNT_ID _DVC_ACCESS_KEY _DVC_SECRET_KEY
    _flux_prompt_value "Bucket"        "${1:-}" false; _DVC_BUCKET="$FLUX_VALUE"
    _flux_prompt_value "Account ID"    "${2:-}" false; _DVC_ACCOUNT_ID="$FLUX_VALUE"
    _flux_prompt_value "Access Key ID" ""       false; _DVC_ACCESS_KEY="$FLUX_VALUE"
    _flux_prompt_value "Secret Key"    ""       true;  _DVC_SECRET_KEY="$FLUX_VALUE"
  }

  _cfg_prompt_git() {
    # Prompts for a git account entry. Uses $1 $2 $3 as current proto/host/account.
    # Sets global: _GIT_ENTRY
    local _p
    while true; do
      _flux_prompt_value "Protocol (ssh/https)" "${1:-ssh}" false; _p="$FLUX_VALUE"
      [[ "$_p" == "ssh" || "$_p" == "https" ]] && break
      warn "Protocol must be 'ssh' or 'https'."
    done
    _flux_prompt_value "Host"    "${2:-github.com}" false; local _h="$FLUX_VALUE"
    _flux_prompt_value "Account" "${3:-}"           false; local _a="$FLUX_VALUE"
    _GIT_ENTRY="${_p}:${_h}:${_a}"
  }

  # ── load current state ────────────────────────────────────────────────────

  FLUX_DVC_REMOTES=()
  FLUX_GIT_ACCOUNTS=()
  FLUX_PRIMARY_DVC_REMOTE=""
  FLUX_SIZE_CAP_MB=5
  FLUX_VERBOSE=false

  if [[ -f "$FLUX_CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$FLUX_CONFIG" 2>/dev/null || true
  fi

  # ── detect legacy format ──────────────────────────────────────────────────

  local _legacy=false
  if [[ -n "${FLUX_R2_BUCKET:-}" ]] && [[ "${#FLUX_DVC_REMOTES[@]}" -eq 0 ]]; then
    _legacy=true
  fi

  # ── decide: setup or manage ───────────────────────────────────────────────

  local _has_creds=false
  if [[ "${#FLUX_DVC_REMOTES[@]}" -gt 0 ]]; then
    local _b="${FLUX_DVC_REMOTES[0]%%:*}"
    [[ -n "$(_kc_get_dvc "$_b" 'access-key-id')" ]] && _has_creds=true
  fi

  if [[ "$_legacy" == "true" ]] || [[ "${#FLUX_DVC_REMOTES[@]}" -eq 0 ]] || [[ "$_has_creds" == "false" ]]; then

    # ── not configured (or legacy): full setup ────────────────────────────
    echo ""
    if [[ "$_legacy" == "true" ]]; then
      warn "Legacy config detected. Re-configuring in new multi-account format."
      echo ""
      FLUX_DVC_REMOTES=()
      FLUX_GIT_ACCOUNTS=()
    else
      echo "  flux is not configured. Let's set it up:"
      echo ""
    fi

    # Stash existing entries before resetting; they are preserved below and
    # never silently discarded — only missing credentials are prompted for.
    local _preset_dvc=("${FLUX_DVC_REMOTES[@]}") _preset_git=("${FLUX_GIT_ACCOUNTS[@]}")
    FLUX_DVC_REMOTES=()
    FLUX_GIT_ACCOUNTS=()

    echo "  ── DVC remotes (Cloudflare R2) ──────────────────────────────────────────"
    echo ""

    if [[ "${#_preset_dvc[@]}" -gt 0 ]]; then
      # Preserve all existing entries; only prompt for missing credentials or new entries.
      FLUX_DVC_REMOTES=("${_preset_dvc[@]}")
      echo "  Existing DVC remotes:"
      local _pi=0
      for _pe in "${_preset_dvc[@]}"; do
        local _pb="${_pe%%:*}" _pa="${_pe#*:}"
        local _cst; [[ -n "$(_kc_get_dvc "$_pb" 'access-key-id')" ]] && _cst="credentials OK" || _cst="credentials MISSING"
        printf "    %d. %-28s account: %s  (%s)\n" "$(( _pi + 1 ))" "$_pb" "$_pa" "$_cst"
        (( ++_pi ))
      done
      echo ""
      _pi=0
      for _pe in "${_preset_dvc[@]}"; do
        local _pb="${_pe%%:*}"
        if [[ -z "$(_kc_get_dvc "$_pb" 'access-key-id')" ]]; then
          local _fix; read -rp "  Entry $(( _pi + 1 )) ('$_pb') is missing credentials. Enter them now? [Y/n]: " _fix || true
          if [[ ! "${_fix:-Y}" =~ ^[Nn]$ ]]; then
            echo ""
            _flux_prompt_value "Access Key ID" "" false; local _ak="$FLUX_VALUE"
            _flux_prompt_value "Secret Key"    "" true;  local _sk="$FLUX_VALUE"
            if [[ -n "$_ak" && -n "$_sk" ]]; then
              _kc_set_dvc "$_pb" "access-key-id" "$_ak"
              _kc_set_dvc "$_pb" "secret-key"    "$_sk"
              ok "Credentials saved for '${_pb}'."
            else
              warn "Credentials not updated — both fields are required."
            fi
            echo ""
          fi
        fi
        (( ++_pi ))
      done
      local _more; read -rp "  Add another DVC remote? [y/N]: " _more || true
      if [[ "${_more:-N}" =~ ^[Yy]$ ]]; then
        echo ""
        while true; do
          _cfg_prompt_dvc
          if [[ -z "$_DVC_BUCKET" ]]; then
            warn "Bucket is required."; continue
          fi
          [[ -n "$_DVC_ACCOUNT_ID"  ]] || { warn "Account ID is required."; continue; }
          [[ -n "$_DVC_ACCESS_KEY"  ]] || { warn "Access Key ID is required."; continue; }
          [[ -n "$_DVC_SECRET_KEY"  ]] || { warn "Secret Key is required."; continue; }
          FLUX_DVC_REMOTES+=("${_DVC_BUCKET}:${_DVC_ACCOUNT_ID}")
          _kc_set_dvc "$_DVC_BUCKET" "access-key-id" "$_DVC_ACCESS_KEY"
          _kc_set_dvc "$_DVC_BUCKET" "secret-key"    "$_DVC_SECRET_KEY"
          ok "DVC remote '${_DVC_BUCKET}' saved."
          echo ""
          local _more2; read -rp "  Add another DVC remote? [y/N]: " _more2 || true
          [[ "${_more2:-N}" =~ ^[Yy]$ ]] || break
          echo ""
        done
      fi
    else
      while true; do
        _cfg_prompt_dvc
        if [[ -z "$_DVC_BUCKET" ]]; then
          warn "Bucket is required."; continue
        fi
        [[ -n "$_DVC_ACCOUNT_ID"  ]] || { warn "Account ID is required."; continue; }
        [[ -n "$_DVC_ACCESS_KEY"  ]] || { warn "Access Key ID is required."; continue; }
        [[ -n "$_DVC_SECRET_KEY"  ]] || { warn "Secret Key is required."; continue; }
        FLUX_DVC_REMOTES+=("${_DVC_BUCKET}:${_DVC_ACCOUNT_ID}")
        _kc_set_dvc "$_DVC_BUCKET" "access-key-id" "$_DVC_ACCESS_KEY"
        _kc_set_dvc "$_DVC_BUCKET" "secret-key"    "$_DVC_SECRET_KEY"
        ok "DVC remote '${_DVC_BUCKET}' saved."
        echo ""
        local _more; read -rp "  Add another DVC remote? [y/N]: " _more || true
        [[ "${_more:-N}" =~ ^[Yy]$ ]] || break
        echo ""
      done
    fi

    echo ""
    echo "  ── Routing ──────────────────────────────────────────────────────────────"
    echo ""
    while true; do
      _flux_prompt_value "Size cap MB" "${FLUX_SIZE_CAP_MB:-5}" false
      [[ "$FLUX_VALUE" =~ ^[1-9][0-9]*$ ]] && { FLUX_SIZE_CAP_MB="$FLUX_VALUE"; break; }
      warn "Size cap must be a positive integer."
    done
    while true; do
      _flux_prompt_value "Verbose (true/false)" "${FLUX_VERBOSE:-false}" false
      [[ "$FLUX_VALUE" == "true" || "$FLUX_VALUE" == "false" ]] && { FLUX_VERBOSE="$FLUX_VALUE"; break; }
      warn "Verbose must be 'true' or 'false'."
    done

    echo ""
    echo "  ── Git accounts (optional) ──────────────────────────────────────────────"
    echo "  Used to propose git remote URLs during 'flux add'."
    echo ""

    if [[ "${#_preset_git[@]}" -gt 0 ]]; then
      # Preserve all existing entries; offer to add new ones.
      FLUX_GIT_ACCOUNTS=("${_preset_git[@]}")
      echo "  Existing git accounts (all preserved):"
      local _gi=1
      for _ge in "${_preset_git[@]}"; do
        printf "    %d. %s\n" "$_gi" "$_ge"
        (( _gi++ ))
      done
      echo ""
      local _more; read -rp "  Add another git account? [y/N]: " _more || true
      if [[ "${_more:-N}" =~ ^[Yy]$ ]]; then
        echo ""
        while true; do
          _cfg_prompt_git
          local _acct="${_GIT_ENTRY##*:}"
          [[ -z "$_acct" ]] && break
          FLUX_GIT_ACCOUNTS+=("$_GIT_ENTRY")
          ok "Git account '${_GIT_ENTRY}' added."
          echo ""
          local _more2; read -rp "  Add another git account? [y/N]: " _more2 || true
          [[ "${_more2:-N}" =~ ^[Yy]$ ]] || break
          echo ""
        done
      fi
    else
      while true; do
        _cfg_prompt_git
        local _acct="${_GIT_ENTRY##*:}"
        [[ -z "$_acct" ]] && break
        FLUX_GIT_ACCOUNTS+=("$_GIT_ENTRY")
        ok "Git account '${_GIT_ENTRY}' added."
        echo ""
        local _more; read -rp "  Add another git account? [y/N]: " _more || true
        [[ "${_more:-N}" =~ ^[Yy]$ ]] || break
        echo ""
      done
    fi

    echo ""
    _cfg_save
    echo ""

  else

    # ── already configured: manage ────────────────────────────────────────
    local _subcmd _subarg _idx _entry _old _bucket

    while true; do
      clear 2>/dev/null || true
      echo ""
      echo "  flux config  —  ${FLUX_CONFIG}"
      echo ""
      _cfg_show_dvc
      echo ""
      _cfg_show_git
      echo ""
      printf "  Routing: %s MB  verbose: %s\n" "${FLUX_SIZE_CAP_MB:-5}" "${FLUX_VERBOSE:-false}"
      echo ""
      local _choice
      read -rp "  [d] DVC remotes   [g] Git accounts   [o] Routing   [r] Remove all   Enter to exit: " _choice || true
      echo ""

      case "${_choice:-}" in

        d|D)
          while true; do
            clear 2>/dev/null || true
            echo ""
            _cfg_show_dvc
            echo ""
            local _sub _dvc_n="${#FLUX_DVC_REMOTES[@]}"
            if (( _dvc_n == 0 )); then
              read -rp "  [a] Add   Enter to go back: " _sub || true
            elif (( _dvc_n == 1 )); then
              read -rp "  [a] Add   [e] Edit   [r] Remove   Enter to go back: " _sub || true
            else
              read -rp "  [a] Add   [e #] Edit   [r #] Remove   [p #] Set primary   Enter to go back: " _sub || true
            fi
            echo ""
            _subcmd="${_sub%% *}"; _subarg="${_sub#* }"
            [[ "$_subcmd" == "$_subarg" ]] && _subarg=""
            case "$_subcmd" in
              a|A)
                echo ""
                _cfg_prompt_dvc
                if [[ -n "$_DVC_BUCKET" && -n "$_DVC_ACCESS_KEY" ]]; then
                  FLUX_DVC_REMOTES+=("${_DVC_BUCKET}:${_DVC_ACCOUNT_ID}")
                  _kc_set_dvc "$_DVC_BUCKET" "access-key-id" "$_DVC_ACCESS_KEY"
                  _kc_set_dvc "$_DVC_BUCKET" "secret-key"    "$_DVC_SECRET_KEY"
                  _cfg_save
                else
                  warn "Skipped — bucket and credentials required."
                fi ;;
              e|E)
                [[ -z "$_subarg" && _dvc_n -eq 1 ]] && _subarg="1"
                if [[ "$_subarg" =~ ^[0-9]+$ ]]; then
                  _idx=$(( _subarg - 1 ))
                  if (( _idx >= 0 && _idx < ${#FLUX_DVC_REMOTES[@]} )); then
                    _old="${FLUX_DVC_REMOTES[$_idx]}"
                    echo ""
                    _cfg_prompt_dvc "${_old%%:*}" "${_old#*:}"
                    if [[ -n "$_DVC_BUCKET" ]]; then
                      if [[ "${_old%%:*}" != "$_DVC_BUCKET" ]]; then
                        _kc_del_dvc "${_old%%:*}" "access-key-id"
                        _kc_del_dvc "${_old%%:*}" "secret-key"
                        [[ "$FLUX_PRIMARY_DVC_REMOTE" == "${_old%%:*}" ]] && FLUX_PRIMARY_DVC_REMOTE="$_DVC_BUCKET"
                      fi
                      FLUX_DVC_REMOTES[$_idx]="${_DVC_BUCKET}:${_DVC_ACCOUNT_ID}"
                      [[ -n "$_DVC_ACCESS_KEY" ]] && _kc_set_dvc "$_DVC_BUCKET" "access-key-id" "$_DVC_ACCESS_KEY"
                      [[ -n "$_DVC_SECRET_KEY" ]] && _kc_set_dvc "$_DVC_BUCKET" "secret-key"    "$_DVC_SECRET_KEY"
                      _cfg_save
                    fi
                  else warn "Invalid index."; fi
                else warn "Usage: e #  (e.g. 'e 2')"; fi ;;
              r|R)
                [[ -z "$_subarg" && _dvc_n -eq 1 ]] && _subarg="1"
                if [[ "$_subarg" =~ ^[0-9]+$ ]]; then
                  _idx=$(( _subarg - 1 ))
                  if (( _idx >= 0 && _idx < ${#FLUX_DVC_REMOTES[@]} )); then
                    _bucket="${FLUX_DVC_REMOTES[$_idx]%%:*}"
                    FLUX_DVC_REMOTES=( "${FLUX_DVC_REMOTES[@]:0:$_idx}" "${FLUX_DVC_REMOTES[@]:$((_idx+1))}" )
                    _kc_del_dvc "$_bucket" "access-key-id"
                    _kc_del_dvc "$_bucket" "secret-key"
                    [[ "$FLUX_PRIMARY_DVC_REMOTE" == "$_bucket" ]] && FLUX_PRIMARY_DVC_REMOTE=""
                    _cfg_save
                    ok "Removed DVC remote '${_bucket}'."
                  else warn "Invalid index."; fi
                else warn "Usage: r #  (e.g. 'r 2')"; fi ;;
              p|P)
                if [[ "$_subarg" =~ ^[0-9]+$ ]]; then
                  _idx=$(( _subarg - 1 ))
                  if (( _idx >= 0 && _idx < ${#FLUX_DVC_REMOTES[@]} )); then
                    FLUX_PRIMARY_DVC_REMOTE="${FLUX_DVC_REMOTES[$_idx]%%:*}"
                    _cfg_save
                    ok "Primary DVC remote set to '${FLUX_PRIMARY_DVC_REMOTE}'."
                  else warn "Invalid index."; fi
                else warn "Usage: p #  (e.g. 'p 2')"; fi ;;
              "") break ;;
              *) warn "Unknown command." ;;
            esac
          done ;;

        g|G)
          while true; do
            clear 2>/dev/null || true
            echo ""
            _cfg_show_git
            echo ""
            local _sub _git_n="${#FLUX_GIT_ACCOUNTS[@]}"
            if (( _git_n == 0 )); then
              read -rp "  [a] Add   Enter to go back: " _sub || true
            elif (( _git_n == 1 )); then
              read -rp "  [a] Add   [e] Edit   [r] Remove   Enter to go back: " _sub || true
            else
              read -rp "  [a] Add   [e #] Edit   [r #] Remove   Enter to go back: " _sub || true
            fi
            echo ""
            _subcmd="${_sub%% *}"; _subarg="${_sub#* }"
            [[ "$_subcmd" == "$_subarg" ]] && _subarg=""
            case "$_subcmd" in
              a|A)
                echo ""
                _cfg_prompt_git
                if [[ -n "${_GIT_ENTRY##*:}" ]]; then
                  FLUX_GIT_ACCOUNTS+=("$_GIT_ENTRY")
                  _cfg_save
                else
                  warn "Skipped — account is required."
                fi ;;
              e|E)
                [[ -z "$_subarg" && _git_n -eq 1 ]] && _subarg="1"
                if [[ "$_subarg" =~ ^[0-9]+$ ]]; then
                  _idx=$(( _subarg - 1 ))
                  if (( _idx >= 0 && _idx < ${#FLUX_GIT_ACCOUNTS[@]} )); then
                    _old="${FLUX_GIT_ACCOUNTS[$_idx]}"
                    local _op="${_old%%:*}" _or="${_old#*:}"
                    echo ""
                    _cfg_prompt_git "$_op" "${_or%%:*}" "${_or#*:}"
                    if [[ -n "${_GIT_ENTRY##*:}" ]]; then
                      FLUX_GIT_ACCOUNTS[$_idx]="$_GIT_ENTRY"
                      _cfg_save
                    fi
                  else warn "Invalid index."; fi
                else warn "Usage: e #  (e.g. 'e 2')"; fi ;;
              r|R)
                [[ -z "$_subarg" && _git_n -eq 1 ]] && _subarg="1"
                if [[ "$_subarg" =~ ^[0-9]+$ ]]; then
                  _idx=$(( _subarg - 1 ))
                  if (( _idx >= 0 && _idx < ${#FLUX_GIT_ACCOUNTS[@]} )); then
                    local _removed="${FLUX_GIT_ACCOUNTS[$_idx]}"
                    FLUX_GIT_ACCOUNTS=( "${FLUX_GIT_ACCOUNTS[@]:0:$_idx}" "${FLUX_GIT_ACCOUNTS[@]:$((_idx+1))}" )
                    _cfg_save
                    ok "Removed git account '${_removed}'."
                  else warn "Invalid index."; fi
                else warn "Usage: r #  (e.g. 'r 2')"; fi ;;
              "") break ;;
              *) warn "Unknown command." ;;
            esac
          done ;;

        o|O)
          clear 2>/dev/null || true
          echo ""
          while true; do
            _flux_prompt_value "Size cap MB" "${FLUX_SIZE_CAP_MB:-5}" false
            [[ "$FLUX_VALUE" =~ ^[1-9][0-9]*$ ]] && { FLUX_SIZE_CAP_MB="$FLUX_VALUE"; break; }
            warn "Size cap must be a positive integer."
          done
          while true; do
            _flux_prompt_value "Verbose (true/false)" "${FLUX_VERBOSE:-false}" false
            [[ "$FLUX_VALUE" == "true" || "$FLUX_VALUE" == "false" ]] && { FLUX_VERBOSE="$FLUX_VALUE"; break; }
            warn "Verbose must be 'true' or 'false'."
          done
          echo ""
          _cfg_save ;;

        r|R)
          clear 2>/dev/null || true
          local _confirm
          read -rp "  Remove all flux config and credentials? [y/N]: " _confirm || true
          if [[ "${_confirm:-}" =~ ^[Yy]$ ]]; then
            for _entry in "${FLUX_DVC_REMOTES[@]}"; do
              _bucket="${_entry%%:*}"
              _kc_del_dvc "$_bucket" "access-key-id"
              _kc_del_dvc "$_bucket" "secret-key"
            done
            rm -f "$FLUX_CONFIG"
            ok "Config and all credentials removed."
          else
            echo "  Cancelled."
          fi
          break ;;

        "") break ;;
      esac
    done
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# Sub-repo management — detect nested git repos and maintain .gitignore exclusions
# ---------------------------------------------------------------------------

_flux_scan_subrepos() {
  # Outputs newline-separated relative paths to top-level nested git repo roots.
  # "Top-level" means not nested inside another discovered sub-repo.
  local root_dir
  root_dir=$(git rev-parse --show-toplevel 2>/dev/null) || return 0

  local all=()
  while IFS= read -r gitdir; do
    [[ -n "$gitdir" ]] && all+=("${gitdir%/.git}")
  done < <(find "$root_dir" -mindepth 2 -name ".git" -type d \
             -not -path '*/.git/*' 2>/dev/null | sort)

  # Keep only paths not nested inside another found sub-repo
  local result=()
  for path in "${all[@]}"; do
    local nested=false
    for other in "${all[@]}"; do
      [[ "$path" == "$other" ]] && continue
      [[ "$path" == "$other/"* ]] && nested=true && break
    done
    [[ "$nested" == "false" ]] && result+=("${path#${root_dir}/}")
  done

  (( ${#result[@]} > 0 )) && printf '%s\n' "${result[@]}"
  return 0
}

_flux_subrepo_sync() {
  # Diffs live sub-repo scan against registry; adds/removes .gitignore entries.
  # Sets FLUX_SUBREPO_CHANGED=true when any modification is made.
  FLUX_SUBREPO_CHANGED=false
  git rev-parse --show-toplevel &>/dev/null || return 0
  local root_dir
  root_dir=$(git rev-parse --show-toplevel)

  local current=()
  while IFS= read -r p; do [[ -n "$p" ]] && current+=("$p"); done \
    < <(_flux_scan_subrepos)

  local previous=()
  while IFS= read -r p; do [[ -n "$p" ]] && previous+=("$p"); done \
    < <(_flux_registry_read subrepo_exclusion)

  local appeared=()
  for p in "${current[@]}"; do
    local found=false
    for q in "${previous[@]}"; do [[ "$p" == "$q" ]] && found=true && break; done
    [[ "$found" == "false" ]] && appeared+=("$p")
  done

  local disappeared=()
  for p in "${previous[@]}"; do
    local found=false
    for q in "${current[@]}"; do [[ "$p" == "$q" ]] && found=true && break; done
    [[ "$found" == "false" ]] && disappeared+=("$p")
  done

  local gitignore="${root_dir}/.gitignore"

  for path in "${appeared[@]}"; do
    local tracked
    tracked=$(git ls-files -- "$path" 2>/dev/null || true)
    if [[ -n "$tracked" ]]; then
      git rm --cached -r --quiet -- "$path" 2>/dev/null || true
      warn "Un-tracked '${path}/' from workspace git (new sub-repo detected)."
    fi
    touch "$gitignore"
    grep -qxF "${path}/" "$gitignore" 2>/dev/null || echo "${path}/" >> "$gitignore"
    _flux_registry_write subrepo_exclusion "$path"
    ok "Sub-repo detected: ${path}/ → excluded from workspace git."
    FLUX_SUBREPO_CHANGED=true
  done

  for path in "${disappeared[@]}"; do
    if [[ -f "$gitignore" ]] && grep -qxF "${path}/" "$gitignore" 2>/dev/null; then
      local tmp; tmp=$(mktemp)
      grep -vxF "${path}/" "$gitignore" > "$tmp" || true
      mv "$tmp" "$gitignore"
    fi
    _flux_registry_delete subrepo_exclusion "$path"
    warn "Sub-repo removed: ${path}/ → files now visible to workspace git."
    FLUX_SUBREPO_CHANGED=true
  done
}

# ---------------------------------------------------------------------------
# push upstream — probe remote, create if needed, set tracking branch
# ---------------------------------------------------------------------------

_flux_try_push_upstream() {
  local _remote_url="$1"
  local _branch
  _branch=$(git branch --show-current 2>/dev/null || echo "main")

  local _is_github=false _has_gh=false
  local _is_gitlab=false _has_glab=false
  [[ "$_remote_url" == *"github.com"* ]] && _is_github=true
  [[ "$_remote_url" == *"gitlab.com"* ]] && _is_gitlab=true
  command -v gh   &>/dev/null && _has_gh=true
  command -v glab &>/dev/null && _has_glab=true

  echo ""
  if ! git ls-remote origin &>/dev/null 2>&1; then
    if [[ "$_is_github" == "true" && "$_has_gh" == "true" ]]; then
      local _slug
      _slug=$(echo "$_remote_url" | sed 's|.*github\.com[:/]\(.*\)\.git$|\1|; s|.*github\.com[:/]\(.*\)$|\1|')
      local _vis
      read -rp "  Create GitHub repo '${_slug}' as private or public? [private]: " _vis || true
      local _vis_flag="--private"
      [[ "${_vis:-}" == "public" ]] && _vis_flag="--public"
      local _gh_err=""
      if _gh_err=$(gh repo create "$_slug" "$_vis_flag" 2>&1); then
        ok "GitHub repo created: ${_slug}"
      else
        warn "Could not create GitHub repo: ${_gh_err}"
        warn "  Check: gh auth status"
        warn "  Then run: git push -u origin ${_branch}"
        return
      fi
    elif [[ "$_is_github" == "true" && "$_has_gh" == "false" ]]; then
      warn "Remote repo not found. Create it on GitHub first, then:"
      warn "  git push -u origin ${_branch}"
      warn "  Tip: install the GitHub CLI (gh) to automate repo creation."
      return
    elif [[ "$_is_gitlab" == "true" && "$_has_glab" == "true" ]]; then
      local _slug
      _slug=$(echo "$_remote_url" | sed 's|.*gitlab\.com[:/]\(.*\)\.git$|\1|; s|.*gitlab\.com[:/]\(.*\)$|\1|')
      local _vis
      read -rp "  Create GitLab repo '${_slug}' as private or public? [private]: " _vis || true
      local _vis_flag="--private"
      [[ "${_vis:-}" == "public" ]] && _vis_flag="--public"
      local _glab_err=""
      if _glab_err=$(glab repo create "$_slug" "$_vis_flag" 2>&1); then
        ok "GitLab repo created: ${_slug}"
      else
        warn "Could not create GitLab repo: ${_glab_err}"
        warn "  Check: glab auth status"
        warn "  Then run: git push -u origin ${_branch}"
        return
      fi
    elif [[ "$_is_gitlab" == "true" && "$_has_glab" == "false" ]]; then
      warn "Remote repo not reachable. Create it on GitLab first, then:"
      warn "  git push -u origin ${_branch}"
      warn "  Tip: install the GitLab CLI (glab) to automate repo creation."
      return
    else
      warn "Remote repo not reachable. Create it, then: git push -u origin ${_branch}"
      return
    fi
  fi

  if git push -u origin HEAD 2>/dev/null; then
    ok "Upstream set: ${_branch} → origin/${_branch}"
  else
    warn "Push failed. Set upstream manually: git push -u origin ${_branch}"
  fi
}

# ---------------------------------------------------------------------------
# add — add flux to the current repository
# ---------------------------------------------------------------------------

_flux_add() {
  _flux_require_macos
  clear 2>/dev/null || true

  echo ""
  echo "  flux ${VERSION} — add"
  echo ""

  _flux_is_configured \
    || fail "Not configured. Run 'flux config' to set up."

  # ── already-initialized check ──────────────────────────────────────────────
  if _flux_is_repo_initialized; then
    local _r2_folder _bucket _remote
    _r2_folder=$(git config --get flux.r2-folder 2>/dev/null || echo "")
    _bucket=$(git config --get flux.dvc-remote-bucket 2>/dev/null || echo "")
    _remote=$(git remote get-url origin 2>/dev/null || echo "(none)")
    echo ""
    ok "This project is already managed by flux."
    echo ""
    [[ -n "$_r2_folder" ]] && echo "  R2 folder:   ${_r2_folder}"
    [[ -n "$_bucket"    ]] && echo "  DVC bucket:  ${_bucket}"
    echo "  Git remote:  ${_remote}"
    echo ""
    _flux_subrepo_sync
    if [[ "${FLUX_SUBREPO_CHANGED}" == "true" ]]; then
      git add -A 2>/dev/null || true
      if ! git diff --cached --quiet 2>/dev/null; then
        git commit --quiet -m "chore: sync sub-repo exclusions"
      fi
    fi
    echo "  Run 'flux remove' to detach, or 'flux doctor' to check the setup."
    echo ""
    return 0
  fi
  # ───────────────────────────────────────────────────────────────────────────

  local DVC; _flux_require_dvc

  # Values available after _flux_is_configured sourced flux.env
  local cap="${FLUX_SIZE_CAP_MB:-5}"
  local verbose="${FLUX_VERBOSE:-false}"

  # Select DVC remote
  local chosen_bucket chosen_account_id chosen_access_key chosen_secret_key
  if [[ "${#FLUX_DVC_REMOTES[@]}" -eq 1 ]]; then
    local _e="${FLUX_DVC_REMOTES[0]}"
    chosen_bucket="${_e%%:*}"; chosen_account_id="${_e#*:}"
  else
    echo "  Available DVC remotes:"
    local _i=1
    for _e in "${FLUX_DVC_REMOTES[@]}"; do
      printf "    %d. %s\n" "$_i" "${_e%%:*}"
      (( _i++ ))
    done
    echo ""
    local _pick _n="${#FLUX_DVC_REMOTES[@]}"
    while true; do
      read -rp "  Select DVC remote [1]: " _pick || true
      _pick="${_pick:-1}"
      if [[ "$_pick" =~ ^[0-9]+$ ]] && (( _pick >= 1 && _pick <= _n )); then
        break
      fi
      warn "Invalid selection — enter a number between 1 and ${_n}."
    done
    local _sel="${FLUX_DVC_REMOTES[$(( _pick - 1 ))]}"
    chosen_bucket="${_sel%%:*}"; chosen_account_id="${_sel#*:}"
    echo ""
  fi
  chosen_access_key=$(_kc_get_dvc "$chosen_bucket" "access-key-id")
  chosen_secret_key=$(_kc_get_dvc "$chosen_bucket" "secret-key")
  [[ -n "$chosen_access_key" ]] \
    || fail "No credentials found for DVC remote '${chosen_bucket}'. Run 'flux config'."

  ok "Config: $FLUX_CONFIG"
  ok "DVC remote: ${chosen_bucket}"

  if ! git rev-parse --git-dir &>/dev/null; then
    git init --quiet
    _flux_registry_write git_initialized true
    ok "Git repository initialised."
  else
    ok "Git repository found."
  fi

  # Capture pre-staged files before subrepo sync so that git rm --cached
  # operations performed by subrepo cleanup do not appear as user-staged changes.
  local _pre_staged
  _pre_staged=$(git diff --cached --name-only 2>/dev/null || true)

  _flux_subrepo_sync

  if [[ ! -d .dvc ]]; then
    "$DVC" init --quiet
    _flux_registry_write dvc_initialized true
    ok "DVC initialised."
  else
    ok "DVC already initialised."
  fi

  local FLUX_R2_FOLDER
  FLUX_R2_FOLDER=$(git config --get flux.r2-folder 2>/dev/null || true)
  if [[ -z "$FLUX_R2_FOLDER" ]]; then
    local derived
    derived=$(_flux_sanitize_repo_name "$(basename "$(pwd)")")
    local override
    read -rp "  R2 folder${derived:+ [${derived}]}: " override || true
    if [[ -n "$override" ]]; then
      local _sanitized; _sanitized=$(_flux_sanitize_repo_name "$override")
      [[ "$_sanitized" != "$override" ]] && warn "Name adjusted to: ${_sanitized}"
      FLUX_R2_FOLDER="$_sanitized"
    else
      FLUX_R2_FOLDER="$derived"
    fi
  fi
  [[ -n "$FLUX_R2_FOLDER" ]] \
    || fail "Cannot derive R2 folder — run: git config flux.r2-folder <name>"
  ok "R2 folder: ${FLUX_R2_FOLDER}"

  local R2_ENDPOINT _jur_pick
  read -rp "  R2 jurisdiction: [1] Default  [2] EU  [3] FedRAMP [1]: " _jur_pick || true
  case "${_jur_pick:-1}" in
    2) R2_ENDPOINT="https://${chosen_account_id}.eu.r2.cloudflarestorage.com"
       ok "R2 jurisdiction: EU" ;;
    3) R2_ENDPOINT="https://${chosen_account_id}.fedramp.r2.cloudflarestorage.com"
       ok "R2 jurisdiction: FedRAMP" ;;
    *) R2_ENDPOINT="https://${chosen_account_id}.r2.cloudflarestorage.com"
       ok "R2 jurisdiction: Default (global)" ;;
  esac

  local remote_verb="added"
  grep -q 'r2remote' .dvc/config 2>/dev/null && remote_verb="updated"
  "$DVC" remote add    -f      r2remote "s3://${chosen_bucket}/${FLUX_R2_FOLDER}" --quiet
  "$DVC" remote default        r2remote                                            --quiet
  "$DVC" remote modify         r2remote endpointurl "$R2_ENDPOINT"                --quiet
  "$DVC" remote modify         r2remote region      auto                          --quiet
  _flux_apply_dvc_profile "$DVC"
  _flux_registry_write dvc_remote r2remote
  ok "DVC remote ${remote_verb}: s3://${chosen_bucket}/${FLUX_R2_FOLDER}"

  local existing_project_cap
  existing_project_cap=$(git config --get dvc-router.size-cap-mb 2>/dev/null || true)
  if [[ -z "$existing_project_cap" ]]; then
    git config dvc-router.size-cap-mb "$cap"
    _flux_registry_write git_config dvc-router.size-cap-mb
  else
    cap="$existing_project_cap"
  fi
  git config dvc-router.verbose      "$verbose"
  git config flux.r2-folder          "$FLUX_R2_FOLDER"
  git config flux.dvc-remote-bucket  "$chosen_bucket"
  _flux_registry_write git_config dvc-router.verbose
  _flux_registry_write git_config flux.r2-folder
  _flux_registry_write git_config flux.dvc-remote-bucket

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
    # Check for files the user staged themselves (not DVC/flux-created files)
    local _user_staged=""
    if [[ -n "$_pre_staged" ]]; then
      _user_staged=$(echo "$_pre_staged" | grep -v '^\.dvc/' | grep -v '^\.dvcignore$' || true)
    fi
    local _do_commit=true
    if [[ -n "$_user_staged" ]]; then
      echo ""
      warn "Your staged changes will be included in this commit:"
      echo "$_user_staged" | sed 's/^/    /'
      echo ""
      local confirm
      read -rp "  Commit now? [Y/n]: " confirm || true
      [[ "${confirm:-Y}" =~ ^[Yy]?$ ]] || _do_commit=false
    fi
    if [[ "$_do_commit" == "true" ]]; then
      git commit --quiet -m "chore: initialise DVC with Cloudflare R2 remote"
      ok "DVC configuration committed."
    else
      git rm --cached .dvc/config .gitignore 2>/dev/null || true
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

  # Git remote setup
  local _existing_remote
  _existing_remote=$(git remote get-url origin 2>/dev/null || true)
  if [[ -n "$_existing_remote" ]]; then
    ok "Git remote: ${_existing_remote}"
    if ! git rev-parse --abbrev-ref --symbolic-full-name '@{u}' &>/dev/null; then
      _flux_try_push_upstream "$_existing_remote"
    fi
  else
    local _repo_name; _repo_name="${FLUX_R2_FOLDER}"
    local _proposed_url=""
    if [[ "${#FLUX_GIT_ACCOUNTS[@]}" -eq 0 ]]; then
      local _input
      read -rp "  Git remote URL (optional, Enter to skip): " _input || true
      _proposed_url="${_input:-}"
    elif [[ "${#FLUX_GIT_ACCOUNTS[@]}" -eq 1 ]]; then
      local _e="${FLUX_GIT_ACCOUNTS[0]}"
      local _proto="${_e%%:*}" _rest="${_e#*:}"
      local _host="${_rest%%:*}" _account="${_rest#*:}"
      if [[ "$_proto" == "ssh" ]]; then
        _proposed_url="git@${_host}:${_account}/${_repo_name}.git"
      else
        _proposed_url="https://${_host}/${_account}/${_repo_name}.git"
      fi
      local _override
      read -rp "  Git remote URL [${_proposed_url}]: " _override || true
      [[ -n "$_override" ]] && _proposed_url="$_override"
    else
      echo "  Proposed git remotes:"
      local _i=1
      for _e in "${FLUX_GIT_ACCOUNTS[@]}"; do
        local _proto="${_e%%:*}" _rest="${_e#*:}"
        local _host="${_rest%%:*}" _account="${_rest#*:}" _url
        if [[ "$_proto" == "ssh" ]]; then
          _url="git@${_host}:${_account}/${_repo_name}.git"
        else
          _url="https://${_host}/${_account}/${_repo_name}.git"
        fi
        printf "    %d. %s\n" "$_i" "$_url"
        (( _i++ ))
      done
      echo ""
      local _pick
      read -rp "  Select [1-${#FLUX_GIT_ACCOUNTS[@]}], paste a custom URL, or Enter to skip: " _pick || true
      if [[ -z "$_pick" ]]; then
        _proposed_url=""
      elif [[ "$_pick" =~ ^[0-9]+$ ]] && (( _pick >= 1 && _pick <= ${#FLUX_GIT_ACCOUNTS[@]} )); then
        local _e="${FLUX_GIT_ACCOUNTS[$(( _pick - 1 ))]}"
        local _proto="${_e%%:*}" _rest="${_e#*:}"
        local _host="${_rest%%:*}" _account="${_rest#*:}"
        if [[ "$_proto" == "ssh" ]]; then
          _proposed_url="git@${_host}:${_account}/${_repo_name}.git"
        else
          _proposed_url="https://${_host}/${_account}/${_repo_name}.git"
        fi
      else
        _proposed_url="$_pick"
      fi
    fi
    if [[ -n "$_proposed_url" ]]; then
      git remote add origin "$_proposed_url"
      _flux_registry_write git_remote "$_proposed_url"
      ok "Git remote added: ${_proposed_url}"
      _flux_try_push_upstream "$_proposed_url"
    else
      warn "No git remote set — add later with: git remote add origin <url>"
    fi
  fi

  echo ""
  echo "  flux added. Your workflow:"
  echo ""
  echo "    flux        # commit any changes and push to all remotes"
  echo "    flux pull   # pull the latest from all remotes"
  echo ""
  echo "  For a named commit: git commit -m 'message'  then flux to push."
  echo "  The pre-commit hook routes files automatically on every commit:"
  echo "  large or binary → Cloudflare R2 (DVC), small text → Git."
  echo ""
  echo "  Preview routing before committing: flux dry-run"
  echo ""
}

# ---------------------------------------------------------------------------
# remove git — remove flux's git integration (hook + git config keys)
# ---------------------------------------------------------------------------

_flux_remove_git() {
  git rev-parse --git-dir &>/dev/null || fail "Not inside a Git repository."
  clear 2>/dev/null || true

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
    keys=(flux.r2-folder flux.dvc-remote-bucket dvc-router.size-cap-mb dvc-router.verbose \
          dvc-router.force-dvc dvc-router.force-git)
  fi
  local removed=0
  for key in "${keys[@]}"; do
    if [[ "$key" == dvc-router.force-dvc || "$key" == dvc-router.force-git ]]; then
      if git config --unset-all "$key" 2>/dev/null; then
        _flux_registry_delete git_config "$key"
        (( removed++ )) || true
      fi
    elif git config --unset "$key" 2>/dev/null; then
      _flux_registry_delete git_config "$key"
      (( removed++ )) || true
    fi
  done
  (( removed > 0 )) && ok "Git config entries removed (${removed})." || warn "No flux git config entries found."

  # Remove git remote if flux added it
  local _added_remote
  _added_remote=$(_flux_registry_read git_remote | tail -1)
  if [[ -n "$_added_remote" ]]; then
    local _current_remote
    _current_remote=$(git remote get-url origin 2>/dev/null || true)
    if [[ "$_current_remote" == "$_added_remote" ]]; then
      git remote remove origin
      _flux_registry_delete git_remote "$_added_remote"
      ok "Git remote 'origin' removed."
    else
      warn "Git remote 'origin' was changed after flux added it — not removing."
    fi
  fi

  # Remove sub-repo exclusions flux added to .gitignore
  local excl_paths=()
  while IFS= read -r p; do [[ -n "$p" ]] && excl_paths+=("$p"); done \
    < <(_flux_registry_read subrepo_exclusion)
  local removed_excl=0
  for path in "${excl_paths[@]}"; do
    if [[ -f ".gitignore" ]] && grep -qxF "${path}/" .gitignore 2>/dev/null; then
      local tmp; tmp=$(mktemp)
      grep -vxF "${path}/" .gitignore > "$tmp" || true
      mv "$tmp" .gitignore
    fi
    _flux_registry_delete subrepo_exclusion "$path"
    (( removed_excl++ )) || true
  done
  (( removed_excl > 0 )) && ok "Sub-repo exclusions removed (${removed_excl})."

  if [[ -f ".gitignore" ]] && [[ ! -s ".gitignore" ]]; then
    rm ".gitignore"
    ok ".gitignore removed (empty)."
  fi

  if [[ ! -f "${HOOKS_DIR}/pre-commit" ]] && (( removed == 0 )) && (( removed_excl == 0 )); then
    echo -e "${RED}✘${NC} Not a flux-managed project."
  fi
}

# ---------------------------------------------------------------------------
# remove dvc — thoroughly remove all DVC traces from the current repo
# ---------------------------------------------------------------------------

_flux_remove_dvc() {
  git rev-parse --git-dir &>/dev/null || fail "Not inside a Git repository."
  local force="${1:-}"
  clear 2>/dev/null || true

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

  # Remove *.dvc pointer files from git index and disk.
  # Use git ls-files (not find) so we never touch files inside gitignored
  # sub-repos. Staged-but-uncommitted pointers are included because git ls-files
  # reads the index, not just committed history.
  # Also clean the DVC-written entry from the sibling .gitignore for each pointer,
  # and remove the sibling .gitignore entirely if it becomes empty.
  local -a ptrs=()
  while IFS= read -r line; do [[ -n "$line" ]] && ptrs+=("$line"); done \
    < <(git ls-files | grep '\.dvc$')
  if (( ${#ptrs[@]} > 0 )); then
    for ptr in "${ptrs[@]}"; do
      local _target_rel _ptr_dir _target_name _gi_entry _tmp
      _target_rel=$(grep '^\s*path:' "$ptr" 2>/dev/null \
        | head -1 | sed 's/.*path:[[:space:]]*//' | tr -d '"' | tr -d "'" || true)
      [[ -z "$_target_rel" ]] && continue
      _ptr_dir=$(dirname "$ptr")
      _target_name=$(basename "$_target_rel")
      # Root-level files: DVC writes /basename; non-root: flux writes subdir/file.
      if [[ "$_ptr_dir" == "." ]]; then
        _gi_entry="/$_target_name"
      else
        _gi_entry="${_ptr_dir}/${_target_rel}"
      fi
      if [[ -f ".gitignore" ]] && grep -qxF "$_gi_entry" .gitignore 2>/dev/null; then
        _tmp=$(mktemp)
        grep -vxF "$_gi_entry" .gitignore > "$_tmp" || true
        mv "$_tmp" .gitignore
      fi
    done
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

  # Remove .dvc/ directory only if flux created it
  if [[ "$(_flux_registry_read dvc_initialized)" == "true" ]]; then
    git rm -r --cached -q .dvc/ 2>/dev/null || true
    rm -rf .dvc/
    _flux_registry_delete dvc_initialized true
    ok ".dvc/ directory removed."
  else
    warn ".dvc/ was not created by flux — leaving directory in place."
  fi

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
    if [[ ! -s ".gitignore" ]]; then
      rm ".gitignore"
      ok ".gitignore removed (empty)."
    fi
  fi
}

# ---------------------------------------------------------------------------
# maybe remove .git — offer to remove the repo if flux created it
# ---------------------------------------------------------------------------

_flux_maybe_remove_git_repo() {
  [[ "$(_flux_registry_read git_initialized)" == "true" ]] || return 0

  local _extra_branches _stash_count _commit_count
  _extra_branches=$(git branch 2>/dev/null | grep -v '^\* ' | wc -l | tr -d ' ')
  _stash_count=$(git stash list 2>/dev/null | wc -l | tr -d ' ')
  _commit_count=$(git rev-list --count HEAD 2>/dev/null || echo 0)

  echo ""
  if (( _extra_branches > 0 )); then
    warn "Other branches: ${_extra_branches}"
  fi
  if (( _stash_count > 0 )); then
    warn "Stashed changes: ${_stash_count}"
  fi
  if (( _commit_count > 1 )); then
    warn "Commits in history: ${_commit_count}"
  fi

  local _confirm
  read -rp "  flux created this git repo — remove .git/ too? [Y/n]: " _confirm || true
  if [[ "${_confirm:-Y}" =~ ^[Yy]?$ ]]; then
    local _gitdir
    _gitdir=$(git rev-parse --git-dir 2>/dev/null)
    rm -rf "$_gitdir"
    ok "Git repository removed."
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
      _flux_maybe_remove_git_repo
      echo ""
      warn "Global config and credentials were not touched."
      warn "To remove them too (optional): flux config → [r]"
      echo ""
      ;;
    *)
      fail "Unknown remove target '${sub}'. Usage: flux remove [git|dvc]"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# hook update — silently refresh the pre-commit hook if it is outdated
# Called during sync so repos stay current after brew upgrade flux.
# ---------------------------------------------------------------------------

_flux_hook_update() {
  local _hooks_dir _installed _script_dir _hook_source
  _hooks_dir="$(git rev-parse --git-dir 2>/dev/null)/hooks"
  _installed="${_hooks_dir}/pre-commit"

  [[ -f "$_installed" ]] || return 0
  grep -q 'dvc-router\|flux' "$_installed" 2>/dev/null || return 0

  _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _hook_source="${_script_dir}/../share/flux/pre-commit"
  [[ -f "$_hook_source" ]] || _hook_source="${_script_dir}/pre-commit"
  [[ -f "$_hook_source" ]] || return 0

  if ! cmp -s "$_hook_source" "$_installed"; then
    cp "$_hook_source" "$_installed"
    chmod +x "$_installed"
    warn "Pre-commit hook updated to latest version."
  fi
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
  clear 2>/dev/null || true

  _flux_subrepo_sync
  if [[ "${FLUX_SUBREPO_CHANGED}" == "true" ]]; then
    git add -A 2>/dev/null || true
    if ! git diff --cached --quiet 2>/dev/null; then
      git commit --quiet -m "chore: sync sub-repo exclusions"
    fi
  fi

  [[ -n "${FLUX_AWS_CONFIG_FILE:-}" ]] && export AWS_CONFIG_FILE="$FLUX_AWS_CONFIG_FILE"
  _flux_apply_dvc_profile "$DVC"
  ok "Pulling from Git remote..."; git pull "$@"
  ok "Pulling DVC data from R2..."; "$DVC" pull
}

# ---------------------------------------------------------------------------
# _flux_repair_dvcignore — remove DVC-tracked file patterns from .dvcignore
#
# The pre-commit hook keeps .dvcignore in sync, but on a fresh project or when
# no commit is made, stale patterns can linger. DVC refuses to push files that
# appear in .dvcignore, so this runs defensively before every dvc push.
# ---------------------------------------------------------------------------
_flux_repair_dvcignore() {
  local -a _patterns=()
  while IFS= read -r _ptr; do
    [[ -z "$_ptr" ]] && continue
    local _tracked _dir _base
    _tracked="${_ptr%.dvc}"
    _dir=$(dirname "$_tracked")
    _base=$(basename "$_tracked")
    if [[ "$_dir" == "." ]]; then
      _patterns+=("$_tracked" "/$_tracked")
    else
      _patterns+=("$_tracked" "/$_base" "$_base")
    fi
  done < <(git -c core.quotepath=false ls-files 2>/dev/null | grep -E '\.dvc$' || true)

  (( ${#_patterns[@]} == 0 )) && return 0

  local _fixed=false
  while IFS= read -r _dvcignore; do
    [[ -z "$_dvcignore" || ! -f "$_dvcignore" ]] && continue
    local _before _after
    _before=$(cat "$_dvcignore")
    for _pat in "${_patterns[@]}"; do
      local _tmp; _tmp=$(mktemp)
      grep -vxF "$_pat" "$_dvcignore" > "$_tmp" || true
      mv "$_tmp" "$_dvcignore"
    done
    _after=$(cat "$_dvcignore")
    if [[ "$_before" != "$_after" ]]; then
      git add "$_dvcignore"
      _fixed=true
    fi
  done < <(find . -name ".dvcignore" \
    -not -path "./.git/*" -not -path "./.dvc/*" 2>/dev/null)

  if [[ "$_fixed" == "true" ]]; then
    if ! git diff --cached --quiet 2>/dev/null; then
      git commit --quiet -m "fix: remove DVC-tracked file patterns from .dvcignore"
      warn ".dvcignore had stale entries — fixed automatically."
    fi
  fi
}

# ---------------------------------------------------------------------------
# sync — pull then push (git + dvc)
# ---------------------------------------------------------------------------

_flux_sync() {
  git rev-parse --git-dir &>/dev/null \
    || fail "Not inside a Git repository."
  clear 2>/dev/null || true
  _flux_spin_start "flux syncing..."
  _flux_require_dvc_repo
  _flux_require_git_remote
  _flux_is_configured \
    || fail "Not configured. Run 'flux config' to set up."
  local DVC; _flux_require_dvc

  _flux_hook_update
  _flux_subrepo_sync

  if [[ -n "$(git status --porcelain 2>/dev/null | head -1)" ]]; then
    git add -A
    _flux_spin_stop  # stop before commit so hook output appears cleanly
    git commit --quiet -m "sync: $(date '+%Y-%m-%d %H:%M')"
  else
    _flux_spin_stop
  fi

  _flux_sync_summary

  _flux_spin_start "pulling from Git..."
  if git pull --quiet 2>/dev/null; then
    _flux_spin_stop; ok "Pulled from Git remote."
  else
    _flux_spin_stop; warn "Git pull failed — check remote or resolve conflicts."
  fi

  [[ -n "${FLUX_AWS_CONFIG_FILE:-}" ]] && export AWS_CONFIG_FILE="$FLUX_AWS_CONFIG_FILE"
  _flux_apply_dvc_profile "$DVC"

  local _dvc_err
  _flux_spin_start "pulling DVC data..."
  _dvc_err=$(mktemp)
  if "$DVC" pull --quiet 2>"$_dvc_err"; then
    _flux_spin_stop; ok "Pulled DVC data from R2."
  elif grep -qiE 'AccessDenied|Access Denied' "$_dvc_err" 2>/dev/null; then
    _flux_spin_stop; warn "DVC pull failed — access denied. Check R2 API token permissions (Admin Read & Write required)."
  elif grep -qiE 'Checkout failed|missing-files|do not exist neither' "$_dvc_err" 2>/dev/null; then
    _flux_spin_stop; warn "DVC pull failed — some files missing from remote. Run 'dvc pull' for details."
  elif grep -q . "$_dvc_err" 2>/dev/null; then
    _flux_spin_stop; warn "DVC pull failed — run 'dvc pull' to see the full error."
  else
    _flux_spin_stop; warn "DVC pull skipped — R2 may be empty (first push)."
  fi
  rm -f "$_dvc_err"

  _flux_spin_start "pushing to Git..."
  if git push --quiet 2>/dev/null; then
    _flux_spin_stop; ok "Pushed to Git remote."
  else
    _flux_spin_stop; warn "Git push failed — check remote."
  fi

  _flux_repair_dvcignore

  _flux_spin_start "pushing DVC data..."
  _dvc_err=$(mktemp)
  if "$DVC" push --quiet 2>"$_dvc_err"; then
    _flux_spin_stop; ok "Pushed DVC data to R2."
  elif grep -qiE 'AccessDenied|Access Denied' "$_dvc_err" 2>/dev/null; then
    _flux_spin_stop; warn "DVC push failed — access denied. Check R2 API token permissions (Admin Read & Write required)."
  else
    _flux_spin_stop; warn "DVC push failed — run 'dvc push' to see the full error."
  fi
  rm -f "$_dvc_err"
}

_flux_sync_summary() {
  local git_count=0 git_bytes=0 dvc_count=0 dvc_bytes=0 skip_count=0

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

  skip_count=$(git ls-files --others --ignored --exclude-standard --directory 2>/dev/null | wc -l | tr -d ' ')

  echo ""
  echo "  flux sync — repository contents"
  echo ""

  local count_digits=1 max_c
  max_c=$(( git_count > dvc_count ? git_count : dvc_count ))
  max_c=$(( max_c > skip_count ? max_c : skip_count ))
  while (( max_c >= 10 )); do count_digits=$(( count_digits + 1 )); max_c=$(( max_c / 10 )); done

  printf "  Git   %*d file(s)   %s\n"       "$count_digits" "$git_count"  "$(_flux_size_unit "$git_bytes")"
  printf "  DVC   %*d file(s)   %s\n"       "$count_digits" "$dvc_count"  "$(_flux_size_unit "$dvc_bytes")"
  printf "  Skip  %*d file(s)   gitignored\n" "$count_digits" "$skip_count"
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

# Generic histogram renderer called multiple times by _flux_dry_run.
# $1 = section title   $2 = cap_bytes (0 = no separator line)
# Reads _H_GIT[] and _H_DVC[] globals (byte sizes for ░ and █ bars).
_flux_render_histogram() {
  local section_title="$1" cap_bytes="${2:-0}"
  local BAR_WIDTH=20

  local total=$(( ${#_H_GIT[@]} + ${#_H_DVC[@]} ))
  [[ $total -eq 0 ]] && return 0

  local fixed_thresholds=(1024 10240 102400 1048576 10485760 104857600 1073741824)
  local boundaries=(0) cap_added=false t last_idx

  if (( cap_bytes > 0 )); then
    for t in "${fixed_thresholds[@]}"; do
      if [[ "$cap_added" == "false" ]] && (( cap_bytes <= t )); then
        last_idx=$(( ${#boundaries[@]} - 1 ))
        (( cap_bytes > boundaries[last_idx] )) && boundaries+=("$cap_bytes")
        cap_added=true
      fi
      last_idx=$(( ${#boundaries[@]} - 1 ))
      (( t != boundaries[last_idx] )) && boundaries+=("$t")
    done
    if [[ "$cap_added" == "false" ]]; then
      last_idx=$(( ${#boundaries[@]} - 1 ))
      (( cap_bytes > boundaries[last_idx] )) && boundaries+=("$cap_bytes")
    fi
  else
    for t in "${fixed_thresholds[@]}"; do
      last_idx=$(( ${#boundaries[@]} - 1 ))
      (( t != boundaries[last_idx] )) && boundaries+=("$t")
    done
  fi
  boundaries+=(0)

  local nbrackets=$(( ${#boundaries[@]} - 1 ))
  local i counts=() sizes=() git_in=() dvc_in=()
  for (( i=0; i<nbrackets; i++ )); do counts+=( 0 ); sizes+=( 0 ); git_in+=( 0 ); dvc_in+=( 0 ); done

  local sz lo hi
  for sz in "${_H_GIT[@]+"${_H_GIT[@]}"}"; do
    for (( i=0; i<nbrackets; i++ )); do
      lo="${boundaries[$i]}"; hi="${boundaries[$((i+1))]}"
      if (( sz >= lo )) && (( hi == 0 || sz < hi )); then
        counts[$i]=$(( counts[$i] + 1 )); sizes[$i]=$(( sizes[$i] + sz ))
        git_in[$i]=$(( git_in[$i] + 1 )); break
      fi
    done
  done
  for sz in "${_H_DVC[@]+"${_H_DVC[@]}"}"; do
    for (( i=0; i<nbrackets; i++ )); do
      lo="${boundaries[$i]}"; hi="${boundaries[$((i+1))]}"
      if (( sz >= lo )) && (( hi == 0 || sz < hi )); then
        counts[$i]=$(( counts[$i] + 1 )); sizes[$i]=$(( sizes[$i] + sz ))
        dvc_in[$i]=$(( dvc_in[$i] + 1 )); break
      fi
    done
  done

  local non_empty=0
  for (( i=0; i<nbrackets; i++ )); do
    if (( counts[$i] > 0 )); then non_empty=$(( non_empty + 1 )); fi
  done
  if (( non_empty == 0 )); then return 0; fi

  local sep_after=-1
  if (( cap_bytes > 0 )); then
    for (( i=0; i<nbrackets; i++ )); do
      (( boundaries[$((i+1))] == cap_bytes )) && { sep_after=$i; break; }
    done
  fi

  # Display range: with cap → full git zone + trimmed dvc zone; without → trim both ends
  local display_first=0 display_last
  if (( sep_after >= 0 )); then
    display_first=0
    local dvc_first=$(( sep_after + 1 )) dvc_last=$(( sep_after + 1 ))
    for (( i=dvc_first; i<nbrackets; i++ )); do (( counts[$i] > 0 )) && dvc_last=$i; done
    display_last=$dvc_last
  else
    display_last=$(( nbrackets - 1 ))
    for (( i=0; i<nbrackets; i++ )); do
      if (( counts[$i] > 0 )); then display_first=$i; break; fi
    done
    for (( i=nbrackets-1; i>=0; i-- )); do
      if (( counts[$i] > 0 )); then display_last=$i; break; fi
    done
  fi

  local max_count=0
  for (( i=display_first; i<=display_last; i++ )); do
    (( counts[$i] > max_count )) && max_count=${counts[$i]}
  done
  (( max_count == 0 )) && return 0
  (( ${_FLUX_BAR_MAX:-0} > max_count )) && max_count=${_FLUX_BAR_MAX:-0}
  _FLUX_BAR_MAX=$max_count

  local count_digits=${#max_count}
  local max_lo_width=0 max_right_width=0 lw rw lo_str hi_str
  for (( i=display_first; i<=display_last; i++ )); do
    lo="${boundaries[$i]}"; hi="${boundaries[$((i+1))]}"
    if (( lo != 0 && hi != 0 )); then
      lo_str=$(_flux_size_unit "$lo"); hi_str=$(_flux_size_unit "$hi")
      lw=${#lo_str}; rw=${#hi_str}
      (( lw > max_lo_width ))    && max_lo_width=$lw
      (( rw > max_right_width )) && max_right_width=$rw
    elif (( lo == 0 )); then
      hi_str=$(_flux_size_unit "$hi"); rw=${#hi_str}
      (( rw > max_right_width )) && max_right_width=$rw
    else
      lo_str=$(_flux_size_unit "$lo"); lw=${#lo_str}
      (( lw > max_right_width )) && max_right_width=$lw
    fi
  done

  local label_width=$(( max_lo_width + 3 + max_right_width ))
  local sep_width=$(( label_width + 2 + BAR_WIDTH ))
  _FLUX_HIST_LABEL_WIDTH=$label_width

  echo ""
  echo "  $section_title"
  echo ""

  local bar bar_len bar_pad j count size_str git_chars dvc_chars
  for (( i=display_first; i<=display_last; i++ )); do
    lo="${boundaries[$i]}"; hi="${boundaries[$((i+1))]}"; count="${counts[$i]}"

    if (( lo == 0 )); then
      printf "    %*s < %-*s" "$max_lo_width" "" "$max_right_width" "$(_flux_size_unit "$hi")"
    elif (( hi == 0 )); then
      printf "    %*s > %-*s" "$max_lo_width" "" "$max_right_width" "$(_flux_size_unit "$lo")"
    else
      printf "    %*s - %-*s" "$max_lo_width" "$(_flux_size_unit "$lo")" "$max_right_width" "$(_flux_size_unit "$hi")"
    fi

    bar=""; bar_len=0
    if (( count > 0 )); then
      bar_len=$(( count * BAR_WIDTH / max_count ))
      (( bar_len < 1 )) && bar_len=1
      git_chars=$(( git_in[$i] * bar_len / count ))
      dvc_chars=$(( bar_len - git_chars ))
      for (( j=0; j<git_chars; j++ )); do bar="${bar}░"; done
      for (( j=0; j<dvc_chars; j++ )); do bar="${bar}█"; done
    fi
    bar_pad=""; for (( j=bar_len; j<BAR_WIDTH; j++ )); do bar_pad="${bar_pad} "; done

    (( count > 0 )) && size_str="  ($(_flux_size_unit "${sizes[$i]}"))" || size_str=""
    printf "  %s%s  %*d%s\n" "$bar" "$bar_pad" "$count_digits" "$count" "$size_str"

    if (( i == sep_after )); then
      local sep_line=""
      for (( j=0; j<sep_width; j++ )); do sep_line="${sep_line}─"; done
      printf "    %s  cap: %s\n" "$sep_line" "$(_flux_size_unit "$cap_bytes")"
    fi
  done

  echo ""
}

# Summary row rendered below the text histogram — one bar line per category.
# $1=label  $2=bar-char  $3=count  $4=total-bytes  $5=count-field-width
# Uses _FLUX_BAR_MAX (shared scale) and _FLUX_HIST_LABEL_WIDTH (label padding).
# Skipped silently when count==0.
_flux_render_summary_row() {
  local label="$1" char="$2" count="$3" total_bytes="$4" count_w="${5:-1}"
  (( count == 0 )) && return 0
  local BAR_WIDTH=20
  local bar_len=$(( count * BAR_WIDTH / _FLUX_BAR_MAX ))
  (( bar_len < 1 )) && bar_len=1
  local bar="" bar_pad="" j
  for (( j=0; j<bar_len; j++ )); do bar="${bar}${char}"; done
  for (( j=bar_len; j<BAR_WIDTH; j++ )); do bar_pad="${bar_pad} "; done
  printf "    %-*s  %s%s  %*d  (%s)\n" \
    "${_FLUX_HIST_LABEL_WIDTH:-10}" "$label" "$bar" "$bar_pad" \
    "$count_w" "$count" "$(_flux_size_unit "$total_bytes")"
}

# ---------------------------------------------------------------------------
# dry-run — preview staged file routing without executing any changes
# ---------------------------------------------------------------------------

_flux_dry_run() {
  git rev-parse --git-dir &>/dev/null \
    || fail "Not inside a Git repository."

  clear 2>/dev/null || true

  local SIZE_CAP_MB SIZE_CAP_BYTES
  SIZE_CAP_MB=$(git config --get dvc-router.size-cap-mb 2>/dev/null || echo "5")
  SIZE_CAP_BYTES=$(( SIZE_CAP_MB * 1024 * 1024 ))

  local -a FORCE_DVC_DIRS=() FORCE_GIT_DIRS=()
  while IFS= read -r line; do [[ -n "$line" ]] && FORCE_DVC_DIRS+=("$line"); done \
    < <(git config --get-all dvc-router.force-dvc 2>/dev/null || true)
  while IFS= read -r line; do [[ -n "$line" ]] && FORCE_GIT_DIRS+=("$line"); done \
    < <(git config --get-all dvc-router.force-git 2>/dev/null || true)

  local staged_files scan_mode
  staged_files=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)

  if [[ -z "$staged_files" ]]; then
    staged_files=$(
      { git ls-files 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } | sort -u
    )
    scan_mode="all files"
  else
    scan_mode="staged files"
  fi

  if [[ -z "$staged_files" ]]; then
    echo ""
    echo "  No files to preview."
    echo ""
    return 0
  fi

  local git_files=() git_bytes=0 git_notes=() git_file_sizes=()
  local dvc_files=() dvc_bytes=0 dvc_migrating=() dvc_notes=() dvc_file_sizes=() dvc_file_is_binary=()
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

    if _flux_in_dir_override "$file" "${FORCE_DVC_DIRS[@]+"${FORCE_DVC_DIRS[@]}"}"; then
      dvc_files+=("$file")
      dvc_notes+=("[pinned]")
      dvc_file_sizes+=("$file_size")
      dvc_file_is_binary+=(0)
      dvc_bytes=$(( dvc_bytes + file_size ))
      if git ls-files --error-unmatch "$file" &>/dev/null 2>&1; then
        dvc_migrating+=("$file")
      fi
    elif _flux_in_dir_override "$file" "${FORCE_GIT_DIRS[@]+"${FORCE_GIT_DIRS[@]}"}"; then
      git_files+=("$file")
      git_notes+=("[pinned]")
      git_file_sizes+=("$file_size")
      git_bytes=$(( git_bytes + file_size ))
    elif [[ "$is_binary" == "true" ]] || (( file_size > SIZE_CAP_BYTES )); then
      dvc_files+=("$file")
      dvc_notes+=("")
      dvc_file_sizes+=("$file_size")
      dvc_file_is_binary+=("$( [[ "$is_binary" == "true" ]] && echo 1 || echo 0 )")
      dvc_bytes=$(( dvc_bytes + file_size ))
      if git ls-files --error-unmatch "$file" &>/dev/null 2>&1; then
        dvc_migrating+=("$file")
      fi
    else
      git_files+=("$file")
      git_notes+=("")
      git_file_sizes+=("$file_size")
      git_bytes=$(( git_bytes + file_size ))
    fi
  done <<< "$staged_files"

  # .dvc pointer files that landed in dvc_files (because they're in a pinned dir) were sized
  # via wc -c, giving the tiny pointer-file size instead of the actual data size.  Fix that now.
  local _pdi=0 _pdf _pds _pline _old_ptr_sz
  for _pdf in "${dvc_files[@]+"${dvc_files[@]}"}"; do
    if [[ "$_pdf" == *.dvc ]]; then
      _pds=0
      while IFS= read -r _pline; do
        [[ "$_pline" =~ ^[[:space:]]*size:[[:space:]]*([0-9]+) ]] && \
          _pds=$(( _pds + BASH_REMATCH[1] ))
      done < "$_pdf"
      if (( _pds > 0 )); then
        _old_ptr_sz="${dvc_file_sizes[$_pdi]:-0}"
        dvc_bytes=$(( dvc_bytes - _old_ptr_sz + _pds ))
        dvc_file_sizes[$_pdi]=$_pds
      fi
    fi
    (( _pdi++ )) || true
  done

  local dvc_managed_paths=() dvc_managed_sizes=() dvc_managed_total=0
  local _pm _pp _ps _pd _line
  for _pm in "${git_files[@]}"; do
    [[ "$_pm" != *.dvc ]] && continue
    _pp=""; _ps=0
    while IFS= read -r _line; do
      if [[ -z "$_pp" ]] && [[ "$_line" =~ ^[[:space:]]*path:[[:space:]]+(.+)$ ]]; then
        _pp="${BASH_REMATCH[1]#\"}" ; _pp="${_pp%\"}"
        _pp="${_pp#\'}"             ; _pp="${_pp%\'}"
      elif [[ "$_line" =~ ^[[:space:]]*size:[[:space:]]*([0-9]+) ]]; then
        _ps=$(( _ps + BASH_REMATCH[1] ))
      fi
    done < "$_pm"
    [[ -z "$_pp" ]] && continue
    _pd=$(dirname "$_pm")
    [[ "$_pd" != "." ]] && _pp="${_pd}/${_pp}"
    dvc_managed_paths+=("$_pp")
    dvc_managed_sizes+=("$_ps")
    dvc_managed_total=$(( dvc_managed_total + _ps ))
  done

  local _pin_count=$(( ${#FORCE_DVC_DIRS[@]} + ${#FORCE_GIT_DIRS[@]} ))
  local _pin_note=""
  (( _pin_count > 0 )) && _pin_note=", ${_pin_count} pin(s) active"

  echo ""
  echo "  flux dry-run — routing preview (${scan_mode}, cap: ${SIZE_CAP_MB} MB${_pin_note})"
  echo ""

  local skip_bytes=0 skip_file_sizes=()
  local _sf _ssz
  for _sf in "${skip_files[@]}"; do
    if [[ -f "$_sf" ]]; then
      _ssz=$(wc -c < "$_sf" | tr -d ' ')
      skip_bytes=$(( skip_bytes + _ssz ))
      skip_file_sizes+=("$_ssz")
    fi
  done

  local _dvc_total_n=$(( ${#dvc_files[@]} + ${#skip_files[@]} + ${#dvc_managed_paths[@]} ))
  local _dvc_total_b=$(( dvc_bytes + skip_bytes + dvc_managed_total ))
  printf "  → Git     %d file(s)    %s\n" "${#git_files[@]}" "$(_flux_format_size "$git_bytes")"
  printf "  → DVC     %d file(s)    %s\n" "$_dvc_total_n" "$(_flux_format_size "$_dvc_total_b")"

  # Split routed files into three histogram categories:
  #   text  — text files; threshold line separates git (below) from dvc (above)
  #   binary — binary files; always DVC regardless of size, no threshold line
  #   pinned — explicitly pinned files; no threshold line
  local _H_TEXT_GIT=() _H_TEXT_DVC=() _H_BIN=() _H_PIN_GIT=() _H_PIN_DVC=()

  local _hi=0
  for _hsz in "${git_file_sizes[@]+"${git_file_sizes[@]}"}"; do
    if [[ "${git_notes[$_hi]:-}" == "[pinned]" ]]; then _H_PIN_GIT+=("$_hsz")
    else                                                  _H_TEXT_GIT+=("$_hsz"); fi
    (( _hi++ )) || true
  done

  local _hj=0
  for _hsz in "${dvc_file_sizes[@]+"${dvc_file_sizes[@]}"}"; do
    if   [[ "${dvc_notes[$_hj]:-}" == "[pinned]" ]];    then _H_PIN_DVC+=("$_hsz")
    elif [[ "${dvc_file_is_binary[$_hj]:-0}" == "1" ]]; then _H_BIN+=("$_hsz")
    else                                                      _H_TEXT_DVC+=("$_hsz"); fi
    (( _hj++ )) || true
  done

  # Already-DVC-managed files (skip_files + dvc_managed_paths) → binary category
  _H_BIN+=("${skip_file_sizes[@]+"${skip_file_sizes[@]}"}")
  local _dm=0
  for _dmp in "${dvc_managed_paths[@]}"; do
    local _dmsz="${dvc_managed_sizes[$_dm]:-0}"
    (( _dmsz > 0 )) && _H_BIN+=("$_dmsz")
    (( _dm++ )) || true
  done

  local _pin_git_n=${#_H_PIN_GIT[@]} _pin_dvc_n=${#_H_PIN_DVC[@]} _bin_n=${#_H_BIN[@]}
  local _pin_git_bytes=0 _pin_dvc_bytes=0 _bin_bytes=0 _sz
  for _sz in "${_H_PIN_GIT[@]+"${_H_PIN_GIT[@]}"}"; do _pin_git_bytes=$(( _pin_git_bytes + _sz )); done
  for _sz in "${_H_PIN_DVC[@]+"${_H_PIN_DVC[@]}"}"; do _pin_dvc_bytes=$(( _pin_dvc_bytes + _sz )); done
  for _sz in "${_H_BIN[@]+"${_H_BIN[@]}"}"; do          _bin_bytes=$(( _bin_bytes + _sz )); done

  # Shared bar scale: seed with max summary count; text histogram raises it if needed
  local _FLUX_BAR_MAX _FLUX_HIST_LABEL_WIDTH=10
  _FLUX_BAR_MAX=$(( _pin_git_n > _pin_dvc_n ? _pin_git_n : _pin_dvc_n ))
  (( _bin_n > _FLUX_BAR_MAX )) && _FLUX_BAR_MAX=$_bin_n

  local _sum_max_n=$(( _pin_git_n > _pin_dvc_n ? _pin_git_n : _pin_dvc_n ))
  (( _bin_n > _sum_max_n )) && _sum_max_n=$_bin_n
  local _sum_count_w=${#_sum_max_n}; (( _sum_count_w < 1 )) && _sum_count_w=1

  _H_GIT=("${_H_TEXT_GIT[@]}"); _H_DVC=("${_H_TEXT_DVC[@]}")
  _flux_render_histogram "Text files" "$SIZE_CAP_BYTES"
  echo ""
  _flux_render_summary_row "Pinned Git" "░" "$_pin_git_n" "$_pin_git_bytes" "$_sum_count_w"
  _flux_render_summary_row "Pinned DVC" "█" "$_pin_dvc_n" "$_pin_dvc_bytes" "$_sum_count_w"
  _flux_render_summary_row "Binary"     "█" "$_bin_n"     "$_bin_bytes"     "$_sum_count_w"

  local _leg_git=$(( ${#_H_TEXT_GIT[@]} + _pin_git_n ))
  local _leg_dvc=$(( ${#_H_TEXT_DVC[@]} + _pin_dvc_n + _bin_n ))
  echo ""
  (( _leg_git > 0 )) && printf "  ░ → Git\n"
  (( _leg_dvc > 0 )) && printf "  █ → DVC\n"

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
      local _i=0
      for f in "${git_files[@]}"; do
        local sz; sz=$(wc -c < "$f" | tr -d ' ')
        local _fn="${git_notes[_i]:-}"
        local _fn_str; _fn_str="${_fn:+   ${_fn}}"
        printf "    ·  %-42s %s%s\n" "$f" "$(_flux_format_size "$sz")" "$_fn_str"
        (( _i++ )) || true
      done
    fi

    if (( _dvc_total_n > 0 )); then
      echo ""
      printf "  DVC files:\n"
      local _j=0
      for f in "${dvc_files[@]}"; do
        local sz; sz=$(wc -c < "$f" | tr -d ' ')
        local note="${dvc_notes[_j]:-}"
        local _note_str; _note_str="${note:+   ${note}}"
        printf "    ✦  %-42s %s%s\n" "$f" "$(_flux_format_size "$sz")" "$_note_str"
        (( _j++ )) || true
      done
      for f in "${skip_files[@]}"; do
        local sz; sz=$(wc -c < "$f" | tr -d ' ')
        printf "    ✦  %-42s %s\n" "$f" "$(_flux_format_size "$sz")"
      done
      local _dm=0
      for _dmp in "${dvc_managed_paths[@]}"; do
        local _dmsz="${dvc_managed_sizes[$_dm]:-0}"
        local _dmsz_str
        if (( _dmsz > 0 )); then
          _dmsz_str=$(_flux_format_size "$_dmsz")
        else
          _dmsz_str="(size unknown)"
        fi
        printf "    ✦  %-42s %s\n" "$_dmp" "$_dmsz_str"
        (( _dm++ )) || true
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
# pin — show or set directory routing pins
# ---------------------------------------------------------------------------

# Safely removes one specific value from a multi-value git config key.
_flux_pin_config_remove() {
  local key="$1" target="$2"
  local -a current=()
  while IFS= read -r line; do [[ -n "$line" ]] && current+=("$line"); done \
    < <(git config --get-all "$key" 2>/dev/null || true)
  (( ${#current[@]} == 0 )) && return 0
  git config --unset-all "$key" 2>/dev/null || true
  local v
  for v in "${current[@]}"; do
    [[ "$v" == "$target" ]] && continue
    git config --add "$key" "$v"
  done
}

_flux_pin() {
  local subcmd="${1:-}"

  # ── no args: show usage + current pins ────────────────────────────────────
  if [[ -z "$subcmd" ]]; then
    echo ""
    echo "  flux pin — directory routing pins"
    echo ""
    echo "  Usage:"
    echo "    flux pin dvc          Pin current directory to DVC"
    echo "    flux pin git          Pin current directory to Git"
    echo "    flux pin reset        Remove pin for current directory"
    echo "    flux pin reset --all  Clear all directory pins"
    echo ""
    echo "  (Pins are shown in 'flux list' when inside a project)"
    if git rev-parse --git-dir &>/dev/null 2>&1; then
      local -a dvc_dirs=() git_dirs=()
      while IFS= read -r line; do [[ -n "$line" ]] && dvc_dirs+=("$line"); done \
        < <(git config --get-all dvc-router.force-dvc 2>/dev/null || true)
      while IFS= read -r line; do [[ -n "$line" ]] && git_dirs+=("$line"); done \
        < <(git config --get-all dvc-router.force-git 2>/dev/null || true)
      if (( ${#dvc_dirs[@]} > 0 || ${#git_dirs[@]} > 0 )); then
        echo ""
        printf "  Pinned:\n"
        for d in "${dvc_dirs[@]}"; do printf "    ✦  %-24s → DVC\n" "$d"; done
        for d in "${git_dirs[@]}"; do printf "    ·  %-24s → Git\n" "$d"; done
      fi
    fi
    echo ""
    return 0
  fi

  git rev-parse --git-dir &>/dev/null \
    || fail "Not inside a Git repository."

  # ── reset --all ────────────────────────────────────────────────────────────
  if [[ "$subcmd" == "reset" && "${2:-}" == "--all" ]]; then
    git config --unset-all dvc-router.force-dvc 2>/dev/null || true
    git config --unset-all dvc-router.force-git 2>/dev/null || true
    ok "All directory pins cleared."
    return 0
  fi

  # ── reset (current dir) ───────────────────────────────────────────────────
  if [[ "$subcmd" == "reset" ]]; then
    local rel_path
    rel_path=$(git rev-parse --show-prefix 2>/dev/null)
    rel_path="${rel_path%/}"
    [[ -z "$rel_path" ]] && rel_path="."
    _flux_pin_config_remove dvc-router.force-dvc "$rel_path"
    _flux_pin_config_remove dvc-router.force-git "$rel_path"
    ok "Pin removed for: ${rel_path}"
    return 0
  fi

  # ── dvc / git ─────────────────────────────────────────────────────────────
  if [[ "$subcmd" != "dvc" && "$subcmd" != "git" ]]; then
    fail "Usage: flux pin [list|dvc|git|reset [--all]]"
  fi

  local rel_path
  rel_path=$(git rev-parse --show-prefix 2>/dev/null)
  rel_path="${rel_path%/}"
  [[ -z "$rel_path" ]] && rel_path="."

  if [[ "$subcmd" == "dvc" ]]; then
    _flux_pin_config_remove dvc-router.force-git "$rel_path"
    local -a existing=()
    while IFS= read -r line; do [[ -n "$line" ]] && existing+=("$line"); done \
      < <(git config --get-all dvc-router.force-dvc 2>/dev/null || true)
    local already=false
    for e in "${existing[@]}"; do [[ "$e" == "$rel_path" ]] && already=true && break; done
    [[ "$already" == "false" ]] && git config --add dvc-router.force-dvc "$rel_path"
    _flux_registry_write git_config dvc-router.force-dvc
    ok "Pinned to DVC: ${rel_path}"
  else
    _flux_pin_config_remove dvc-router.force-dvc "$rel_path"
    local -a existing=()
    while IFS= read -r line; do [[ -n "$line" ]] && existing+=("$line"); done \
      < <(git config --get-all dvc-router.force-git 2>/dev/null || true)
    local already=false
    for e in "${existing[@]}"; do [[ "$e" == "$rel_path" ]] && already=true && break; done
    [[ "$already" == "false" ]] && git config --add dvc-router.force-git "$rel_path"
    _flux_registry_write git_config dvc-router.force-git
    ok "Pinned to Git: ${rel_path}"
  fi
  ok "Takes effect on the next commit."
}

# ---------------------------------------------------------------------------
# _flux_doctor_inline — single-line status for embedding in other tools
# ---------------------------------------------------------------------------

_flux_doctor_inline() {
  FLUX_DVC_REMOTES=()
  if _flux_is_configured 2>/dev/null; then
    local _buckets="" _e
    for _e in "${FLUX_DVC_REMOTES[@]}"; do _buckets+="${_e%%:*} "; done
    echo "✔ flux configured (DVC: ${_buckets% })"
  else
    echo "✘ flux not configured — run: flux config"
  fi
}

# ---------------------------------------------------------------------------
# doctor — environment diagnostics
# ---------------------------------------------------------------------------

_flux_doctor() {
  _flux_require_macos
  clear 2>/dev/null || true

  local pass=true

  echo ""
  echo "  flux doctor"
  echo ""

  # Global config
  FLUX_DVC_REMOTES=()
  FLUX_GIT_ACCOUNTS=()
  if [[ -f "$FLUX_CONFIG" ]]; then
    ok "Config file: $FLUX_CONFIG"
    # shellcheck source=/dev/null
    source "$FLUX_CONFIG" 2>/dev/null || true
    if [[ "${#FLUX_DVC_REMOTES[@]}" -gt 0 ]]; then
      local _di=1 _de _db _da _ak _sk
      for _de in "${FLUX_DVC_REMOTES[@]}"; do
        _db="${_de%%:*}"; _da="${_de#*:}"
        _ak=$(_kc_get_dvc "$_db" "access-key-id")
        _sk=$(_kc_get_dvc "$_db" "secret-key")
        if [[ -n "$_ak" && -n "$_sk" ]]; then
          ok "DVC remote ${_di}: ${_db}  (account: ${_da})  key: ****"
        else
          warn "DVC remote ${_di}: ${_db} — credentials missing — run: flux config"
          pass=false
        fi
        (( _di++ ))
      done
    else
      warn "No DVC remotes configured — run: flux config"
      pass=false
    fi
    if [[ "${#FLUX_GIT_ACCOUNTS[@]}" -gt 0 ]]; then
      local _gi=1 _ge
      for _ge in "${FLUX_GIT_ACCOUNTS[@]}"; do
        ok "Git account ${_gi}: ${_ge}"
        (( _gi++ ))
      done
    fi
  else
    warn "Config file not found: $FLUX_CONFIG"
    warn "  Run: flux config"
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
# list — find all flux-managed projects under the current directory
# ---------------------------------------------------------------------------

_flux_list() {
  local base_dir; base_dir="$(pwd)"
  local found=0

  local -a _paths _dvc_remotes _git_remotes _caps _repo_dirs

  while IFS= read -r git_dir; do
    local repo_dir; repo_dir="$(cd "$(dirname "$git_dir")" 2>/dev/null && pwd)" || continue

    [[ -d "$repo_dir/.dvc" ]] || continue
    local dvc_folder; dvc_folder="$(git -C "$repo_dir" config --get flux.r2-folder 2>/dev/null || true)"
    [[ -n "$dvc_folder" ]] || continue
    grep -q 'r2remote' "$repo_dir/.dvc/config" 2>/dev/null || continue

    local bucket cap rel_path git_remote dvc_remote
    bucket="$(git -C "$repo_dir" config --get flux.dvc-remote-bucket 2>/dev/null || true)"
    if [[ -z "$bucket" ]]; then
      bucket="$(grep -E '^\s*url\s*=' "$repo_dir/.dvc/config" 2>/dev/null \
        | head -1 | sed 's|.*s3://||' | cut -d'/' -f1 | tr -d ' ')"
    fi
    [[ -n "$bucket" ]] && dvc_remote="${bucket}/${dvc_folder}" || dvc_remote="-"

    cap="$(git -C "$repo_dir" config --get dvc-router.size-cap-mb 2>/dev/null || echo "5")"
    git_remote="$(git -C "$repo_dir" remote get-url origin 2>/dev/null || echo "-")"

    if [[ "$repo_dir" == "$base_dir" ]]; then
      rel_path=". (current)"
    else
      rel_path="./${repo_dir#${base_dir}/}"
    fi

    _paths+=("$rel_path")
    _dvc_remotes+=("$dvc_remote")
    _git_remotes+=("$git_remote")
    _caps+=("$cap")
    _repo_dirs+=("$repo_dir")
    (( found++ )) || true
  done < <(find . -type d -name ".git" -prune -print 2>/dev/null | sort)

  local w1=4 w2=10 w3=10  # minimum = header label lengths
  for i in "${!_paths[@]}"; do
    (( ${#_paths[$i]}        > w1 )) && w1=${#_paths[$i]}
    (( ${#_dvc_remotes[$i]}  > w2 )) && w2=${#_dvc_remotes[$i]}
    (( ${#_git_remotes[$i]}  > w3 )) && w3=${#_git_remotes[$i]}
  done

  local sep1 sep2 sep3
  sep1="$(printf '%*s' "$w1" '' | tr ' ' '-')"
  sep2="$(printf '%*s' "$w2" '' | tr ' ' '-')"
  sep3="$(printf '%*s' "$w3" '' | tr ' ' '-')"

  printf "%-${w1}s  %-${w2}s  %-${w3}s  %s\n" "PATH" "DVC REMOTE" "GIT REMOTE" "CAP"
  printf "%-${w1}s  %-${w2}s  %-${w3}s  %s\n" "$sep1" "$sep2" "$sep3" "---"

  for i in "${!_paths[@]}"; do
    printf "%-${w1}s  %-${w2}s  %-${w3}s  %s MB\n" \
      "${_paths[$i]}" "${_dvc_remotes[$i]}" "${_git_remotes[$i]}" "${_caps[$i]}"
  done

  if (( found == 0 )); then
    echo ""
    echo "  No flux-managed projects found under $(pwd)"
    return 0
  fi

  # Show pinned directories when the user is inside a single project.
  # For multiple projects: only show pins if CWD is exactly the root of one
  # of them (the ". (current)" case), which covers the nested-sub-project
  # scenario without cluttering pure workspace views.
  local pins_repo_dir=""
  if (( found == 1 )); then
    pins_repo_dir="${_repo_dirs[0]}"
  else
    local i
    for i in "${!_repo_dirs[@]}"; do
      if [[ "${_repo_dirs[$i]}" == "$base_dir" ]]; then
        pins_repo_dir="${_repo_dirs[$i]}"
        break
      fi
    done
  fi

  if [[ -n "$pins_repo_dir" ]]; then
    local -a dvc_pins=() git_pins=()
    while IFS= read -r line; do [[ -n "$line" ]] && dvc_pins+=("$line"); done \
      < <(git -C "$pins_repo_dir" config --get-all dvc-router.force-dvc 2>/dev/null || true)
    while IFS= read -r line; do [[ -n "$line" ]] && git_pins+=("$line"); done \
      < <(git -C "$pins_repo_dir" config --get-all dvc-router.force-git 2>/dev/null || true)
    if (( ${#dvc_pins[@]} > 0 || ${#git_pins[@]} > 0 )); then
      echo ""
      printf "  Pinned:\n"
      for d in "${dvc_pins[@]}"; do printf "    ✦  %-24s → DVC\n" "$d"; done
      for d in "${git_pins[@]}"; do printf "    ·  %-24s → Git\n" "$d"; done
    fi
  fi
}

# ---------------------------------------------------------------------------
# clone — clone a flux-managed git repo and wire up DVC + credentials
# ---------------------------------------------------------------------------

_flux_clone() {
  _flux_require_macos

  # Source flux.env early so FLUX_AWS_CONFIG_FILE is available for credential setup.
  [[ -f "$FLUX_CONFIG" ]] && source "$FLUX_CONFIG" 2>/dev/null || true

  local git_url="${1:-}"
  local target_dir="${2:-}"
  [[ -n "$git_url" ]] || fail "Usage: flux clone <git-url> [directory]"

  if [[ -z "$target_dir" ]]; then
    target_dir=$(basename "$git_url")
    target_dir="${target_dir%.git}"
    target_dir="${target_dir%/}"
  fi

  clear 2>/dev/null || true
  echo ""
  echo "  flux ${VERSION} — clone"
  echo ""

  local DVC; _flux_require_dvc

  # Step 1: git clone
  git clone "$git_url" "$target_dir" \
    || fail "git clone failed."
  ok "Cloned into: ${target_dir}/"

  # Step 2: verify this is a flux-managed repo
  [[ -f "$target_dir/.dvc/config" ]] \
    || fail "This does not look like a flux-managed repository (.dvc/config not found)."

  # Step 3: parse bucket, R2 folder, and account ID from committed .dvc/config
  local dvc_cfg="$target_dir/.dvc/config"
  local raw_url endpoint
  raw_url=$(grep -E '^\s*url\s*='         "$dvc_cfg" 2>/dev/null | head -1 | sed 's/.*=\s*//' | tr -d ' ')
  endpoint=$(grep -E '^\s*endpointurl\s*=' "$dvc_cfg" 2>/dev/null | head -1 | sed 's/.*=\s*//' | tr -d ' ')

  [[ -n "$raw_url" ]]  || fail "Cannot find DVC remote URL in .dvc/config."
  [[ -n "$endpoint" ]] || fail "Cannot find DVC endpoint URL in .dvc/config — was this repository set up with flux?"

  local s3_path="${raw_url#s3://}"
  local bucket="${s3_path%%/*}"
  local r2_folder="${s3_path#*/}"
  local hostname="${endpoint#https://}"
  local account_id="${hostname%%.*}"

  [[ -n "$bucket" && -n "$r2_folder" && -n "$account_id" ]] \
    || fail "Could not parse remote config from .dvc/config."

  ok "DVC remote: s3://${bucket}/${r2_folder}"

  # Step 4: resolve credentials from Keychain, or prompt and save them
  local access_key secret_key
  access_key=$(_kc_get_dvc "$bucket" "access-key-id")
  secret_key=$(_kc_get_dvc "$bucket" "secret-key")

  if [[ -z "$access_key" || -z "$secret_key" ]]; then
    echo ""
    warn "No credentials found in Keychain for bucket '${bucket}'."
    echo "  These are your Cloudflare R2 API credentials for this bucket."
    echo ""
    read -rp  "  Access Key ID: " access_key || true
    read -rsp "  Secret Key:    " secret_key || true
    echo ""
    [[ -n "$access_key" && -n "$secret_key" ]] \
      || fail "Credentials are required to access the DVC remote."
    _kc_set_dvc "$bucket" "access-key-id" "$access_key"
    _kc_set_dvc "$bucket" "secret-key"    "$secret_key"
    ok "Credentials saved to Keychain."
  else
    ok "Credentials found in Keychain for bucket '${bucket}'."
  fi

  # Step 5: wire up AWS credential process and point .dvc/config.local at the profile
  (cd "$target_dir" && _flux_apply_dvc_profile "$DVC")

  # Step 6: write git config and registry
  local cap verbose
  if [[ -f "$FLUX_CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$FLUX_CONFIG" 2>/dev/null || true
  fi
  cap="${FLUX_SIZE_CAP_MB:-5}"
  verbose="${FLUX_VERBOSE:-false}"

  git -C "$target_dir" config dvc-router.size-cap-mb "$cap"
  git -C "$target_dir" config dvc-router.verbose      "$verbose"
  git -C "$target_dir" config flux.r2-folder          "$r2_folder"
  git -C "$target_dir" config flux.dvc-remote-bucket  "$bucket"

  {
    echo "dvc_remote:r2remote"
    echo "git_config:dvc-router.size-cap-mb"
    echo "git_config:dvc-router.verbose"
    echo "git_config:flux.r2-folder"
    echo "git_config:flux.dvc-remote-bucket"
    echo "hook:pre-commit"
  } > "$target_dir/.git/flux-registry"

  ok "Repository configured."

  # Step 7: install pre-commit hook
  local _hooks_dir _script_dir _hook_source
  _hooks_dir="$target_dir/.git/hooks"
  _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _hook_source="${_script_dir}/../share/flux/pre-commit"
  [[ -f "$_hook_source" ]] || _hook_source="${_script_dir}/pre-commit"
  [[ -f "$_hook_source" ]] || fail "pre-commit hook not found (expected at ${_hook_source})."

  cp "$_hook_source" "${_hooks_dir}/pre-commit"
  chmod +x "${_hooks_dir}/pre-commit"
  ok "Pre-commit hook installed."

  # Step 8: dvc pull
  echo ""
  echo "  Pulling large files from R2..."
  if (cd "$target_dir" && "$DVC" pull); then
    ok "DVC pull complete."
  else
    warn "dvc pull encountered issues — run 'dvc pull' manually once the remote is accessible."
  fi

  echo ""
  ok "flux clone complete."
  echo ""
  echo "  Next: cd ${target_dir}"
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
    clone)             _flux_clone "$@" ;;
    list)              _flux_list ;;
    remove)            _flux_remove "$@" ;;
    sync|"")           _flux_sync ;;
    _api-version)      echo "1" ;;
    _credential-helper) _flux_credential_helper ;;
    _pull)
      _flux_require_dvc_repo
      local DVC; _flux_require_dvc
      if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
        git pull 2>&1 || echo "⚠  Git pull failed — continuing with local state"
      fi
      "$DVC" pull
      ;;
    _push)             _flux_require_dvc_repo; local DVC; _flux_require_dvc; "$DVC" push && git push ;;
    _doctor)           _flux_doctor_inline ;;
    pull)              _flux_pull "$@" ;;
    dry-run)           _flux_dry_run ;;
    cap)               _flux_cap "$@" ;;
    pin)               _flux_pin "$@" ;;
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
