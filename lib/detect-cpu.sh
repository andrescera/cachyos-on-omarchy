#!/bin/bash
set -euo pipefail

# CachyOS on Omarchy - CPU detection library
#
# Detects x86-64 microarchitecture level (v1..v4) and CPU vendor using the
# canonical glibc-hwcaps method via /lib/ld-linux-x86-64.so.2 --help.
#
# Per Metis R5: do NOT derive the arch level from CPU feature-flag bits
# (avx2, sse4_2, ...). The glibc-hwcaps "(supported, searched)" markers
# from the dynamic linker are the source of truth.

# detect_arch_level
#
# Returns the highest supported x86-64 microarchitecture level as
# v1 | v2 | v3 | v4 by parsing the glibc-hwcaps section of
# /lib/ld-linux-x86-64.so.2 --help output.
#
# Reads from stdin when stdin is not a terminal (for fixture testing);
# otherwise invokes the dynamic linker directly.
#
# Defaults to v2 on uncertainty/failure (safe conservative choice).
detect_arch_level() {
  local input
  if [[ -p /dev/stdin || -f /dev/stdin ]]; then
    input=$(cat)
  else
    input=$(/lib/ld-linux-x86-64.so.2 --help 2>&1 || true)
  fi

  local highest=""
  local line level
  while IFS= read -r line; do
    if [[ "$line" =~ x86-64-(v[1-4])[[:space:]]*\(supported,[[:space:]]*searched\) ]]; then
      level="${BASH_REMATCH[1]}"
      if [[ -z "$highest" || "$level" > "$highest" ]]; then
        highest="$level"
      fi
    fi
  done <<<"$input"

  if [[ -z "$highest" ]]; then
    printf 'v2\n'
    return 0
  fi

  printf '%s\n' "$highest"
}

# detect_cpu_vendor
#
# Returns the CPU vendor as: amd | intel | unknown.
#
# Reads from stdin when stdin is not a terminal (for fixture testing);
# otherwise reads /proc/cpuinfo directly.
detect_cpu_vendor() {
  local raw_vendor=""

  if [[ -p /dev/stdin || -f /dev/stdin ]]; then
    raw_vendor=$(grep -m1 '^vendor_id' | awk '{print $3}' || true)
  else
    raw_vendor=$(grep -m1 '^vendor_id' /proc/cpuinfo 2>/dev/null | awk '{print $3}' || true)
  fi

  case "$raw_vendor" in
    AuthenticAMD) printf 'amd\n' ;;
    GenuineIntel) printf 'intel\n' ;;
    *)            printf 'unknown\n' ;;
  esac
}

# microcode_pkg_for_vendor VENDOR
#
# Maps a vendor string (amd | intel | other) to the corresponding microcode
# package name. Prints "unknown" for unrecognized vendors.
microcode_pkg_for_vendor() {
  local vendor="${1:-}"
  case "$vendor" in
    amd)   printf 'amd-ucode\n' ;;
    intel) printf 'intel-ucode\n' ;;
    *)     printf 'unknown\n' ;;
  esac
}

# is_v3_capable
#
# Exit 0 if detect_arch_level reports v3 or v4; exit 1 otherwise.
# Produces no stdout output.
is_v3_capable() {
  local level
  level=$(detect_arch_level)
  case "$level" in
    v3|v4) return 0 ;;
    *)     return 1 ;;
  esac
}
