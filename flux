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
# Write non-sensitive global config to flux.env
# ---------------------------------------------------------------------------

_flux_write_config() {
  # $1: newline-separated "bucket:account_id" DVC remote entries
  # $2: size cap MB
  # $3: verbose
  # $4: newline-separated "proto:host:account" git account entries
  # $5: primary DVC remote bucket name
  local dvc_str="$1" cap="$2" verbose="$3" git_str="$4" primary_dvc="${5:-}"
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
  flux                  Sync both ways (pull then push)
  flux add              Opt current project into sync
  flux list             List all flux-managed projects under current directory
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
    _flux_write_config "$(_cfg_dvc_str)" "${FLUX_SIZE_CAP_MB:-5}" "${FLUX_VERBOSE:-false}" "$(_cfg_git_str)" "$FLUX_PRIMARY_DVC_REMOTE"
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

  local DVC; _flux_require_dvc

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

  local R2_ENDPOINT="https://${chosen_account_id}.r2.cloudflarestorage.com"
  local remote_verb="added"
  grep -q 'r2remote' .dvc/config 2>/dev/null && remote_verb="updated"
  "$DVC" remote add    -f      r2remote "s3://${chosen_bucket}/${FLUX_R2_FOLDER}" --quiet
  "$DVC" remote default        r2remote                                            --quiet
  "$DVC" remote modify         r2remote endpointurl "$R2_ENDPOINT"                --quiet
  "$DVC" remote modify         r2remote region      auto                          --quiet
  "$DVC" remote modify --local r2remote access_key_id     "$chosen_access_key"    --quiet
  "$DVC" remote modify --local r2remote secret_access_key "$chosen_secret_key"    --quiet
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

  local _pre_staged
  _pre_staged=$(git diff --cached --name-only 2>/dev/null || true)

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
    keys=(flux.r2-folder flux.dvc-remote-bucket dvc-router.size-cap-mb dvc-router.verbose)
  fi
  local removed=0
  for key in "${keys[@]}"; do
    if git config --unset "$key" 2>/dev/null; then
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
  clear 2>/dev/null || true

  _flux_subrepo_sync

  if ! git diff --quiet || ! git diff --cached --quiet; then
    git add -A
    git commit --quiet -m "sync: $(date '+%Y-%m-%d %H:%M')"
  fi

  _flux_sync_summary
  ok "Pulling from Git remote..."; git pull --quiet
  ok "Pulling DVC data from R2..."; "$DVC" pull --quiet
  ok "Pushing to Git remote...";   git push --quiet
  ok "Pushing DVC data to R2...";  "$DVC" push --quiet
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

  # Only suppress when no files at all
  local non_empty=0
  for (( i=0; i<nbrackets; i++ )); do
    if (( counts[$i] > 0 )); then non_empty=$(( non_empty + 1 )); fi
  done
  if (( non_empty == 0 )); then return 0; fi

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

    # Bar: build blocks then pad explicitly in display columns (block chars are
    # multi-byte, so %-*s byte-based padding would misalign counts for partial bars).
    # Shading: ░ for Git-routed buckets, █ for DVC-routed buckets.
    bar=""; bar_len=0
    if (( count > 0 && max_count > 0 )); then
      bar_len=$(( count * BAR_WIDTH / max_count ))
      if (( bar_len < 1 )); then bar_len=1; fi
      local bar_char
      if (( sep_after >= 0 && i <= sep_after )); then bar_char="░"; else bar_char="█"; fi
      for (( j=0; j<bar_len; j++ )); do bar="${bar}${bar_char}"; done
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

  clear 2>/dev/null || true

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

  printf "  → Git     %d file(s)    %s\n" "${#git_files[@]}" "$(_flux_format_size "$git_bytes")"
  local migrating_note=""
  (( ${#dvc_migrating[@]} > 0 )) && migrating_note="    (${#dvc_migrating[@]} migrating from Git)"
  printf "  → DVC     %d file(s)    %s%s\n" "${#dvc_files[@]}" "$(_flux_format_size "$dvc_bytes")" "$migrating_note"
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

  printf "%-40s  %-20s  %-16s  %s\n" "PATH" "R2 FOLDER" "REMOTE" "CAP"
  printf "%-40s  %-20s  %-16s  %s\n" \
    "$(printf '%0.s-' {1..40})" \
    "$(printf '%0.s-' {1..20})" \
    "$(printf '%0.s-' {1..16})" \
    "---"

  while IFS= read -r git_dir; do
    local repo_dir; repo_dir="$(cd "$(dirname "$git_dir")" 2>/dev/null && pwd)" || continue

    [[ -d "$repo_dir/.dvc" ]] || continue
    local r2_folder; r2_folder="$(git -C "$repo_dir" config --get flux.r2-folder 2>/dev/null || true)"
    [[ -n "$r2_folder" ]] || continue
    grep -q 'r2remote' "$repo_dir/.dvc/config" 2>/dev/null || continue

    local bucket cap rel_path
    bucket="$(git -C "$repo_dir" config --get flux.dvc-remote-bucket 2>/dev/null || echo "-")"
    cap="$(git -C "$repo_dir" config --get dvc-router.size-cap-mb 2>/dev/null || echo "5")"

    if [[ "$repo_dir" == "$base_dir" ]]; then
      rel_path="."
    else
      rel_path="./${repo_dir#${base_dir}/}"
    fi

    printf "%-40s  %-20s  %-16s  %s MB\n" "$rel_path" "$r2_folder" "$bucket" "$cap"
    (( found++ )) || true
  done < <(find . -type d -name ".git" -prune -print 2>/dev/null | sort)

  if (( found == 0 )); then
    echo ""
    echo "  No flux-managed projects found under $(pwd)"
  fi
}

# ---------------------------------------------------------------------------
# dispatcher
# ---------------------------------------------------------------------------

flux() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    add)               _flux_add ;;
    list)              _flux_list ;;
    remove)            _flux_remove "$@" ;;
    sync|"")           _flux_sync ;;
    _api-version)      echo "1" ;;
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
