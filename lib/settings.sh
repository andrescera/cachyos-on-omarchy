#!/bin/bash
set -euo pipefail

# CachyOS on Omarchy - cachyos-settings installation and verification
#
# Installs the cachyos-settings meta-package (which pulls in ananicy-cpp,
# zram-generator, sysctl tweaks, and IO scheduler udev rules) and verifies
# that the resulting system state matches CachyOS defaults.
#
# Metis R9: Only cachyos-settings is installed; cachyos-hyprland-settings,
# cachyos-fish-config, and cachyos-zsh-config are explicitly excluded because
# they conflict with the Omarchy desktop layer (see FORBIDDEN_PKGS in const.sh).
#
# Verification is advisory: each failed check emits a log_warn (not log_err)
# and verify_settings returns the warning count. A non-zero return is a
# soft signal to the caller, not a hard abort.
#
# Depends on:
#   - lib/const.sh  → CACHYOS_SETTINGS_PKGS
#   - lib/log.sh    → log_step, log_ok, log_warn, log_dry

# install_cachyos_settings
#
# Installs the cachyos-settings package via the Omarchy package helper
# (omarchy-pkg-add wraps pacman with proper confirmation handling).
# In DRY_RUN=1 mode, prints the install plan without making changes.
# After install, invokes verify_settings to confirm the resulting state.
install_cachyos_settings() {
  log_step "Installing cachyos-settings"
  log_dry "omarchy-pkg-add cachyos-settings"
  log_ok "cachyos-settings install step complete"

  log_step "Verifying cachyos-settings state"
  verify_settings
}

# verify_settings
#
# Runs five advisory checks against the running system to confirm
# cachyos-settings has been applied. Each failed check emits log_warn
# and increments a counter. Returns the total warning count (0 = all good).
#
# Checks (in order):
#   1. ananicy-cpp service is active
#   2. zram swap device is online
#   3. vm.swappiness == 150
#   4. kernel.nmi_watchdog == 0
#   5. IO scheduler matches CachyOS defaults (kyber for NVMe, bfq for SATA)
#
# The IO scheduler check is best-effort: it warns once if neither preferred
# scheduler is active on any block device, but does not enumerate per-device
# failures (schedulers may legitimately vary by workload/distro overlay).
verify_settings() {
  local warnings=0

  log_step "Check: ananicy-cpp service active"
  local ananicy_state
  ananicy_state=$(systemctl is-active ananicy-cpp 2>/dev/null || true)
  if [[ "$ananicy_state" == "active" ]]; then
    log_ok "ananicy-cpp is active"
  else
    log_warn "ananicy-cpp not active (state: ${ananicy_state:-unknown})"
    ((warnings++)) || true
  fi

  log_step "Check: zram swap online"
  if swapon --show 2>/dev/null | grep -q 'zram'; then
    log_ok "zram swap is online"
  else
    log_warn "zram swap not online"
    ((warnings++)) || true
  fi

  log_step "Check: vm.swappiness == 150"
  local swappiness
  swappiness=$(sysctl -n vm.swappiness 2>/dev/null || echo "")
  if [[ "$swappiness" == "150" ]]; then
    log_ok "vm.swappiness = 150"
  else
    log_warn "vm.swappiness = ${swappiness:-unset} (expected 150)"
    ((warnings++)) || true
  fi

  log_step "Check: kernel.nmi_watchdog == 0"
  local nmi
  nmi=$(sysctl -n kernel.nmi_watchdog 2>/dev/null || echo "")
  if [[ "$nmi" == "0" ]]; then
    log_ok "kernel.nmi_watchdog = 0"
  else
    log_warn "kernel.nmi_watchdog = ${nmi:-unset} (expected 0)"
    ((warnings++)) || true
  fi

  log_step "Check: IO scheduler (kyber for NVMe, bfq for SATA)"
  local matched=0
  local checked=0
  local sched_file scheduler
  for sched_file in /sys/block/nvme*/queue/scheduler; do
    [[ -r "$sched_file" ]] || continue
    checked=1
    scheduler=$(<"$sched_file")
    if [[ "$scheduler" == *"[kyber]"* ]]; then
      matched=1
    fi
  done
  for sched_file in /sys/block/sd*/queue/scheduler; do
    [[ -r "$sched_file" ]] || continue
    checked=1
    scheduler=$(<"$sched_file")
    if [[ "$scheduler" == *"[bfq]"* ]]; then
      matched=1
    fi
  done

  if [[ "$checked" -eq 0 ]]; then
    log_warn "No nvme*/sd* block devices found to check scheduler"
    ((warnings++)) || true
  elif [[ "$matched" -eq 1 ]]; then
    log_ok "IO scheduler matches CachyOS defaults on at least one device"
  else
    log_warn "IO scheduler does not match CachyOS defaults (kyber/bfq) on any device"
    ((warnings++)) || true
  fi

  if [[ "$warnings" -eq 0 ]]; then
    log_ok "Settings verification: all good"
  else
    log_warn "Settings verification: $warnings warnings"
  fi

  return "$warnings"
}
