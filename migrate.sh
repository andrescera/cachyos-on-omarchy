#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# CachyOS on Omarchy - Main migration orchestrator
#
# Layers CachyOS optimisations (repos + linux-cachyos-bore kernel +
# cachyos-settings) onto an existing Omarchy installation in seven
# phases gated by three tollgates:
#
#   Tollgate 1: lib/preflight.sh (read-only safety checks)
#   Tollgate 2: lib/verify-uki.sh (read-only UKI/Limine verification,
#               ALWAYS runs - never skipped, even with --resume)
#   Tollgate 3: lib/post-reboot-verify.sh (post-reboot runtime checks,
#               invoked via --verify after reboot)
#
# Flags (exhaustive - no others permitted; Metis "no-bypass" directive):
#   --dry-run, --help, --resume PHASE, --version, --verify

# Resolve the directory of this script so siblings can be sourced no
# matter where the user invokes ./migrate.sh from. Use a unique name
# because several lib/*.sh files internally (re)set SCRIPT_DIR to their
# own directory and would otherwise clobber ours during sourcing.
MIGRATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source every library in dependency order. The libs use re-source guards
# so transitively repeating a source is safe (preflight.sh re-sources
# const.sh + log.sh; kernel.sh re-sources verify-uki.sh).
# shellcheck source=lib/const.sh
source "$MIGRATE_DIR/lib/const.sh"
# shellcheck source=lib/log.sh
source "$MIGRATE_DIR/lib/log.sh"
# shellcheck source=lib/detect-gpu.sh
source "$MIGRATE_DIR/lib/detect-gpu.sh"
# shellcheck source=lib/detect-cpu.sh
source "$MIGRATE_DIR/lib/detect-cpu.sh"
# shellcheck source=lib/detect-system.sh
source "$MIGRATE_DIR/lib/detect-system.sh"
# shellcheck source=lib/preflight.sh
source "$MIGRATE_DIR/lib/preflight.sh"
# shellcheck source=lib/backup.sh
source "$MIGRATE_DIR/lib/backup.sh"
# shellcheck source=lib/repos.sh
source "$MIGRATE_DIR/lib/repos.sh"
# shellcheck source=lib/upgrade.sh
source "$MIGRATE_DIR/lib/upgrade.sh"
# shellcheck source=lib/kernel.sh
source "$MIGRATE_DIR/lib/kernel.sh"
# shellcheck source=lib/settings.sh
source "$MIGRATE_DIR/lib/settings.sh"
# shellcheck source=lib/verify-uki.sh
source "$MIGRATE_DIR/lib/verify-uki.sh"
# shellcheck source=lib/post-reboot-verify.sh
source "$MIGRATE_DIR/lib/post-reboot-verify.sh"
# shellcheck source=lib/cleanup.sh
source "$MIGRATE_DIR/lib/cleanup.sh"

# _sigint_handler
# Trap target for SIGINT. Prints a recovery hint pointing the operator at
# --resume and rollback.sh, then exits 130 (the conventional Ctrl-C code).
# Metis R11: a Ctrl-C mid-pacman must leave a discoverable trail.
_sigint_handler() {
  log_err ""
  log_err "Migration interrupted by Ctrl-C."
  log_err "  To resume from a specific phase: ./migrate.sh --resume PHASE"
  log_err "    (phases: preflight repos kernel settings verify)"
  log_err "  To undo changes: ./rollback.sh --list"
  exit 130
}

# Register SIGINT trap BEFORE any argument parsing or phase execution
# so a Ctrl-C during the earliest setup still surfaces the recovery hint.
trap '_sigint_handler' INT

# usage
# --help target. Heredoc is quoted so $ expansion doesn't fire.
usage() {
  cat <<'EOF'
Usage: ./migrate.sh [OPTIONS]

Layer CachyOS optimizations onto your Omarchy installation.

Options:
  --dry-run          Show what would happen without making changes
  --help             Show this help message
  --resume PHASE     Resume from a specific phase (preflight|repos|kernel|settings|verify)
  --version          Show version
  --verify           Run post-reboot verification only (Tollgate 3)

Phases (in order): preflight → repos → kernel → settings → verify

EOF
}

# _should_run_phase PHASE RESUME_FROM
# Decide whether PHASE should execute given the user's --resume choice.
# Returns 0 to run, non-zero to skip. With no --resume, every phase runs.
# Unknown resume values abort with a clear error (and never silently
# skip phases).
_should_run_phase() {
  local phase="$1" resume="$2"
  [[ -z "$resume" ]] && return 0  # No --resume: run all phases
  case "$resume" in
    preflight) return 0 ;;  # Resume from start: run everything downstream
    backup)    [[ "$phase" == "backup" ]] && return 0; return 1 ;;
    repos)     [[ "$phase" =~ ^(repos|kernel|settings|backup)$ ]] && return 0; return 1 ;;
    kernel)    [[ "$phase" =~ ^(kernel|settings|backup)$ ]] && return 0; return 1 ;;
    settings)  [[ "$phase" == "settings" ]] && return 0; return 1 ;;
    verify)    return 1 ;;  # --resume verify means only verify; phases already done
    *)
      log_err "Unknown phase '$resume'. Valid phases: preflight repos kernel settings verify"
      exit 1
      ;;
  esac
}

# install_pacman_hook
# Install /etc/pacman.d/hooks/zz-cachyos-conf-restore.hook + its helper
# script under /usr/local/lib/cachyos-on-omarchy/. Metis R6: this is the
# discoverable mechanism that re-inserts CachyOS repo blocks after
# omarchy-update overwrites pacman.conf. pacman-hook-restore.sh sources
# const.sh, log.sh, detect-cpu.sh, and pacman-conf-restore.sh from its
# own directory, so all four dependency files must be installed alongside.
install_pacman_hook() {
  local hook_dir
  hook_dir="$(dirname "$HOOK_DEST")"
  local helper_dir
  helper_dir="$(dirname "$HOOK_HELPER_DEST")"

  if [[ -f "$HOOK_DEST" ]]; then
    log_ok "Pacman hook already installed: $HOOK_DEST"
    return 0
  fi

  log_dry "sudo mkdir -p '$helper_dir'"
  log_dry "sudo cp '$MIGRATE_DIR/lib/pacman-hook-restore.sh' '$HOOK_HELPER_DEST'"
  log_dry "sudo chmod 755 '$HOOK_HELPER_DEST'"
  local dep
  for dep in const.sh log.sh detect-cpu.sh pacman-conf-restore.sh; do
    log_dry "sudo cp '$MIGRATE_DIR/lib/$dep' '$helper_dir/$dep'"
    log_dry "sudo chmod 644 '$helper_dir/$dep'"
  done
  log_dry "sudo mkdir -p '$hook_dir'"
  log_dry "sudo cp '$MIGRATE_DIR/hooks/zz-cachyos-conf-restore.hook' '$HOOK_DEST'"
  log_ok "Pacman hook installed: $HOOK_DEST"
}

# install_omarchy_hook
# Install ~/.config/omarchy/hooks/pre-refresh-pacman.d/01-cachyos-repos-restore.sh.
# Metis R6/R14: omarchy-refresh-pacman does a raw `cp` of pacman.conf
# (which the Alpm Type=Path hook does NOT catch) and reinstalls
# archlinux-keyring (which can leave CachyOS keys untrusted). This hook
# fires between those steps and the subsequent `pacman -Syyuu`,
# re-trusting CachyOS keys and re-injecting the repo blocks first.
install_omarchy_hook() {
  if [[ -f "$PRE_REFRESH_HOOK_DEST" ]]; then
    log_ok "Omarchy pre-refresh hook already installed: $PRE_REFRESH_HOOK_DEST"
    return 0
  fi
  log_dry "mkdir -p '$PRE_REFRESH_HOOK_DIR'"
  log_dry "cp '$MIGRATE_DIR/$PRE_REFRESH_HOOK_SRC' '$PRE_REFRESH_HOOK_DEST'"
  log_dry "chmod 755 '$PRE_REFRESH_HOOK_DEST'"
  log_ok "Omarchy pre-refresh hook installed: $PRE_REFRESH_HOOK_DEST"
}

# ----- Argument parsing -------------------------------------------------
DRY_RUN=0
RESUME_FROM=""
CMD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --help)      usage; exit 0 ;;
    --version)   echo "cachyos-on-omarchy ${SCRIPT_VERSION}"; exit 0 ;;
    --verify)    CMD="verify" ;;
    --resume)
      shift
      [[ -z "${1:-}" ]] && { log_err "--resume requires a PHASE argument"; exit 1; }
      RESUME_FROM="$1"
      ;;
    *)
      log_err "Unknown option: $1"
      log_err "Run './migrate.sh --help' for usage."
      exit 1
      ;;
  esac
  shift
done

# Make DRY_RUN visible to every sourced library that reads it via env.
export DRY_RUN

# ----- --verify mode (Tollgate 3 only) ---------------------------------
if [[ "$CMD" == "verify" ]]; then
  log_step "Running post-reboot verification (Tollgate 3)"
  run_preflight
  run_post_reboot_verify
  exit $?
fi

# ----- Phase 1: Pre-flight checks (Tollgate 1) -------------------------
# Always run preflight, even with --resume - it's idempotent and free
# and surfaces any host changes since the last attempt.
log_step "Phase 1: Pre-flight checks (Tollgate 1)"
run_preflight

# ----- Phase 2: Backup -------------------------------------------------
if _should_run_phase "backup" "$RESUME_FROM"; then
  log_step "Phase 2: Creating pre-migration backup"
  # create_backup contract: stdout is mixed (log_step/log_ok/log_dry +
  # final path line). tee /dev/stderr keeps the log output visible while
  # tail -1 plucks only the path line for BACKUP_PATH.
  BACKUP_PATH=$(create_backup | tee /dev/stderr | tail -1)
fi

# ----- Phase 3: Repos --------------------------------------------------
if _should_run_phase "repos" "$RESUME_FROM"; then
  log_step "Phase 3: Installing CachyOS repositories"
  install_cachyos_repos
fi

# ----- Phase 3.5: Drift-aware system upgrade ---------------------------
# After repos are added, upgrade every Arch-supplied package to its
# CachyOS-optimized counterpart. Detects lib32 strict-pin drift and
# resolves via cascade remove → pacman -Syu → reinstall. See lib/upgrade.sh
# and docs/gotchas.md R15 for the full algorithm.
if _should_run_phase "repos" "$RESUME_FROM"; then
  run_system_upgrade "${BACKUP_PATH:-}"
fi

# ----- Phase 4: Kernel -------------------------------------------------
if _should_run_phase "kernel" "$RESUME_FROM"; then
  log_step "Phase 4: Installing CachyOS kernel (linux-cachyos-bore)"
  install_cachyos_kernel
  # Metis R13: diff mkinitcpio.conf after kernel install so any
  # user customisations the package overwrote are surfaced before reboot.
  # Skipped in DRY_RUN: Phase 2 never wrote the tarball, so the diff
  # would print a misleading red error against state that was never
  # supposed to exist.
  if [[ "$DRY_RUN" != "1" ]] && [[ -n "${BACKUP_PATH:-}" ]]; then
    diff_mkinitcpio_after_migration "$BACKUP_PATH" || true
  fi
fi

# ----- Phase 5: Settings -----------------------------------------------
if _should_run_phase "settings" "$RESUME_FROM"; then
  log_step "Phase 5: Installing CachyOS settings (cachyos-settings)"
  install_cachyos_settings
fi

# ----- Phase 6: Tollgate 2 - UKI/Limine verification -------------------
# ALWAYS runs. Never skipped. Even with --resume, the kernel may have
# regenerated and Limine may have drifted, so this is the last guard
# before the user reboots into a potentially broken system.
log_step "Phase 6: UKI verification (Tollgate 2)"
verify_uki_safety linux-cachyos-bore || {
  log_err "Tollgate 2 FAILED. Migration aborted before reboot."
  log_err "Recovery: Fix the issue above, then re-run: ./migrate.sh --resume verify"
  exit 1
}

# ----- Phase 7: Install pacman.conf restore hooks ----------------------
log_step "Phase 7: Installing pacman.conf restore hooks"
install_pacman_hook
install_omarchy_hook

# ----- Phase 8: Final summary + optional cleanup ----------------------
print_migration_complete_banner
offer_default_kernel_removal
log_ok "After reboot, run: ./migrate.sh --verify"
printf "\n"

# ----- Final reboot prompt --------------------------------------------
confirm "Reboot now into linux-cachyos-bore?" && {
  log_step "Rebooting..."
  if command -v omarchy-system-reboot >/dev/null 2>&1; then
    log_dry "omarchy-system-reboot"
  else
    log_dry "sudo systemctl reboot"
  fi
}
