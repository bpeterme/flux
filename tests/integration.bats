#!/usr/bin/env bats
# Integration tests for flux CLI.
# Uses mock DVC and python3 — no real DVC installation or R2 credentials needed.

load 'helpers/common'

setup()    { setup_flux_test; }
teardown() { teardown_flux_test; }

# ---------------------------------------------------------------------------
# Syntax checks
# ---------------------------------------------------------------------------

@test "flux passes bash syntax check" {
  run bash -n "$REPO_ROOT/flux"
  [ "$status" -eq 0 ]
}

@test "pre-commit passes bash syntax check" {
  run bash -n "$REPO_ROOT/pre-commit"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Error cases — fail fast with clear messages
# ---------------------------------------------------------------------------

@test "flux add fails when flux.env is absent" {
  rm -f "$HOME/.config/flux/flux.env"
  run bash "$REPO_ROOT/flux" add
  [ "$status" -ne 0 ]
  [[ "$output" == *"flux config"* ]]
}

@test "flux add fails when secret key is missing from Keychain" {
  local partial_keychain
  partial_keychain=$(mktemp -d)
  MOCK_KEYCHAIN_DIR="$partial_keychain" "$MOCK_BIN/security" \
    add-generic-password -U -s "flux.r2.access-key-id" -w "test-key-id"
  # No secret key — _flux_is_configured must return 1
  run env MOCK_KEYCHAIN_DIR="$partial_keychain" bash "$REPO_ROOT/flux" add
  [ "$status" -ne 0 ]
  [[ "$output" == *"flux config"* ]]
  rm -rf "$partial_keychain"
}

@test "flux add fails when not inside a git repo" {
  local no_git
  no_git=$(mktemp -d)
  run bash -c "cd '$no_git' && HOME='$MOCK_HOME' XDG_CONFIG_HOME='$MOCK_HOME/.config' MOCK_KEYCHAIN_DIR='$MOCK_KEYCHAIN_DIR' PATH='$PATH' bash '$REPO_ROOT/flux' add"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Git repository"* ]]
  rm -rf "$no_git"
}

# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------

@test "flux add exits successfully with valid config and mock DVC" {
  run bash "$REPO_ROOT/flux" add
  [ "$status" -eq 0 ]
  [[ "$output" == *"flux added"* ]]
}

@test "flux add installs the pre-commit hook" {
  run bash "$REPO_ROOT/flux" add
  [ "$status" -eq 0 ]
  [ -x ".git/hooks/pre-commit" ]
}

@test "flux add configures DVC remote" {
  run bash "$REPO_ROOT/flux" add
  [ "$status" -eq 0 ]
  assert_dvc_called "remote add"
}

@test "flux add writes required .gitignore entries" {
  run bash "$REPO_ROOT/flux" add
  [ "$status" -eq 0 ]
  grep -qF ".dvc/config.local" .gitignore
  grep -qF ".dvc/tmp/"         .gitignore
  grep -qF ".dvc/cache/"       .gitignore
}

@test "flux add derives R2 folder from git remote when flux.r2-folder is not configured" {
  # git config flux.r2-folder is not set — auto-detection from the remote URL kicks in
  run bash "$REPO_ROOT/flux" add
  [ "$status" -eq 0 ]
  # Remote URL is https://github.com/test/test-project.git → folder = test-project
  assert_dvc_called "remote add -f r2remote s3://test-bucket/test-project"
}

@test "flux add skips DVC init when .dvc already exists" {
  mkdir -p .dvc && printf '' > .dvc/config
  run bash "$REPO_ROOT/flux" add
  [ "$status" -eq 0 ]
  [[ "$output" == *"already initialised"* ]]
  assert_dvc_not_called "init"
}

# ---------------------------------------------------------------------------
# flux version and help
# ---------------------------------------------------------------------------

@test "flux version prints version string" {
  run bash "$REPO_ROOT/flux" version
  [ "$status" -eq 0 ]
  [[ "$output" == flux* ]]
}

@test "flux help prints all three sections" {
  run bash "$REPO_ROOT/flux" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"Maintenance"* ]]
  [[ "$output" == *"Help"* ]]
  [[ "$output" == *"flux doctor"* ]]
}

@test "flux unknown command exits non-zero" {
  run bash "$REPO_ROOT/flux" notacommand
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown command"* ]]
}

# ---------------------------------------------------------------------------
# flux remove
# ---------------------------------------------------------------------------

@test "flux remove removes the pre-commit hook" {
  bash "$REPO_ROOT/flux" add
  run bash "$REPO_ROOT/flux" remove
  [ "$status" -eq 0 ]
  [ ! -f ".git/hooks/pre-commit" ]
}

@test "flux remove warns when no pre-commit hook is present" {
  run bash "$REPO_ROOT/flux" remove
  [ "$status" -eq 0 ]
  [[ "$output" == *"No pre-commit hook"* ]]
}

# ---------------------------------------------------------------------------
# flux doctor
# ---------------------------------------------------------------------------

@test "flux doctor passes in a fully configured environment" {
  bash "$REPO_ROOT/flux" add
  run bash "$REPO_ROOT/flux" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"All checks passed"* ]]
}

@test "flux doctor warns when flux.env is absent" {
  rm -f "$HOME/.config/flux/flux.env"
  run bash "$REPO_ROOT/flux" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"Some checks failed"* ]]
  [[ "$output" == *"Config file not found"* ]]
}

@test "flux doctor warns when pre-commit hook is missing" {
  bash "$REPO_ROOT/flux" add
  rm -f ".git/hooks/pre-commit"
  run bash "$REPO_ROOT/flux" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"Some checks failed"* ]]
  [[ "$output" == *"Pre-commit hook"* ]]
}
