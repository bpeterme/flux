#!/usr/bin/env bash
# flux-setup — initialize flux in the current Git repository.
#
# Prerequisites:
#   dvc is installed (Homebrew dependency of flux).
#   ~/.config/flux/flux.env exists with R2 credentials.
#   Copy flux.env.example to get started.

set -euo pipefail

VERSION="dev"

FLUX_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/flux/flux.env"

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

echo ""
echo "  flux ${VERSION} — setup"
echo ""

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Verify Git repo
# ---------------------------------------------------------------------------
git rev-parse --git-dir &>/dev/null || fail "Not inside a Git repository — run 'git init' first."
ok "Git repository found."

# ---------------------------------------------------------------------------
# Ensure dvc-s3 is available (dvc itself is a Homebrew dependency of flux)
# ---------------------------------------------------------------------------
if ! python3 -c "import dvc_s3" 2>/dev/null; then
  warn "dvc-s3 not found — installing via pip..."
  pip3 install --quiet dvc-s3 2>/dev/null \
    || pip3 install --quiet dvc-s3 --break-system-packages \
    || fail "Could not install dvc-s3. Try: pip install dvc-s3"
fi
ok "dvc-s3 available."

# ---------------------------------------------------------------------------
# Initialise DVC
# ---------------------------------------------------------------------------
if [[ ! -d .dvc ]]; then
  dvc init --quiet
  ok "DVC initialised."
else
  ok "DVC already initialised."
fi

# ---------------------------------------------------------------------------
# Determine R2 folder name
# ---------------------------------------------------------------------------
if [[ -z "${FLUX_R2_FOLDER:-}" ]]; then
  FLUX_R2_FOLDER=$(git remote get-url origin 2>/dev/null \
    | sed 's/\.git$//' | sed 's/.*\///' || true)
fi
[[ -n "$FLUX_R2_FOLDER" ]] \
  || fail "Cannot derive R2 folder — set FLUX_R2_FOLDER in $FLUX_CONFIG or add a git remote."
ok "R2 folder: ${FLUX_R2_FOLDER}"

# ---------------------------------------------------------------------------
# Configure DVC remote
# ---------------------------------------------------------------------------
R2_ENDPOINT="https://${FLUX_R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
dvc remote add    -f    r2remote "s3://${FLUX_R2_BUCKET}/${FLUX_R2_FOLDER}" --quiet
dvc remote modify       r2remote endpointurl "$R2_ENDPOINT"                 --quiet
dvc remote modify       r2remote region      auto                            --quiet
dvc remote modify --local r2remote access_key_id    "$FLUX_R2_ACCESS_KEY_ID"  --quiet
dvc remote modify --local r2remote secret_access_key "$FLUX_R2_SECRET_KEY"    --quiet
ok "DVC remote: s3://${FLUX_R2_BUCKET}/${FLUX_R2_FOLDER}"

# ---------------------------------------------------------------------------
# Per-repo git config
# ---------------------------------------------------------------------------
git config dvc-router.size-threshold-mb "$FLUX_SIZE_THRESHOLD_MB"
git config dvc-router.verbose "$FLUX_VERBOSE"

# ---------------------------------------------------------------------------
# Install pre-commit hook
# ---------------------------------------------------------------------------
HOOKS_DIR="$(git rev-parse --git-dir)/hooks"
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SOURCE="${_dir}/../share/flux/pre-commit"
[[ -f "$HOOK_SOURCE" ]] || HOOK_SOURCE="${_dir}/pre-commit"
[[ -f "$HOOK_SOURCE" ]] || fail "pre-commit hook not found (expected at $HOOK_SOURCE)."
cp "$HOOK_SOURCE" "${HOOKS_DIR}/pre-commit"
chmod +x "${HOOKS_DIR}/pre-commit"
ok "pre-commit hook installed."

# ---------------------------------------------------------------------------
# Update .gitignore
# ---------------------------------------------------------------------------
touch .gitignore
for entry in ".dvc/config.local" ".dvc/tmp/" ".dvc/cache/"; do
  grep -qF "$entry" .gitignore || echo "$entry" >> .gitignore
done
ok ".gitignore updated."

# ---------------------------------------------------------------------------
# Commit initial DVC config
# ---------------------------------------------------------------------------
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
echo "    flux-commit -m 'your message'   # commit — hook routes files automatically"
echo "    flux-push                        # git push + dvc push"
echo "    flux-pull                        # git pull + dvc pull"
echo ""
