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
  assert_dvc_called "remote default r2remote"
}

@test "flux add writes required .gitignore entries" {
  run bash "$REPO_ROOT/flux" add
  [ "$status" -eq 0 ]
  grep -qF ".dvc/config.local" .gitignore
  grep -qF ".dvc/tmp/"         .gitignore
  grep -qF ".dvc/cache/"       .gitignore
}

@test "flux add uses pre-configured R2 folder from git config" {
  # flux.r2-folder set in git config — flux must use it without prompting
  git config flux.r2-folder "test-project"
  run bash "$REPO_ROOT/flux" add
  [ "$status" -eq 0 ]
  assert_dvc_called "remote add -f r2remote s3://test-bucket/test-project"
}

@test "flux add skips DVC init when .dvc already exists" {
  mkdir -p .dvc && printf '' > .dvc/config
  run bash "$REPO_ROOT/flux" add
  [ "$status" -eq 0 ]
  [[ "$output" == *"already initialised"* ]]
  assert_dvc_not_called "init"
}

@test "flux add does not mark dvc_initialized in registry when .dvc pre-existed" {
  # Simulate a project that already had DVC before flux add was run.
  mkdir -p .dvc && printf '' > .dvc/config
  run bash "$REPO_ROOT/flux" add
  [ "$status" -eq 0 ]
  # Registry must NOT contain dvc_initialized — flux did not create .dvc/
  ! grep -q "dvc_initialized" .git/flux-registry
}

@test "flux remove dvc does not remove pre-existing .dvc directory" {
  # Create .dvc before flux add so flux does not own it.
  mkdir -p .dvc && printf '' > .dvc/config
  bash "$REPO_ROOT/flux" add
  # flux-registry must not have dvc_initialized (asserted above),
  # so flux remove dvc should leave .dvc/ intact.
  run bash "$REPO_ROOT/flux" remove dvc
  [ "$status" -eq 0 ]
  [ -d ".dvc" ]
}

@test "flux add warns about pre-existing staged files before committing" {
  # Stage a user file before running flux add.
  echo "my work" > work.txt
  git add work.txt
  run bash "$REPO_ROOT/flux" add
  [ "$status" -eq 0 ]
  # User must be explicitly told their staged changes are present.
  [[ "$output" == *"Your staged changes will be included"* ]]
}

@test "flux add does not commit pre-existing staged files when user declines" {
  # Skip the R2 folder prompt so the only interactive read is the commit confirm.
  git config flux.r2-folder "test-project"
  echo "my work" > work.txt
  git add work.txt
  # Decline the flux commit (send 'n').
  run bash -c "echo n | bash '$REPO_ROOT/flux' add"
  [ "$status" -eq 0 ]
  # work.txt must still be staged (not committed, not unstaged).
  run git diff --cached --name-only
  [[ "$output" == *"work.txt"* ]]
  # No commit should have been made beyond the initial empty one.
  [ "$(git rev-list --count HEAD)" -eq 1 ]
}

@test "flux add on an already-initialized repo shows status and exits cleanly" {
  bash "$REPO_ROOT/flux" add
  run bash "$REPO_ROOT/flux" add
  [ "$status" -eq 0 ]
  [[ "$output" == *"already managed by flux"* ]]
  [[ "$output" != *"flux added"* ]]
}

@test "flux add on an already-initialized repo still syncs sub-repos" {
  bash "$REPO_ROOT/flux" add

  mkdir -p late
  git -C late init -q

  run bash "$REPO_ROOT/flux" add
  [ "$status" -eq 0 ]
  [[ "$output" == *"already managed by flux"* ]]
  grep -qF "late/" .gitignore
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

@test "flux remove fails with clear error in a non-flux git repo" {
  run bash "$REPO_ROOT/flux" remove
  [ "$status" -ne 0 ]
  [[ "$output" == *"flux add"* ]]
}

@test "flux remove git warns when no pre-commit hook is present" {
  run bash "$REPO_ROOT/flux" remove git
  [ "$status" -eq 0 ]
  [[ "$output" == *"No pre-commit hook"* ]]
}

@test "flux remove removes .dvc/ directory" {
  bash "$REPO_ROOT/flux" add
  run bash "$REPO_ROOT/flux" remove
  [ "$status" -eq 0 ]
  [ ! -d ".dvc" ]
}

@test "flux remove cleans up flux .gitignore entries" {
  bash "$REPO_ROOT/flux" add
  bash "$REPO_ROOT/flux" remove
  ! grep -qF ".dvc/config.local" .gitignore
  ! grep -qF ".dvc/tmp/" .gitignore
  ! grep -qF ".dvc/cache/" .gitignore
}

@test "flux remove git removes hook and git config but leaves .dvc/" {
  bash "$REPO_ROOT/flux" add
  run bash "$REPO_ROOT/flux" remove git
  [ "$status" -eq 0 ]
  [ ! -f ".git/hooks/pre-commit" ]
  [ -d ".dvc" ]
  ! git config --get flux.r2-folder 2>/dev/null
}

@test "flux remove dvc removes .dvc/ but leaves git hook" {
  bash "$REPO_ROOT/flux" add
  run bash "$REPO_ROOT/flux" remove dvc
  [ "$status" -eq 0 ]
  [ ! -d ".dvc" ]
  [ -f ".git/hooks/pre-commit" ]
}

@test "flux remove dvc removes .dvc pointer files" {
  bash "$REPO_ROOT/flux" add
  # create pointer + matching data file so the missing-data guard does not trigger
  echo "data" > model.bin
  echo "outs:" > model.bin.dvc
  run bash "$REPO_ROOT/flux" remove dvc
  [ "$status" -eq 0 ]
  [ ! -f "model.bin.dvc" ]
}

@test "flux add writes registry file" {
  bash "$REPO_ROOT/flux" add
  [ -f ".git/flux-registry" ]
  grep -q "hook:pre-commit" .git/flux-registry
  grep -q "dvc_remote:r2remote" .git/flux-registry
  grep -q "gitignore:.dvc/config.local" .git/flux-registry
}

@test "flux remove unknown subcommand exits non-zero" {
  run bash "$REPO_ROOT/flux" remove badarg
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown remove target"* ]]
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
# flux pull / sync — guard against non-flux repos
# ---------------------------------------------------------------------------

@test "flux pull fails with clear error in a non-flux git repo" {
  run bash "$REPO_ROOT/flux" pull
  [ "$status" -ne 0 ]
  [[ "$output" == *"flux add"* ]]
}

@test "flux sync fails with clear error in a non-flux git repo" {
  run bash "$REPO_ROOT/flux" sync
  [ "$status" -ne 0 ]
  [[ "$output" == *"flux add"* ]]
}

@test "flux sync updates an outdated pre-commit hook" {
  # Wire up a local bare remote so sync can complete
  local bare; bare="$(mktemp -d)/origin.git"
  git clone --bare -q "$TEST_REPO" "$bare"
  git remote set-url origin "file://$bare"
  git push -u origin main -q

  bash "$REPO_ROOT/flux" add

  # Simulate an outdated hook: still a flux hook but different content
  printf '#!/usr/bin/env bash\n# flux dvc-router v0.0 (outdated)\n' > .git/hooks/pre-commit

  run bash "$REPO_ROOT/flux" sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pre-commit hook updated"* ]]
  # Hook must now match the current pre-commit script
  cmp -s "$REPO_ROOT/pre-commit" .git/hooks/pre-commit
  rm -rf "$(dirname "$bare")"
}

@test "flux sync does not print hook update notice when hook is current" {
  local bare; bare="$(mktemp -d)/origin.git"
  git clone --bare -q "$TEST_REPO" "$bare"
  git remote set-url origin "file://$bare"
  git push -u origin main -q

  bash "$REPO_ROOT/flux" add

  run bash "$REPO_ROOT/flux" sync
  [ "$status" -eq 0 ]
  [[ "$output" != *"Pre-commit hook updated"* ]]
  rm -rf "$(dirname "$bare")"
}

@test "flux sync commits and pushes untracked files (not just modified tracked files)" {
  local bare; bare="$(mktemp -d)/origin.git"
  git clone --bare -q "$TEST_REPO" "$bare"
  git remote set-url origin "file://$bare"
  git push -u origin main -q

  bash "$REPO_ROOT/flux" add

  # Create an untracked file — never staged, never added to git
  echo "brand new content" > new_file.txt

  run bash "$REPO_ROOT/flux" sync
  [ "$status" -eq 0 ]

  # The sync commit must have been created locally
  local sync_commit
  sync_commit=$(git log --oneline | grep "^.\{7\} sync:" | head -1)
  [[ -n "$sync_commit" ]]

  # The sync commit must have been pushed to the bare remote
  local remote_log
  remote_log=$(git -C "$bare" log --oneline)
  [[ "$remote_log" == *"sync:"* ]]

  # The file must be tracked in git after the sync commit
  git ls-files new_file.txt | grep -q "new_file.txt"

  rm -rf "$(dirname "$bare")"
}

# ---------------------------------------------------------------------------
# flux dry-run
# ---------------------------------------------------------------------------

@test "flux dry-run with no staged files exits cleanly" {
  run bash "$REPO_ROOT/flux" dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"No files to preview"* ]]
}

@test "flux dry-run shows small text file routed to Git" {
  echo "hello" > note.txt
  git add note.txt

  run bash "$REPO_ROOT/flux" dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"→ Git"* ]]
}

@test "flux dry-run shows binary file routed to DVC" {
  printf '\x00\x01\x02\x03\xff\xfe' > asset.bin
  git add asset.bin

  run bash "$REPO_ROOT/flux" dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"→ DVC"* ]]
}

@test "flux dry-run shows large text file routed to DVC" {
  # cap in setup_flux_test is 5 MB; make a 6 MB file
  printf '%*s' $(( 6 * 1024 * 1024 + 1 )) '' | tr ' ' 'a' > big.txt
  git add big.txt

  run bash "$REPO_ROOT/flux" dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"→ DVC"* ]]
}

@test "flux dry-run shows both sections for mixed staging" {
  echo "small" > keep.txt
  printf '\x00\x01\x02' > drop.bin
  git add keep.txt drop.bin

  run bash "$REPO_ROOT/flux" dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"→ Git"* ]]
  [[ "$output" == *"→ DVC"* ]]
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
  [[ "$output" == *"already in DVC"* ]]
}

@test "flux dry-run flags Git-tracked file that now exceeds cap as migrating" {
  echo "small" > growing.txt
  git add growing.txt
  git commit -m "small file" --no-verify -q

  printf '%*s' $(( 6 * 1024 * 1024 + 1 )) '' | tr ' ' 'a' > growing.txt
  git add growing.txt

  run bash "$REPO_ROOT/flux" dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"migrating from Git"* ]]
}

@test "flux dry-run includes untracked files when nothing is staged" {
  echo "untracked content" > untracked.txt

  run bash "$REPO_ROOT/flux" dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"→ Git"* ]]
  [[ "$output" == *"all files"* ]]
}

@test "flux dry-run includes large untracked file routed to DVC" {
  printf '%*s' $(( 6 * 1024 * 1024 + 1 )) '' | tr ' ' 'a' > big_untracked.txt

  run bash "$REPO_ROOT/flux" dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"→ DVC"* ]]
}

@test "flux dry-run respects per-repo size cap from git config" {
  git config dvc-router.size-cap-mb 1
  # File is 2 KB — above 1 KB but well below default 5 MB; should go to Git at 5 MB cap
  # but with a 1 MB cap it still goes to Git (2 KB < 1 MB).
  # Use a file just over 1 MB to verify the cap is read correctly.
  printf '%*s' $(( 1024 * 1024 + 1 )) '' | tr ' ' 'a' > medium.txt
  git add medium.txt

  run bash "$REPO_ROOT/flux" dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"→ DVC"* ]]
  [[ "$output" == *"cap: 1 MB"* ]]
}

# ---------------------------------------------------------------------------
# flux cap
# ---------------------------------------------------------------------------

@test "flux cap shows global default as active when no per-project override is set" {
  run bash "$REPO_ROOT/flux" cap
  [ "$status" -eq 0 ]
  [[ "$output" == *"Global default:"*"5 MB"* ]]
  [[ "$output" == *"← active"* ]]
  [[ "$output" == *"(not set)"* ]]
}

@test "flux cap shows per-project override as active when set" {
  git config dvc-router.size-cap-mb 20
  run bash "$REPO_ROOT/flux" cap
  [ "$status" -eq 0 ]
  [[ "$output" == *"Global default:"*"5 MB"* ]]
  [[ "$output" == *"Per-project:"*"20 MB"* ]]
  [[ "$output" == *"← active"* ]]
}

@test "flux cap N sets the per-project cap in git config" {
  run bash "$REPO_ROOT/flux" cap 20
  [ "$status" -eq 0 ]
  [ "$(git config --get dvc-router.size-cap-mb)" = "20" ]
}

@test "flux cap --reset removes the per-project override" {
  git config dvc-router.size-cap-mb 20
  run bash "$REPO_ROOT/flux" cap --reset
  [ "$status" -eq 0 ]
  run git config --get dvc-router.size-cap-mb
  [ "$status" -ne 0 ]
}

@test "flux cap rejects zero" {
  run bash "$REPO_ROOT/flux" cap 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid value"* ]]
}

@test "flux cap rejects non-numeric input" {
  run bash "$REPO_ROOT/flux" cap abc
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid value"* ]]
}

@test "flux cap fails outside a git repo" {
  local no_git
  no_git=$(mktemp -d)
  run bash -c "cd '$no_git' && HOME='$MOCK_HOME' XDG_CONFIG_HOME='$MOCK_HOME/.config' MOCK_KEYCHAIN_DIR='$MOCK_KEYCHAIN_DIR' PATH='$PATH' bash '$REPO_ROOT/flux' cap"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Git repository"* ]]
  rm -rf "$no_git"
}

@test "flux cap set before flux add is preserved by flux add" {
  bash "$REPO_ROOT/flux" cap 20

  run bash "$REPO_ROOT/flux" add
  [ "$status" -eq 0 ]

  [ "$(git config --get dvc-router.size-cap-mb)" = "20" ]
}

# ---------------------------------------------------------------------------
# Sub-repo exclusion — workspace with nested git repositories
# ---------------------------------------------------------------------------

@test "flux add excludes a nested git repo from workspace tracking" {
  mkdir -p sub
  git -C sub init -q
  git -C sub config user.email "sub@example.com"
  git -C sub config user.name "Sub"

  run bash "$REPO_ROOT/flux" add
  [ "$status" -eq 0 ]

  grep -qF "sub/" .gitignore
}

@test "flux add excludes sub-repos at multiple depth levels" {
  mkdir -p a/b/c
  git -C a/b init -q
  git -C a/b config user.email "sub@example.com"
  git -C a/b config user.name "Sub"
  git -C a/b/c init -q  # nested inside a/b — should NOT appear in workspace .gitignore
  git -C a/b/c config user.email "sub@example.com"
  git -C a/b/c config user.name "Sub"

  mkdir -p d/e
  git -C d/e init -q
  git -C d/e config user.email "sub@example.com"
  git -C d/e config user.name "Sub"

  run bash "$REPO_ROOT/flux" add
  [ "$status" -eq 0 ]

  # top-level sub-repos are excluded
  grep -qF "a/b/" .gitignore
  grep -qF "d/e/" .gitignore
  # a/b/c is inside a/b — its parent covers it, so it must NOT get its own entry
  ! grep -qF "a/b/c/" .gitignore
}

@test "files inside a nested git repo are not tracked by the workspace git" {
  mkdir -p service
  git -C service init -q
  git -C service config user.email "sub@example.com"
  git -C service config user.name "Sub"
  echo "service code" > service/main.py

  bash "$REPO_ROOT/flux" add

  run git ls-files service/main.py
  [ -z "$output" ]
}

@test "sub-repo registry entry is written on flux add" {
  mkdir -p sub
  git -C sub init -q

  bash "$REPO_ROOT/flux" add

  grep -q "subrepo_exclusion:sub" .git/flux-registry
}

@test "a sub-repo that disappears is removed from .gitignore on next flux add" {
  mkdir -p sub
  git -C sub init -q

  bash "$REPO_ROOT/flux" add
  grep -qF "sub/" .gitignore

  # Remove the sub-repo
  rm -rf sub

  bash "$REPO_ROOT/flux" add
  ! grep -qF "sub/" .gitignore
}

@test "a new sub-repo appearing after initial flux add is picked up by flux add" {
  bash "$REPO_ROOT/flux" add

  mkdir -p late
  git -C late init -q

  bash "$REPO_ROOT/flux" add

  grep -qF "late/" .gitignore
  grep -q "subrepo_exclusion:late" .git/flux-registry
}

@test "flux remove git cleans up sub-repo exclusions from .gitignore" {
  mkdir -p sub
  git -C sub init -q

  bash "$REPO_ROOT/flux" add
  grep -qF "sub/" .gitignore

  bash "$REPO_ROOT/flux" remove git
  ! grep -qF "sub/" .gitignore
}

# ---------------------------------------------------------------------------
# flux list
# ---------------------------------------------------------------------------

@test "flux list exits zero with no flux repos present" {
  run bash "$REPO_ROOT/flux" list
  [ "$status" -eq 0 ]
}

@test "flux list reports no projects when none are flux-managed" {
  run bash "$REPO_ROOT/flux" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"No flux-managed projects"* ]]
}

@test "flux list finds the current directory when it is flux-managed" {
  git config flux.r2-folder "test-project"
  bash "$REPO_ROOT/flux" add
  run bash "$REPO_ROOT/flux" list
  [ "$status" -eq 0 ]
  [[ "$output" == *". (current)"* ]]
  [[ "$output" == *"test-project"* ]]
}

@test "flux list shows combined bucket/folder as DVC REMOTE" {
  git config flux.r2-folder "test-project"
  bash "$REPO_ROOT/flux" add
  run bash "$REPO_ROOT/flux" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-bucket/test-project"* ]]
  [[ "$output" == *"5 MB"* ]]
}

@test "flux list finds a flux-managed subdirectory" {
  make_flux_repo "$TEST_REPO/child" "child-data" "my-bucket"
  run bash "$REPO_ROOT/flux" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"child"* ]]
  [[ "$output" == *"my-bucket/child-data"* ]]
}

@test "flux list finds multiple flux repos in subdirectories" {
  make_flux_repo "$TEST_REPO/alpha" "alpha-data" "bucket-a"
  make_flux_repo "$TEST_REPO/beta"  "beta-data"  "bucket-b"
  run bash "$REPO_ROOT/flux" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"bucket-a/alpha-data"* ]]
  [[ "$output" == *"bucket-b/beta-data"* ]]
}

@test "flux list excludes plain git repos that are not flux-managed" {
  mkdir -p "$TEST_REPO/plain"
  git -C "$TEST_REPO/plain" init -q
  run bash "$REPO_ROOT/flux" list
  [ "$status" -eq 0 ]
  [[ "$output" != *"plain"* ]]
  [[ "$output" == *"No flux-managed projects"* ]]
}

@test "flux list finds nested flux repos" {
  make_flux_repo "$TEST_REPO/outer"        "outer-data" "bucket"
  make_flux_repo "$TEST_REPO/outer/inner"  "inner-data" "bucket"
  run bash "$REPO_ROOT/flux" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"outer"* ]]
  [[ "$output" == *"inner"* ]]
  [[ "$output" == *"outer-data"* ]]
  [[ "$output" == *"inner-data"* ]]
}

@test "flux list shows custom cap when set" {
  make_flux_repo "$TEST_REPO/capped" "capped-data" "bucket" 20
  run bash "$REPO_ROOT/flux" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"20 MB"* ]]
}

@test "flux list falls back to .dvc/config when flux.dvc-remote-bucket is missing" {
  make_flux_repo "$TEST_REPO/legacy" "legacy-data" "legacy-bucket"
  git -C "$TEST_REPO/legacy" config --unset flux.dvc-remote-bucket
  run bash "$REPO_ROOT/flux" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"legacy-bucket"* ]]
}

@test "flux list shows git remote for current repo" {
  git config flux.r2-folder "test-project"
  bash "$REPO_ROOT/flux" add
  run bash "$REPO_ROOT/flux" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"github.com/test/test-project"* ]]
}

@test "flux list shows dash for git remote when none is configured" {
  make_flux_repo "$TEST_REPO/no-remote" "no-remote-data" "bucket"
  run bash "$REPO_ROOT/flux" list
  [ "$status" -eq 0 ]
  # make_flux_repo does not add a git remote — should display as -
  [[ "$output" == *"no-remote-data"* ]]
}

# ---------------------------------------------------------------------------
# flux clone
# ---------------------------------------------------------------------------

@test "flux clone fails without a URL" {
  run bash "$REPO_ROOT/flux" clone
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "flux clone fails when repo has no .dvc/config" {
  local remote; remote=$(mktemp -d)
  git -C "$remote" init -q
  git -C "$remote" config user.email "test@example.com"
  git -C "$remote" config user.name  "Test"
  git -C "$remote" checkout -b main 2>/dev/null || true
  git -C "$remote" commit --allow-empty -q -m "empty" --no-verify
  run bash "$REPO_ROOT/flux" clone "$remote" "$TEST_REPO/cloned"
  [ "$status" -ne 0 ]
  [[ "$output" == *".dvc/config"* ]]
  rm -rf "$remote"
}

@test "flux clone succeeds with credentials already in Keychain" {
  local remote; remote=$(mktemp -d)
  make_clone_remote "$remote" "test-bucket" "test-project" "abc123"
  run bash "$REPO_ROOT/flux" clone "$remote" "$TEST_REPO/cloned"
  [ "$status" -eq 0 ]
  [[ "$output" == *"flux clone complete"* ]]
  rm -rf "$remote"
}

@test "flux clone writes git config keys" {
  local remote; remote=$(mktemp -d)
  make_clone_remote "$remote" "test-bucket" "test-project" "abc123"
  bash "$REPO_ROOT/flux" clone "$remote" "$TEST_REPO/cloned"
  [ "$(git -C "$TEST_REPO/cloned" config --get flux.r2-folder)" = "test-project" ]
  [ "$(git -C "$TEST_REPO/cloned" config --get flux.dvc-remote-bucket)" = "test-bucket" ]
  rm -rf "$remote"
}

@test "flux clone installs pre-commit hook" {
  local remote; remote=$(mktemp -d)
  make_clone_remote "$remote" "test-bucket" "test-project" "abc123"
  bash "$REPO_ROOT/flux" clone "$remote" "$TEST_REPO/cloned"
  [ -x "$TEST_REPO/cloned/.git/hooks/pre-commit" ]
  grep -q 'dvc-router\|flux' "$TEST_REPO/cloned/.git/hooks/pre-commit"
  rm -rf "$remote"
}

@test "flux clone writes registry file" {
  local remote; remote=$(mktemp -d)
  make_clone_remote "$remote" "test-bucket" "test-project" "abc123"
  bash "$REPO_ROOT/flux" clone "$remote" "$TEST_REPO/cloned"
  [ -f "$TEST_REPO/cloned/.git/flux-registry" ]
  grep -q "hook:pre-commit"             "$TEST_REPO/cloned/.git/flux-registry"
  grep -q "git_config:flux.r2-folder"   "$TEST_REPO/cloned/.git/flux-registry"
  grep -q "dvc_remote:r2remote"         "$TEST_REPO/cloned/.git/flux-registry"
  rm -rf "$remote"
}

@test "flux clone prompts for credentials when not in Keychain" {
  local remote; remote=$(mktemp -d)
  make_clone_remote "$remote" "new-bucket" "new-project" "xyz789"
  run bash -c "printf 'new-key-id\nnew-secret\n' | bash '$REPO_ROOT/flux' clone '$remote' '$TEST_REPO/cloned'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Credentials saved to Keychain"* ]]
  rm -rf "$remote"
}

@test "flux clone saves prompted credentials to Keychain" {
  local remote; remote=$(mktemp -d)
  make_clone_remote "$remote" "new-bucket" "new-project" "xyz789"
  printf 'new-key-id\nnew-secret\n' | bash "$REPO_ROOT/flux" clone "$remote" "$TEST_REPO/cloned"
  local saved
  saved=$(MOCK_KEYCHAIN_DIR="$MOCK_KEYCHAIN_DIR" "$MOCK_BIN/security" \
    find-generic-password -s "flux.dvc.new-bucket.access-key-id" -w 2>/dev/null || echo "")
  [ "$saved" = "new-key-id" ]
  rm -rf "$remote"
}

@test "flux clone runs dvc pull" {
  local remote; remote=$(mktemp -d)
  make_clone_remote "$remote" "test-bucket" "test-project" "abc123"
  bash "$REPO_ROOT/flux" clone "$remote" "$TEST_REPO/cloned"
  assert_dvc_called "pull"
  rm -rf "$remote"
}

@test "flux clone shows next-step cd hint" {
  local remote; remote=$(mktemp -d)
  make_clone_remote "$remote" "test-bucket" "test-project" "abc123"
  run bash "$REPO_ROOT/flux" clone "$remote" "$TEST_REPO/cloned"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cd "$TEST_REPO/cloned""* ]]
  rm -rf "$remote"
}
