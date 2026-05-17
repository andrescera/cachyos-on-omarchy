#!/usr/bin/env bats
# Tests for detect-system.sh
# Verifies root filesystem detection, UKI mode detection, and semantic version
# comparison against fixture files. Every findmnt/limine-default fixture is
# exercised at least once.

load test_helper

# NOTE: const.sh is intentionally NOT sourced here. It declares
# `readonly LIMINE_DEFAULT=/etc/default/limine`, which would prevent these
# tests from overriding LIMINE_DEFAULT to point at fixture files. The
# detect-system.sh library has no real dependency on const.sh (it falls back
# to a hard-coded path when LIMINE_DEFAULT is unset).
setup() {
  source "$PROJECT_ROOT/lib/log.sh"
  source "$PROJECT_ROOT/lib/detect-system.sh"
}

# --- detect_root_fs: findmnt output parsing ---

@test "detect_root_fs: ext4 fixture -> ext4" {
  result=$(detect_root_fs < "$PROJECT_ROOT/tests/fixtures/findmnt/ext4.txt")
  assert_eq "$result" "ext4" "ext4 fixture should yield ext4"
}

@test "detect_root_fs: btrfs fixture -> btrfs" {
  result=$(detect_root_fs < "$PROJECT_ROOT/tests/fixtures/findmnt/btrfs.txt")
  assert_eq "$result" "btrfs" "btrfs fixture should yield btrfs"
}

@test "detect_root_fs: xfs fixture -> xfs (recognized but unsupported)" {
  result=$(detect_root_fs < "$PROJECT_ROOT/tests/fixtures/findmnt/xfs.txt")
  assert_eq "$result" "xfs" "xfs fixture should yield xfs"
}

# --- detect_uki_mode: /etc/default/limine parsing ---

@test "detect_uki_mode: uki-enabled fixture -> exit 0" {
  LIMINE_DEFAULT="$PROJECT_ROOT/tests/fixtures/limine-default/uki-enabled.txt" \
    run detect_uki_mode
  [ "$status" -eq 0 ]
}

@test "detect_uki_mode: uki-disabled fixture -> exit 1" {
  LIMINE_DEFAULT="$PROJECT_ROOT/tests/fixtures/limine-default/uki-disabled.txt" \
    run detect_uki_mode
  [ "$status" -ne 0 ]
}

@test "detect_uki_mode: nonexistent file -> exit 1" {
  LIMINE_DEFAULT="/tmp/does-not-exist-$$.conf" \
    run detect_uki_mode
  [ "$status" -ne 0 ]
}

# --- version_ge: semantic version comparison via sort -V ---

@test "version_ge: 3.1 >= 3.0 -> true" {
  run version_ge "3.1" "3.0"
  [ "$status" -eq 0 ]
}

@test "version_ge: 2.9 >= 3.0 -> false" {
  run version_ge "2.9" "3.0"
  [ "$status" -ne 0 ]
}

@test "version_ge: 10.0 >= 9.99 -> true (numeric not lexical)" {
  run version_ge "10.0" "9.99"
  [ "$status" -eq 0 ]
}

@test "version_ge: 3.0 >= 3.0 -> true (equal)" {
  run version_ge "3.0" "3.0"
  [ "$status" -eq 0 ]
}

@test "version_ge: 3.0.0 >= 3.0 -> true (sort -V treats as equal)" {
  run version_ge "3.0.0" "3.0"
  [ "$status" -eq 0 ]
}

@test "version_ge: 3.0 >= 3.0.1 -> false" {
  run version_ge "3.0" "3.0.1"
  [ "$status" -ne 0 ]
}

@test "version_ge: 3.1.2 >= 3.0 -> true (multi-segment greater)" {
  run version_ge "3.1.2" "3.0"
  [ "$status" -eq 0 ]
}
