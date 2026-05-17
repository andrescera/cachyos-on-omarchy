#!/bin/bash
set -euo pipefail

# lib/repos.sh - CachyOS repository installation
#
# Wraps the upstream cachyos-repo installer and adds:
# - Anchor-based repo insertion (Metis R10: search MULTIPLE anchors, fail loud)
# - Architecture line upgrade for v3-capable CPUs (Metis R5 safety)
# - IgnorePkg merge with Omarchy defaults
# - Full idempotency: safely runnable multiple times
# - Fail-fast on network errors (Metis R7)
#
# Requires: lib/const.sh, lib/log.sh, lib/detect-cpu.sh to be sourced first.

# install_cachyos_repos
#
# Idempotent CachyOS repo installer. 10-step process:
#   1. Check if cachyos repos already in pacman.conf — skip if so
#   2. Download upstream installer (fail-fast on network error, R7)
#   3. Extract + run upstream (installs cachyos-keyring + cachyos-mirrorlist)
#   4. Verify keyring + mirrorlist were actually installed
#   5. Find anchor section in pacman.conf (R10: [core] → [extra] → first non-options)
#   6. Insert 4 cachyos repo blocks above anchor
#   7. Upgrade Architecture line if CPU is v3-capable (R5)
#   8. Merge IgnorePkg list (don't overwrite existing entries)
#   9. Sync package databases (pacman -Sy, NO upgrade)
#   10. Rate mirrors via cachyos-rate-mirrors
#
# Returns 0 on success, non-zero on any failure.
# Respects DRY_RUN=1: prints intended actions but never modifies state.
install_cachyos_repos() {
  local anchor=""
  local tarball="/tmp/cachyos-repo.tar.xz"
  local extract_dir="/tmp/cachyos-repo"

  log_step "Installing CachyOS repositories"

  # Step 1: Idempotent check — short-circuit if already installed
  if grep -q '^\[cachyos' "${PACMAN_CONF}" 2>/dev/null; then
    log_ok "CachyOS repos already in ${PACMAN_CONF} — skipping install"
    return 0
  fi

  # Step 2: Download upstream installer (Metis R7: fail-fast on network error)
  log_step "Downloading upstream installer from ${CACHYOS_REPO_URL}"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf "DRY-RUN: curl -fsSL --max-time 30 '%s' -o '%s'\n" "${CACHYOS_REPO_URL}" "${tarball}"
  else
    if ! curl -fsSL --max-time 30 "${CACHYOS_REPO_URL}" -o "${tarball}"; then
      log_err "Network error: failed to download from ${CACHYOS_REPO_URL}"
      return 1
    fi
    log_ok "Downloaded ${tarball}"
  fi

  # Step 3: Extract + run upstream (upstream handles keyring + mirrorlist install)
  log_step "Extracting and running upstream cachyos-repo installer"
  log_dry "rm -rf '${extract_dir}' && mkdir -p '${extract_dir}' && tar -xf '${tarball}' -C '${extract_dir}' --strip-components=1"
  log_dry "cd '${extract_dir}' && sudo ./cachyos-repo.sh"

  # Step 4: Post-install verify (defensive — upstream script could fail silently)
  log_step "Verifying cachyos-keyring + cachyos-mirrorlist installed"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf "DRY-RUN: pacman -Q cachyos-keyring cachyos-mirrorlist\n"
  else
    if ! pacman -Q cachyos-keyring cachyos-mirrorlist >/dev/null 2>&1; then
      log_err "cachyos-keyring or cachyos-mirrorlist not installed after upstream script"
      return 1
    fi
    log_ok "cachyos-keyring and cachyos-mirrorlist verified installed"
  fi

  # Step 5: Find anchor (Metis R10: search MULTIPLE anchors, fail loudly)
  # Order: [core] first, [extra] second, else first non-options section.
  log_step "Locating anchor section in ${PACMAN_CONF}"
  if grep -q '^\[core\]' "${PACMAN_CONF}"; then
    anchor="core"
  elif grep -q '^\[extra\]' "${PACMAN_CONF}"; then
    anchor="extra"
  else
    anchor=$(awk '/^\[/ && !/options/ {gsub(/[][]/,""); print; exit}' "${PACMAN_CONF}")
  fi

  if [[ -z "$anchor" ]]; then
    log_err "Cannot find anchor in ${PACMAN_CONF} — is it heavily customized?"
    return 1
  fi
  log_ok "Found anchor: [${anchor}]"

  # Step 6: Insert CachyOS blocks above anchor (defensive re-check for idempotency).
  if grep -q '^\[cachyos' "${PACMAN_CONF}" 2>/dev/null; then
    log_ok "CachyOS repos already present (re-check) — skipping insert"
  else
    log_step "Inserting 4 CachyOS repo blocks above [${anchor}]"
    if [[ "$DRY_RUN" == "1" ]]; then
      printf "DRY-RUN: would insert [cachyos-v3], [cachyos-core-v3], [cachyos-extra-v3], [cachyos] above [%s] in %s\n" "${anchor}" "${PACMAN_CONF}"
    else
      sudo sed -i "/^\[${anchor}\]/i\\
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
" "${PACMAN_CONF}"

      if ! grep -q '^\[cachyos-v3\]' "${PACMAN_CONF}"; then
        log_err "Failed to insert CachyOS repo blocks"
        return 1
      fi
      log_ok "CachyOS repo blocks inserted above [${anchor}]"
    fi
  fi

  # Step 7: Architecture line upgrade (Metis R5: NEVER set v3 on non-v3-capable CPUs)
  log_step "Checking Architecture line"
  if is_v3_capable; then
    if grep -q '^Architecture = auto$' "${PACMAN_CONF}"; then
      if [[ "$DRY_RUN" == "1" ]]; then
        printf "DRY-RUN: sed -i 's/^Architecture = auto$/Architecture = auto x86_64 x86_64_v3/' '%s'\n" "${PACMAN_CONF}"
      else
        sudo sed -i 's/^Architecture = auto$/Architecture = auto x86_64 x86_64_v3/' "${PACMAN_CONF}"
        log_ok "Architecture line upgraded to: auto x86_64 x86_64_v3"
      fi
    else
      log_ok "Architecture already configured (not 'auto' alone) — leaving unchanged"
    fi
  else
    log_warn "CPU is not x86_64-v3 capable — leaving Architecture line unchanged (R5 safety)"
  fi

  # Step 8: IgnorePkg merge (add missing entries, don't overwrite)
  log_step "Merging IgnorePkg entries"
  _merge_ignore_pkg

  # Step 9: Sync package databases (NOT upgrade!)
  log_step "Syncing package databases (pacman -Sy)"
  log_dry "sudo pacman -Sy"

  # Step 10: Rate CachyOS mirrors for fastest mirror selection
  log_step "Rating CachyOS mirrors"
  if [[ "$DRY_RUN" == "1" ]] || require_pkg cachyos-rate-mirrors 2>/dev/null; then
    log_dry "sudo cachyos-rate-mirrors"
  else
    log_warn "cachyos-rate-mirrors not installed — skipping mirror rating"
  fi

  log_ok "CachyOS repositories installed successfully"
  return 0
}

# _merge_ignore_pkg
#
# Merge IGNORE_PKGS entries into pacman.conf's IgnorePkg line.
# - If IgnorePkg already exists: append missing entries only (preserve existing)
# - If no IgnorePkg line: add one immediately after [options]
# Respects DRY_RUN=1.
_merge_ignore_pkg() {
  local current_line
  local stripped
  local merged
  local entry e
  local found
  local existing_arr=()
  local final_arr=()

  current_line=$(grep -E '^IgnorePkg[[:space:]]*=' "${PACMAN_CONF}" || true)

  if [[ -n "$current_line" ]]; then
    # Extract existing entries after `=` and trim
    stripped="${current_line#*=}"
    stripped="${stripped# }"
    # Deliberate word-split to build array of existing entries
    # shellcheck disable=SC2206
    existing_arr=( $stripped )

    # Build merged list: existing + any IGNORE_PKGS not already present
    final_arr=( "${existing_arr[@]}" )
    for entry in "${IGNORE_PKGS[@]}"; do
      found=0
      for e in "${existing_arr[@]}"; do
        if [[ "$e" == "$entry" ]]; then
          found=1
          break
        fi
      done
      if [[ "$found" -eq 0 ]]; then
        final_arr+=( "$entry" )
      fi
    done

    # No-op if nothing new to add
    if [[ "${#final_arr[@]}" -eq "${#existing_arr[@]}" ]]; then
      log_ok "IgnorePkg already contains all required entries — no change needed"
      return 0
    fi

    merged="IgnorePkg = ${final_arr[*]}"
    if [[ "$DRY_RUN" == "1" ]]; then
      printf "DRY-RUN: replace IgnorePkg line with: %s\n" "$merged"
    else
      # Use | as sed delimiter (package names contain no | char) so the
      # replacement doesn't need additional escaping.
      sudo sed -i "s|^IgnorePkg[[:space:]]*=.*|${merged}|" "${PACMAN_CONF}"
      log_ok "IgnorePkg updated: ${merged}"
    fi
  else
    # No IgnorePkg line — add one under [options]
    merged="IgnorePkg = ${IGNORE_PKGS[*]}"
    if [[ "$DRY_RUN" == "1" ]]; then
      printf "DRY-RUN: insert new line under [options]: %s\n" "$merged"
    else
      sudo sed -i "/^\[options\]/a ${merged}" "${PACMAN_CONF}"
      log_ok "IgnorePkg line added: ${merged}"
    fi
  fi
}
