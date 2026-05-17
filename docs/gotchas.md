# Known Gotchas and Operational Caveats

This document covers known edge cases, failure modes, and their mitigations. Each entry describes what you'll see when something goes wrong, why it happens, how the scripts defend against it, and what to do if the automated mitigation fails.

---

## Metis High-Risk Items

### R6: omarchy-update overwrites pacman.conf

**Symptom**: After running `omarchy-update`, CachyOS repos disappear from `pacman.conf`. Package installs fail with "repository not found" or packages resolve to Arch versions instead of CachyOS-optimized builds.

**Root cause**: `omarchy-update` regenerates `pacman.conf` from a template, removing any custom repo blocks that were appended after the initial Omarchy install.

**Mitigation**: This project installs a pacman hook at `/etc/pacman.d/hooks/zz-cachyos-conf-restore.hook`. The hook fires after any transaction that touches `pacman.conf` and re-inserts the CachyOS repo blocks automatically.

**Manual fix**: If the hook is missing or fails, run:
```bash
sudo bash /usr/local/lib/cachyos-on-omarchy/pacman-hook-restore.sh
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
