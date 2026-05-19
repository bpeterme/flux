#!/usr/bin/env bats
# Integration tests for flux setup.sh.
# Uses mock DVC and python3 — no real DVC installation or R2 credentials needed.

load 'helpers/common'

setup()    { setup_flux_test; }
teardown() { teardown_flux_test; }

# ---------------------------------------------------------------------------
# Syntax checks
# ---------------------------------------------------------------------------

@test "setup.sh passes bash syntax check" {
  run bash -n "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
}

@test "pre-commit passes bash syntax check" {
  run bash -n "$REPO_ROOT/pre-commit"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Error cases — fail fast with clear messages
# ---------------------------------------------------------------------------

@test "setup.sh fails when config file is absent" {
  local empty_home
  empty_home=$(mktemp -d)
  run env HOME="$empty_home" bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"flux.env"* ]]
  rm -rf "$empty_home"
}

@test "setup.sh fails when FLUX_R2_SECRET_KEY is unset" {
  local partial_home
  partial_home=$(mktemp -d)
  mkdir -p "$partial_home/.config/flux"
  printf 'FLUX_R2_BUCKET=b\nFLUX_R2_ACCOUNT_ID=a\nFLUX_R2_ACCESS_KEY_ID=k\n' \
    > "$partial_home/.config/flux/flux.env"
  run env HOME="$partial_home" bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FLUX_R2_SECRET_KEY"* ]]
  rm -rf "$partial_home"
}

@test "setup.sh fails when not inside a git repo" {
  local no_git
  no_git=$(mktemp -d)
  run bash -c "cd '$no_git' && HOME='$MOCK_HOME' PATH='$PATH' bash '$REPO_ROOT/setup.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Git repository"* ]]
  rm -rf "$no_git"
}

# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------

@test "setup.sh exits successfully with valid config and mock DVC" {
  run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Setup complete"* ]]
}

@test "setup.sh installs the pre-commit hook" {
  run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  [ -x ".git/hooks/pre-commit" ]
}

@test "setup.sh configures DVC remote" {
  run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  assert_dvc_called "remote add"
}

@test "setup.sh writes required .gitignore entries" {
  run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  grep -qF ".dvc/config.local" .gitignore
  grep -qF ".dvc/tmp/"         .gitignore
  grep -qF ".dvc/cache/"       .gitignore
}

@test "setup.sh derives R2 folder from git remote when FLUX_R2_FOLDER is unset" {
  # Remove FLUX_R2_FOLDER so auto-detection from the git remote URL kicks in
  sed -i '/^FLUX_R2_FOLDER/d' "$HOME/.config/flux/flux.env"
  run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  # Remote URL is https://github.com/test/test-project.git → folder = test-project
  assert_dvc_called "remote add -f r2remote s3://test-bucket/test-project"
}

@test "setup.sh skips DVC init when .dvc already exists" {
  mkdir -p .dvc && printf '' > .dvc/config
  run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already initialised"* ]]
  assert_dvc_not_called "init"
}
