#!/usr/bin/env bats
# Tests for detect-cpu.sh
# Verifies x86-64 microarchitecture level detection, CPU vendor detection,
# and microcode package mapping against fixture files. Every ldso/cpuinfo
# fixture is exercised at least once.

load test_helper

setup() {
  source "$PROJECT_ROOT/lib/const.sh"
  source "$PROJECT_ROOT/lib/log.sh"
  source "$PROJECT_ROOT/lib/detect-cpu.sh"
}

# --- detect_arch_level: glibc-hwcaps parsing ---

@test "detect_arch_level: v3-supported fixture -> v3" {
  result=$(detect_arch_level < "$PROJECT_ROOT/tests/fixtures/ldso/v3-supported.txt")
  assert_eq "$result" "v3" "v3-supported should yield v3"
}

@test "detect_arch_level: v2-only fixture -> v2" {
  result=$(detect_arch_level < "$PROJECT_ROOT/tests/fixtures/ldso/v2-only.txt")
  assert_eq "$result" "v2" "v2-only should yield v2"
}

@test "detect_arch_level: v4-supported fixture -> v4" {
  result=$(detect_arch_level < "$PROJECT_ROOT/tests/fixtures/ldso/v4-supported.txt")
  assert_eq "$result" "v4" "v4-supported should yield v4"
}

@test "detect_arch_level: empty piped input -> v2 (safe default)" {
  # Piped input makes -p /dev/stdin true; cat reads zero bytes; no x86-64-vN
  # markers found -> function returns its conservative v2 default.
  result=$(printf '' | detect_arch_level)
  assert_eq "$result" "v2" "empty piped input should default to v2"
}

# --- detect_cpu_vendor: /proc/cpuinfo parsing ---

@test "detect_cpu_vendor: amd-zen3 fixture -> amd" {
  result=$(detect_cpu_vendor < "$PROJECT_ROOT/tests/fixtures/cpuinfo/amd-zen3.txt")
  assert_eq "$result" "amd" "AuthenticAMD vendor_id should yield amd"
}

@test "detect_cpu_vendor: intel-13thgen fixture -> intel" {
  result=$(detect_cpu_vendor < "$PROJECT_ROOT/tests/fixtures/cpuinfo/intel-13thgen.txt")
  assert_eq "$result" "intel" "GenuineIntel vendor_id should yield intel"
}

@test "detect_cpu_vendor: empty piped input -> unknown" {
  # Piped input makes -p /dev/stdin true; grep finds no vendor_id line
  # -> raw_vendor empty -> case '*' arm -> unknown.
  result=$(printf '' | detect_cpu_vendor)
  assert_eq "$result" "unknown" "missing vendor_id should yield unknown"
}

# --- microcode_pkg_for_vendor: vendor -> microcode package ---

@test "microcode_pkg_for_vendor: amd -> amd-ucode" {
  result=$(microcode_pkg_for_vendor "amd")
  assert_eq "$result" "amd-ucode" "amd should map to amd-ucode"
}

@test "microcode_pkg_for_vendor: intel -> intel-ucode" {
  result=$(microcode_pkg_for_vendor "intel")
  assert_eq "$result" "intel-ucode" "intel should map to intel-ucode"
}

@test "microcode_pkg_for_vendor: unknown -> unknown" {
  result=$(microcode_pkg_for_vendor "unknown")
  assert_eq "$result" "unknown" "unknown vendor should map to unknown"
}

@test "microcode_pkg_for_vendor: empty -> unknown" {
  result=$(microcode_pkg_for_vendor "")
  assert_eq "$result" "unknown" "empty vendor should map to unknown"
}

# --- is_v3_capable: derived predicate ---

@test "is_v3_capable: returns 0 when arch_level is v3" {
  detect_arch_level() { echo "v3"; }
  run is_v3_capable
  [ "$status" -eq 0 ]
}

@test "is_v3_capable: returns 0 when arch_level is v4" {
  detect_arch_level() { echo "v4"; }
  run is_v3_capable
  [ "$status" -eq 0 ]
}

@test "is_v3_capable: returns 1 when arch_level is v2" {
  detect_arch_level() { echo "v2"; }
  run is_v3_capable
  [ "$status" -eq 1 ]
}

@test "is_v3_capable: returns 1 when arch_level is v1" {
  detect_arch_level() { echo "v1"; }
  run is_v3_capable
  [ "$status" -eq 1 ]
}
