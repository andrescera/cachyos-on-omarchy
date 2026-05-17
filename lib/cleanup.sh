#!/bin/bash
set -euo pipefail

# CachyOS on Omarchy - Phase 8: final summary and optional cleanup
#
# Public API:
#   print_migration_complete_banner   — printed unconditionally at end of run
#   offer_default_kernel_removal      — prompts user to remove `linux` after
#                                       linux-cachyos-bore has taken over

if [[ -n "${_CACHYOS_CLEANUP_SH_SOURCED:-}" ]]; then
  return 0
fi
_CACHYOS_CLEANUP_SH_SOURCED=1

_CLEANUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# const.sh declares `readonly` constants; guard against re-source clash.
# log.sh defines functions; guard via declare -F.
# shellcheck source=lib/const.sh
[[ -n "${MIN_OMARCHY_VERSION:-}" ]] || source "$_CLEANUP_DIR/const.sh"
# shellcheck source=lib/log.sh
declare -F log_step >/dev/null 2>&1 || source "$_CLEANUP_DIR/log.sh"

print_migration_complete_banner() {
  printf "\n%b═══════════════════════════════════════════════════%b\n" "$_C_GREEN" "$_C_RESET"
  printf "%b  ✓ Migration Finished%b\n" "$_C_GREEN" "$_C_RESET"
  printf "%b═══════════════════════════════════════════════════%b\n\n" "$_C_GREEN" "$_C_RESET"
  log_ok "CachyOS repositories installed"
  log_ok "System upgraded to CachyOS-optimized versions"
  log_ok "linux-cachyos-bore kernel installed"
  log_ok "cachyos-settings applied"
  log_ok "pacman.conf restore hooks active (Alpm + Omarchy pre-refresh)"
  printf "\n"
}

# offer_default_kernel_removal
# If the stock Omarchy `linux` package is still installed alongside the
# new linux-cachyos-bore, offer to remove it. Removing saves disk and
# prevents accidental boots into the unoptimized kernel — but it also
# eliminates the fallback, so the prompt explicitly warns the user and
# recommends `linux-lts` as a safer alternative fallback.
offer_default_kernel_removal() {
  if ! pacman -Q linux >/dev/null 2>&1; then
    return 0
  fi

  printf "\n%b── Optional: default kernel cleanup ──%b\n\n" "$_C_YELLOW" "$_C_RESET"
  echo "The default Omarchy kernel ('linux') is still installed."
  echo "You are now running linux-cachyos-bore, which replaces it for"
  echo "every boot. Removing 'linux' saves ~200MB of disk space and"
  echo "prevents accidental boots into the unoptimized kernel."
  printf "\n"
  printf "%b⚠ Warning%b: Removing 'linux' leaves you without a fallback kernel.\n" "$_C_YELLOW" "$_C_RESET"
  echo "  If linux-cachyos-bore ever has issues (regression, bad mkinitcpio"
  echo "  run, etc.), you'd have no working kernel to boot."
  echo
  echo "  Safer alternative: install linux-lts as your fallback BEFORE"
  echo "  removing 'linux':"
  echo "    sudo pacman -S linux-lts linux-lts-headers"
  printf "\n"

  if ! confirm "Remove the default 'linux' kernel now?"; then
    log_ok "Keeping default 'linux' kernel as fallback (recommended)"
    return 0
  fi

  log_step "Removing default 'linux' kernel"

  local kernel_pkgs=(linux)
  if pacman -Q linux-headers >/dev/null 2>&1; then
    kernel_pkgs+=(linux-headers)
  fi

  log_dry "sudo pacman -Rns --noconfirm ${kernel_pkgs[*]}"
  log_ok "Default kernel removed (${kernel_pkgs[*]})"
}
