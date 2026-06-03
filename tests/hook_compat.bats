#!/usr/bin/env bats
# Compatibility tests for the pre-commit hook.
#
# Two layers of protection:
#
#   Static checks  — grep the hook source for constructs that are known to
#                    break on bash 3.2 (macOS system bash).  These catch
#                    regressions at review time, regardless of the bash
#                    version running the CI / local test suite.
#
#   Runtime checks — execute the hook explicitly with /bin/bash so that any
#                    bash-4/5 feature that escaped the static check is caught
#                    at runtime.  On macOS /bin/bash is 3.2; on Linux it is
#                    typically 4.x or 5.x, which is still a useful smoke-test.
#
# Known-incompatible constructs (bash 3.2):
#   mapfile / readarray  — added in bash 4.0
#   local -n             — nameref, added in bash 4.3
#   declare -n           — nameref, added in bash 4.3
#   (( a > 0 ) || ...)   — subshell inside arithmetic (silent misparse)

load 'helpers/common'

HOOK="$BATS_TEST_DIRNAME/../pre-commit"

setup()    { setup_test_repo; }
teardown() { teardown_test_repo; }

# ---------------------------------------------------------------------------
# Static — banned constructs
# ---------------------------------------------------------------------------

@test "hook: no mapfile or readarray (bash 3.2 compat)" {
  run grep -En '\bmapfile\b|\breadarray\b' "$HOOK"
  [ "$status" -ne 0 ]   # grep exits 1 when nothing matches — that is what we want
}

@test "hook: no 'local -n' nameref (bash 4.3+ only)" {
  run grep -En '\blocal[[:space:]]+-n\b' "$HOOK"
  [ "$status" -ne 0 ]
}

@test "hook: no 'declare -n' nameref (bash 4.3+ only)" {
  run grep -En '\bdeclare[[:space:]]+-n\b' "$HOOK"
  [ "$status" -ne 0 ]
}

@test "hook: no --keep-outs flag (removed from current DVC)" {
  run grep -En -- '--keep-outs' "$HOOK"
  [ "$status" -ne 0 ]
}

@test "hook: syntax check passes under /bin/bash" {
  run /bin/bash -n "$HOOK"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Runtime — executed under /bin/bash
#
# The hook is invoked directly as "/bin/bash .git/hooks/pre-commit" so it
# runs under the system bash regardless of what #!/usr/bin/env bash resolves
# to on this machine.
# ---------------------------------------------------------------------------

@test "hook under /bin/bash: text file below cap is routed to Git" {
  echo "hello world" > note.txt
  git add note.txt

  run /bin/bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]
  # File must still be staged for Git (not handed to DVC)
  git diff --cached --name-only | grep -q "note.txt"
}

@test "hook under /bin/bash: binary file is routed to DVC" {
  make_binary_file data.bin
  git add data.bin

  run /bin/bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]
  assert_dvc_called "add data.bin"
}

@test "hook under /bin/bash: large text file is routed to DVC" {
  make_large_text_file big.txt
  git add big.txt

  run /bin/bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]
  assert_dvc_called "add big.txt"
}

@test "hook under /bin/bash: no staged files exits cleanly" {
  run /bin/bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]
}

@test "hook under /bin/bash: force-dvc pin routes small text file to DVC" {
  mkdir -p pinned
  echo "small text" > pinned/doc.md
  git add pinned/doc.md
  git config --add dvc-router.force-dvc "pinned"

  run /bin/bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]
  assert_dvc_called "add pinned/doc.md"
}

@test "hook under /bin/bash: force-git pin keeps large binary in Git" {
  mkdir -p keep
  make_binary_file keep/logo.png
  git add keep/logo.png
  git config --add dvc-router.force-git "keep"

  run /bin/bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]
  assert_dvc_not_called "add keep/logo.png"
  git diff --cached --name-only | grep -q "keep/logo.png"
}

@test "hook under /bin/bash: pin path with special characters matches correctly" {
  mkdir -p "StartupCandidates/!Archive"
  echo "notes" > "StartupCandidates/!Archive/notes.md"
  git add "StartupCandidates/!Archive/notes.md"
  git config --add dvc-router.force-dvc "StartupCandidates/!Archive"

  run /bin/bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]
  assert_dvc_called "add StartupCandidates/!Archive/notes.md"
}

@test "hook under /bin/bash: multiple force-dvc values all work" {
  mkdir -p dirA dirB
  echo "a" > dirA/a.md
  echo "b" > dirB/b.md
  git add dirA/a.md dirB/b.md
  git config --add dvc-router.force-dvc "dirA"
  git config --add dvc-router.force-dvc "dirB"

  run /bin/bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]
  assert_dvc_called "add dirA/a.md"
  assert_dvc_called "add dirB/b.md"
}

@test "hook under /bin/bash: empty force-dvc config does not crash" {
  # No pins configured — hook must run cleanly on a plain text file
  echo "plain" > plain.txt
  git add plain.txt

  run /bin/bash .git/hooks/pre-commit 2>&1
  [ "$status" -eq 0 ]
}
