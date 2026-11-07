#!/usr/bin/env bats
# Tests for the post-checkout / post-merge / post-rewrite hook: DVC data
# follows plain git branch switches, merges and rebases.
# Uses the mock DVC binary with a real (file-based) .dvc/cache.

load 'helpers/common'

setup() {
  setup_test_repo
  install_sync_hooks
  printf '\x00v1' > data.bin
  dvc_track data.bin
  git commit -qm "data v1" --no-verify
}
teardown() { teardown_test_repo; }

@test "branch switch restores the data version of the target branch" {
  git checkout -qb feature
  printf '\x00v2' > data.bin && dvc_track data.bin
  git commit -qm "data v2" --no-verify

  git checkout -q main
  [ "$(tail -c2 data.bin)" = "v1" ]
  git checkout -q feature
  [ "$(tail -c2 data.bin)" = "v2" ]
}

@test "merge brings the merged branch's data onto disk" {
  git checkout -qb feature
  printf '\x00v2' > data.bin && dvc_track data.bin
  printf '\x00new' > extra.bin && dvc_track extra.bin
  git commit -qm "feature data" --no-verify
  git checkout -q main
  [ ! -e extra.bin ]

  git merge -q --no-edit feature
  [ "$(tail -c2 data.bin)" = "v2" ]
  [ "$(tail -c3 extra.bin)" = "new" ]
}

@test "rebase leaves the rebased branch's data on disk" {
  git checkout -qb feature
  printf '\x00v2' > data.bin && dvc_track data.bin
  git commit -qm "data v2" --no-verify
  git checkout -q main
  echo "side" > side.txt && git add side.txt && git commit -qm side --no-verify
  git checkout -q feature

  git rebase -q main
  [ "$(tail -c2 data.bin)" = "v2" ]
  [ -f side.txt ]
}

@test "data that never reached this machine is listed with flux pull" {
  git checkout -qb feature
  printf 'outs:\n- md5: 0123456789abcdef\n  hash: md5\n  path: remote.bin\n' > remote.bin.dvc
  echo "/remote.bin" >> .gitignore
  git add remote.bin.dvc .gitignore && git commit -qm "pointer only" --no-verify
  git checkout -q main

  run git checkout -q feature
  [ "$status" -eq 0 ]
  [[ "$output" == *"not downloaded"*"remote.bin"*"flux pull"* ]]
}

@test "unmodified data of a pointer the new branch lacks is removed, and comes back" {
  git checkout -qb feature
  git rm -q data.bin.dvc && git commit -qm "drop data" --no-verify
  git checkout -q main
  [ "$(tail -c2 data.bin)" = "v1" ]

  git checkout -q feature
  [ ! -e data.bin ]
  git checkout -q main
  [ "$(tail -c2 data.bin)" = "v1" ]
}

@test "modified data of a pointer the new branch lacks is kept and listed" {
  git checkout -qb feature
  git rm -q data.bin.dvc && git commit -qm "drop data" --no-verify
  git checkout -q main
  printf '\x00edited' > data.bin

  run git checkout -q feature
  [ "$status" -eq 0 ]
  [ "$(tail -c6 data.bin)" = "edited" ]
  [[ "$output" == *"left on disk"*"data.bin"* ]]
}

@test "unsaved edits are never overwritten by a branch switch" {
  git checkout -qb feature
  printf '\x00v2' > data.bin && dvc_track data.bin
  git commit -qm "data v2" --no-verify
  git checkout -q main
  printf '\x00mine' > data.bin

  run git checkout -q feature
  [ "$status" -eq 0 ]
  [ "$(tail -c4 data.bin)" = "mine" ]
  [[ "$output" == *"local changes were kept"*"data.bin"* ]]
}

@test "one file with unsaved edits does not stop the others from updating" {
  git checkout -qb feature
  printf '\x00v2' > data.bin && dvc_track data.bin
  printf '\x00new' > extra.bin && dvc_track extra.bin
  git commit -qm "feature data" --no-verify
  git checkout -q main
  [ ! -e extra.bin ]
  printf '\x00mine' > data.bin

  run git checkout -q feature
  [ "$status" -eq 0 ]
  [ "$(tail -c4 data.bin)" = "mine" ]
  [ "$(tail -c3 extra.bin)" = "new" ]
  [[ "$output" == *"1 DVC-tracked file(s) have unsaved edits"*"data.bin"* ]]
}

@test "no pointer changes: dvc is not run at all" {
  git checkout -qb feature
  echo "text" > notes.txt && git add notes.txt && git commit -qm notes --no-verify
  : > "$MOCK_DVC_LOG"
  git checkout -q main
  [ ! -s "$MOCK_DVC_LOG" ]
}

@test "file checkout (git checkout -- file) does not run the hook's work" {
  echo "text" > notes.txt && git add notes.txt && git commit -qm notes --no-verify
  echo "changed" > notes.txt
  : > "$MOCK_DVC_LOG"
  git checkout -q -- notes.txt
  [ ! -s "$MOCK_DVC_LOG" ]
}

@test "FLUX_DVC_PULLING=1 (flux pull runs dvc pull itself): hook stays out" {
  git checkout -qb feature
  printf '\x00v2' > data.bin && dvc_track data.bin
  git commit -qm "data v2" --no-verify
  git checkout -q main
  : > "$MOCK_DVC_LOG"
  FLUX_DVC_PULLING=1 git checkout -q feature
  [ ! -s "$MOCK_DVC_LOG" ]
  [ "$(tail -c2 data.bin)" = "v1" ]
}

@test "repo without .dvc: hook does nothing" {
  command rm -rf .dvc
  git checkout -qb feature
  printf '\x00v2' > data.bin && dvc_track data.bin
  git commit -qm "data v2" --no-verify
  command rm -rf .dvc
  : > "$MOCK_DVC_LOG"
  run git checkout -q main
  [ "$status" -eq 0 ]
  [ ! -s "$MOCK_DVC_LOG" ]
}
