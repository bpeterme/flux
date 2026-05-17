#!/usr/bin/env bats
# Tests for .dvcignore sync — every .gitignore in the repo should have a
# sibling .dvcignore with comments and blank lines stripped.

load 'helpers/common'

setup()    { setup_test_repo; }
teardown() { teardown_test_repo; }

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

  # Add a new pattern to .gitignore.
  echo "*.tmp" >> .gitignore
  git add .gitignore
  echo "second" > second.txt
  git add second.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  grep -q '\*.tmp' .dvcignore
}
