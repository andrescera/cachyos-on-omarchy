#!/bin/bash
set -euo pipefail

# Pacman hook wrapper for pacman.conf restoration
# Called by /etc/pacman.d/hooks/zz-cachyos-conf-restore.hook after pacman transactions

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies once
source "$SCRIPT_DIR/const.sh"
source "$SCRIPT_DIR/log.sh"
source "$SCRIPT_DIR/detect-cpu.sh"

# Mark as sourced to prevent re-sourcing in pacman-conf-restore.sh
_PACMAN_RESTORE_SOURCED=1
_PACMAN_CONF="${PACMAN_CONF}"

# Source the restore script (will skip dependency sourcing due to guard)
source "$SCRIPT_DIR/pacman-conf-restore.sh"
