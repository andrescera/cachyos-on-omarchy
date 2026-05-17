#!/bin/bash
set -euo pipefail

# CachyOS pre-refresh-pacman hook for omarchy-refresh-pacman
#
# omarchy-refresh-pacman overwrites /etc/pacman.conf with a raw `cp` from
# omarchy-default-pacman.conf BEFORE running `pacman -Syyuu`. Because it
# is `cp` and not a pacman transaction, the Alpm hook
# zz-cachyos-conf-restore.hook (Type=Path) never fires, so CachyOS repo
# blocks, Architecture, and IgnorePkg silently disappear and the
# subsequent `pacman -Syyuu` would resolve CachyOS-patched packages
# against vanilla Arch (downgrades, signature errors, etc.).
#
# This hook is invoked by `omarchy-hook pre-refresh-pacman` AFTER the cp
# and BEFORE `pacman -Syyuu`. It:
#   1. Re-trusts CachyOS signing keys (Metis R14).
#   2. Restores Architecture = auto x86_64 x86_64_v3 (when CPU is v3+).
#   3. Restores IgnorePkg entries.
#   4. Re-injects the four CachyOS repo blocks above the first
#      non-[options] section.
#
# This script is SELF-CONTAINED: it does NOT source any cachyos-on-omarchy
# lib files (those are not installed at a known path on user machines).
# It runs as the regular user under `omarchy-hook`, so every state-change
# uses `sudo`.

PACMAN_CONF="/etc/pacman.conf"
IGNORE_PKGS=(walker walker-bin elephant elephant-files archlinux-keyring)

# ── 1. Re-trust CachyOS signing keys (R14) ────────────────────────────────────
# archlinux-keyring's post-install runs `pacman-key --populate archlinux`,
# which can leave CachyOS keys in "unknown trust" state. Re-populate them.
if pacman -Qi cachyos-keyring >/dev/null 2>&1; then
  echo "==> Re-trusting CachyOS signing keys (pacman-key --populate cachyos)"
  sudo pacman-key --populate cachyos
else
  echo "==> cachyos-keyring not installed; skipping pacman-key --populate cachyos"
fi

# ── 2. Architecture line ──────────────────────────────────────────────────────
if ! grep -q 'x86_64_v3' "$PACMAN_CONF" 2>/dev/null; then
  if /lib/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -q 'x86-64-v3'; then
    echo "==> Restoring Architecture = auto x86_64 x86_64_v3"
    sudo sed -i 's/^Architecture = auto$/Architecture = auto x86_64 x86_64_v3/' "$PACMAN_CONF"
  fi
fi

# ── 3. IgnorePkg entries ──────────────────────────────────────────────────────
current_line=$(grep -E '^IgnorePkg[[:space:]]*=' "$PACMAN_CONF" 2>/dev/null || true)

if [[ -n "$current_line" ]]; then
  stripped="${current_line#*=}"
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

  if [[ "${#final_arr[@]}" -ne "${#existing_arr[@]}" ]]; then
    merged="IgnorePkg = ${final_arr[*]}"
    echo "==> Restoring IgnorePkg entries: $merged"
    sudo sed -i "s|^IgnorePkg[[:space:]]*=.*|${merged}|" "$PACMAN_CONF"
  fi
else
  merged="IgnorePkg = ${IGNORE_PKGS[*]}"
  echo "==> Adding missing IgnorePkg line under [options]: $merged"
  sudo sed -i "/^\[options\]/a ${merged}" "$PACMAN_CONF"
fi

# ── 4. CachyOS repo blocks ────────────────────────────────────────────────────
if grep -q '^\[cachyos' "$PACMAN_CONF" 2>/dev/null; then
  echo "==> CachyOS repo blocks already present; nothing to inject"
  exit 0
fi

for ml in cachyos-mirrorlist cachyos-v3-mirrorlist; do
  if [[ ! -s "/etc/pacman.d/$ml" ]]; then
    echo "==> WARNING: /etc/pacman.d/$ml missing; skipping CachyOS repo injection"
    exit 0
  fi
done

ANCHOR=$(awk '/^\[/ && !/options/ {print $0; exit}' "$PACMAN_CONF")
if [[ -z "$ANCHOR" ]]; then
  echo "==> WARNING: no non-[options] section found in $PACMAN_CONF; skipping repo injection"
  exit 0
fi

echo "==> Inserting CachyOS repo blocks above: $ANCHOR"
ANCHOR_ESCAPED=$(printf '%s\n' "$ANCHOR" | sed -e 's/[][\/.*^$]/\\&/g')
sudo sed -i "/^${ANCHOR_ESCAPED}/i\\
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
" "$PACMAN_CONF"

if grep -q '^\[cachyos-v3\]' "$PACMAN_CONF"; then
  echo "==> CachyOS repo blocks restored successfully"
else
  echo "==> ERROR: CachyOS repo block insertion failed" >&2
  exit 1
fi
