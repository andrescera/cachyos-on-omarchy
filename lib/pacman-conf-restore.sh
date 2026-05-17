#!/bin/bash
set -euo pipefail

# CachyOS pacman.conf restore helper
# Idempotent: re-insert CachyOS repo blocks + Architecture fix + IgnorePkg
# into /etc/pacman.conf if any are missing.
# Run AFTER any tool that overwrites pacman.conf (e.g., omarchy-update).
# Metis R6: covers all three elements that omarchy-update wipes.
# NEVER invokes upstream Omarchy scripts.

# Only source dependencies if not already sourced (for hook wrapper)
if [[ -z "${_PACMAN_RESTORE_SOURCED:-}" ]]; then
  _PACMAN_CONF="${PACMAN_CONF:-}"
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=lib/const.sh
  source "$SCRIPT_DIR/const.sh"
  # shellcheck source=lib/log.sh
  source "$SCRIPT_DIR/log.sh"
  # shellcheck source=lib/detect-cpu.sh
  source "$SCRIPT_DIR/detect-cpu.sh"
  if [[ -z "$_PACMAN_CONF" ]]; then
    _PACMAN_CONF="${PACMAN_CONF}"
  fi
  _PACMAN_RESTORE_SOURCED=1
fi

DRY_RUN="${DRY_RUN:-0}"
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1
[[ "$DRY_RUN" == "1" ]] && log_warn "DRY RUN: no modifications will be made"

_any_change=0  # track if we made any change

# ── 1. Architecture line ──────────────────────────────────────────────────────
if ! grep -q 'x86_64_v3' "$_PACMAN_CONF" 2>/dev/null; then
  if is_v3_capable; then
    log_step "Fixing Architecture line for v3 capability"
    if [[ "$DRY_RUN" == "0" ]]; then
      sed -i 's/^Architecture = auto$/Architecture = auto x86_64 x86_64_v3/' "$_PACMAN_CONF"
      log_ok "Architecture line updated"
    else
      log_warn "DRY RUN: would update Architecture = auto x86_64 x86_64_v3"
    fi
    _any_change=1
  fi
fi

# ── 2. IgnorePkg entries ──────────────────────────────────────────────────────
# Metis R6: omarchy-update also wipes IgnorePkg; restore entries that protect
# Omarchy-specific packages (walker, elephant, archlinux-keyring, etc.) from
# being overwritten by incompatible Arch/CachyOS versions.
_restore_ignore_pkg() {
  local current_line entry e found
  local existing_arr=() final_arr=()

  current_line=$(grep -E '^IgnorePkg[[:space:]]*=' "$_PACMAN_CONF" 2>/dev/null || true)

  if [[ -n "$current_line" ]]; then
    local stripped="${current_line#*=}"
    stripped="${stripped# }"
    # shellcheck disable=SC2206
    existing_arr=( $stripped )
    final_arr=( "${existing_arr[@]}" )

    for entry in "${IGNORE_PKGS[@]}"; do
      found=0
      for e in "${existing_arr[@]}"; do
        [[ "$e" == "$entry" ]] && found=1 && break
      done
      [[ "$found" -eq 0 ]] && final_arr+=( "$entry" )
    done

    if [[ "${#final_arr[@]}" -eq "${#existing_arr[@]}" ]]; then
      log_ok "IgnorePkg already contains all required entries — no change needed"
      return 0
    fi

    local merged="IgnorePkg = ${final_arr[*]}"
    if [[ "$DRY_RUN" == "1" ]]; then
      log_warn "DRY RUN: would update IgnorePkg: $merged"
    else
      sed -i "s|^IgnorePkg[[:space:]]*=.*|${merged}|" "$_PACMAN_CONF"
      log_ok "IgnorePkg updated: $merged"
    fi
  else
    local merged="IgnorePkg = ${IGNORE_PKGS[*]}"
    log_step "Adding missing IgnorePkg line"
    if [[ "$DRY_RUN" == "1" ]]; then
      log_warn "DRY RUN: would add under [options]: $merged"
    else
      sed -i "/^\[options\]/a ${merged}" "$_PACMAN_CONF"
      log_ok "IgnorePkg line added: $merged"
    fi
  fi
  _any_change=1
}
_restore_ignore_pkg

# ── 3. CachyOS repo blocks ────────────────────────────────────────────────────
if grep -q '^\[cachyos' "$_PACMAN_CONF" 2>/dev/null; then
  log_ok "CachyOS repo blocks already present"
else
  # Verify mirrorlist files exist before attempting insertion
  for ml in cachyos-mirrorlist cachyos-v3-mirrorlist; do
    if [[ ! -s "/etc/pacman.d/$ml" ]]; then
      log_err "/etc/pacman.d/$ml missing — install cachyos-mirrorlist packages first"
      exit 2
    fi
  done

  ANCHOR=$(awk '/^\[/ && !/options/ {print $0; exit}' "$_PACMAN_CONF")
  if [[ -z "$ANCHOR" ]]; then
    log_err "no repo section found in $_PACMAN_CONF — cannot insert CachyOS blocks"
    exit 3
  fi

  log_step "Inserting CachyOS repo blocks above: $ANCHOR"

  if [[ "$DRY_RUN" == "1" ]]; then
    log_warn "DRY RUN: would insert 4 CachyOS blocks above $ANCHOR"
  else
    BAK="${_PACMAN_CONF}.bak.cachyos-restore.$(date +%Y%m%d-%H%M%S)"
    cp "$_PACMAN_CONF" "$BAK"
    log_ok "Backup created: $BAK"

    ANCHOR_ESCAPED=$(printf '%s\n' "$ANCHOR" | sed -e 's/[][\/.*^$]/\\&/g')
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

    if grep -q '^\[cachyos-v3\]' "$_PACMAN_CONF"; then
      log_ok "CachyOS repo blocks restored successfully"
    else
      log_err "insertion failed — restoring backup"
      cp "$BAK" "$_PACMAN_CONF"
      exit 4
    fi
  fi
  _any_change=1
fi

# ── Summary ───────────────────────────────────────────────────────────────────
if [[ "$_any_change" -eq 0 ]]; then
  log_ok "pacman.conf is fully reconciled — no changes needed"
fi
