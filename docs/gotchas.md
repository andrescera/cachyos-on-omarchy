# Known Gotchas and Operational Caveats

This document covers known edge cases, failure modes, and their mitigations. Each entry describes what you'll see when something goes wrong, why it happens, how the scripts defend against it, and what to do if the automated mitigation fails.

---

## Metis High-Risk Items

### R6: omarchy-update overwrites pacman.conf

**Symptom**: After running `omarchy-update` or `omarchy-refresh-pacman`, CachyOS repos disappear from `pacman.conf`. Package installs fail with "repository not found" or packages resolve to Arch versions instead of CachyOS-optimized builds.

**Root cause**: Both `omarchy-update` and `omarchy-refresh-pacman` regenerate `pacman.conf` from a template, removing any custom repo blocks that were appended after the initial Omarchy install. `omarchy-refresh-pacman` is especially dangerous because it uses a raw `cp omarchy-default-pacman.conf /etc/pacman.conf` (not a pacman package transaction), then immediately runs `pacman -Syyuu` — potentially downgrading CachyOS-patched packages against vanilla Arch repos.

**Mitigation**: This project installs **two** restore hooks that together cover both overwrite paths:

1. **Alpm hook** at `/etc/pacman.d/hooks/zz-cachyos-conf-restore.hook` (`Type=Path` on `etc/pacman.conf`). Fires after any *pacman package transaction* that touches `pacman.conf` — covers package upgrades that ship a new `pacman.conf`.
2. **Omarchy pre-refresh-pacman hook** at `~/.config/omarchy/hooks/pre-refresh-pacman.d/01-cachyos-repos-restore.sh`. Invoked by `omarchy-hook pre-refresh-pacman` *between* the raw `cp` overwrite and `pacman -Syyuu` — covers `omarchy-refresh-pacman`, which the Alpm hook misses because `cp` is not a pacman transaction.

Both hooks restore the same three items: CachyOS repo blocks, `Architecture = auto x86_64 x86_64_v3`, and `IgnorePkg` entries (walker, walker-bin, elephant, elephant-files, archlinux-keyring). The Omarchy hook additionally re-trusts CachyOS signing keys (see R14).

**Manual fix**: If either hook is missing or fails, run:
```bash
# Restore via the Alpm-hook helper (for omarchy-update path):
sudo bash /usr/local/lib/cachyos-on-omarchy/pacman-hook-restore.sh

# Or run the Omarchy hook directly (for omarchy-refresh-pacman path):
bash ~/.config/omarchy/hooks/pre-refresh-pacman.d/01-cachyos-repos-restore.sh
```
To manually restore `IgnorePkg`, add the following line under `[options]` in `/etc/pacman.conf`:
```
IgnorePkg = walker walker-bin elephant elephant-files archlinux-keyring
```

---

### R7: CachyOS mirror URL changes

**Symptom**: `migrate.sh` aborts during repo install with an error like `Network error: failed to download from https://mirror.cachyos.org/cachyos-repo.tar.xz`.

**Root cause**: The upstream mirror URL changed, the mirror is temporarily down, or the tarball filename was updated in a new CachyOS release.

**Mitigation**: `migrate.sh` fails fast on network errors within 30 seconds and never blindly proceeds past a failed download. The script will not leave a half-configured system.

**Manual fix**: Check `https://mirror.cachyos.org/` for the current installer URL. Update the `CACHYOS_REPO_URL` constant near the top of `migrate.sh`, then re-run.

---

### R8: Omarchy helper renamed or missing

**Symptom**: `migrate.sh` exits early with "required command not found: \<helper\>". No packages are installed.

**Root cause**: Omarchy occasionally renames or removes internal helper scripts between releases. If a helper the migration script depends on has been renamed, the pre-flight check catches it before any changes are made.

**Mitigation**: `migrate.sh` runs `command -v` on every required Omarchy helper during pre-flight. If any are missing, the script aborts cleanly before touching the system.

**Manual fix**: Check the current Omarchy release notes for renamed helpers. Update the `REQUIRED_HELPERS` list in `migrate.sh` to match the new names, then re-run.

---

### R9: cachyos-settings conflicts with Omarchy settings

**Symptom**: After migration, some Omarchy behaviors change unexpectedly. Examples: swap pressure feels different, process priorities shift, or ananicy-cpp behaves differently than before.

**Root cause**: `cachyos-settings` drops configuration files into system directories that may override Omarchy's defaults. These are intentional CachyOS tuning choices, but they can surprise users who expect Omarchy's baseline behavior.

**Files installed by cachyos-settings**:
- `/etc/sysctl.d/99-cachyos-settings.conf` — sets `vm.swappiness=150`, `kernel.nmi_watchdog=0`, and other kernel tunables
- `/etc/ananicy.d/` — process priority rules for common applications
- `/etc/systemd/system/ananicy-cpp.service.d/` — service override for ananicy-cpp

**Mitigation**: These files are documented here and their installation is expected. The rollback script removes them cleanly.

**Manual fix**: To remove `cachyos-settings` and its companion:
```bash
sudo pacman -Rns cachyos-settings ananicy-cpp
```
Or use the rollback script:
```bash
./rollback.sh --scenario 4
```

---

### R10: pacman.conf anchor not found

**Symptom**: `migrate.sh` aborts with "could not find insertion anchor in pacman.conf". No repos are added.

**Root cause**: The script inserts CachyOS repo blocks by searching for a known anchor line in `pacman.conf` (e.g., `[core]`). If Omarchy's template changes the section ordering or renames sections, the anchor search fails.

**Mitigation**: The script searches multiple candidate anchors in priority order rather than relying on a single hardcoded string. If none are found, it fails loudly with a clear error message rather than silently corrupting the file.

**Manual fix**: Open `/etc/pacman.conf` and identify the first `[repo-name]` section header. Add the CachyOS repo blocks immediately above it, following the format in `lib/pacman-repos.conf`. Then re-run `migrate.sh`.

---

### R11: Ctrl+C mid-pacman leaves partial state

**Symptom**: You interrupt `migrate.sh` during a `pacman -S` call. The database is locked, some packages are half-installed, or the system is in an inconsistent state.

**Root cause**: Interrupting pacman mid-transaction can leave the package database locked and packages partially extracted.

**Mitigation**: `migrate.sh` traps `SIGINT` (Ctrl+C). When caught, it prints a recovery message with exact commands to clean up the partial state before exiting.

**Manual fix**: If you interrupt the script and the trap message doesn't appear:
```bash
sudo rm -f /var/lib/pacman/db.lck
sudo pacman -Syyu
```
Then check which packages from the migration list are missing and install them manually.

---

### R12: Multi-filesystem systems

**Symptom**: On systems with multiple btrfs subvolumes or separate partitions for `/home`, `/boot`, etc., snapshot or backup operations target the wrong filesystem.

**Root cause**: The script was designed for single-root setups. On multi-FS systems, naive path-based operations can cross mount boundaries unexpectedly.

**Mitigation**: All snapshot and backup operations explicitly target `/` only. The script does not recurse into separate mount points.

**Manual fix**: If you have a non-standard partition layout, take manual snapshots of each relevant subvolume before running `migrate.sh`.

---

### R13: User mkinitcpio.conf customizations overwritten

**Symptom**: After migration, custom `mkinitcpio.conf` hooks or modules you had configured are gone.

**Root cause**: Installing `linux-cachyos-bore` and running `mkinitcpio` can interact with your existing `mkinitcpio.conf` if the CachyOS preset differs from your current one.

**Mitigation**: `migrate.sh` backs up `/etc/mkinitcpio.conf` before any kernel operations. After `mkinitcpio` runs, it diffs the backup against the current file and prints any differences so you can review them.

**Manual fix**: Restore your customizations from the backup:
```bash
diff /etc/mkinitcpio.conf /etc/mkinitcpio.conf.cachyos-backup
# Re-apply any lost customizations manually
```

---

### R14: CachyOS signing keys go untrusted after archlinux-keyring reinstall

**Symptom**: `pacman` errors with "signature from 'CachyOS...' is unknown trust" or "invalid signature" when trying to install or update CachyOS-provided packages. Typically surfaces right after `omarchy-update-keyring` or `omarchy-refresh-pacman` has run.

**Root cause**: `omarchy-update-keyring` runs `sudo pacman -Sy --noconfirm archlinux-keyring`. The post-install script of `archlinux-keyring` runs `pacman-key --populate archlinux`, which can leave CachyOS signing keys in "unknown trust" state in `/etc/pacman.d/gnupg/`. CachyOS packages then fail signature verification on the next `pacman -Syyuu`.

**Mitigation**: The `pre-refresh-pacman.d` hook installed by `migrate.sh` at `~/.config/omarchy/hooks/pre-refresh-pacman.d/01-cachyos-repos-restore.sh` runs `sudo pacman-key --populate cachyos` before `pacman -Syyuu` executes, re-establishing trust for the CachyOS keyring on every `omarchy-refresh-pacman` invocation.

**Manual fix**: If trust drifts outside of an `omarchy-refresh-pacman` run, restore it directly:
```bash
sudo pacman-key --populate cachyos
```

---

### R15: lib32 dependency drift between CachyOS and Arch multilib

**Symptom**: `pacman -Syu` (or a fresh `migrate.sh` run) errors with `error: failed to prepare transaction (could not satisfy dependencies)` followed by lines like:

```
:: installing expat (2.8.1-1.1) breaks dependency 'expat=2.8.0' required by lib32-expat
```

The package can be any shared library that has a `lib32-*` counterpart in `[multilib]`: `expat`, `glib2`, `glibc`, `openssl`, `icu`, `zlib`, `pcre2`, `sqlite`, `libxml2`, `ffmpeg`, `mesa`, `wayland`, `libdrm`, `vulkan-icd-loader`, `systemd`, etc.

**Root cause**: CachyOS rebuilds and bumps these shared libraries faster than Arch's `[multilib]` repository ships matching `lib32-*` rebuilds. During the "drift window" (6-48h after a CachyOS bump), the strict `expat=X.Y.Z` pin inside `lib32-expat`'s PKGBUILD `depends=()` array points at the **old** Arch version, and `[multilib]` has no newer `lib32-expat` yet. pacman correctly refuses to upgrade `expat` because it would break the declared dep of `lib32-expat`.

This is **not** caused by `migrate.sh` — it's a property of running CachyOS repos alongside Arch's `[multilib]`. The migration script exposes the issue earlier because Phase 3.5 runs a full system upgrade to pull every package to its CachyOS-optimized version.

**Mitigation**: `migrate.sh` Phase 3.5 (`lib/upgrade.sh`) runs a drift-aware system upgrade in four steps:

1. **Detect**: scan every installed `lib32-*` package, parse the strict version pin from its `Depends On` line, compare against the version that the four `cachyos-*` repos offer. Build a `DRIFT_LIB32_PKGS` list.
2. **Compute cascade**: if drift exists, run `pacman -Rpcs --print-format '%n'` against the drift list to compute the full set of packages that would be removed (lib32-* + reverse deps: typically `steam`, `wine`, `lutris`).
3. **Consent gate**: split the cascade into repo-installable and AUR-only. If AUR packages are involved, prompt the user explicitly — AUR cannot be auto-reinstalled and will need a manual rebuild after migration.
4. **Remove → upgrade → reinstall**:
   - `sudo pacman -Rcns <cascade>` to clear all drift conflicts at once
   - `sudo pacman -Syu` runs cleanly with no blocking deps
   - For each removed repo package: `sudo pacman -S --needed <pkg>`. Packages that still fail (multilib has not yet caught up) are recorded as **pending**.

State files written under `$BACKUP_PATH/`:
- `removed-for-upgrade.txt` — every package removed by the cascade (recovery list)
- `pending-reinstall.txt` — packages that failed to reinstall (retry list)

**Manual fix** (when Phase 3.5 leaves pending packages, or when drift hits post-migration during a normal `omarchy-update`):

Wait 24-48h for `[multilib]` to ship matching `lib32-*` rebuilds, then:

```bash
# Retry pending pacman -S list (replace with your actual backup path):
sudo pacman -S $(cat /var/backups/cachyos-on-omarchy/migration-<timestamp>/pending-reinstall.txt)

# Or for a one-off drift error during omarchy-update:
sudo pacman -Syu --ignore <conflicting-pkg>      # skip just that pkg
# or
sudo pacman -Syu --assume-installed '<pkg>=<old-version>'   # bypass the strict pin
```

**AUR cascade recovery**: if Phase 3.5 removed AUR packages (e.g. `wine-staging-git`), they are listed in `removed-for-upgrade.txt` but NOT in `pending-reinstall.txt`. Rebuild them after migration with your preferred AUR helper:

```bash
# Identify removed AUR packages:
comm -23 <(sort $BACKUP_PATH/removed-for-upgrade.txt) <(pacman -Slq | sort)
# Rebuild each via the appropriate AUR helper.
```

---

## Additional Gotchas

### DKMS depmod timing

**Symptom**: After kernel install, NVIDIA modules are not found in the UKI. Boot fails or falls back to nouveau.

**Root cause**: `mkinitcpio` can run before `depmod` finishes registering the new DKMS-built modules for the new kernel version. The initramfs is built without the modules it needs.

**Mitigation**: `migrate.sh` explicitly runs `sudo depmod <kernel-version>` before `sudo mkinitcpio -p linux-cachyos-bore`, ensuring all modules are registered and discoverable before the initramfs is assembled.

---

### scx-* schedulers

**Symptom**: Conflict warnings during migration if `scx-*` packages are already installed.

**Root cause**: `scx` (sched_ext) schedulers conflict with BORE scheduling. Both try to control the kernel scheduler and cannot coexist cleanly.

**Mitigation**: This script does not install any `scx-*` packages. If you have them installed, consider removing them before migration:
```bash
sudo pacman -Rns $(pacman -Qq | grep '^scx-')
```

---

### Hybrid graphics (NVIDIA + Intel laptops)

**Symptom**: The script reports `hybrid:nvidia,intel` during GPU detection. You're unsure whether NVIDIA drivers will work correctly.

**Root cause**: Optimus laptops expose both a discrete NVIDIA GPU and an integrated Intel GPU. The detection logic sees both.

**Mitigation**: The script detects hybrid mode, identifies the NVIDIA GPU, and installs the appropriate driver companion package. Basic NVIDIA functionality works. However, Optimus-specific compositor setup (e.g., `nvidia-prime`, `supergfxctl`, or `envycontrol` configuration) is out of scope for this migration script.

---

### btrfs snapshot vs. ext4 backup

**Symptom**: On ext4, there's no atomic snapshot available before migration. If something goes wrong, recovery requires restoring from a tarball.

**Root cause**: btrfs supports atomic copy-on-write snapshots; ext4 does not. The two filesystems require different backup strategies.

**Mitigation**: On btrfs, if `snapper` is present, `migrate.sh` creates a pre-migration snapshot automatically before making any changes. On ext4, the script creates a tarball backup of key configuration directories instead. The tarball path is printed at the start of the run so you know where to find it.
