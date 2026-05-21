#!/usr/bin/env bash
# Shared test helpers for flux bats test suite.
# Load with: load 'helpers/common'

# Absolute path to the flux repo root (two levels up from tests/helpers/)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ---------------------------------------------------------------------------
# setup_test_repo
#
# Creates an isolated git repo in a temp directory with:
#   - git configured (user, branch name, size cap)
#   - mock DVC installed where find_dvc() will find it
#   - HOME overridden so find_dvc's hardcoded candidate paths resolve to mock
#   - setup.sh containing VERSION="0.0.0" (needed by bump_version)
#   - pre-commit hook installed
#   - working directory set to the test repo
#
# Exports: TEST_REPO, MOCK_HOME, REAL_HOME, MOCK_DVC_LOG
# ---------------------------------------------------------------------------
setup_test_repo() {
  TEST_REPO=$(mktemp -d)
  MOCK_HOME=$(mktemp -d)

  # Place mock DVC at ${HOME}/.homebrew/bin/dvc — one of find_dvc()'s
  # hardcoded candidates — so it is found before any real DVC on PATH.
  mkdir -p "$MOCK_HOME/.homebrew/bin"
  cp "$REPO_ROOT/tests/helpers/mock_dvc" "$MOCK_HOME/.homebrew/bin/dvc"
  chmod +x "$MOCK_HOME/.homebrew/bin/dvc"

  export REAL_HOME="$HOME"
  export HOME="$MOCK_HOME"
  export MOCK_DVC_LOG="$TEST_REPO/dvc_calls.log"

  cd "$TEST_REPO"

  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"
  git config dvc-router.size-cap-mb 1
  git config dvc-router.verbose false

  # Ensure we are on 'main' regardless of git's defaultBranch setting.
  git checkout -b main 2>/dev/null \
    || git checkout main 2>/dev/null \
    || git branch -m main 2>/dev/null \
    || true

  git commit --allow-empty -m "initial" --no-verify -q

  cp "$REPO_ROOT/pre-commit" .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
}

# ---------------------------------------------------------------------------
# teardown_test_repo — cleans up temp dirs created by setup_test_repo
# ---------------------------------------------------------------------------
teardown_test_repo() {
  cd /tmp
  export HOME="$REAL_HOME"
  rm -rf "$TEST_REPO" "$MOCK_HOME"
  unset TEST_REPO MOCK_HOME REAL_HOME MOCK_DVC_LOG
}

# ---------------------------------------------------------------------------
# Helpers to create test files
# ---------------------------------------------------------------------------

# make_large_text_file FILE [SIZE_BYTES]
# Creates a plain-text file just over 1 MB (default) with no null bytes.
make_large_text_file() {
  local file="$1"
  local size="${2:-1048577}"   # 1 MB + 1 byte — above the 1 MB test cap
  printf '%*s' "$size" '' | tr ' ' 'a' > "$file"
}

# make_binary_file FILE
# Creates a file containing null bytes (binary).
make_binary_file() {
  local file="$1"
  printf '\x00\x01\x02\x03\xff\xfe' > "$file"
}

# dvc_calls — print the mock DVC call log
dvc_calls() {
  cat "$MOCK_DVC_LOG" 2>/dev/null || true
}

# assert_dvc_called CMD [ARGS...]
# Fails the test if the mock DVC log does not contain a matching call.
assert_dvc_called() {
  local pattern="$*"
  if ! grep -qF "$pattern" "$MOCK_DVC_LOG" 2>/dev/null; then
    echo "Expected mock DVC to be called with: $pattern"
    echo "Actual calls:"
    dvc_calls
    return 1
  fi
}

# assert_dvc_not_called CMD [ARGS...]
assert_dvc_not_called() {
  local pattern="$*"
  if grep -qF "$pattern" "$MOCK_DVC_LOG" 2>/dev/null; then
    echo "Expected mock DVC NOT to be called with: $pattern"
    echo "Actual calls:"
    dvc_calls
    return 1
  fi
}

# ---------------------------------------------------------------------------
# setup_flux_test / teardown_flux_test
#
# Creates an isolated environment for integration-testing the flux CLI:
#   - Mock dvc, security (Keychain), uname, and python3 prepended to PATH
#   - Mock Keychain pre-populated with all required R2 credentials
#   - Isolated git repo with a remote and git user configured
#   - Working directory set to the test repo
#
# Exports: TEST_REPO, MOCK_HOME, MOCK_BIN, MOCK_KEYCHAIN_DIR,
#          REAL_HOME, REAL_PATH, MOCK_DVC_LOG
# ---------------------------------------------------------------------------
setup_flux_test() {
  TEST_REPO=$(mktemp -d)
  MOCK_HOME=$(mktemp -d)
  MOCK_BIN=$(mktemp -d)
  MOCK_KEYCHAIN_DIR=$(mktemp -d)

  # Mock dvc — flux calls dvc directly, so it must be in PATH
  cp "$REPO_ROOT/tests/helpers/mock_dvc" "$MOCK_BIN/dvc"
  chmod +x "$MOCK_BIN/dvc"

  # Mock security — simulates macOS Keychain using MOCK_KEYCHAIN_DIR
  cp "$REPO_ROOT/tests/helpers/mock_security" "$MOCK_BIN/security"
  chmod +x "$MOCK_BIN/security"

  # Mock uname — returns "Darwin" for the macOS guard in flux
  cat > "$MOCK_BIN/uname" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-s" ]]; then echo "Darwin"; else /usr/bin/uname "$@"; fi
EOF
  chmod +x "$MOCK_BIN/uname"

  # Mock python3 — always exits 0
  cat > "$MOCK_BIN/python3" << 'PYEOF'
#!/usr/bin/env bash
exit 0
PYEOF
  chmod +x "$MOCK_BIN/python3"

  export REAL_HOME="$HOME"
  export REAL_PATH="$PATH"
  export REAL_XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-}"
  export HOME="$MOCK_HOME"
  export XDG_CONFIG_HOME="$MOCK_HOME/.config"
  export PATH="$MOCK_BIN:$PATH"
  export MOCK_DVC_LOG="$TEST_REPO/dvc_calls.log"
  export MOCK_KEYCHAIN_DIR

  # Write non-sensitive global config to flux.env (bucket, account ID, routing).
  mkdir -p "$MOCK_HOME/.config/flux"
  cat > "$MOCK_HOME/.config/flux/flux.env" << 'EOF'
FLUX_R2_BUCKET="test-bucket"
FLUX_R2_ACCOUNT_ID="test-account-id"
FLUX_SIZE_CAP_MB=5
FLUX_VERBOSE=false
EOF

  # Pre-populate mock Keychain with credentials only (access key + secret).
  MOCK_KEYCHAIN_DIR="$MOCK_KEYCHAIN_DIR" "$MOCK_BIN/security" \
    add-generic-password -U -s "flux.r2.access-key-id" -w "test-key-id"
  MOCK_KEYCHAIN_DIR="$MOCK_KEYCHAIN_DIR" "$MOCK_BIN/security" \
    add-generic-password -U -s "flux.r2.secret-key"    -w "test-secret-key"

  cd "$TEST_REPO"

  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"
  git checkout -b main 2>/dev/null \
    || git checkout main 2>/dev/null \
    || git branch -m main 2>/dev/null \
    || true
  git remote add origin "https://github.com/test/test-project.git"
  git commit --allow-empty -m "initial" --no-verify -q
}

# ---------------------------------------------------------------------------
# teardown_flux_test — cleans up temp dirs created by setup_flux_test
# ---------------------------------------------------------------------------
teardown_flux_test() {
  cd /tmp
  export HOME="$REAL_HOME"
  export PATH="$REAL_PATH"
  if [[ -n "${REAL_XDG_CONFIG_HOME:-}" ]]; then
    export XDG_CONFIG_HOME="$REAL_XDG_CONFIG_HOME"
  else
    unset XDG_CONFIG_HOME
  fi
  rm -rf "$TEST_REPO" "$MOCK_HOME" "$MOCK_BIN" "$MOCK_KEYCHAIN_DIR"
  unset TEST_REPO MOCK_HOME MOCK_BIN MOCK_KEYCHAIN_DIR \
        REAL_HOME REAL_PATH REAL_XDG_CONFIG_HOME MOCK_DVC_LOG
}
