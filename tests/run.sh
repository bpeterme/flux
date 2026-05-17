#!/usr/bin/env bash
# Local test runner for the flux test suite.
# Checks for bats-core and runs all .bats files in the tests/ directory.
#
# Usage:
#   ./tests/run.sh
#   ./tests/run.sh tests/routing.bats   # run a single file

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v bats &>/dev/null; then
  echo "bats-core not found. Install it first:"
  echo ""
  echo "  macOS:  brew install bats-core"
  echo "  Linux:  sudo apt-get install bats"
  echo "          or: https://github.com/bats-core/bats-core#installation"
  exit 1
fi

if [[ $# -gt 0 ]]; then
  exec bats "$@"
else
  exec bats "$SCRIPT_DIR"/*.bats
fi
