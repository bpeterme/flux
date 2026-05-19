#!/usr/bin/env bash
# Shared test helpers for flux bats test suite.
# Load with: load 'helpers/common'

# Absolute path to the flux repo root (two levels up from tests/helpers/)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ---------------------------------------------------------------------------
# setup_test_repo
#
# Creates an isolated git repo in a temp directory with:
#   - git configured (user, branch name, size threshold)
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
  git config dvc-router.size-threshold-mb 1
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
  local size="${2:-1048577}"   # 1 MB + 1 byte — above the 1 MB test threshold
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
# Creates an isolated environment for testing setup.sh:
#   - Temp HOME with ~/.config/flux/flux.env (all required vars set)
#   - Mock dvc and python3 prepended to PATH (setup.sh calls both directly)
#   - Isolated git repo with a remote and git user configured
#   - Working directory set to the test repo
#
# Exports: TEST_REPO, MOCK_HOME, MOCK_BIN, REAL_HOME, REAL_PATH, MOCK_DVC_LOG
# ---------------------------------------------------------------------------
setup_flux_test() {
  TEST_REPO=$(mktemp -d)
  MOCK_HOME=$(mktemp -d)
  MOCK_BIN=$(mktemp -d)

  # Flux config with all required vars plus FLUX_R2_FOLDER to skip git-remote detection
  mkdir -p "$MOCK_HOME/.config/flux"
  cat > "$MOCK_HOME/.config/flux/flux.env" << 'EOF'
FLUX_R2_BUCKET=test-bucket
FLUX_R2_ACCOUNT_ID=test-account-id
FLUX_R2_ACCESS_KEY_ID=test-key-id
FLUX_R2_SECRET_KEY=test-secret-key
FLUX_R2_FOLDER=test-project
EOF

  # Mock dvc — setup.sh calls dvc directly (not via find_dvc), so it must be in PATH
  cp "$REPO_ROOT/tests/helpers/mock_dvc" "$MOCK_BIN/dvc"
  chmod +x "$MOCK_BIN/dvc"

  # Mock python3 — always exits 0 so the "import dvc_s3" check passes
  cat > "$MOCK_BIN/python3" << 'PYEOF'
#!/usr/bin/env bash
exit 0
PYEOF
  chmod +x "$MOCK_BIN/python3"

  export REAL_HOME="$HOME"
  export REAL_PATH="$PATH"
  export HOME="$MOCK_HOME"
  export PATH="$MOCK_BIN:$PATH"
  export MOCK_DVC_LOG="$TEST_REPO/dvc_calls.log"

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
  rm -rf "$TEST_REPO" "$MOCK_HOME" "$MOCK_BIN"
  unset TEST_REPO MOCK_HOME MOCK_BIN REAL_HOME REAL_PATH MOCK_DVC_LOG
}
