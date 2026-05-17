#!/bin/bash
set -euo pipefail

# System detection utilities for cachyos-on-omarchy.
# Detects filesystem, bootloader, UKI mode, Omarchy version, and LUKS encryption.
# All functions are READ-ONLY and do not modify system state.

# detect_root_fs
# Detect the filesystem type of the root mount.
# Echoes one of: btrfs | ext4 | xfs | unknown
# When stdin is a regular file (fixture mode), reads the FS name from it;
# otherwise runs `findmnt -n -o FSTYPE /`.
# Only btrfs and ext4 are "supported" by this script; xfs and unknown are
# valid outputs but the caller must abort on them.
detect_root_fs() {
  local fs=""

  if [[ -f /dev/stdin ]]; then
    read -r fs || true
  else
    fs=$(findmnt -n -o FSTYPE / 2>/dev/null || true)
  fi

  case "${fs:-}" in
    btrfs|ext4|xfs) printf '%s\n' "$fs" ;;
    *) printf 'unknown\n' ;;
  esac
}

# detect_bootloader
# Detect which bootloader is installed. Checks in order: limine, grub,
# systemd-boot, then unknown. Echoes one of: limine | grub | systemd-boot | unknown
# This script REQUIRES limine; anything else causes the caller to abort.
detect_bootloader() {
  if command -v limine >/dev/null 2>&1; then
    printf 'limine\n'
    return 0
  fi

  if pacman -Qq grub >/dev/null 2>&1; then
    printf 'grub\n'
    return 0
  fi

  if [[ -d /boot/EFI/systemd ]] || bootctl status >/dev/null 2>&1; then
    printf 'systemd-boot\n'
    return 0
  fi

  printf 'unknown\n'
}

# detect_uki_mode
# Returns exit 0 if Limine UKI mode is enabled (ENABLE_UKI=yes), exit 1 otherwise.
# Honors the LIMINE_DEFAULT env var for fixture testing
# (default: /etc/default/limine).
detect_uki_mode() {
  local config="${LIMINE_DEFAULT:-/etc/default/limine}"

  [[ -r "$config" ]] || return 1
  grep -q '^ENABLE_UKI=yes' "$config"
}

# detect_omarchy_version
# Echoes the installed Omarchy version string with any leading 'v' stripped.
# Sources, in order: $HOME/.local/share/omarchy/VERSION (Omarchy 3.0+),
# then `git -C $HOME/.local/share/omarchy describe --tags --always`.
# Echoes 'unknown' if neither source yields a value.
detect_omarchy_version() {
  local version=""
  local version_file="$HOME/.local/share/omarchy/VERSION"
  local repo="$HOME/.local/share/omarchy"

  if [[ -r "$version_file" ]]; then
    version=$(cat "$version_file" 2>/dev/null || true)
  fi

  if [[ -z "$version" ]] && [[ -d "$repo/.git" ]]; then
    version=$(git -C "$repo" describe --tags --always 2>/dev/null || true)
  fi

  if [[ -z "$version" ]]; then
    printf 'unknown\n'
    return 0
  fi

  printf '%s\n' "${version#v}"
}

# version_ge ACTUAL MIN
# Semantic version comparison. Returns exit 0 if ACTUAL >= MIN, exit 1 otherwise.
# Uses `sort -V` so the comparison is numeric (10.0 > 9.99), not lexical.
# Correctly handles '3.0.0 >= 3.0' (true) and equal versions.
version_ge() {
  local actual="$1"
  local min="$2"
  local smallest

  smallest=$(printf '%s\n%s\n' "$actual" "$min" | sort -V | head -n 1)
  [[ "$smallest" == "$min" ]]
}

# detect_luks
# Returns exit 0 if LUKS encryption (type 'crypt') is present anywhere in the
# block storage stack, exit 1 otherwise.
detect_luks() {
  lsblk -o TYPE 2>/dev/null | grep -q 'crypt'
}
