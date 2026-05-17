#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# CachyOS on Omarchy - Rollback Orchestrator
#
# Implements scenarios 2-5 from docs/rollback.md. Scenario 1 (full nuclear
# rollback) is intentionally manual — see docs/rollback.md#scenario-1.
#
# Flags (exhaustive — no others permitted):
#   --scenario N    Run scenario N (2, 3, 4, or 5). 1 prints a manual-only
#                   message and exits non-zero.
#   --dry-run       Print planned actions without executing. All state changes
#                   are wrapped in log_dry so DRY_RUN=1 makes zero changes.
#   --help          Print usage and exit 0.
#   --list          Print all scenarios with one-line descriptions, exit 0.
#
# Every destructive operation is gated by `confirm` (gum confirm). DRY_RUN=1
# auto-approves confirmations and replaces all sudo state-changes with prints.
#
# NOTE on pacman-conf-restore.sh: lib/pacman-conf-restore.sh is intentionally
# NOT sourced here. It is designed to be executed (not sourced) and contains
# top-level logic that `exit 0`s when cachyos repo blocks are present in
# pacman.conf, which would terminate this script before any rollback runs.
# Scenario 3 uses restore_backup_pacman_conf from lib/backup.sh instead.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/const.sh
source "$SCRIPT_DIR/lib/const.sh"
# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/detect-gpu.sh
source "$SCRIPT_DIR/lib/detect-gpu.sh"
# shellcheck source=lib/detect-cpu.sh
source "$SCRIPT_DIR/lib/detect-cpu.sh"
# shellcheck source=lib/detect-system.sh
source "$SCRIPT_DIR/lib/detect-system.sh"
# shellcheck source=lib/verify-uki.sh
source "$SCRIPT_DIR/lib/verify-uki.sh"
# shellcheck source=lib/backup.sh
source "$SCRIPT_DIR/lib/backup.sh"

DRY_RUN="${DRY_RUN:-0}"
SCENARIO=""

usage() {
  cat <<EOF
rollback.sh — CachyOS on Omarchy rollback orchestrator

USAGE:
  ./rollback.sh --list
  ./rollback.sh --scenario N [--dry-run]
  ./rollback.sh --help

FLAGS:
  --scenario N    Run scenario N (2-5). Scenario 1 is manual; see
                  docs/rollback.md#scenario-1.
  --dry-run       Print planned actions without executing.
  --help          Show this help and exit.
  --list          List all scenarios with descriptions and exit.

SCENARIOS:
  2. Kernel only           Remove linux-cachyos-bore + NVIDIA companion.
  3. Repos only            Restore pacman.conf, remove CachyOS packages.
  4. Settings only         Remove cachyos-settings, restore system tuning.
  5. Emergency boot        Remove cachyos-bore from a fallback kernel.

EXAMPLES:
  ./rollback.sh --list
  ./rollback.sh --scenario 2 --dry-run
  ./rollback.sh --scenario 5

See docs/rollback.md for full per-scenario details.
EOF
}

print_scenarios() {
  cat <<EOF
Rollback Scenarios:

  1. Full rollback (MANUAL) — see docs/rollback.md#scenario-1
     Returns to clean Arch/Omarchy state. Complex; do manually.

  2. Kernel only — ./rollback.sh --scenario 2
     Removes linux-cachyos-bore + NVIDIA companion; rebuilds limine.

  3. Repos only — ./rollback.sh --scenario 3
     Restores pacman.conf from backup; removes CachyOS packages.

  4. Settings only — ./rollback.sh --scenario 4
     Removes cachyos-settings; restores prior system tuning.

  5. Emergency boot recovery — ./rollback.sh --scenario 5
     Removes linux-cachyos-bore when booted from fallback kernel.
     MUST be run from a fallback kernel (not linux-cachyos-bore itself).
EOF
}

# rollback_scenario_2
# Remove linux-cachyos-bore + headers + NVIDIA companion, verify fallback
# limine entries remain, then offer reboot.
rollback_scenario_2() {
  log_step "Scenario 2: Kernel rollback (linux-cachyos-bore removal)"

  local nvidia_pkg=""
  local pkg
  for pkg in linux-cachyos-bore-nvidia-open nvidia-580xx-dkms nvidia-470xx-dkms; do
    if pacman -Qq "$pkg" >/dev/null 2>&1; then
      nvidia_pkg="$pkg"
      break
    fi
  done

  if [[ -n "$nvidia_pkg" ]]; then
    log_ok "NVIDIA companion detected: $nvidia_pkg"
  else
    log_ok "No NVIDIA companion installed"
  fi

  confirm "Remove linux-cachyos-bore, linux-cachyos-bore-headers${nvidia_pkg:+, $nvidia_pkg}?" || exit 0

  log_dry "sudo pacman -Rns linux-cachyos-bore linux-cachyos-bore-headers${nvidia_pkg:+ $nvidia_pkg}"

  log_step "Verifying fallback kernel entries in limine.conf..."
  local entries=""
  entries=$(list_kernel_entries 2>/dev/null || true)
  if [[ -n "$entries" ]]; then
    log_ok "Remaining limine entries:"
    printf '%s\n' "$entries" | sed 's/^/    /'
  else
    log_warn "Could not enumerate limine entries (check ${LIMINE_CONF})"
  fi

  log_ok "Scenario 2 plan complete."
  if confirm "Reboot to complete kernel rollback?"; then
    log_dry "sudo systemctl reboot"
  fi
}

# rollback_scenario_3
# Restore pacman.conf from latest backup, then remove CachyOS-specific
# packages. Aborts if no backup is found under $BACKUP_BASE.
rollback_scenario_3() {
  log_step "Scenario 3: Repository rollback"

  local latest_backup=""
  if [[ -d "$BACKUP_BASE" ]]; then
    latest_backup=$(find "$BACKUP_BASE" -maxdepth 1 -type d -name 'migration-*' 2>/dev/null \
      | sort -r | head -1 || true)
  fi

  if [[ -z "$latest_backup" ]]; then
    log_err "No backup found in $BACKUP_BASE"
    log_err "Manual restoration required. See docs/rollback.md#scenario-3"
    exit 1
  fi
  log_ok "Found backup: $latest_backup"

  confirm "Restore pacman.conf from backup and remove CachyOS packages?" || exit 0

  restore_backup_pacman_conf "$latest_backup"

  log_dry "sudo pacman -Rns cachyos-keyring cachyos-mirrorlist cachyos-rate-mirrors 2>/dev/null || true"
  log_dry "sudo pacman -Sy"
  log_ok "Scenario 3 complete. CachyOS repos removed."
}

# rollback_scenario_4
# Remove cachyos-settings and companion tuning packages. Soft rollback —
# no reboot required.
rollback_scenario_4() {
  log_step "Scenario 4: Settings rollback (cachyos-settings removal)"

  confirm "Remove cachyos-settings and restore default system tuning?" || exit 0

  log_dry "sudo pacman -Rns cachyos-settings ananicy-cpp ananicy-rules-cachyos 2>/dev/null || true"
  log_dry "sudo systemctl daemon-reload"

  log_ok "Scenario 4 complete. CachyOS settings removed."
  log_ok "System will use default kernel scheduler and sysctl settings after reboot."
}

# rollback_scenario_5
# Emergency boot recovery: remove linux-cachyos-bore + every companion.
# REFUSES to run while booted into a cachyos-bore kernel — user must reboot
# to a fallback kernel (linux, linux-lts) first.
rollback_scenario_5() {
  log_step "Scenario 5: Emergency boot recovery"

  local running_kernel
  running_kernel=$(uname -r)
  if [[ "$running_kernel" == *"cachyos-bore"* ]]; then
    log_err "Cannot run scenario 5 while booted into cachyos-bore kernel ($running_kernel)."
    log_err "Boot into a fallback kernel (linux, linux-lts) first, then re-run."
    exit 1
  fi

  log_ok "Running kernel: $running_kernel (not cachyos-bore) ✓"

  confirm "Remove linux-cachyos-bore and all companions? (This removes the CachyOS kernel entirely)" || exit 0

  local pkgs_to_remove=""
  local pkg
  for pkg in linux-cachyos-bore linux-cachyos-bore-headers linux-cachyos-bore-nvidia-open nvidia-580xx-dkms nvidia-470xx-dkms; do
    if pacman -Qq "$pkg" >/dev/null 2>&1; then
      pkgs_to_remove="$pkgs_to_remove $pkg"
    fi
  done

  if [[ -z "$pkgs_to_remove" ]]; then
    log_ok "No cachyos-bore packages found. Nothing to remove."
    exit 0
  fi

  log_dry "sudo pacman -Rns${pkgs_to_remove}"
  log_dry "sudo mkinitcpio -P"

  log_ok "Scenario 5 complete. CachyOS kernel removed."
  if confirm "Reboot to verify fallback kernel boots correctly?"; then
    log_dry "sudo systemctl reboot"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --help)
      usage
      exit 0
      ;;
    --list)
      print_scenarios
      exit 0
      ;;
    --scenario)
      shift
      if [[ -z "${1:-}" ]]; then
        log_err "--scenario requires N (2-5)"
        exit 1
      fi
      SCENARIO="$1"
      ;;
    *)
      log_err "Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done
export DRY_RUN

case "$SCENARIO" in
  1)
    log_err "Scenario 1 is manual. See docs/rollback.md#scenario-1"
    exit 1
    ;;
  2) rollback_scenario_2 ;;
  3) rollback_scenario_3 ;;
  4) rollback_scenario_4 ;;
  5) rollback_scenario_5 ;;
  "")
    log_err "No scenario specified. Use --list or --scenario N"
    exit 1
    ;;
  *)
    log_err "Unknown scenario: $SCENARIO (valid: 2-5)"
    exit 1
    ;;
esac
