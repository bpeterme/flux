#!/usr/bin/env bats
# Tests for orphaned .dvc pointer cleanup.
# An orphan is a .dvc file whose target no longer exists on disk
# (because the user deleted or renamed the DVC-tracked file).

load 'helpers/common'

setup()    { setup_test_repo; }
teardown() { teardown_test_repo; }

# ---------------------------------------------------------------------------

@test "deleted DVC-tracked file has its pointer staged for removal" {
  # Commit a .dvc pointer — the actual binary "lives in R2" and never touches disk.
  cat > video.mp4.dvc << 'EOF'
outs:
- md5: deadbeef
  path: video.mp4
EOF
  echo "/video.mp4" >> .gitignore
  git add video.mp4.dvc .gitignore
  git commit -m "dvc-tracked video" --no-verify -q

  # video.mp4 is absent from disk (never was there, or user deleted it).
  # Stage a trigger so the hook runs.
  echo "trigger" > trigger.txt
  git add trigger.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  # .dvc pointer must be staged for deletion.
  run git diff --cached --name-status
  [[ "$output" == *"D"*"video.mp4.dvc"* ]]
}

@test "stale .gitignore entry is removed when pointer is cleaned up" {
  cat > clip.mp4.dvc << 'EOF'
outs:
- md5: cafebabe
  path: clip.mp4
EOF
  # DVC adds the entry as /clip.mp4 in the sibling .gitignore.
  printf '/clip.mp4\n' >> .gitignore
  git add clip.mp4.dvc .gitignore
  git commit -m "dvc-tracked clip" --no-verify -q

  echo "trigger" > trigger.txt
  git add trigger.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  # The /clip.mp4 entry must be gone from .gitignore.
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

  # Pointer must still be tracked by git — not staged for deletion.
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

  # None of the actual binary files exist on disk.
  echo "trigger" > trigger.txt
  git add trigger.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  for name in a b c; do
    run git diff --cached --name-status
    [[ "$output" == *"D"*"${name}.bin.dvc"* ]]
  done
}
