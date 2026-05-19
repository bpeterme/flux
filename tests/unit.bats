#!/usr/bin/env bats
# Unit tests for the flux pre-commit hook.
# Covers: file routing, cross-direction migration, orphan cleanup, .dvcignore sync.
# All tests use a mock DVC binary — no real DVC installation or R2 credentials needed.

load 'helpers/common'

setup()    { setup_test_repo; }
teardown() { teardown_test_repo; }

# ---------------------------------------------------------------------------
# Routing — binary and size-based decisions
# ---------------------------------------------------------------------------

@test "binary file is routed to DVC" {
  make_binary_file binary.bin
  git add binary.bin

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  [ -f "binary.bin.dvc" ]
  assert_dvc_called "add binary.bin"

  run git ls-files binary.bin
  [ -z "$output" ]

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
  make_large_text_file managed.bin
  cat > managed.bin.dvc << 'EOF'
outs:
- md5: aabbccdd
  path: managed.bin
EOF
  git add managed.bin.dvc
  git commit -m "pre-existing dvc file" --no-verify -q

  git add managed.bin 2>/dev/null || true
  echo "extra" > trigger.txt
  git add trigger.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

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

  run git diff --cached --name-only
  [[ "$output" == *"keep.txt"* ]]

  [ -f "drop.bin.dvc" ]
  run git ls-files drop.bin
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Migration — Git ↔ DVC transitions
# ---------------------------------------------------------------------------

@test "git-tracked file that grows past threshold is migrated to DVC" {
  echo "small" > growing.txt
  git add growing.txt
  git commit -m "small file" --no-verify -q

  make_large_text_file growing.txt
  git add growing.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  [ -f "growing.txt.dvc" ]
  assert_dvc_called "add growing.txt"

  run git ls-files growing.txt
  [ -z "$output" ]

  run git diff --cached --name-only
  [[ "$output" == *"growing.txt.dvc"* ]]
}

@test "DVC-tracked file that shrinks below threshold is migrated to Git" {
  make_large_text_file big.txt
  cat > big.txt.dvc << 'EOF'
outs:
- md5: 1234567890abcdef
  path: big.txt
EOF
  echo "/big.txt" >> .gitignore
  git add big.txt.dvc .gitignore
  git commit -m "dvc-tracked large file" --no-verify -q

  echo "small now" > big.txt

  echo "trigger" > trigger.txt
  git add trigger.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  assert_dvc_called "remove big.txt.dvc"

  [ ! -f "big.txt.dvc" ]

  run git diff --cached --name-only
  [[ "$output" == *"big.txt"* ]]
}

@test "DVC-tracked binary file stays in DVC even when small" {
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

# ---------------------------------------------------------------------------
# Orphan cleanup — deleted and renamed DVC-tracked files
# ---------------------------------------------------------------------------

@test "deleted DVC-tracked file has its pointer staged for removal" {
  cat > video.mp4.dvc << 'EOF'
outs:
- md5: deadbeef
  path: video.mp4
EOF
  echo "/video.mp4" >> .gitignore
  git add video.mp4.dvc .gitignore
  git commit -m "dvc-tracked video" --no-verify -q

  echo "trigger" > trigger.txt
  git add trigger.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  run git diff --cached --name-status
  [[ "$output" == *"D"*"video.mp4.dvc"* ]]
}

@test "stale .gitignore entry is removed when pointer is cleaned up" {
  cat > clip.mp4.dvc << 'EOF'
outs:
- md5: cafebabe
  path: clip.mp4
EOF
  printf '/clip.mp4\n' >> .gitignore
  git add clip.mp4.dvc .gitignore
  git commit -m "dvc-tracked clip" --no-verify -q

  echo "trigger" > trigger.txt
  git add trigger.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  ! grep -qF '/clip.mp4' .gitignore
}

@test "healthy DVC pointer whose target exists is left untouched" {
  make_binary_file asset.bin
  cat > asset.bin.dvc << 'EOF'
outs:
- md5: 12345678
  path: asset.bin
EOF
  echo "/asset.bin" >> .gitignore
  git add asset.bin.dvc .gitignore
  git commit -m "dvc-tracked asset" --no-verify -q

  echo "trigger" > trigger.txt
  git add trigger.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  run git diff --cached --name-status
  [[ "$output" != *"D"*"asset.bin.dvc"* ]]
  [ -f "asset.bin.dvc" ]
}

@test "multiple orphaned pointers are all cleaned up in one commit" {
  for name in a b c; do
    cat > "${name}.bin.dvc" << EOF
outs:
- md5: 0000000${name}
  path: ${name}.bin
EOF
    echo "/${name}.bin" >> .gitignore
    git add "${name}.bin.dvc"
  done
  git add .gitignore
  git commit -m "three dvc files" --no-verify -q

  echo "trigger" > trigger.txt
  git add trigger.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  for name in a b c; do
    run git diff --cached --name-status
    [[ "$output" == *"D"*"${name}.bin.dvc"* ]]
  done
}

# ---------------------------------------------------------------------------
# .dvcignore sync
# ---------------------------------------------------------------------------

@test ".dvcignore is generated from .gitignore" {
  cat > .gitignore << 'EOF'
*.log
*.tmp
EOF
  git add .gitignore
  echo "trigger" > t.txt
  git add t.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  [ -f ".dvcignore" ]
  grep -q '\*.log' .dvcignore
  grep -q '\*.tmp' .dvcignore
}

@test "comments are stripped from .dvcignore" {
  cat > .gitignore << 'EOF'
# this is a comment
*.log
EOF
  git add .gitignore
  echo "trigger" > t.txt
  git add t.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  ! grep -q '^#' .dvcignore
  grep -q '\*.log' .dvcignore
}

@test "blank lines are stripped from .dvcignore" {
  printf '*.log\n\n*.tmp\n\n' > .gitignore
  git add .gitignore
  echo "trigger" > t.txt
  git add t.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  ! grep -q '^$' .dvcignore
}

@test ".dvcignore is staged after generation" {
  echo "*.log" > .gitignore
  git add .gitignore
  echo "trigger" > t.txt
  git add t.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  run git diff --cached --name-only
  [[ "$output" == *".dvcignore"* ]]
}

@test "nested .gitignore produces a sibling .dvcignore in the same directory" {
  mkdir -p subdir
  echo "*.cache" > subdir/.gitignore
  git add subdir/.gitignore
  echo "trigger" > t.txt
  git add t.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  [ -f "subdir/.dvcignore" ]
  grep -q '\*.cache' subdir/.dvcignore

  run git diff --cached --name-only
  [[ "$output" == *"subdir/.dvcignore"* ]]
}

@test ".dvcignore is regenerated when .gitignore gains a new entry" {
  echo "*.log" > .gitignore
  git add .gitignore
  echo "first" > first.txt
  git add first.txt
  bash .git/hooks/pre-commit 2>&1 || true
  git commit -m "baseline" --no-verify -q

  echo "*.tmp" >> .gitignore
  git add .gitignore
  echo "second" > second.txt
  git add second.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  grep -q '\*.tmp' .dvcignore
}
