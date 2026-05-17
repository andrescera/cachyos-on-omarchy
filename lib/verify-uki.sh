#!/bin/bash
set -euo pipefail

# CachyOS on Omarchy - UKI and Limine verification (Tollgate 2)
#
# SAFETY-CRITICAL. A bug here can brick the bootloader. Every check is
# READ-ONLY; this file MUST NOT modify any /boot file under any condition.
#
# The main entry point is `verify_uki_safety KERNEL_NAME`, which runs four
# checks in strict order. All four must pass for the function to return 0:
#
#   Check 1: UKI file exists in $BOOT_EFI_LINUX and is >= 50 MB.
#   Check 2: limine.conf has a `//KERNEL_NAME` entry.
#   Check 3: The path in that entry resolves to an existing file. If the
#            entry carries a SHA-512 hash, the file's hash must match.
#   Check 4: Every OTHER installed kernel has its own limine entry (boot
#            fallback safety). A single-kernel system passes with a warning.
#
# All checks emit a log_step banner, a log_ok on success, and a log_err
# describing both the failure and the operator's recovery path on failure.
#
# Environment overrides (for fixture testing — production should leave these
# unset and let lib/const.sh's readonly defaults win):
#   BOOT_EFI_LINUX            UKI directory (default: /boot/EFI/Linux)
#   LIMINE_CONF               limine.conf path (default: /boot/limine.conf)
#   INSTALLED_KERNELS_OVERRIDE  space-separated kernel package names; bypasses
#                             `pacman -Qq` so tests can simulate multi-kernel
#                             systems without actually installing packages.
#
# Depends on:
#   - lib/log.sh    → log_step, log_ok, log_warn, log_err
#   - sha512sum, grep, awk, sed, find, stat, pacman (optional in test mode)

# list_kernel_entries
#
# Prints every kernel entry name found in limine.conf, one per line.
# A kernel entry is any line of the form `  //NAME` (indented, two slashes,
# then the package name with no embedded whitespace). The default conf path
# is /boot/limine.conf, overridable via $LIMINE_CONF.
# Returns 0 on success, 1 if the conf file is unreadable.
list_kernel_entries() {
  local conf="${LIMINE_CONF:-/boot/limine.conf}"

  [[ -r "$conf" ]] || return 1
  grep -oP '^\s+//\K[^\s]+' "$conf" 2>/dev/null || true
}

# get_uki_path_for_kernel KERNEL_NAME
#
# Echoes the absolute path to the UKI declared for KERNEL_NAME in limine.conf.
# Reads the conf at $LIMINE_CONF (default /boot/limine.conf), finds the
# `//KERNEL_NAME` block, extracts the `path: boot():...` value, strips any
# trailing `#sha512` hash, and prefixes `/boot` so the result is an absolute
# filesystem path.
# Echoes the empty string if the entry or path line cannot be parsed.
get_uki_path_for_kernel() {
  local kernel="$1"
  local conf="${LIMINE_CONF:-/boot/limine.conf}"

  [[ -r "$conf" ]] || return 1

  # Match the kernel header line exactly: optional leading whitespace,
  # `//KERNEL_NAME`, then end-of-line. Without the anchor a search for
  # `//linux` would also match `//linux-cachyos-bore` and pick up the wrong
  # section's `path:` line.
  awk -v k="$kernel" '
    $0 ~ "^[[:space:]]*//" k "[[:space:]]*$" , /^(\/[^\/]|$)/ {
      if ($0 ~ /^[[:space:]]*path:/) {
        # Strip everything through "boot():"
        sub(/^.*path:[[:space:]]*boot\(\):/, "", $0)
        # Strip any trailing "#hash..."
        sub(/#.*$/, "", $0)
        print "/boot" $0
        exit
      }
    }
  ' "$conf" 2>/dev/null
}

# verify_uki_safety KERNEL_NAME
#
# Run the four-check Tollgate 2 verification for KERNEL_NAME. Returns 0 only
# if every check passes (Check 4 may pass vacuously on single-kernel systems
# with a warning). Returns non-zero with a recovery message on any failure.
verify_uki_safety() {
  local kernel_name="${1:-}"
  local boot_efi_linux_dir="${BOOT_EFI_LINUX:-/boot/EFI/Linux}"
  local limine_conf_path="${LIMINE_CONF:-/boot/limine.conf}"

  if [[ -z "$kernel_name" ]]; then
    log_err "verify_uki_safety: missing KERNEL_NAME argument"
    return 2
  fi

  # ----- Check 1: UKI file exists and is large enough -----
  log_step "Check 1: UKI file exists at ${boot_efi_linux_dir}/"
  local uki_file=""
  uki_file=$(find "$boot_efi_linux_dir" -maxdepth 1 -name "*${kernel_name}*.efi" 2>/dev/null | head -1)
  if [[ -z "$uki_file" || ! -f "$uki_file" ]]; then
    log_err "Check 1 FAIL: UKI file not found for kernel '$kernel_name' in ${boot_efi_linux_dir}"
    log_err "Recovery: Run 'sudo mkinitcpio -p $kernel_name' to regenerate. If still missing, see rollback scenario 2."
    return 1
  fi
  local uki_size
  uki_size=$(stat -c %s "$uki_file" 2>/dev/null || echo 0)
  if [[ "$uki_size" -lt 52428800 ]]; then  # 50 MB minimum
    log_err "Check 1 FAIL: UKI file '$uki_file' is too small (${uki_size} bytes, expected >= 50 MB)"
    log_err "Recovery: The UKI may be corrupt. Run 'sudo mkinitcpio -p $kernel_name' to rebuild."
    return 1
  fi
  log_ok "Check 1 PASS: UKI found at $uki_file ($(( uki_size / 1048576 )) MB)"

  # ----- Check 2: Limine entry exists for this kernel -----
  log_step "Check 2: Limine entry for kernel '$kernel_name'"
  if [[ ! -r "$limine_conf_path" ]]; then
    log_err "Check 2 FAIL: cannot read ${limine_conf_path}"
    log_err "Recovery: Verify the file exists and is readable by the current user."
    return 1
  fi
  if ! grep -qE "^[[:space:]]*//${kernel_name}[[:space:]]*$" "$limine_conf_path"; then
    log_err "Check 2 FAIL: No limine entry found for '//${kernel_name}' in ${limine_conf_path}"
    log_err "Recovery: Check ${limine_conf_path} manually. Entry should be '//${kernel_name}' under a parent section."
    return 1
  fi
  log_ok "Check 2 PASS: Limine entry '//${kernel_name}' found"

  # ----- Check 3: Limine entry path resolves and (if present) hash matches -----
  log_step "Check 3: UKI path resolves and hash matches"
  local path_line
  path_line=$(awk -v k="$kernel_name" '
    $0 ~ "^[[:space:]]*//" k "[[:space:]]*$" , /^(\/[^\/]|$)/ {
      if ($0 ~ /^[[:space:]]*path:/) { print; exit }
    }
  ' "$limine_conf_path" 2>/dev/null || true)

  if [[ -z "$path_line" ]]; then
    log_err "Check 3 FAIL: No 'path:' line found in entry '//${kernel_name}'"
    log_err "Recovery: Edit ${limine_conf_path} and add a 'path: boot():/EFI/Linux/<uki>.efi' line under the entry."
    return 1
  fi

  # Strip "path: boot():" prefix to obtain the boot-relative path.
  # Strip trailing "#hash" if present; record the hash separately.
  local boot_relative_path hash_from_conf full_path
  boot_relative_path=$(printf '%s' "$path_line" | sed -e 's/^.*path:[[:space:]]*boot():\?//' -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  hash_from_conf=$(printf '%s' "$path_line" | sed -n 's/.*#\([0-9a-fA-F]*\).*/\1/p')

  if [[ -z "$boot_relative_path" ]]; then
    log_err "Check 3 FAIL: Could not parse path from line: $path_line"
    return 1
  fi

  # Resolve to a real file. In production, limine's `boot():/` refers to /boot
  # so the natural location is `/boot${boot_relative_path}`. In fixture mode,
  # callers point BOOT_EFI_LINUX at a fixture directory; the conf still
  # contains a `boot():` path so we fall back to looking up the basename
  # inside the BOOT_EFI_LINUX directory.
  if [[ -f "/boot${boot_relative_path}" ]]; then
    full_path="/boot${boot_relative_path}"
  elif [[ -f "${boot_efi_linux_dir}/$(basename "$boot_relative_path")" ]]; then
    full_path="${boot_efi_linux_dir}/$(basename "$boot_relative_path")"
  else
    log_err "Check 3 FAIL: Path from limine.conf does not exist: /boot${boot_relative_path}"
    log_err "Recovery: Restore the UKI or correct the path in ${limine_conf_path}."
    return 1
  fi

  if [[ -n "$hash_from_conf" && "${#hash_from_conf}" -eq 128 ]]; then
    local actual_hash
    actual_hash=$(sha512sum "$full_path" | awk '{print $1}')
    if [[ "$actual_hash" != "${hash_from_conf,,}" ]]; then
      log_err "Check 3 FAIL: SHA512 hash mismatch for $full_path"
      log_err "  Expected: $hash_from_conf"
      log_err "  Actual:   $actual_hash"
      log_err "Recovery: Regenerate the UKI ('sudo mkinitcpio -p $kernel_name') and re-run limine-update."
      return 1
    fi
    log_ok "Check 3 PASS: Path resolves + SHA-512 matches ($full_path)"
  else
    log_warn "Check 3: No hash in limine.conf for this entry — skipping hash verification"
    log_ok "Check 3 PASS: Path resolves to $full_path (no hash to verify)"
  fi

  # ----- Check 4: All other installed kernels have limine entries -----
  log_step "Check 4: Fallback kernel entries present"
  local installed_kernels=()
  if [[ -n "${INSTALLED_KERNELS_OVERRIDE:-}" ]]; then
    # Test hook: simulate multi-kernel scenarios without installing packages.
    read -r -a installed_kernels <<< "${INSTALLED_KERNELS_OVERRIDE}"
  else
    # The `cachyos[a-z-]*` clause matches every cachyos variant the user
    # might have, but it also catches companion packages like `-headers`
    # and `-nvidia-open`. The second grep strips those non-kernel suffixes
    # so Check 4 doesn't falsely demand a limine entry for `linux-cachyos-bore-headers`.
    mapfile -t installed_kernels < <(
      pacman -Qq 2>/dev/null \
        | grep -E '^linux(-(lts|zen|hardened|cachyos[a-z-]*))?$' \
        | grep -vE -- '-(headers|docs|nvidia(-open)?)$' \
        || true
    )
  fi

  local other_kernels=()
  local k
  for k in "${installed_kernels[@]}"; do
    [[ -n "$k" && "$k" != "$kernel_name" ]] && other_kernels+=("$k")
  done

  if [[ ${#other_kernels[@]} -eq 0 ]]; then
    log_warn "Check 4: Single-kernel system — no fallback kernel installed. Consider installing 'linux' or 'linux-lts' as a fallback before relying on this kernel."
    log_ok "Check 4 PASS (vacuous): Single-kernel system accepted with warning."
    return 0
  fi

  local check4_fail=0
  for k in "${other_kernels[@]}"; do
    if ! grep -qE "^[[:space:]]*//${k}[[:space:]]*$" "$limine_conf_path"; then
      log_err "Check 4 FAIL: Installed kernel '$k' has no limine entry '//${k}' — boot fallback unsafe"
      check4_fail=1
    else
      log_ok "  Fallback '$k' has limine entry"
    fi
  done

  if [[ "$check4_fail" -eq 1 ]]; then
    log_err "Recovery: Boot into fallback kernel. Add missing limine entries for listed kernels. See rollback.md scenario 2."
    return 1
  fi
  log_ok "Check 4 PASS: All fallback kernels have limine entries"

  return 0
}
