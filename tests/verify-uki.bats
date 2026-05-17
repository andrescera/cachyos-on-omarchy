#!/usr/bin/env bats
# Tests for verify_uki_safety (Tollgate 2 four-check bootloader guard).
#
# Each test invokes the function in a child bash via `run bash -c` so that:
#   - `set -euo pipefail` from lib/verify-uki.sh stays scoped to the child.
#   - Env overrides (LIMINE_CONF / BOOT_EFI_LINUX / INSTALLED_KERNELS_OVERRIDE)
#     win over lib/const.sh's readonly defaults — which means we deliberately
#     DO NOT source lib/const.sh in these tests. const.sh's `readonly X=...`
#     would overwrite the env overrides and silently redirect the function
#     at the real /boot tree.

load test_helper

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
FIXTURE_DIR="$PROJECT_ROOT/tests/fixtures"

# Regenerate fake EFI fixtures if they are missing or wrong size. The script
# writes exactly 60 MB of zeros so Check 1 (>= 50 MB) passes and the SHA-512
# baked into valid-with-bore.conf / missing-fallback.conf matches.
setup() {
  local efi_bore="$FIXTURE_DIR/boot-efi-linux/test_linux-cachyos-bore.efi"
  local efi_linux="$FIXTURE_DIR/boot-efi-linux/test_linux.efi"
  if [[ ! -f "$efi_bore" || ! -f "$efi_linux" \
        || "$(stat -c %s "$efi_bore" 2>/dev/null || echo 0)" -lt 52428800 \
        || "$(stat -c %s "$efi_linux" 2>/dev/null || echo 0)" -lt 52428800 ]]; then
    bash "$FIXTURE_DIR/boot-efi-linux/generate.sh" >/dev/null
  fi
}

# Shared invocation pattern: source log.sh + verify-uki.sh, then call the
# function under test. Quoting is escaped so $PROJECT_ROOT expands in the
# outer (bats) shell, not the inner bash.
_verify() {
  local kernel="$1"
  bash -c "source '$PROJECT_ROOT/lib/log.sh'; source '$PROJECT_ROOT/lib/verify-uki.sh'; verify_uki_safety '$kernel'"
}

# ---------------------------------------------------------------------------
# Positive cases
# ---------------------------------------------------------------------------

@test "verify_uki_safety: valid-with-bore + multi-kernel → all 4 checks pass, exit 0" {
  LIMINE_CONF="$FIXTURE_DIR/limine-conf/valid-with-bore.conf" \
  BOOT_EFI_LINUX="$FIXTURE_DIR/boot-efi-linux" \
  INSTALLED_KERNELS_OVERRIDE="linux linux-cachyos-bore" \
  run bash -c "source '$PROJECT_ROOT/lib/log.sh'; source '$PROJECT_ROOT/lib/verify-uki.sh'; verify_uki_safety linux-cachyos-bore"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Check 1 PASS" ]]
  [[ "$output" =~ "Check 2 PASS" ]]
  [[ "$output" =~ "Check 3 PASS" ]]
  [[ "$output" =~ "Check 4 PASS" ]]
}

@test "verify_uki_safety: single-kernel system → Check 4 vacuous pass, exit 0" {
  LIMINE_CONF="$FIXTURE_DIR/limine-conf/valid-with-bore.conf" \
  BOOT_EFI_LINUX="$FIXTURE_DIR/boot-efi-linux" \
  INSTALLED_KERNELS_OVERRIDE="linux-cachyos-bore" \
  run bash -c "source '$PROJECT_ROOT/lib/log.sh'; source '$PROJECT_ROOT/lib/verify-uki.sh'; verify_uki_safety linux-cachyos-bore"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Single-kernel" ]] || [[ "$output" =~ "vacuous" ]]
}

# ---------------------------------------------------------------------------
# Check 1: UKI file existence / size
# ---------------------------------------------------------------------------

@test "verify_uki_safety: nonexistent kernel → Check 1 FAIL, exit 1" {
  LIMINE_CONF="$FIXTURE_DIR/limine-conf/valid-with-bore.conf" \
  BOOT_EFI_LINUX="$FIXTURE_DIR/boot-efi-linux" \
  INSTALLED_KERNELS_OVERRIDE="linux-cachyos-bore" \
  run bash -c "source '$PROJECT_ROOT/lib/log.sh'; source '$PROJECT_ROOT/lib/verify-uki.sh'; verify_uki_safety nonexistent-kernel-99999"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Check 1 FAIL" ]]
}

@test "verify_uki_safety: Check 1 fail includes recovery hint (mkinitcpio / rollback)" {
  LIMINE_CONF="$FIXTURE_DIR/limine-conf/valid-with-bore.conf" \
  BOOT_EFI_LINUX="$FIXTURE_DIR/boot-efi-linux" \
  INSTALLED_KERNELS_OVERRIDE="linux-cachyos-bore" \
  run bash -c "source '$PROJECT_ROOT/lib/log.sh'; source '$PROJECT_ROOT/lib/verify-uki.sh'; verify_uki_safety nonexistent-kernel-99999"
  [ "$status" -ne 0 ]
  [[ "$output" =~ mkinitcpio ]] || [[ "$output" =~ rollback ]] || [[ "$output" =~ Recovery ]]
}

# ---------------------------------------------------------------------------
# Check 2: Limine entry presence
# ---------------------------------------------------------------------------

@test "verify_uki_safety: no-bore-entry fixture → Check 2 FAIL" {
  LIMINE_CONF="$FIXTURE_DIR/limine-conf/no-bore-entry.conf" \
  BOOT_EFI_LINUX="$FIXTURE_DIR/boot-efi-linux" \
  INSTALLED_KERNELS_OVERRIDE="linux-cachyos-bore" \
  run bash -c "source '$PROJECT_ROOT/lib/log.sh'; source '$PROJECT_ROOT/lib/verify-uki.sh'; verify_uki_safety linux-cachyos-bore"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Check 2 FAIL" ]]
  [[ "$output" =~ "//linux-cachyos-bore" ]]
}

@test "verify_uki_safety: unreadable limine.conf → Check 2 FAIL with read error" {
  LIMINE_CONF="/tmp/cachyos-bats-nonexistent-$$.conf" \
  BOOT_EFI_LINUX="$FIXTURE_DIR/boot-efi-linux" \
  INSTALLED_KERNELS_OVERRIDE="linux-cachyos-bore" \
  run bash -c "source '$PROJECT_ROOT/lib/log.sh'; source '$PROJECT_ROOT/lib/verify-uki.sh'; verify_uki_safety linux-cachyos-bore"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Check 2 FAIL" ]]
  [[ "$output" =~ "cannot read" ]]
}

# ---------------------------------------------------------------------------
# Check 3: UKI path resolves and hash matches
# ---------------------------------------------------------------------------

@test "verify_uki_safety: wrong-uki-path fixture → Check 3 FAIL (path)" {
  LIMINE_CONF="$FIXTURE_DIR/limine-conf/wrong-uki-path.conf" \
  BOOT_EFI_LINUX="$FIXTURE_DIR/boot-efi-linux" \
  INSTALLED_KERNELS_OVERRIDE="linux-cachyos-bore" \
  run bash -c "source '$PROJECT_ROOT/lib/log.sh'; source '$PROJECT_ROOT/lib/verify-uki.sh'; verify_uki_safety linux-cachyos-bore"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Check 3 FAIL" ]]
  [[ "$output" =~ "does not exist" ]]
}

@test "verify_uki_safety: bad-hash fixture (no panic=no) → Check 3 FAIL with hash mismatch" {
  LIMINE_CONF="$FIXTURE_DIR/limine-conf/bad-hash.conf" \
  BOOT_EFI_LINUX="$FIXTURE_DIR/boot-efi-linux" \
  INSTALLED_KERNELS_OVERRIDE="linux-cachyos-bore" \
  run bash -c "source '$PROJECT_ROOT/lib/log.sh'; source '$PROJECT_ROOT/lib/verify-uki.sh'; verify_uki_safety linux-cachyos-bore"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Check 3 FAIL" ]]
  [[ "$output" =~ "hash mismatch" ]]
}

# ---------------------------------------------------------------------------
# Check 4: Fallback kernel entries
# ---------------------------------------------------------------------------

@test "verify_uki_safety: missing-fallback + linux simulated → Check 4 FAIL" {
  LIMINE_CONF="$FIXTURE_DIR/limine-conf/missing-fallback.conf" \
  BOOT_EFI_LINUX="$FIXTURE_DIR/boot-efi-linux" \
  INSTALLED_KERNELS_OVERRIDE="linux linux-cachyos-bore" \
  run bash -c "source '$PROJECT_ROOT/lib/log.sh'; source '$PROJECT_ROOT/lib/verify-uki.sh'; verify_uki_safety linux-cachyos-bore"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Check 4 FAIL" ]]
  [[ "$output" =~ "linux" ]]
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "verify_uki_safety: missing kernel argument → exit 2" {
  LIMINE_CONF="$FIXTURE_DIR/limine-conf/valid-with-bore.conf" \
  BOOT_EFI_LINUX="$FIXTURE_DIR/boot-efi-linux" \
  run bash -c "source '$PROJECT_ROOT/lib/log.sh'; source '$PROJECT_ROOT/lib/verify-uki.sh'; verify_uki_safety"
  [ "$status" -eq 2 ]
  [[ "$output" =~ "missing KERNEL_NAME" ]]
}

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

@test "list_kernel_entries: valid-with-bore fixture → both linux-cachyos-bore and linux" {
  LIMINE_CONF="$FIXTURE_DIR/limine-conf/valid-with-bore.conf" \
  run bash -c "source '$PROJECT_ROOT/lib/log.sh'; source '$PROJECT_ROOT/lib/verify-uki.sh'; list_kernel_entries"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "linux-cachyos-bore" ]]
  [[ "$output" =~ linux ]]
}

@test "get_uki_path_for_kernel: returns parsed path for linux-cachyos-bore" {
  LIMINE_CONF="$FIXTURE_DIR/limine-conf/valid-with-bore.conf" \
  run bash -c "source '$PROJECT_ROOT/lib/log.sh'; source '$PROJECT_ROOT/lib/verify-uki.sh'; get_uki_path_for_kernel linux-cachyos-bore"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "test_linux-cachyos-bore.efi" ]]
  [[ "$output" =~ ^/boot ]]
  # Hash suffix must be stripped — output should not contain a 128-char hex tail.
  [[ ! "$output" =~ \#[0-9a-fA-F]{128} ]]
}
