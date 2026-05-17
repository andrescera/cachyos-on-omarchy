#!/bin/bash
# shellcheck disable=SC1091  # Sibling lib files are resolved at runtime, not by shellcheck
set -euo pipefail

# CachyOS on Omarchy - Pre-flight check orchestrator (Tollgate 1)
#
# Runs ALL pre-flight checks in a strict, fail-fast order before any
# state-changing migration work begins. Every check is READ-ONLY; this
# file MUST NOT modify system state under any circumstance.
#
# Designed to be called ONCE from migrate.sh as `run_preflight` with no
# arguments. Aborts hard (exit 1) on the first failure — no fallbacks.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Idempotent dependency sourcing. const.sh uses `readonly` so a naive
# re-source would crash; the guards below skip already-loaded files.
# shellcheck source=./const.sh
[[ -n "${MIN_OMARCHY_VERSION:-}" ]] || source "$SCRIPT_DIR/const.sh"
# shellcheck source=./log.sh
declare -F log_step >/dev/null 2>&1 || source "$SCRIPT_DIR/log.sh"
# shellcheck source=./detect-gpu.sh
declare -F detect_gpu_vendor >/dev/null 2>&1 || source "$SCRIPT_DIR/detect-gpu.sh"
# shellcheck source=./detect-cpu.sh
declare -F detect_arch_level >/dev/null 2>&1 || source "$SCRIPT_DIR/detect-cpu.sh"
# shellcheck source=./detect-system.sh
declare -F detect_root_fs >/dev/null 2>&1 || source "$SCRIPT_DIR/detect-system.sh"

# preflight_fail MSG
# Print error message, mark migration aborted, exit non-zero.
preflight_fail() {
  local msg="$1"
  log_err "$msg"
  log_err "Migration aborted."
  exit 1
}

# run_preflight
# Tollgate 1: runs all 12 safety checks in strict order. Aborts hard on
# any failure. No arguments — callers pass configuration via env vars
# (DRY_RUN, NO_COLOR) which the underlying helpers already honour.
run_preflight() {
  local root_fs bootloader omarchy_ver gpu_vendor cpu_arch
  local root_avail_kb boot_avail_kb
  local cmd

  # ----- Check 1: must NOT run as root -----
  log_step "Check 1: Running as non-root user"
  if [[ $EUID -eq 0 ]]; then
    preflight_fail "Must not run as root. Re-run as your user."
  fi
  log_ok "OK: running as UID $EUID (non-root)"

  # ----- Check 2: internet reachable -----
  log_step "Check 2: Internet reachable (mirror.cachyos.org)"
  if ! curl -sf --max-time 10 https://mirror.cachyos.org -o /dev/null; then
    preflight_fail "No internet access to mirror.cachyos.org"
  fi
  log_ok "OK: mirror.cachyos.org reachable"

  # ----- Check 3: pacman database not locked -----
  log_step "Check 3: pacman database not locked"
  if [[ -f /var/lib/pacman/db.lck ]]; then
    preflight_fail "pacman.db is locked — another process is running. Remove /var/lib/pacman/db.lck if stale."
  fi
  log_ok "OK: pacman lock absent"

  # ----- Check 4: Omarchy installation present -----
  log_step "Check 4: Omarchy installation present"
  if [[ ! -d "$HOME/.local/share/omarchy" ]]; then
    preflight_fail "Omarchy not found at ~/.local/share/omarchy. This script requires Omarchy 3.0+."
  fi
  log_ok "OK: Omarchy installed at ~/.local/share/omarchy"

  # ----- Check 5: Omarchy version >= minimum -----
  log_step "Check 5: Omarchy version >= $MIN_OMARCHY_VERSION"
  omarchy_ver="$(detect_omarchy_version)"
  if ! version_ge "$omarchy_ver" "$MIN_OMARCHY_VERSION"; then
    preflight_fail "Omarchy version $omarchy_ver is below minimum $MIN_OMARCHY_VERSION"
  fi
  log_ok "OK: Omarchy version $omarchy_ver"

  # ----- Check 6: required commands present -----
  log_step "Check 6: Required commands available"
  for cmd in gum yay limine mkinitcpio; do
    if ! require_cmd "$cmd"; then
      preflight_fail "Required command '$cmd' not found"
    fi
  done
  # Optional Omarchy helpers — warn if missing, never abort.
  for cmd in omarchy-cmd-present omarchy-pkg-present; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_warn "Optional Omarchy helper '$cmd' not found (continuing without)"
    fi
  done
  log_ok "OK: required commands (gum, yay, limine, mkinitcpio) available"

  # ----- Check 7: bootloader is Limine -----
  log_step "Check 7: Bootloader is Limine"
  bootloader="$(detect_bootloader)"
  if [[ "$bootloader" != "limine" ]]; then
    preflight_fail "Bootloader must be Limine. Detected: $bootloader. This script only supports Limine+UKI."
  fi
  log_ok "OK: bootloader is limine"

  # ----- Check 8: UKI mode enabled -----
  log_step "Check 8: Limine UKI mode enabled"
  if ! detect_uki_mode; then
    preflight_fail "ENABLE_UKI is not set to 'yes' in /etc/default/limine. This script requires UKI mode."
  fi
  log_ok "OK: ENABLE_UKI=yes"

  # ----- Check 9: root filesystem supported -----
  log_step "Check 9: Root filesystem supported (btrfs | ext4)"
  root_fs="$(detect_root_fs)"
  if [[ "$root_fs" != "btrfs" && "$root_fs" != "ext4" ]]; then
    preflight_fail "Root filesystem '$root_fs' not supported. Only btrfs and ext4 are supported."
  fi
  log_ok "OK: root filesystem is $root_fs"

  # ----- Check 10: disk space on / (>= 4 GB) -----
  log_step "Check 10: At least 4GB free on /"
  root_avail_kb="$(df --output=avail / 2>/dev/null | tail -1 | tr -d ' ')"
  if [[ -z "$root_avail_kb" || ! "$root_avail_kb" =~ ^[0-9]+$ ]]; then
    preflight_fail "Unable to determine free space on /"
  fi
  if (( root_avail_kb < 4 * 1024 * 1024 )); then
    preflight_fail "Less than 4GB free on /. Needed for kernel + packages."
  fi
  log_ok "OK: $((root_avail_kb / 1024)) MB free on /"

  # ----- Check 11: disk space on /boot (>= 500 MB) -----
  log_step "Check 11: At least 500MB free on /boot"
  boot_avail_kb="$(df --output=avail /boot 2>/dev/null | tail -1 | tr -d ' ')"
  if [[ -z "$boot_avail_kb" || ! "$boot_avail_kb" =~ ^[0-9]+$ ]]; then
    preflight_fail "Unable to determine free space on /boot"
  fi
  if (( boot_avail_kb < 500 * 1024 )); then
    preflight_fail "Less than 500MB free on /boot. Needed for new UKI."
  fi
  log_ok "OK: $((boot_avail_kb / 1024)) MB free on /boot"

  # ----- Check 12: GPU vendor + CPU arch detection -----
  log_step "Check 12: GPU vendor + CPU architecture detection"
  # Explicit lspci pipe so detect_gpu_vendor's stdin heuristic is bypassed.
  gpu_vendor="$(lspci -nn 2>/dev/null | detect_gpu_vendor)"
  if [[ "$gpu_vendor" == "unknown" ]]; then
    log_warn "GPU vendor could not be identified — NVIDIA install path will be disabled."
  else
    log_ok "OK: GPU vendor is $gpu_vendor"
  fi
  cpu_arch="$(detect_arch_level)"
  log_ok "OK: CPU arch level is $cpu_arch"

  # ----- Summary table -----
  log_step "Pre-flight summary"
  if command -v gum >/dev/null 2>&1; then
    gum format <<EOF || true
| Item            | Value                          |
|-----------------|--------------------------------|
| Filesystem      | $root_fs                       |
| Bootloader      | $bootloader                    |
| UKI mode        | yes                            |
| Omarchy version | $omarchy_ver                   |
| GPU vendor      | $gpu_vendor                    |
| CPU arch        | $cpu_arch                      |
| Free on /       | $((root_avail_kb / 1024)) MB   |
| Free on /boot   | $((boot_avail_kb / 1024)) MB   |
EOF
  else
    printf '  Filesystem      : %s\n'    "$root_fs"
    printf '  Bootloader      : %s\n'    "$bootloader"
    printf '  UKI mode        : %s\n'    "yes"
    printf '  Omarchy version : %s\n'    "$omarchy_ver"
    printf '  GPU vendor      : %s\n'    "$gpu_vendor"
    printf '  CPU arch        : %s\n'    "$cpu_arch"
    printf '  Free on /       : %s MB\n' "$((root_avail_kb / 1024))"
    printf '  Free on /boot   : %s MB\n' "$((boot_avail_kb / 1024))"
  fi

  # ----- Final confirmation gate -----
  if ! confirm "Pre-flight checks passed. Proceed with migration?"; then
    log_err "User declined to proceed."
    exit 1
  fi

  return 0
}
