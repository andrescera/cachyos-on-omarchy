#!/bin/bash
# Common test setup for cachyos-on-omarchy bats tests

# Force dry-run mode for all tests (safety)
export DRY_RUN=1

# Project root (so tests can source lib files)
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Simple assertion: assert_eq ACTUAL EXPECTED MESSAGE
assert_eq() {
  local actual="$1" expected="$2" msg="${3:-assertion failed}"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $msg" >&2
    echo "  Expected: '$expected'" >&2
    echo "  Actual:   '$actual'" >&2
    return 1
  fi
  return 0
}

# Regex assertion: assert_match ACTUAL PATTERN MESSAGE
assert_match() {
  local actual="$1" pattern="$2" msg="${3:-pattern not matched}"
  if [[ ! "$actual" =~ $pattern ]]; then
    echo "FAIL: $msg" >&2
    echo "  Pattern: '$pattern'" >&2
    echo "  Actual:  '$actual'" >&2
    return 1
  fi
  return 0
}

# Load a fixture file (reads file, outputs content)
load_fixture() {
  local fixture_path="${PROJECT_ROOT}/tests/fixtures/${1}"
  if [[ ! -f "$fixture_path" ]]; then
    echo "ERROR: fixture not found: $fixture_path" >&2
    return 1
  fi
  cat "$fixture_path"
}
