#!/usr/bin/env bats
# Tests for automatic patch version bumping in the pre-commit hook.
# Bump happens only on the 'dev' branch; all other branches are left alone.

load 'helpers/common'

setup()    { setup_test_repo; }
teardown() { teardown_test_repo; }

# ---------------------------------------------------------------------------

@test "patch version increments on dev branch" {
  git checkout -b dev 2>/dev/null

  echo "content" > file.txt
  git add file.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  grep -q 'VERSION="0.0.1"' setup.sh
}

@test "version is not incremented on main branch" {
  # setup_test_repo already lands on main.
  echo "content" > file.txt
  git add file.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  grep -q 'VERSION="0.0.0"' setup.sh
}

@test "version is not incremented on an arbitrary feature branch" {
  git checkout -b feature/something 2>/dev/null

  echo "content" > file.txt
  git add file.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  grep -q 'VERSION="0.0.0"' setup.sh
}

@test "patch number increments correctly past single digit" {
  # Set a version where patch is 9 — next must be 10, not 0.
  sed -i.bak 's/VERSION="0.0.0"/VERSION="0.0.9"/' setup.sh && rm -f setup.sh.bak
  git add setup.sh
  git commit -m "set patch to 9" --no-verify -q

  git checkout -b dev 2>/dev/null

  echo "content" > file.txt
  git add file.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]

  grep -q 'VERSION="0.0.10"' setup.sh
}

@test "hook exits cleanly when setup.sh has no VERSION line" {
  sed -i.bak '/^VERSION=/d' setup.sh && rm -f setup.sh.bak
  git add setup.sh
  git commit -m "remove VERSION" --no-verify -q

  git checkout -b dev 2>/dev/null
  echo "content" > file.txt
  git add file.txt

  run bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]
}

@test "version is bumped and staged so it lands in the commit" {
  git checkout -b dev 2>/dev/null

  echo "content" > file.txt
  git add file.txt

  bash .git/hooks/pre-commit 2>&1

  # After the hook, setup.sh with bumped VERSION must be in the staged index.
  run git diff --cached --name-only
  [[ "$output" == *"setup.sh"* ]]
}
