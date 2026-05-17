#!/bin/bash
set -euo pipefail

# CachyOS pacman.conf restore helper
# Idempotent: re-insert CachyOS repo blocks + Architecture fix into /etc/pacman.conf if missing.
# Run AFTER any tool that overwrites pacman.conf (e.g., omarchy-update).
# NEVER invokes upstream Omarchy scripts.

# Only source dependencies if not already sourced (for hook wrapper)
if [[ -z "${_PACMAN_RESTORE_SOURCED:-}" ]]; then
  # Capture environment override before sourcing const.sh (which declares PACMAN_CONF readonly)
  _PACMAN_CONF="${PACMAN_CONF:-}"

  # Source dependencies
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=lib/const.sh
  source "$SCRIPT_DIR/const.sh"
  # shellcheck source=lib/log.sh
  source "$SCRIPT_DIR/log.sh"
  # shellcheck source=lib/detect-cpu.sh
  source "$SCRIPT_DIR/detect-cpu.sh"

  # Use const.sh value if no override was provided
  if [[ -z "$_PACMAN_CONF" ]]; then
    _PACMAN_CONF="${PACMAN_CONF}"
  fi

  _PACMAN_RESTORE_SOURCED=1
fi

# Handle DRY_RUN flag
DRY_RUN="${DRY_RUN:-0}"
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

if [[ "$DRY_RUN" == "1" ]]; then
  log_warn "DRY RUN: no modifications will be made"
fi

# Fix Architecture if needed (only on v3-capable systems)
if ! grep -q 'x86_64_v3' "$_PACMAN_CONF" 2>/dev/null; then
  if is_v3_capable; then
    log_step "Fixing Architecture line for v3 capability"
    if [[ "$DRY_RUN" == "0" ]]; then
      sed -i 's/^Architecture = auto$/Architecture = auto x86_64 x86_64_v3/' "$_PACMAN_CONF"
      log_ok "Architecture line updated"
    else
      log_warn "DRY RUN: would update Architecture line"
    fi
  fi
fi

# Check if cachyos blocks already present
if grep -q '^\[cachyos' "$_PACMAN_CONF" 2>/dev/null; then
  log_ok "cachyos repo blocks already present — no action needed"
  exit 0
fi

# Verify mirrorlist files exist
for ml in cachyos-mirrorlist cachyos-v3-mirrorlist; do
  if [[ ! -s "/etc/pacman.d/$ml" ]]; then
    log_err "/etc/pacman.d/$ml missing — install cachyos-mirrorlist packages first"
    exit 2
  fi
done

# Find anchor repo block
ANCHOR=$(awk '/^\[/ && !/options/ {print $0; exit}' "$_PACMAN_CONF")
if [[ -z "$ANCHOR" ]]; then
  log_err "no repo block found in $_PACMAN_CONF"
  exit 3
fi

log_step "Inserting cachyos repo blocks above: $ANCHOR"

if [[ "$DRY_RUN" == "1" ]]; then
  log_warn "DRY RUN: would insert 4 cachyos blocks"
  exit 0
fi

# Create backup
BAK="${_PACMAN_CONF}.bak.cachyos-restore.$(date +%Y%m%d-%H%M%S)"
cp "$_PACMAN_CONF" "$BAK"
log_ok "Backup created: $BAK"

# Insert repo blocks
ANCHOR_ESCAPED=$(echo "$ANCHOR" | sed -e 's/[][\/.*^$]/\\&/g')
sed -i "/^${ANCHOR_ESCAPED}/i\\
[cachyos-v3]\\
Include = /etc/pacman.d/cachyos-v3-mirrorlist\\
\\
[cachyos-core-v3]\\
Include = /etc/pacman.d/cachyos-v3-mirrorlist\\
\\
[cachyos-extra-v3]\\
Include = /etc/pacman.d/cachyos-v3-mirrorlist\\
\\
[cachyos]\\
Include = /etc/pacman.d/cachyos-mirrorlist\\
" "$_PACMAN_CONF"

# Verify insertion
if grep -q '^\[cachyos-v3\]' "$_PACMAN_CONF"; then
  log_ok "cachyos repo blocks restored successfully"
  exit 0
else
  log_err "failed to insert cachyos blocks — restoring backup"
  cp "$BAK" "$_PACMAN_CONF"
  exit 4
fi
