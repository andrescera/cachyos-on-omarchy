#!/usr/bin/env bats
# Tests for detect-gpu.sh
# Verifies GPU vendor detection, NVIDIA generation mapping, and companion
# package selection against fixture files. Every lspci fixture is exercised
# at least once.

load test_helper

setup() {
  source "$PROJECT_ROOT/lib/const.sh"
  source "$PROJECT_ROOT/lib/log.sh"
  source "$PROJECT_ROOT/lib/detect-gpu.sh"
}

# --- detect_gpu_vendor: vendor classification ---

@test "detect_gpu_vendor: rtx4080 fixture -> nvidia" {
  local fixture="$PROJECT_ROOT/tests/fixtures/lspci/rtx4080.txt"
  result=$(detect_gpu_vendor < "$fixture")
  assert_eq "$result" "nvidia" "rtx4080 should be nvidia"
}

@test "detect_gpu_vendor: rtx3070 fixture -> nvidia" {
  local fixture="$PROJECT_ROOT/tests/fixtures/lspci/rtx3070.txt"
  result=$(detect_gpu_vendor < "$fixture")
  assert_eq "$result" "nvidia" "rtx3070 should be nvidia"
}

@test "detect_gpu_vendor: rtx2070 fixture -> nvidia" {
  local fixture="$PROJECT_ROOT/tests/fixtures/lspci/rtx2070.txt"
  result=$(detect_gpu_vendor < "$fixture")
  assert_eq "$result" "nvidia" "rtx2070 should be nvidia"
}

@test "detect_gpu_vendor: gtx1080 fixture -> nvidia" {
  local fixture="$PROJECT_ROOT/tests/fixtures/lspci/gtx1080.txt"
  result=$(detect_gpu_vendor < "$fixture")
  assert_eq "$result" "nvidia" "gtx1080 should be nvidia"
}

@test "detect_gpu_vendor: gtx970 fixture -> nvidia" {
  local fixture="$PROJECT_ROOT/tests/fixtures/lspci/gtx970.txt"
  result=$(detect_gpu_vendor < "$fixture")
  assert_eq "$result" "nvidia" "gtx970 should be nvidia"
}

@test "detect_gpu_vendor: rx7900xt fixture -> amd" {
  local fixture="$PROJECT_ROOT/tests/fixtures/lspci/rx7900xt.txt"
  result=$(detect_gpu_vendor < "$fixture")
  assert_eq "$result" "amd" "rx7900xt should be amd"
}

@test "detect_gpu_vendor: intel-iris fixture -> intel" {
  local fixture="$PROJECT_ROOT/tests/fixtures/lspci/intel-iris.txt"
  result=$(detect_gpu_vendor < "$fixture")
  assert_eq "$result" "intel" "intel-iris should be intel"
}

@test "detect_gpu_vendor: hybrid-nvidia-intel fixture -> hybrid:nvidia,intel" {
  local fixture="$PROJECT_ROOT/tests/fixtures/lspci/hybrid-nvidia-intel.txt"
  result=$(detect_gpu_vendor < "$fixture")
  assert_eq "$result" "hybrid:nvidia,intel" "hybrid should be hybrid:nvidia,intel"
}

@test "detect_gpu_vendor: no-gpu fixture -> unknown" {
  local fixture="$PROJECT_ROOT/tests/fixtures/lspci/no-gpu.txt"
  result=$(detect_gpu_vendor < "$fixture")
  assert_eq "$result" "unknown" "no-gpu (class 0880) should be unknown"
}

# --- detect_nvidia_gen: device ID -> generation ---

@test "detect_nvidia_gen: 2704 (RTX 4080) -> ada" {
  result=$(detect_nvidia_gen "2704")
  assert_eq "$result" "ada" "RTX 4080 device ID should be ada"
}

@test "detect_nvidia_gen: 2488 (RTX 3070) -> ampere" {
  result=$(detect_nvidia_gen "2488")
  assert_eq "$result" "ampere" "RTX 3070 device ID should be ampere"
}

@test "detect_nvidia_gen: 1f02 (RTX 2070) -> turing" {
  result=$(detect_nvidia_gen "1f02")
  assert_eq "$result" "turing" "RTX 2070 device ID should be turing"
}

@test "detect_nvidia_gen: 1b80 (GTX 1080) -> pascal" {
  result=$(detect_nvidia_gen "1b80")
  assert_eq "$result" "pascal" "GTX 1080 device ID should be pascal"
}

@test "detect_nvidia_gen: 13c2 (GTX 970) -> maxwell" {
  result=$(detect_nvidia_gen "13c2")
  assert_eq "$result" "maxwell" "GTX 970 device ID should be maxwell"
}

@test "detect_nvidia_gen: 2b00 -> blackwell" {
  result=$(detect_nvidia_gen "2b00")
  assert_eq "$result" "blackwell" "2b00 should be blackwell"
}

@test "detect_nvidia_gen: ffff -> unknown" {
  result=$(detect_nvidia_gen "ffff")
  assert_eq "$result" "unknown" "ffff should be unknown"
}

@test "detect_nvidia_gen: empty string -> unknown" {
  result=$(detect_nvidia_gen "")
  assert_eq "$result" "unknown" "empty input should be unknown"
}

# --- nvidia_companion_for_gen: generation -> companion package family ---

@test "nvidia_companion_for_gen: ada -> nvidia-open" {
  result=$(nvidia_companion_for_gen "ada")
  assert_eq "$result" "nvidia-open" "ada should be nvidia-open"
}

@test "nvidia_companion_for_gen: ampere -> nvidia-open" {
  result=$(nvidia_companion_for_gen "ampere")
  assert_eq "$result" "nvidia-open" "ampere should be nvidia-open"
}

@test "nvidia_companion_for_gen: pascal -> 580xx" {
  result=$(nvidia_companion_for_gen "pascal")
  assert_eq "$result" "580xx" "pascal should be 580xx"
}

@test "nvidia_companion_for_gen: kepler -> 470xx" {
  result=$(nvidia_companion_for_gen "kepler")
  assert_eq "$result" "470xx" "kepler should be 470xx"
}

@test "nvidia_companion_for_gen: fermi -> nouveau" {
  result=$(nvidia_companion_for_gen "fermi")
  assert_eq "$result" "nouveau" "fermi should be nouveau"
}

@test "nvidia_companion_for_gen: unknown -> none" {
  result=$(nvidia_companion_for_gen "unknown")
  assert_eq "$result" "none" "unknown should be none"
}
