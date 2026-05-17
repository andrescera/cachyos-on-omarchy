#!/bin/bash
# Run all bats tests for cachyos-on-omarchy
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export PROJECT_ROOT

# Ensure bats is available
if ! command -v bats >/dev/null 2>&1; then
  echo "ERROR: bats not found. Install with: sudo pacman -S bats" >&2
  exit 1
fi

# Run all .bats files in tests/
exec bats "$SCRIPT_DIR"/*.bats
