#!/bin/bash
set -euo pipefail

# CachyOS on Omarchy - Phase 3.5: drift-aware system upgrade
#
# After Phase 3 adds CachyOS repos, the system has access to newer
# CachyOS-optimized package versions. A naive `pacman -Syu` often fails
# during the "drift window" — CachyOS bumps a package (e.g. expat 2.8.1)
# before Arch's [multilib] catches up, so lib32-<pkg> still pins the
# older version and blocks the upgrade.
#
# This module:
#   1. Detects drift by scanning installed lib32-* packages and comparing
#      each declared dep version against what CachyOS repos currently
#      offer.
#   2. If drift is detected:
#       a. Computes the cascade removal list via `pacman -Rpcs`
#       b. Splits the cascade into repo-installable vs AUR-only packages
#       c. Asks the user for explicit consent when AUR is involved
#          (AUR packages can't be auto-reinstalled later)
#       d. Saves the full list to $BACKUP_PATH/removed-for-upgrade.txt
#       e. Removes the cascade with `pacman -Rcns`
#       f. Runs `pacman -Syu` cleanly (no blocking deps)
#       g. Reinstalls every repo package; records failures
#       h. Reports reinstalled vs still-pending packages
#   3. If no drift is detected:
#       a. Runs a plain `pacman -Syu` with scoped `--overwrite` for known
#          cachyos-settings file-overlap paths.

# Re-source guard — the migrate.sh orchestrator sources this file once
# but defensive lib/*.sh re-sourcing is a project pattern.
if [[ -n "${_CACHYOS_UPGRADE_SH_SOURCED:-}" ]]; then
  return 0
fi
_CACHYOS_UPGRADE_SH_SOURCED=1

_UPGRADE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# const.sh declares `readonly` constants; guard against re-source clash.
# log.sh defines functions; guard via declare -F.
# shellcheck source=lib/const.sh
[[ -n "${MIN_OMARCHY_VERSION:-}" ]] || source "$_UPGRADE_DIR/const.sh"
# shellcheck source=lib/log.sh
declare -F log_step >/dev/null 2>&1 || source "$_UPGRADE_DIR/log.sh"

# CachyOS repos in priority order: v3 (x86_64-v3 optimized) first, then
# generic cachyos repo as fallback. Matches the order Phase 3 injects
# into /etc/pacman.conf.
readonly CACHYOS_REPOS_FOR_DRIFT=(cachyos-v3 cachyos-core-v3 cachyos-extra-v3 cachyos)

# Scoped --overwrite globs for cachyos-settings file overlap paths.
# Never use '*' — too broad. Each entry is a directory that the
# cachyos-settings package legitimately ships into and may collide
# with existing Omarchy/Arch defaults.
readonly UPGRADE_OVERWRITE_GLOBS=(
  '/usr/lib/sysctl.d/*'
  '/usr/lib/modprobe.d/*'
  '/usr/lib/systemd/*'
  '/usr/lib/udev/rules.d/*'
  '/etc/sysctl.d/*'
  '/etc/modprobe.d/*'
)

# detect_lib32_drift
# Populates globals DRIFT_LIB32_PKGS and DRIFT_DETAILS with the lib32-*
# packages whose strict version pin disagrees with the current CachyOS
# repo version of the same base package.
#
# Returns: 0 if drift detected, 1 if all lib32-* deps are satisfied.
detect_lib32_drift() {
  DRIFT_LIB32_PKGS=()
  DRIFT_DETAILS=()

  local lib32_pkg base required_ver cachyos_ver repo

  # pacman -Qq | grep '^lib32-' lists installed 32-bit packages
  # `|| true` so set -e tolerates the empty case (no lib32 packages at all)
  while IFS= read -r lib32_pkg; do
    [[ -z "$lib32_pkg" ]] && continue
    base="${lib32_pkg#lib32-}"

    # Parse the strict version pin from "Depends On" line.
    # Format: "Depends On      : expat=2.8.1  lib32-glibc"
    # We want the value after `<base>=`.
    required_ver=$(pacman -Qi "$lib32_pkg" 2>/dev/null | awk -v base="$base" '
      /^Depends On/ {
        for (i=4; i<=NF; i++) {
          if ($i ~ "^"base"=") {
            split($i, a, "=")
            print a[2]
            exit
          }
        }
      }
    ')

    # No strict pin — lib32-* expressed dep as ">=" or no version; safe to upgrade
    [[ -z "$required_ver" ]] && continue

    # Find the highest CachyOS version across all 4 cachyos-* repos
    cachyos_ver=""
    for repo in "${CACHYOS_REPOS_FOR_DRIFT[@]}"; do
      cachyos_ver=$(pacman -Si "$repo/$base" 2>/dev/null | awk '/^Version/{print $NF; exit}')
      [[ -n "$cachyos_ver" ]] && break
    done

    # Base package isn't in CachyOS repos — no drift possible
    [[ -z "$cachyos_ver" ]] && continue

    # Arch version-spec semantics: `pkg=X.Y.Z` (no pkgrel) is satisfied by
    # ANY pkgrel of X.Y.Z. `pkg=X.Y.Z-N` (with pkgrel) requires exact match.
    # Normalize: if the lib32 dep omits pkgrel, strip pkgrel from cachyos_ver
    # before comparing — otherwise `2.8.1` vs `2.8.1-1.1` would falsely
    # register as drift even though pacman would resolve it.
    local cachyos_ver_normalized="$cachyos_ver"
    if [[ "$required_ver" != *-* ]]; then
      cachyos_ver_normalized="${cachyos_ver%-*}"
    fi
    [[ "$cachyos_ver_normalized" == "$required_ver" ]] && continue

    DRIFT_LIB32_PKGS+=("$lib32_pkg")
    DRIFT_DETAILS+=("$base: $lib32_pkg pins $required_ver, cachyos has $cachyos_ver")
  done < <(pacman -Qq 2>/dev/null | grep '^lib32-' || true)

  [[ ${#DRIFT_LIB32_PKGS[@]} -gt 0 ]]
}

# _compute_cascade_pkgs LIB32_PKG [LIB32_PKG ...]
# Run `pacman -Rpcs --print-format '%n'` to compute the full cascade
# removal list — includes the named lib32-* packages plus any
# non-lib32 packages that depend on them (typically steam, wine, lutris).
# Prints one package name per line.
_compute_cascade_pkgs() {
  pacman -Rpcs "$@" --print-format '%n' 2>/dev/null
}

# _split_aur_vs_repo PKG_LIST...
# Splits a list of package names into AUR_PKGS (foreign, can't auto-reinstall)
# and REPO_PKGS (in a configured repo, pacman -S works).
# Uses `pacman -Si <pkg>` exit code as authoritative.
_split_aur_vs_repo() {
  AUR_PKGS=()
  REPO_PKGS=()
  local pkg
  for pkg in "$@"; do
    if pacman -Si "$pkg" >/dev/null 2>&1; then
      REPO_PKGS+=("$pkg")
    else
      AUR_PKGS+=("$pkg")
    fi
  done
}

# _build_overwrite_args
# Emits the --overwrite flag/value pairs for `pacman -Syu` as a single
# string suitable for log_dry / eval. Returns "--overwrite 'X' --overwrite 'Y' ..."
_build_overwrite_args() {
  local glob args=""
  for glob in "${UPGRADE_OVERWRITE_GLOBS[@]}"; do
    args+=" --overwrite '$glob'"
  done
  echo "${args# }"
}

# run_system_upgrade [BACKUP_PATH]
# Phase 3.5 orchestrator. Public entry point.
run_system_upgrade() {
  local backup_path="${1:-}"
  local overwrite_args
  overwrite_args=$(_build_overwrite_args)

  log_step "Phase 3.5: System upgrade to CachyOS-optimized versions"

  log_step "Detecting lib32 dependency drift with CachyOS repos"
  if ! detect_lib32_drift; then
    log_ok "No lib32 drift detected — running clean system upgrade"
    log_dry "sudo pacman -Syu --noconfirm $overwrite_args"
    return 0
  fi

  log_warn "Drift detected in ${#DRIFT_LIB32_PKGS[@]} package(s):"
  local detail
  for detail in "${DRIFT_DETAILS[@]}"; do
    log_warn "  - $detail"
  done

  log_step "Computing cascade removal list (lib32 + reverse-deps)"
  local cascade_pkgs=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && cascade_pkgs+=("$line")
  done < <(_compute_cascade_pkgs "${DRIFT_LIB32_PKGS[@]}")

  if [[ ${#cascade_pkgs[@]} -eq 0 ]]; then
    log_err "Cascade computation returned empty — pacman -Rpcs failed"
    log_err "Cannot safely proceed. Aborting upgrade phase."
    return 1
  fi

  log_warn "Cascade will remove ${#cascade_pkgs[@]} package(s):"
  local pkg
  for pkg in "${cascade_pkgs[@]}"; do
    log_warn "  - $pkg"
  done

  _split_aur_vs_repo "${cascade_pkgs[@]}"

  if [[ ${#AUR_PKGS[@]} -gt 0 ]]; then
    log_warn ""
    log_warn "⚠ ${#AUR_PKGS[@]} AUR package(s) will be removed and CANNOT be auto-reinstalled:"
    for pkg in "${AUR_PKGS[@]}"; do
      log_warn "  - $pkg  (you will need to rebuild from AUR after migration)"
    done
    log_warn ""
    if ! confirm "Continue? AUR packages will need manual rebuild after migration."; then
      log_err "User declined upgrade. Migration cannot proceed cleanly with"
      log_err "lib32 drift unresolved. Re-run migrate.sh after removing AUR"
      log_err "packages manually, or wait for [multilib] to catch up (24-48h)."
      return 1
    fi
  fi

  if [[ -n "$backup_path" ]]; then
    log_step "Saving removal manifest to $backup_path/$UPGRADE_REMOVED_LIST"
    local manifest
    manifest=$(printf '%s\n' "${cascade_pkgs[@]}")
    log_dry "printf '%s' '$manifest' | sudo tee '$backup_path/$UPGRADE_REMOVED_LIST' >/dev/null"
  fi

  log_step "Removing ${#cascade_pkgs[@]} package(s) to clear drift"
  log_dry "sudo pacman -Rcns --noconfirm ${cascade_pkgs[*]}"

  log_step "Running full system upgrade (pacman -Syu)"
  log_dry "sudo pacman -Syu --noconfirm $overwrite_args"

  log_step "Reinstalling ${#REPO_PKGS[@]} previously-removed repo package(s)"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf "DRY-RUN: for each removed repo package, run: sudo pacman -S --needed --noconfirm <pkg>\n"
    printf "DRY-RUN:   (some may still fail if multilib drift has not resolved)\n"
    return 0
  fi

  local reinstalled=() still_pending=()
  for pkg in "${REPO_PKGS[@]}"; do
    if sudo pacman -S --needed --noconfirm "$pkg" >/dev/null 2>&1; then
      reinstalled+=("$pkg")
    else
      still_pending+=("$pkg")
    fi
  done

  log_ok "Reinstalled ${#reinstalled[@]} package(s) successfully"

  if [[ ${#still_pending[@]} -gt 0 ]]; then
    log_warn ""
    log_warn "Could not reinstall ${#still_pending[@]} package(s) — multilib drift persists:"
    for pkg in "${still_pending[@]}"; do
      log_warn "  - $pkg"
    done

    if [[ -n "$backup_path" ]]; then
      printf '%s\n' "${still_pending[@]}" | sudo tee "$backup_path/$UPGRADE_PENDING_LIST" >/dev/null
      log_warn ""
      log_warn "Saved pending list to: $backup_path/$UPGRADE_PENDING_LIST"
      log_warn "Retry in 24-48h once [multilib] catches up:"
      log_warn "  sudo pacman -S \$(cat '$backup_path/$UPGRADE_PENDING_LIST')"
    fi
  fi

  if [[ ${#AUR_PKGS[@]} -gt 0 ]]; then
    log_warn ""
    log_warn "AUR packages requiring manual rebuild after migration:"
    for pkg in "${AUR_PKGS[@]}"; do
      log_warn "  - $pkg"
    done
  fi

  return 0
}
