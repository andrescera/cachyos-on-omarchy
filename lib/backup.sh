#!/bin/bash
set -euo pipefail

# CachyOS on Omarchy - Pre-Migration Backup Library
#
# Filesystem-aware backup strategy. Every sudo state-change is wrapped via
# lib/log.sh's log_dry, so DRY_RUN=1 produces NO filesystem changes.
#
# The caller MUST source these libraries BEFORE sourcing this file:
#   lib/const.sh         (BACKUP_BASE, PACMAN_CONF, ...)
#   lib/log.sh           (log_step, log_ok, log_warn, log_err, log_dry)
#   lib/detect-system.sh (detect_root_fs, detect_luks)
#
# Public functions:
#   create_backup
#       Create timestamped backup dir under $BACKUP_BASE. Tarballs core
#       system config (NOT $HOME, NOT /boot, NOT UKI .efi files).
#       Honours DRY_RUN. Final stdout line is the backup dir path.
#
#   verify_backup PATH
#       Verify tarball exists, SHA256 matches manifest, and etc/pacman.conf
#       is present in the tarball listing. Returns 0 on success; non-zero
#       with log_err on first failure.
#
#   restore_backup_pacman_conf PATH
#       Restore only /etc/pacman.conf from PATH/backup.tar.zst. Used by
#       rollback scenarios 3 and 4. Honours DRY_RUN.
#
#   diff_mkinitcpio_after_migration BACKUP_PATH
#       Metis R13 mitigation. Diff pre-migration /etc/mkinitcpio.conf
#       (extracted from backup tarball) against the current file. Writes
#       the unified diff to BACKUP_PATH/mkinitcpio.diff. If non-empty,
#       surfaces a warning via log_warn and prints the diff to stdout.
#
# Notes:
#   - Tarball uses zstd (.tar.zst). GNU tar 1.35 errors on '-I zstd -czf'
#     ("Conflicting compression options"); the working form is
#     '-I zstd -cf' — '-I' supplies the compressor, '-z' would request gzip.
#   - /boot/EFI/Linux/*.efi files (100-300 MB each) are NEVER tarballed;
#     a directory listing is saved to uki-listing.txt instead.
#   - All sidecar writes use 'cmd | sudo tee FILE >/dev/null' to avoid
#     subshell quoting bugs with 'sudo bash -c ... > "$VAR/..."'.

# _backup_paths_str
# Print a space-prefixed list of paths to include in the tarball. The first
# five paths are mandatory; /etc/cmdline.d is appended only if present.
_backup_paths_str() {
  local s=" /etc/pacman.conf /etc/pacman.d /etc/mkinitcpio.conf /etc/default/limine /boot/limine.conf"
  [[ -e /etc/cmdline.d ]] && s+=" /etc/cmdline.d"
  printf '%s' "$s"
}

# _snapper_available
# Return 0 if snapper is installed. Prefers omarchy-cmd-present (matches
# project convention) with a command -v fallback.
_snapper_available() {
  if command -v omarchy-cmd-present >/dev/null 2>&1; then
    omarchy-cmd-present snapper
  else
    command -v snapper >/dev/null 2>&1
  fi
}

# create_backup
# See file header for full contract.
create_backup() {
  local ts bpath paths fs size
  ts=$(date +%Y%m%d-%H%M%S)
  bpath="${BACKUP_BASE}/migration-${ts}"
  paths=$(_backup_paths_str)

  log_step "Creating pre-migration backup at ${bpath}"

  # Create backup directory (root-owned).
  log_dry "sudo mkdir -p ${bpath}"

  # Tarball core system config. See file header note re: -I zstd vs -z.
  log_dry "sudo tar -I zstd -cf ${bpath}/backup.tar.zst${paths} 2>/dev/null"

  # Metadata sidecar files. The \$1 escape inside the double-quoted string
  # parses to literal $1 in the command passed to eval; awk receives the
  # script {print $1} via the embedded single quotes.
  log_dry "pacman -Qqe | sudo tee ${bpath}/pkglist.txt >/dev/null"
  log_dry "pacman -Qqm | sudo tee ${bpath}/aurlist.txt >/dev/null"
  log_dry "uname -a | sudo tee ${bpath}/uname.txt >/dev/null"

  # UKI listing only — DO NOT tarball UKIs (each is 100-300 MB).
  if [[ -d /boot/EFI/Linux ]]; then
    log_dry "ls -la /boot/EFI/Linux/ | sudo tee ${bpath}/uki-listing.txt >/dev/null"
  fi

  # SHA256 manifest of the tarball.
  log_dry "sha256sum ${bpath}/backup.tar.zst | awk '{print \$1}' | sudo tee ${bpath}/manifest.sha256 >/dev/null"

  # Filesystem-specific extras.
  fs=$(detect_root_fs)
  case "$fs" in
    btrfs)
      if _snapper_available; then
        log_dry "sudo snapper -c root create -d 'pre-cachyos-migration'"
        log_ok "btrfs: snapper snapshot planned"
      else
        log_warn "btrfs detected but snapper not present; tarball-only backup"
      fi
      ;;
    ext4)
      log_ok "ext4: tarball-only backup (no snapshot mechanism)"
      ;;
    *)
      log_warn "Unsupported root filesystem '${fs}'; tarball-only backup"
      ;;
  esac

  # Report summary. In DRY_RUN there is no real dir to du.
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_ok "DRY-RUN: backup plan complete (no state changes)"
  else
    size=$(sudo du -sh "$bpath" 2>/dev/null | awk '{print $1}')
    log_ok "Backup created at ${bpath} (${size:-unknown size})"
  fi

  # Last stdout line is the backup dir path. Callers parse this.
  printf '%s\n' "$bpath"
}

# verify_backup PATH
# See file header for full contract.
verify_backup() {
  local path tarball manifest expected
  path="${1:-}"
  if [[ -z "$path" ]]; then
    log_err "verify_backup: PATH argument required"
    return 2
  fi

  tarball="${path}/backup.tar.zst"
  manifest="${path}/manifest.sha256"

  if [[ ! -f "$tarball" ]]; then
    log_err "verify_backup: tarball missing: ${tarball}"
    return 1
  fi
  if [[ ! -f "$manifest" ]]; then
    log_err "verify_backup: manifest missing: ${manifest}"
    return 1
  fi

  # sha256sum -c reads "<hash><space><space><filename>" lines from stdin.
  expected=$(cat "$manifest")
  if ! printf '%s  %s\n' "$expected" "$tarball" | sha256sum -c - >/dev/null 2>&1; then
    log_err "verify_backup: sha256 mismatch for ${tarball}"
    return 1
  fi

  if ! tar -I zstd -tf "$tarball" 2>/dev/null | grep -q 'etc/pacman.conf'; then
    log_err "verify_backup: tarball missing etc/pacman.conf"
    return 1
  fi

  log_ok "Backup verified: ${path}"
  return 0
}

# restore_backup_pacman_conf PATH
# See file header for full contract.
restore_backup_pacman_conf() {
  local path tarball
  path="${1:-}"
  if [[ -z "$path" ]]; then
    log_err "restore_backup_pacman_conf: PATH argument required"
    return 2
  fi

  tarball="${path}/backup.tar.zst"
  if [[ ! -f "$tarball" ]]; then
    log_err "restore_backup_pacman_conf: tarball missing: ${tarball}"
    return 1
  fi

  log_step "Restoring /etc/pacman.conf from ${tarball}"
  log_dry "sudo tar -I zstd -xf ${tarball} -C / etc/pacman.conf 2>/dev/null"
  log_ok "Restored /etc/pacman.conf from backup"
  return 0
}

# diff_mkinitcpio_after_migration BACKUP_PATH
# See file header for full contract.
diff_mkinitcpio_after_migration() {
  local path tarball diff_out pre d
  path="${1:-}"
  if [[ -z "$path" ]]; then
    log_err "diff_mkinitcpio_after_migration: BACKUP_PATH argument required"
    return 2
  fi

  tarball="${path}/backup.tar.zst"
  diff_out="${path}/mkinitcpio.diff"

  if [[ ! -f "$tarball" ]]; then
    log_err "diff_mkinitcpio_after_migration: tarball missing: ${tarball}"
    return 1
  fi

  pre=$(mktemp -t mkinitcpio.pre.XXXXXX) || {
    log_err "diff_mkinitcpio_after_migration: mktemp failed"
    return 1
  }

  # -xO extracts a single member to stdout; -I zstd reads .tar.zst.
  if ! tar -I zstd -xOf "$tarball" etc/mkinitcpio.conf >"$pre" 2>/dev/null; then
    rm -f "$pre"
    log_err "diff_mkinitcpio_after_migration: failed to extract etc/mkinitcpio.conf"
    return 1
  fi

  # diff exits 1 when files differ; guard with || true so set -e tolerates it.
  d=$(diff -u "$pre" /etc/mkinitcpio.conf 2>/dev/null || true)
  rm -f "$pre"

  # Persist the diff to the backup dir (root-owned), honouring DRY_RUN.
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf 'DRY-RUN: would write %d bytes of diff to %s\n' "${#d}" "$diff_out"
  else
    printf '%s\n' "$d" | sudo tee "$diff_out" >/dev/null
  fi

  if [[ -n "$d" ]]; then
    log_warn "mkinitcpio.conf changed after migration. Diff saved to ${diff_out}"
    printf '%s\n' "$d"
  else
    log_ok "mkinitcpio.conf unchanged since pre-migration backup"
  fi

  return 0
}
