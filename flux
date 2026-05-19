#!/usr/bin/env bash
# flux — Git + DVC auto-router for Cloudflare R2
# Install via Homebrew:
#   brew tap bpeterme/homebrew-flux && brew install flux
# Configure via ~/.config/flux/flux.env (see flux.env.example)

set -euo pipefail

VERSION="dev"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
fail() { echo -e "${RED}✘${NC} $*"; exit 1; }

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------

_flux_help() {
  cat <<'EOF'
flux — Git + DVC auto-router for Cloudflare R2

Usage:
  flux setup          Initialise flux in the current Git repository
  flux commit         git commit — pre-commit hook routes files automatically
  flux push           git push && dvc push
  flux pull           git pull && dvc pull

Other:
  flux version        Show version
  flux help           Show this help
EOF
}

# ---------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------

_flux_setup() {
  local FLUX_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/flux/flux.env"

  echo ""
  echo "  flux ${VERSION} — setup"
  echo ""

  command -v dvc >/dev/null || fail 'dvc is not installed. Run: pip install "dvc[s3]"'

  [[ -f "$FLUX_CONFIG" ]] || fail "Config not found: $FLUX_CONFIG
  Copy flux.env.example to $FLUX_CONFIG and fill in your R2 credentials."

  # shellcheck source=/dev/null
  source "$FLUX_CONFIG"

  for var in FLUX_R2_BUCKET FLUX_R2_ACCOUNT_ID FLUX_R2_ACCESS_KEY_ID FLUX_R2_SECRET_KEY; do
    [[ -n "${!var:-}" ]] || fail "$var is not set in $FLUX_CONFIG"
  done
  ok "Config: $FLUX_CONFIG"

  FLUX_SIZE_THRESHOLD_MB="${FLUX_SIZE_THRESHOLD_MB:-5}"
  FLUX_VERBOSE="${FLUX_VERBOSE:-false}"

  git rev-parse --git-dir &>/dev/null || fail "Not inside a Git repository — run 'git init' first."
  ok "Git repository found."

  if [[ ! -d .dvc ]]; then
    dvc init --quiet
    ok "DVC initialised."
  else
    ok "DVC already initialised."
  fi

  if [[ -z "${FLUX_R2_FOLDER:-}" ]]; then
    FLUX_R2_FOLDER=$(git remote get-url origin 2>/dev/null \
      | sed 's/\.git$//' | sed 's/.*\///' || true)
  fi
  [[ -n "${FLUX_R2_FOLDER:-}" ]] \
    || fail "Cannot derive R2 folder — set FLUX_R2_FOLDER in $FLUX_CONFIG or add a git remote."
  ok "R2 folder: ${FLUX_R2_FOLDER}"

  local R2_ENDPOINT="https://${FLUX_R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
  dvc remote add    -f    r2remote "s3://${FLUX_R2_BUCKET}/${FLUX_R2_FOLDER}" --quiet
  dvc remote modify       r2remote endpointurl "$R2_ENDPOINT"                 --quiet
  dvc remote modify       r2remote region      auto                            --quiet
  dvc remote modify --local r2remote access_key_id    "$FLUX_R2_ACCESS_KEY_ID"  --quiet
  dvc remote modify --local r2remote secret_access_key "$FLUX_R2_SECRET_KEY"    --quiet
  ok "DVC remote: s3://${FLUX_R2_BUCKET}/${FLUX_R2_FOLDER}"

  git config dvc-router.size-threshold-mb "$FLUX_SIZE_THRESHOLD_MB"
  git config dvc-router.verbose "$FLUX_VERBOSE"

  local HOOKS_DIR _script_dir HOOK_SOURCE
  HOOKS_DIR="$(git rev-parse --git-dir)/hooks"
  _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  HOOK_SOURCE="${_script_dir}/../share/flux/pre-commit"
  [[ -f "$HOOK_SOURCE" ]] || HOOK_SOURCE="${_script_dir}/pre-commit"
  [[ -f "$HOOK_SOURCE" ]] || fail "pre-commit hook not found (expected at $HOOK_SOURCE)."
  cp "$HOOK_SOURCE" "${HOOKS_DIR}/pre-commit"
  chmod +x "${HOOKS_DIR}/pre-commit"
  ok "pre-commit hook installed."

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
  echo "  Setup complete. Your workflow:"
  echo ""
  echo "    flux commit -m 'your message'   # commit — hook routes files automatically"
  echo "    flux push                        # git push + dvc push"
  echo "    flux pull                        # git pull + dvc pull"
  echo ""
}

# ---------------------------------------------------------------------------
# dispatcher
# ---------------------------------------------------------------------------

flux() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    setup)             _flux_setup ;;
    commit)            git commit "$@" ;;
    push)              git push "$@" && dvc push ;;
    pull)              git pull "$@" && dvc pull ;;
    version)           echo "flux ${VERSION}" ;;
    help|--help|-h|"") _flux_help ;;
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
