#!/bin/bash
set -euo pipefail

# Logging utilities and gum/DRY_RUN wrappers for cachyos-on-omarchy
# Supports DRY_RUN mode and NO_COLOR environment variable

# Default DRY_RUN to 0 (execute commands)
DRY_RUN="${DRY_RUN:-0}"

# Detect NO_COLOR support
_NO_COLOR="${NO_COLOR:-}"

# Color codes (empty if NO_COLOR is set)
if [[ -z "$_NO_COLOR" ]]; then
  _C_RESET='\033[0m'
  _C_BOLD='\033[1m'
  _C_BLUE='\033[1;34m'
  _C_GREEN='\033[0;32m'
  _C_YELLOW='\033[0;33m'
  _C_RED='\033[0;31m'
else
  _C_RESET=''
  _C_BOLD=''
  _C_BLUE=''
  _C_GREEN=''
  _C_YELLOW=''
  _C_RED=''
fi

# log_step MSG
# Print a bold colored step banner (blue/cyan)
log_step() {
  local msg="$1"
  printf "\n${_C_BLUE}==> %s${_C_RESET}\n" "$msg"
}

# log_ok MSG
# Print green ✓ prefix
log_ok() {
  local msg="$1"
  printf "${_C_GREEN}✓ %s${_C_RESET}\n" "$msg"
}

# log_warn MSG
# Print yellow ⚠ prefix to stderr
log_warn() {
  local msg="$1"
  printf "${_C_YELLOW}⚠ %s${_C_RESET}\n" "$msg" >&2
}

# log_err MSG
# Print red ✗ prefix to stderr
log_err() {
  local msg="$1"
  printf "${_C_RED}✗ %s${_C_RESET}\n" "$msg" >&2
}

# log_dry CMD
# If DRY_RUN=1: print "DRY-RUN: CMD" and do NOT execute
# If DRY_RUN=0: execute the command via eval
log_dry() {
  local cmd="$1"
  
  if [[ "$DRY_RUN" == "1" ]]; then
    printf "DRY-RUN: %s\n" "$cmd"
    return 0
  else
    eval "$cmd"
  fi
}

# confirm MSG
# Wraps gum confirm. If DRY_RUN=1: auto-approve and print message.
# If DRY_RUN=0: run gum confirm interactively.
confirm() {
  local msg="$1"
  
  if [[ "$DRY_RUN" == "1" ]]; then
    printf "DRY-RUN: confirm: %s\n" "$msg"
    return 0
  else
    gum confirm "$msg"
  fi
}

# spin MSG CMD_ARGS
# Wraps gum spin. If DRY_RUN=1: just log_dry the command.
# If DRY_RUN=0: run gum spin with the command.
spin() {
  local msg="$1"
  local cmd="$2"
  
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "$cmd"
  else
    gum spin --title "$msg" -- bash -c "$cmd"
  fi
}

# require_cmd CMD
# Check if CMD is available. Uses omarchy-cmd-present if available,
# otherwise falls back to command -v. Returns 1 on failure.
require_cmd() {
  local cmd="$1"
  
  if command -v omarchy-cmd-present >/dev/null 2>&1; then
    if ! omarchy-cmd-present "$cmd"; then
      log_err "Required command '$cmd' not found"
      return 1
    fi
  else
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_err "Required command '$cmd' not found"
      return 1
    fi
  fi
  
  return 0
}

# require_pkg PKG
# Check if PKG is installed. Uses omarchy-pkg-present if available,
# otherwise falls back to pacman -Qq. Returns 1 on failure.
require_pkg() {
  local pkg="$1"
  
  if command -v omarchy-pkg-present >/dev/null 2>&1; then
    if ! omarchy-pkg-present "$pkg"; then
      log_err "Required package '$pkg' not installed"
      return 1
    fi
  else
    if ! pacman -Qq "$pkg" >/dev/null 2>&1; then
      log_err "Required package '$pkg' not installed"
      return 1
    fi
  fi
  
  return 0
}
