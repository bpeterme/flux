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
