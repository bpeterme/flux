#!/usr/bin/env bats
# Integration tests for flux — exercises the full CLI flow.
# These tests may require a real DVC installation and shell environment.

load 'helpers/common'

setup()    { setup_test_repo; }
teardown() { teardown_test_repo; }

# ---------------------------------------------------------------------------

@test "setup.sh passes bash syntax check" {
  run bash -n "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
}

@test "pre-commit passes bash syntax check" {
  run bash -n "$REPO_ROOT/pre-commit"
  [ "$status" -eq 0 ]
}
