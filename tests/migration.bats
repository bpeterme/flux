#!/usr/bin/env bats
# Tests for cross-direction file migration:
#   Git → DVC  when a previously-committed file crosses the threshold
#   DVC → Git  when a DVC-tracked file shrinks back below the threshold

load 'helpers/common'

setup()    { setup_test_repo; }
teardown() { teardown_test_repo; }

# ---------------------------------------------------------------------------

@test "git-tracked file that grows past threshold is migrated to DVC" {
  # Commit a small version to git history.
  echo "small" > growing.txt
  git add growing.txt
  git commit -m "small file" --no-verify -q

  # Replace with a version above threshold and stage it.
  make_large_text_file growing.txt
  git add growing.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  [ -f "growing.txt.dvc" ]
  assert_dvc_called "add growing.txt"

  # File must be removed from the git index.
  run git ls-files growing.txt
  [ -z "$output" ]

  # .dvc pointer must be staged.
  run git diff --cached --name-only
  [[ "$output" == *"growing.txt.dvc"* ]]
}

@test "DVC-tracked file that shrinks below threshold is migrated to Git" {
  # Set up a committed .dvc pointer (as if the file was previously routed to DVC).
  make_large_text_file big.txt
  cat > big.txt.dvc << 'EOF'
outs:
- md5: 1234567890abcdef
  path: big.txt
EOF
  echo "/big.txt" >> .gitignore
  git add big.txt.dvc .gitignore
  git commit -m "dvc-tracked large file" --no-verify -q

  # Replace with a small version on disk (simulates file being compacted).
  echo "small now" > big.txt

  # Stage a trigger file so the hook runs.
  echo "trigger" > trigger.txt
  git add trigger.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  assert_dvc_called "remove big.txt.dvc"

  # .dvc pointer must be gone.
  [ ! -f "big.txt.dvc" ]

  # File must appear in the staged set (migrated back to git).
  run git diff --cached --name-only
  [[ "$output" == *"big.txt"* ]]
}

@test "DVC-tracked binary file stays in DVC even when small" {
  # A binary file that is small — binary detection always wins over size.
  make_binary_file tiny.bin
  cat > tiny.bin.dvc << 'EOF'
outs:
- md5: aabbccdd
  path: tiny.bin
EOF
  echo "/tiny.bin" >> .gitignore
  git add tiny.bin.dvc .gitignore
  git commit -m "dvc-tracked binary" --no-verify -q

  echo "trigger" > trigger.txt
  git add trigger.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  # dvc remove must NOT be called — binary files stay in DVC.
  assert_dvc_not_called "remove tiny.bin.dvc"
  [ -f "tiny.bin.dvc" ]
}

@test "dvc gc is called after a DVC-to-Git migration" {
  make_large_text_file shrinking.txt
  cat > shrinking.txt.dvc << 'EOF'
outs:
- md5: cafebabe
  path: shrinking.txt
EOF
  echo "/shrinking.txt" >> .gitignore
  git add shrinking.txt.dvc .gitignore
  git commit -m "large file in dvc" --no-verify -q

  echo "now small" > shrinking.txt
  echo "trigger" > t.txt
  git add t.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  assert_dvc_called "gc --cloud --all-branches --force --quiet"
}
