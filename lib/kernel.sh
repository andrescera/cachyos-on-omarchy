#!/bin/bash
set -euo pipefail

# CachyOS on Omarchy - Kernel installation phase
#
# Installs linux-cachyos-bore + headers, the correct NVIDIA companion driver
# (by PCI device ID lookup, never by name heuristics), and the appropriate
# microcode package for the detected CPU. Then runs the DKMS depmod workaround
# and triggers UKI generation so the resulting image is signed with DKMS
# modules embedded.
#
# Safety properties (Metis review):
#   R1/R2/R3 — UKI hook is triggered explicitly; caller is expected to run
#              `verify_uki_safety` (Tollgate 2) after this function returns
#              with DRY_RUN=0.
#   R4       — NVIDIA companion is chosen via detect_nvidia_gen +
#              nvidia_companion_for_gen ONLY. "none" → install nothing.
#   R5       — Microcode selected via detect_cpu_vendor; "unknown" → install
#              nothing rather than guessing.
#
# DRY_RUN=1 honoured throughout via log_dry; no state changes.

# Resolve the directory this script lives in so we can defensively source
# verify-uki.sh when it becomes available (T13). Use BASH_SOURCE so this
# works whether the file is sourced or executed.
_KERNEL_SH_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly _KERNEL_SH_DIR

# Source verify-uki.sh if it exists and defines verify_uki_safety. T13
# delivers this file; until then the post-install check is a no-op.
if [[ -f "$_KERNEL_SH_DIR/verify-uki.sh" ]]; then
  # shellcheck source=/dev/null
  source "$_KERNEL_SH_DIR/verify-uki.sh"
fi

# install_cachyos_kernel
#
# Six-step kernel install flow:
#   1. linux-cachyos-bore + linux-cachyos-bore-headers
#   2. NVIDIA decision (PCI device ID → generation → companion)
#   3. CPU microcode
#   4. depmod for the installed kernel version (DKMS workaround)
#   5. mkinitcpio -p linux-cachyos-bore (triggers UKI generation)
#   6. UKI safety verification (Tollgate 2, only when DRY_RUN=0)
#
# Reads CACHYOS_KERNEL_PKGS from lib/const.sh.
# Returns 0 on success. In DRY_RUN=1 always returns 0 (plan only).
install_cachyos_kernel() {
  log_step "Installing CachyOS kernel (linux-cachyos-bore)"

  # ---- Step 1: kernel + headers ------------------------------------------
  local pkg
  for pkg in "${CACHYOS_KERNEL_PKGS[@]}"; do
    log_dry "omarchy-pkg-add $pkg"
  done

  # ---- Step 2: GPU detection → NVIDIA companion --------------------------
  log_step "Detecting GPU for NVIDIA driver decision"
  local vendor gen companion dev_id lspci_out
  # Capture lspci once; pipe explicitly into detect_gpu_vendor so the call
  # works in non-interactive shells where [[ -t 0 ]] would be false but no
  # data is actually piped in. (Reusing the output also avoids a second
  # PCI scan for the device-ID lookup below.)
  lspci_out=$(lspci -nn 2>/dev/null || true)
  vendor=$(printf '%s\n' "$lspci_out" | detect_gpu_vendor)
  log_ok "GPU vendor: $vendor"

  if [[ "$vendor" == nvidia* ]]; then
    # First PCI device ID for an NVIDIA card from the cached lspci output.
    # grep -oP (PCRE) is portable on Arch's default grep package.
    dev_id=$(printf '%s\n' "$lspci_out" | grep -oP '(?<=\[10de:)[0-9a-f]{4}' | head -1 || true)
    if [[ -z "$dev_id" ]]; then
      log_warn "NVIDIA vendor reported but no device ID found via lspci; skipping NVIDIA driver"
      companion="none"
      gen="unknown"
    else
      gen=$(detect_nvidia_gen "$dev_id")
      companion=$(nvidia_companion_for_gen "$gen")
      log_ok "NVIDIA device ID: $dev_id → generation: $gen → companion: $companion"
    fi

    case "$companion" in
      none)
        # Metis R4: never install a driver on unknown hardware.
        log_warn "GPU not recognized (device ID: ${dev_id:-n/a}). No NVIDIA driver installed. Install manually if needed."
        ;;
      nouveau)
        log_ok "Nouveau (built-in) handles this GPU. No separate NVIDIA package needed."
        ;;
      nvidia-open)
        # Kernel-companion DKMS package — pairs with linux-cachyos-bore.
        log_dry "omarchy-pkg-add linux-cachyos-bore-nvidia-open"
        ;;
      580xx)
        log_dry "omarchy-pkg-add nvidia-580xx-dkms"
        ;;
      470xx)
        log_dry "omarchy-pkg-add nvidia-470xx-dkms"
        ;;
      *)
        log_warn "Unknown NVIDIA companion '$companion'; skipping driver install"
        ;;
    esac
  else
    log_ok "GPU: $vendor — no NVIDIA driver needed"
  fi

  # ---- Step 3: microcode -------------------------------------------------
  log_step "Selecting CPU microcode package"
  local cpu_vendor ucode_pkg
  cpu_vendor=$(detect_cpu_vendor)
  ucode_pkg=$(microcode_pkg_for_vendor "$cpu_vendor")
  log_ok "CPU vendor: $cpu_vendor → microcode: $ucode_pkg"

  if [[ "$ucode_pkg" != "unknown" ]]; then
    log_dry "omarchy-pkg-add $ucode_pkg"
  else
    log_warn "CPU vendor unknown; no microcode package installed. Verify manually."
  fi

  # ---- Step 4: DKMS depmod workaround ------------------------------------
  # Background: without an explicit `depmod $KVER` before mkinitcpio, the
  # NVIDIA DKMS modules in /lib/modules/$KVER/extramodules are not yet
  # registered, so mkinitcpio builds a UKI without NVIDIA support. The
  # validated migration plan calls this out as a hard requirement.
  log_step "Running depmod for cachyos-bore kernel modules"
  local kver=""

  if [[ -d /lib/modules ]]; then
    # Newest cachyos-bore module directory wins. Glob + sort -V avoids the
    # `ls | grep` antipattern (SC2010) and tolerates non-alphanumeric names.
    local mod_dir
    local -a mod_candidates=()
    for mod_dir in /lib/modules/*-cachyos-bore; do
      [[ -d "$mod_dir" ]] || continue
      mod_candidates+=("$(basename "$mod_dir")")
    done
    if (( ${#mod_candidates[@]} > 0 )); then
      kver=$(printf '%s\n' "${mod_candidates[@]}" | sort -V | tail -1)
    fi
  fi

  if [[ -z "$kver" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      # In dry-run on a fresh machine the modules dir may not yet exist for
      # this kernel; show the intent so the plan is still complete.
      kver="<linux-cachyos-bore-version>"
      log_warn "No /lib/modules/*-cachyos-bore directory yet (expected on first install)"
    else
      log_err "depmod skipped: no /lib/modules/*-cachyos-bore directory found"
      return 1
    fi
  fi

  log_dry "sudo depmod '$kver'"

  # ---- Step 5: UKI generation -------------------------------------------
  log_step "Triggering UKI regeneration via mkinitcpio"
  log_dry "sudo mkinitcpio -p linux-cachyos-bore"

  # ---- Step 6: Tollgate 2 pre-check -------------------------------------
  if [[ "$DRY_RUN" != "1" ]]; then
    if declare -f verify_uki_safety >/dev/null 2>&1; then
      log_step "Verifying UKI safety (Tollgate 2)"
      if ! verify_uki_safety linux-cachyos-bore; then
        log_err "UKI safety verification failed; aborting kernel phase"
        return 1
      fi
    else
      log_warn "verify_uki_safety not available (lib/verify-uki.sh missing); skipping Tollgate 2"
    fi

  fi
  # Metis R13 mkinitcpio.conf diff lives in migrate.sh (orchestrator
  # concern). Don't duplicate it here.

  log_ok "CachyOS kernel phase complete"
  return 0
}
