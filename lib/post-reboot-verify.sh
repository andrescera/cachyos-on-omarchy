#!/bin/bash
set -euo pipefail

# CachyOS on Omarchy - Post-reboot verification (Tollgate 3)
#
# READ-ONLY runtime verification that the system actually came up with the
# CachyOS kernel + tunables applied. Intended to run AFTER reboot from a
# successful migration, wired through `migrate.sh --verify` (the wiring
# itself lives in migrate.sh; this file only provides the function).
#
# Nine advisory checks. Each failed check emits log_warn and increments a
# counter; the function returns the warning count. A non-zero return is a
# soft signal to the caller (migrate.sh treats it as a concern, NOT a hard
# abort). Critical correctness checks (kernel name, BORE sysctl) and
# environment-conditional checks (NVIDIA, IO scheduler) are treated
# uniformly so a single weird machine doesn't fail the gate.
#
# Checks (in order):
#   1. Running kernel name contains "cachyos-bore"
#   2. kernel.sched_bore == 1
#   3. systemd unit ananicy-cpp is active
#   4. zram swap device is mounted
#   5. vm.swappiness == 150
#   6. kernel.nmi_watchdog == 0
#   7. IO scheduler matches CachyOS defaults (kyber/bfq/mq-deadline)
#      on at least one block device (best-effort, hardware-dependent)
#   8. NVIDIA driver working (nvidia-smi) — skipped on non-NVIDIA systems
#   9. CachyOS pacman repo is accessible (pacman -Sl cachyos)
#
# Depends on:
#   - lib/log.sh       → log_step, log_ok, log_warn, log_err
#   - lib/detect-gpu.sh → detect_gpu_vendor (for Check 8)
#
# Tools: uname, sysctl, systemctl, swapon, cat (/sys), pacman, nvidia-smi.

# run_post_reboot_verify
#
# Run all 9 checks. Returns the total warning count (0 = all good).
# Performs NO state changes. Safe to run repeatedly.
run_post_reboot_verify() {
  local warnings=0

  log_step "Tollgate 3: Post-reboot verification (9 checks)"

  # ----- Check 1: Running cachyos-bore kernel -----
  log_step "Check 1: Running linux-cachyos-bore kernel"
  local kern
  kern=$(uname -r)
  if [[ "$kern" == *"cachyos-bore"* ]]; then
    log_ok "Check 1 PASS: Running cachyos-bore kernel ($kern)"
  else
    log_warn "Check 1 WARN: Not running cachyos-bore kernel ($kern)"
    (( warnings++ )) || true
  fi

  # ----- Check 2: BORE scheduler sysctl active -----
  log_step "Check 2: BORE scheduler active"
  local bore_val
  bore_val=$(sysctl -n kernel.sched_bore 2>/dev/null || echo "absent")
  if [[ "$bore_val" == "1" ]]; then
    log_ok "Check 2 PASS: kernel.sched_bore = 1"
  else
    log_warn "Check 2 WARN: kernel.sched_bore = $bore_val (expected 1)"
    (( warnings++ )) || true
  fi

  # ----- Check 3: ananicy-cpp active -----
  log_step "Check 3: ananicy-cpp service"
  if systemctl is-active ananicy-cpp >/dev/null 2>&1; then
    log_ok "Check 3 PASS: ananicy-cpp is active"
  else
    log_warn "Check 3 WARN: ananicy-cpp is not active"
    (( warnings++ )) || true
  fi

  # ----- Check 4: zram swap active -----
  log_step "Check 4: zram swap"
  if swapon --show 2>/dev/null | grep -q 'zram'; then
    log_ok "Check 4 PASS: zram swap is active"
  else
    log_warn "Check 4 WARN: zram swap not found in swapon --show"
    (( warnings++ )) || true
  fi

  # ----- Check 5: swappiness == 150 -----
  log_step "Check 5: vm.swappiness"
  local swappiness
  swappiness=$(sysctl -n vm.swappiness 2>/dev/null || echo "0")
  if [[ "$swappiness" -eq 150 ]]; then
    log_ok "Check 5 PASS: vm.swappiness = 150"
  else
    log_warn "Check 5 WARN: vm.swappiness = $swappiness (expected 150)"
    (( warnings++ )) || true
  fi

  # ----- Check 6: nmi_watchdog == 0 -----
  log_step "Check 6: kernel.nmi_watchdog"
  local nmi_val
  nmi_val=$(sysctl -n kernel.nmi_watchdog 2>/dev/null || echo "1")
  if [[ "$nmi_val" -eq 0 ]]; then
    log_ok "Check 6 PASS: kernel.nmi_watchdog = 0"
  else
    log_warn "Check 6 WARN: kernel.nmi_watchdog = $nmi_val (expected 0)"
    (( warnings++ )) || true
  fi

  # ----- Check 7: IO scheduler (best-effort) -----
  # Walk nvme*/sd* block devices, looking for any with kyber/bfq/mq-deadline
  # as the active scheduler (denoted by square brackets). One match is
  # enough — schedulers may legitimately vary across devices/workloads.
  log_step "Check 7: IO scheduler"
  local sched_ok=0
  local sched_file sched
  for sched_file in /sys/block/nvme*/queue/scheduler /sys/block/sd*/queue/scheduler; do
    [[ -r "$sched_file" ]] || continue
    sched=$(cat "$sched_file" 2>/dev/null || echo "")
    if [[ "$sched" =~ \[(kyber|bfq|mq-deadline)\] ]]; then
      sched_ok=1
      break
    fi
  done
  if [[ "$sched_ok" -eq 1 ]]; then
    log_ok "Check 7 PASS: IO scheduler matches CachyOS defaults"
  else
    log_warn "Check 7 WARN: IO scheduler not matched (may be OK on some hardware)"
    (( warnings++ )) || true
  fi

  # ----- Check 8: NVIDIA driver (skip if no NVIDIA GPU) -----
  # detect_gpu_vendor returns "nvidia" or "hybrid:nvidia,..." when NVIDIA
  # hardware is present; both match `grep -q nvidia`. Non-NVIDIA hosts skip
  # this check entirely (counted as PASS, not WARN).
  log_step "Check 8: NVIDIA driver (if applicable)"
  if detect_gpu_vendor 2>/dev/null | grep -q nvidia; then
    if nvidia-smi >/dev/null 2>&1; then
      local nv_info
      nv_info=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1)
      log_ok "Check 8 PASS: nvidia-smi works ($nv_info)"
    else
      log_warn "Check 8 WARN: NVIDIA GPU detected but nvidia-smi failed"
      (( warnings++ )) || true
    fi
  else
    log_ok "Check 8 SKIP: No NVIDIA GPU detected"
  fi

  # ----- Check 9: CachyOS pacman repo functional -----
  # `pacman -Sl cachyos` exits 0 iff the cachyos repo is configured AND
  # reachable in the local sync db. Network is not required (we hit the
  # cached db, not the mirror). Output is discarded; only the exit code
  # is significant.
  log_step "Check 9: CachyOS repos functional"
  if pacman -Sl cachyos >/dev/null 2>&1; then
    log_ok "Check 9 PASS: cachyos repo is accessible"
  else
    log_warn "Check 9 WARN: cachyos repo not accessible (check pacman.conf)"
    (( warnings++ )) || true
  fi

  # ----- Summary -----
  if [[ "$warnings" -eq 0 ]]; then
    log_ok ""
    log_ok "Tollgate 3 PASS: All post-reboot checks passed."
  else
    log_warn "Tollgate 3: $warnings check(s) with warnings (not all critical)."
  fi
  return "$warnings"
}
