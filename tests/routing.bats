#!/usr/bin/env bats
# Tests for the core file routing logic in the pre-commit hook.
# Each test verifies that a file staged for commit ends up in the right
# destination (DVC or Git) based on binary detection and size threshold.

load 'helpers/common'

setup()    { setup_test_repo; }
teardown() { teardown_test_repo; }

# ---------------------------------------------------------------------------

@test "binary file is routed to DVC" {
  make_binary_file binary.bin
  git add binary.bin

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  [ -f "binary.bin.dvc" ]
  assert_dvc_called "add binary.bin"

  # binary.bin must not be in the git index
  run git ls-files binary.bin
  [ -z "$output" ]

  # .dvc pointer must be staged
  run git diff --cached --name-only
  [[ "$output" == *"binary.bin.dvc"* ]]
}

@test "small text file is kept in Git" {
  echo "small content" > small.txt
  git add small.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  [ ! -f "small.txt.dvc" ]
  assert_dvc_not_called "add small.txt"

  run git diff --cached --name-only
  [[ "$output" == *"small.txt"* ]]
}

@test "large text file is routed to DVC" {
  make_large_text_file large.txt
  git add large.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  [ -f "large.txt.dvc" ]
  assert_dvc_called "add large.txt"

  run git ls-files large.txt
  [ -z "$output" ]
}

@test "file at exactly the threshold boundary stays in Git" {
  # Threshold is 1 MB = 1048576 bytes; files must be STRICTLY greater to go to DVC.
  printf '%1048576s' '' | tr ' ' 'a' > boundary.txt
  git add boundary.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  [ ! -f "boundary.txt.dvc" ]
  assert_dvc_not_called "add boundary.txt"
}

@test "file one byte over threshold is routed to DVC" {
  printf '%1048577s' '' | tr ' ' 'a' > over.txt
  git add over.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  [ -f "over.txt.dvc" ]
  assert_dvc_called "add over.txt"
}

@test "file with existing .dvc pointer is not re-processed" {
  # Simulate a file already managed by DVC: commit its .dvc pointer.
  make_large_text_file managed.bin
  cat > managed.bin.dvc << 'EOF'
outs:
- md5: aabbccdd
  path: managed.bin
EOF
  git add managed.bin.dvc
  git commit -m "pre-existing dvc file" --no-verify -q

  # Stage the data file itself (unusual but possible if .gitignore is missing).
  git add managed.bin 2>/dev/null || true
  echo "extra" > trigger.txt
  git add trigger.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  # dvc add must NOT be called for the already-tracked file.
  assert_dvc_not_called "add managed.bin"
}

@test "hook exits cleanly with no staged files" {
  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]
}

@test "multiple files in one commit are each routed correctly" {
  echo "text" > keep.txt
  make_binary_file drop.bin
  git add keep.txt drop.bin

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  # Text file stays in git
  run git diff --cached --name-only
  [[ "$output" == *"keep.txt"* ]]

  # Binary file goes to DVC
  [ -f "drop.bin.dvc" ]
  run git ls-files drop.bin
  [ -z "$output" ]
}
