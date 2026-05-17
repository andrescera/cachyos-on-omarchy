#!/bin/bash
# shellcheck disable=SC2034  # Constants are sourced by other scripts; unused-in-isolation is expected
set -euo pipefail

# CachyOS on Omarchy - Constants
# Single source of truth for all constants used by lib/*.sh files

# Repository and signing
readonly CACHYOS_REPO_URL="https://mirror.cachyos.org/cachyos-repo.tar.xz"
readonly CACHYOS_KEY_FINGERPRINT="F3B607488DB35A47"

# Version requirements
readonly MIN_OMARCHY_VERSION="3.0"
readonly SCRIPT_VERSION="0.1.0"

# Backup and storage paths
readonly BACKUP_BASE="/var/backups/cachyos-on-omarchy"

# Boot and configuration paths
readonly BOOT_EFI_LINUX="/boot/EFI/Linux"
readonly LIMINE_CONF="/boot/limine.conf"
readonly PACMAN_CONF="/etc/pacman.conf"
readonly LIMINE_DEFAULT="/etc/default/limine"

# Pacman hook paths
readonly HOOK_DEST="/etc/pacman.d/hooks/zz-cachyos-conf-restore.hook"
readonly HOOK_HELPER_DEST="/usr/local/lib/cachyos-on-omarchy/pacman-hook-restore.sh"

# Omarchy hook paths
readonly PRE_REFRESH_HOOK_DIR="${HOME}/.config/omarchy/hooks/pre-refresh-pacman.d"
readonly PRE_REFRESH_HOOK_DEST="${HOME}/.config/omarchy/hooks/pre-refresh-pacman.d/01-cachyos-repos-restore.sh"
readonly PRE_REFRESH_HOOK_SRC="hooks/omarchy/pre-refresh-pacman.d/01-cachyos-repos-restore.sh"

# Package arrays
readonly CACHYOS_BASE_PKGS=(cachyos-keyring cachyos-mirrorlist cachyos-v3-mirrorlist cachyos-rate-mirrors)
readonly CACHYOS_KERNEL_PKGS=(linux-cachyos-bore linux-cachyos-bore-headers)
readonly CACHYOS_SETTINGS_PKGS=(cachyos-settings)

# Forbidden packages (must not be installed)
readonly FORBIDDEN_PKGS=(cachyos-fish-config cachyos-zsh-config cachyos-hyprland-settings tealdeer paru)

# Packages to ignore in pacman.conf (verified from this machine)
readonly IGNORE_PKGS=(walker walker-bin elephant elephant-files archlinux-keyring)
