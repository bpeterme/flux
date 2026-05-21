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

# ---------------------------------------------------------------------------
# flux dry-run
# ---------------------------------------------------------------------------

@test "flux dry-run with no staged files exits cleanly" {
  run bash "$REPO_ROOT/flux" dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"No staged files"* ]]
}

@test "flux dry-run shows small text file routed to Git" {
  echo "hello" > note.txt
  git add note.txt

  run bash "$REPO_ROOT/flux" dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"→ Git"* ]]
  [[ "$output" == *"note.txt"* ]]
}

@test "flux dry-run shows binary file routed to DVC" {
  printf '\x00\x01\x02\x03\xff\xfe' > asset.bin
  git add asset.bin

  run bash "$REPO_ROOT/flux" dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"→ DVC / R2"* ]]
  [[ "$output" == *"asset.bin"* ]]
}

@test "flux dry-run shows large text file routed to DVC" {
  # threshold in setup_flux_test is 5 MB; make a 6 MB file
  printf '%*s' $(( 6 * 1024 * 1024 + 1 )) '' | tr ' ' 'a' > big.txt
  git add big.txt

  run bash "$REPO_ROOT/flux" dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"→ DVC / R2"* ]]
  [[ "$output" == *"big.txt"* ]]
}

@test "flux dry-run shows both sections for mixed staging" {
  echo "small" > keep.txt
  printf '\x00\x01\x02' > drop.bin
  git add keep.txt drop.bin

  run bash "$REPO_ROOT/flux" dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"→ Git"* ]]
  [[ "$output" == *"→ DVC / R2"* ]]
  [[ "$output" == *"keep.txt"* ]]
  [[ "$output" == *"drop.bin"* ]]
}

@test "flux dry-run shows already-DVC-tracked file as skipped" {
  printf '\x00\x01\x02' > asset.bin
  cat > asset.bin.dvc << 'EOF'
outs:
- md5: deadbeef
  path: asset.bin
EOF
  git add asset.bin.dvc
  git commit -m "dvc-tracked asset" --no-verify -q

  echo "trigger" > t.txt
  git add t.txt asset.bin 2>/dev/null || true

  run bash "$REPO_ROOT/flux" dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already in DVC"* ]]
  [[ "$output" == *"asset.bin"* ]]
}

@test "flux dry-run flags Git-tracked file that now exceeds threshold as migrating" {
  echo "small" > growing.txt
  git add growing.txt
  git commit -m "small file" --no-verify -q

  printf '%*s' $(( 6 * 1024 * 1024 + 1 )) '' | tr ' ' 'a' > growing.txt
  git add growing.txt

  run bash "$REPO_ROOT/flux" dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"migrating from Git"* ]]
  [[ "$output" == *"growing.txt"* ]]
}

@test "flux dry-run respects per-repo size threshold from git config" {
  git config dvc-router.size-threshold-mb 1
  # File is 2 KB — above 1 KB but well below default 5 MB; should go to Git at 5 MB threshold
  # but with a 1 MB threshold it still goes to Git (2 KB < 1 MB).
  # Use a file just over 1 MB to verify the threshold is read correctly.
  printf '%*s' $(( 1024 * 1024 + 1 )) '' | tr ' ' 'a' > medium.txt
  git add medium.txt

  run bash "$REPO_ROOT/flux" dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"→ DVC / R2"* ]]
  [[ "$output" == *"medium.txt"* ]]
  [[ "$output" == *"threshold: 1 MB"* ]]
}
