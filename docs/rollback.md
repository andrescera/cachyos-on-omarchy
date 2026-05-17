# Rollback Guide

This guide covers all rollback scenarios for the cachyos-on-omarchy migration.

**System:** andres @ Omarchy/Arch Linux (Hyprland)
**Migration date:** 2026-05-07
**GPU:** RTX 4080, driver 595.71.05 (open modules)
**Boot:** Limine UKI mode

---

## Backup Inventory

Before touching anything, confirm your backups are intact.

```bash
# Verify the pre-migration tarball exists
ls -lh /var/backups/migration-pre-W0-20260507-184104.tar.zst

# Verify SHA256 checksum
sha256sum /var/backups/migration-pre-W0-20260507-184104.tar.zst
# Expected: f1940e3ad87beb2f125f386db4d0adb4a0456743beb2c137351e7289d42cfbab

# Verify UKI snapshot directory
ls /var/backups/migration-pre-W0-uki-snapshot-20260507-184104/

# Verify pacman.conf backups
ls -la /etc/pacman.conf.bak.20260507-190508
ls -la /etc/pacman.conf.bak.arch-fix.*
```

### Available Kernels

| Kernel | Version | UKI |
|--------|---------|-----|
| linux | 7.0.3-arch1-2 | omarchy_linux.efi |
| linux-lts | 6.18.26-2 | omarchy_linux-lts.efi |
| linux-cachyos-bore | 7.0.3-1-cachyos-bore | omarchy_linux-cachyos-bore.efi |

### Key Files

- **Restore script:** `/usr/local/bin/cachyos-pacman-conf-restore.sh`
- **pacman.conf backup (post-arch-fix):** `/etc/pacman.conf.bak.20260507-190508`
- **pacman.conf backup (arch-fix variant):** `/etc/pacman.conf.bak.arch-fix.*`
- **Backup tarball:** `/var/backups/migration-pre-W0-20260507-184104.tar.zst`

---

## Decision Tree

Which scenario do you need?

```
Something broke after migration?
│
├─ System won't boot at all?
│   └─ → Scenario 5 (Emergency boot recovery)
│
├─ Want to undo everything completely?
│   └─ → Scenario 1 (Full rollback — manual)
│
├─ Kernel issues but repos are fine?
│   └─ → Scenario 2 (Kernel only)
│
├─ Repo conflicts / package issues?
│   └─ → Scenario 3 (Repos only)
│
└─ Performance tuning causing issues?
    └─ → Scenario 4 (Settings only)
```

---

## Scenario 1: Full Rollback ⚠️ MANUAL ONLY

> **Warning:** Scenario 1 is complex and destructive. Use scenarios 2-4 first unless you need a complete reset. Consider a fresh Omarchy reinstall instead if you want a truly clean slate.

**When to use:** You want to completely undo the CachyOS migration and return to a clean Arch Linux state. Use this if multiple things are broken or you just want a clean slate.

**Estimated time:** 20-40 minutes
**Risk level:** Low (you have verified backups)
**Filesystem note:** ext4+LUKS, no btrfs snapshots available. This rollback uses the tarball backup.

### Step 1: Boot into a working kernel

If your current default kernel boots fine, proceed. If not, go to Scenario 5 first to get a working system, then come back here.

```bash
# Confirm you're running something bootable
uname -r
```

### Step 2: Remove CachyOS kernel and packages

```bash
# Remove the CachyOS kernel
sudo pacman -Rns linux-cachyos-bore linux-cachyos-bore-headers

# Remove CachyOS settings package
sudo pacman -Rns cachyos-settings

# Remove ananicy-cpp if it was pulled in by cachyos-settings
sudo pacman -Rns ananicy-cpp ananicy-rules-cachyos 2>/dev/null || true
```

**Expected output:** pacman will list the packages being removed and ask for confirmation. Type `y`.

**If this fails:** A package may have dependents. Run `pacman -Qi linux-cachyos-bore` to see what depends on it, then remove those first.

### Step 3: Restore pacman.conf from backup

```bash
# Back up the current (CachyOS) pacman.conf first
sudo cp /etc/pacman.conf /etc/pacman.conf.bak.before-rollback

# Restore the pre-migration backup
sudo cp /etc/pacman.conf.bak.20260507-190508 /etc/pacman.conf

# Verify the CachyOS repos are gone
grep -E '^\[cachyos' /etc/pacman.conf
# Expected: no output (no CachyOS repo sections)

# Verify Architecture line is correct
grep '^Architecture' /etc/pacman.conf
# Expected: Architecture = auto
```

**If the grep shows CachyOS repos still present:** The wrong backup was restored. Try:
```bash
sudo cp /etc/pacman.conf.bak.arch-fix.* /etc/pacman.conf
# Then re-check with grep above
```

### Step 4: Remove CachyOS keyring and mirrorlist

```bash
# Remove CachyOS keyring
sudo pacman -Rns cachyos-keyring 2>/dev/null || true

# Remove CachyOS mirrorlist
sudo pacman -Rns cachyos-mirrorlist 2>/dev/null || true

# Remove any remaining CachyOS-specific packages
sudo pacman -Rns cachyos-rate-mirrors 2>/dev/null || true
```

### Step 5: Refresh package databases

```bash
# Sync with Arch repos only
sudo pacman -Syy

# Verify only Arch repos are active
sudo pacman -Sl | grep -c cachyos
# Expected: 0
```

**If pacman -Syy fails with keyring errors:**
```bash
sudo pacman -S --noconfirm archlinux-keyring
sudo pacman -Syy
```

### Step 6: Revert sysctl settings

```bash
# Check if CachyOS sysctl file exists
ls /etc/sysctl.d/ | grep cachyos

# Remove it if present
sudo rm -f /etc/sysctl.d/99-cachyos-settings.conf

# Reload sysctl
sudo sysctl --system
```

### Step 7: Disable and remove zram if it was added by cachyos-settings

```bash
# Check if zram service is active
systemctl is-active systemd-zram-setup@zram0

# If active, disable it
sudo systemctl disable --now systemd-zram-setup@zram0

# Remove zram config if present
sudo rm -f /etc/systemd/zram-generator.conf
```

### Step 8: Disable ananicy-cpp

```bash
sudo systemctl disable --now ananicy-cpp 2>/dev/null || true
```

### Step 9: Rebuild UKIs and update bootloader

```bash
# Regenerate UKIs for remaining kernels
sudo mkinitcpio -P

# Update Limine bootloader entries
# (Limine reads UKIs from /efi/EFI/Linux/ — rebuilding mkinitcpio handles this)
ls /efi/EFI/Linux/
# Should show omarchy_linux.efi and omarchy_linux-lts.efi
# omarchy_linux-cachyos-bore.efi should be gone
```

**If omarchy_linux-cachyos-bore.efi is still present:**
```bash
sudo rm /efi/EFI/Linux/omarchy_linux-cachyos-bore.efi
```

### Step 10: Reboot and verify

```bash
sudo reboot
```

After reboot:
```bash
# Confirm you're on a standard Arch kernel
uname -r
# Expected: 7.0.3-arch1-2 or 6.18.26-2

# Confirm no CachyOS repos
pacman -Sl | grep cachyos
# Expected: no output

# Confirm CachyOS kernel is gone
pacman -Q linux-cachyos-bore 2>&1
# Expected: error: package 'linux-cachyos-bore' was not found
```

---

## Scenario 2: Kernel Only

**Automated (recommended):**
```bash
./rollback.sh --scenario 2 --dry-run  # preview first
./rollback.sh --scenario 2
```

**When to use:** The linux-cachyos-bore kernel is causing problems (crashes, driver issues, incompatibilities) but you want to keep the CachyOS repos for their x86-64-v3 optimized packages.

**Estimated time:** 10-15 minutes
**Risk level:** Low

**Manual (if automation fails):**

### Step 1: Remove the CachyOS kernel

```bash
sudo pacman -Rns linux-cachyos-bore linux-cachyos-bore-headers
```

**Expected output:** pacman removes the kernel and headers, asks for confirmation.

**If headers aren't installed:**
```bash
sudo pacman -Rns linux-cachyos-bore
```

### Step 2: Remove the UKI

```bash
# Verify the UKI exists
ls -lh /efi/EFI/Linux/omarchy_linux-cachyos-bore.efi

# Remove it
sudo rm /efi/EFI/Linux/omarchy_linux-cachyos-bore.efi

# Confirm it's gone
ls /efi/EFI/Linux/
# Should show only omarchy_linux.efi and omarchy_linux-lts.efi
```

### Step 3: Verify remaining kernels are intact

```bash
# Check both kernels are installed
pacman -Q linux linux-lts
# Expected: linux 7.0.3-arch1-2 and linux-lts 6.18.26-2

# Verify their UKIs exist
ls -lh /efi/EFI/Linux/omarchy_linux.efi
ls -lh /efi/EFI/Linux/omarchy_linux-lts.efi
```

### Step 4: Reboot

```bash
sudo reboot
```

After reboot:
```bash
uname -r
# Expected: 7.0.3-arch1-2 (or whichever is your default)

# CachyOS repos should still be active
pacman -Sl cachyos | head -5
```

**If the system boots to linux-cachyos-bore anyway:** The Limine config may still reference it. Check:
```bash
cat /efi/limine.conf 2>/dev/null || cat /boot/limine.conf 2>/dev/null
```
Remove any entry pointing to the deleted UKI.

---

## Scenario 3: Repos Only

**Automated (recommended):**
```bash
./rollback.sh --scenario 3 --dry-run  # preview first
./rollback.sh --scenario 3
```

**When to use:** You want to remove the CachyOS repositories (package conflicts, trust concerns, wanting pure Arch packages) but keep the linux-cachyos-bore kernel running.

**Estimated time:** 15-20 minutes
**Risk level:** Medium (some packages may have been upgraded to CachyOS versions)

**Manual (if automation fails):**

### Step 1: Restore pacman.conf without CachyOS repos

```bash
# Back up current state
sudo cp /etc/pacman.conf /etc/pacman.conf.bak.before-repo-rollback

# Restore the pre-migration backup
sudo cp /etc/pacman.conf.bak.20260507-190508 /etc/pacman.conf

# Verify CachyOS repos are gone
grep -E '^\[cachyos' /etc/pacman.conf
# Expected: no output

# Verify Architecture line
grep '^Architecture' /etc/pacman.conf
# Expected: Architecture = auto
```

### Step 2: Remove CachyOS keyring and mirrorlist packages

```bash
sudo pacman -Rns cachyos-keyring cachyos-mirrorlist 2>/dev/null || true
```

### Step 3: Refresh databases

```bash
sudo pacman -Syy
```

**If this fails with signature errors:**
```bash
sudo pacman -S --noconfirm archlinux-keyring
sudo pacman -Syy
```

### Step 4: Downgrade any packages that were upgraded from CachyOS repos

This step identifies packages currently installed from CachyOS that now have no repo source:

```bash
# Find packages with no known repo (orphaned from removed repos)
pacman -Qm | head -20
```

For any critical system packages showing up here, downgrade them:
```bash
# Example: if mesa was upgraded from CachyOS
sudo pacman -S mesa
```

### Step 5: Verify

```bash
# Confirm only Arch repos active
pacman -Sl | grep -c cachyos
# Expected: 0

# Confirm kernel still running
uname -r
# Expected: 7.0.3-1-cachyos-bore (kernel unchanged)
```

---

## Scenario 4: Settings Only

**Automated (recommended):**
```bash
./rollback.sh --scenario 4 --dry-run  # preview first
./rollback.sh --scenario 4
```

**When to use:** The cachyos-settings package is causing issues (unexpected sysctl values, I/O scheduler changes, ananicy-cpp conflicts) but you want to keep the kernel and repos.

**Estimated time:** 5-10 minutes
**Risk level:** Low

**Manual (if automation fails):**

### Step 1: Remove cachyos-settings

```bash
sudo pacman -Rns cachyos-settings
```

**Expected output:** pacman removes cachyos-settings and asks for confirmation.

**If it has dependents:**
```bash
pacman -Qi cachyos-settings | grep 'Required By'
# Remove those packages first, then retry
```

### Step 2: Remove ananicy-cpp

```bash
sudo systemctl disable --now ananicy-cpp
sudo pacman -Rns ananicy-cpp ananicy-rules-cachyos 2>/dev/null || true
```

### Step 3: Remove zram configuration

```bash
# Disable zram service
sudo systemctl disable --now systemd-zram-setup@zram0

# Remove zram generator config
sudo rm -f /etc/systemd/zram-generator.conf

# Verify zram is gone
lsblk | grep zram
# Expected: no output after next reboot
```

### Step 4: Revert sysctl settings

```bash
# Find CachyOS sysctl files
ls /etc/sysctl.d/ | grep -i cachy

# Remove them
sudo rm -f /etc/sysctl.d/99-cachyos-settings.conf

# Reload
sudo sysctl --system

# Verify swappiness is back to default
sysctl vm.swappiness
# Expected: vm.swappiness = 60 (Arch default)
```

### Step 5: Revert I/O scheduler changes

```bash
# Check for udev rules set by cachyos-settings
ls /etc/udev/rules.d/ | grep -i cachy

# Remove if present
sudo rm -f /etc/udev/rules.d/60-cachyos-io-scheduler.rules

# Reload udev rules
sudo udevadm control --reload-rules
sudo udevadm trigger
```

### Step 6: Verify

```bash
# Confirm cachyos-settings is gone
pacman -Q cachyos-settings 2>&1
# Expected: error: package 'cachyos-settings' was not found

# Confirm ananicy-cpp is stopped
systemctl is-active ananicy-cpp
# Expected: inactive

# Confirm swappiness
sysctl vm.swappiness
# Expected: vm.swappiness = 60
```

---

## Scenario 5: Emergency Boot Recovery

**Automated (recommended, run from fallback kernel):**
```bash
./rollback.sh --scenario 5 --dry-run  # preview first
./rollback.sh --scenario 5
```

> **Note:** This scenario must be run from the fallback kernel (linux-lts). Boot into it first via the Limine menu before running any commands.

**When to use:** The system fails to boot with linux-cachyos-bore (kernel panic, black screen, NVIDIA driver crash, initramfs error). You need to get back into the system using linux-lts, then decide whether to fix or revert.

**Estimated time:** 5 minutes to get running, then varies

**Manual (if automation fails):**

### Step 1: Boot into linux-lts via Limine

At the Limine boot menu, select the entry for `omarchy_linux-lts.efi`.

If Limine doesn't show a menu (boots straight to the broken kernel), interrupt the boot:
- Hold a key during POST to get to Limine menu, or
- If Limine has a timeout of 0, you may need to boot from a USB and edit the Limine config

### Step 2: Verify you're on linux-lts

```bash
uname -r
# Expected: 6.18.26-2
```

### Step 3: Diagnose the boot failure

```bash
# Check journal from the failed boot attempt
journalctl -b -1 -p err | tail -50

# Check for NVIDIA-specific errors
journalctl -b -1 | grep -i nvidia | tail -20

# Check for initramfs errors
journalctl -b -1 | grep -i "initramfs\|mkinitcpio" | tail -20
```

### Step 4a: Fix path — Rebuild the CachyOS kernel's initramfs

If the issue is a corrupted or outdated initramfs:

```bash
# Rebuild only the cachyos-bore preset
sudo mkinitcpio -p linux-cachyos-bore

# Verify the UKI was regenerated
ls -lh /efi/EFI/Linux/omarchy_linux-cachyos-bore.efi

# Reboot and try linux-cachyos-bore again
sudo reboot
```

### Step 4b: Fix path — Reinstall the CachyOS kernel

If the kernel itself is corrupted:

```bash
sudo pacman -S linux-cachyos-bore linux-cachyos-bore-headers
sudo mkinitcpio -p linux-cachyos-bore
sudo reboot
```

### Step 4c: Revert path — Remove linux-cachyos-bore entirely

If you can't fix it or don't want to:

```bash
# Remove the kernel
sudo pacman -Rns linux-cachyos-bore linux-cachyos-bore-headers

# Remove the UKI
sudo rm -f /efi/EFI/Linux/omarchy_linux-cachyos-bore.efi

# Verify remaining kernels
ls /efi/EFI/Linux/
# Expected: omarchy_linux.efi and omarchy_linux-lts.efi only

sudo reboot
```

### Step 5: Make linux-lts the default (if staying on it long-term)

If you're keeping linux-lts as your primary kernel, check your Limine config to ensure it's listed first:

```bash
cat /efi/limine.conf 2>/dev/null || cat /boot/limine.conf 2>/dev/null | grep -A3 'linux-lts'
```

The first `PROTOCOL` entry in limine.conf is the default. Move the linux-lts entry to the top if needed.

---

## Troubleshooting: What if rollback.sh fails?

### Find and use the backup tarball manually

The pre-migration tarball lives at:
```
/var/backups/migration-pre-W0-20260507-184104.tar.zst
```

List its contents:
```bash
sudo tar -tvf /var/backups/migration-pre-W0-20260507-184104.tar.zst | less
```

Extract a specific file (example: `/etc/pacman.conf`):
```bash
sudo tar -xvf /var/backups/migration-pre-W0-20260507-184104.tar.zst \
  -C /tmp \
  --strip-components=1 \
  etc/pacman.conf

# The file lands at /tmp/etc/pacman.conf
ls /tmp/etc/pacman.conf
```

If `tar` can't handle zstd compression, install it first:
```bash
sudo pacman -S zstd
```

### Restore UKIs from snapshot

If a UKI was accidentally deleted or corrupted:
```bash
# List the UKI snapshot
ls /var/backups/migration-pre-W0-uki-snapshot-20260507-184104/

# Restore a specific UKI (example: linux-lts)
sudo cp /var/backups/migration-pre-W0-uki-snapshot-20260507-184104/omarchy_linux-lts.efi \
  /efi/EFI/Linux/omarchy_linux-lts.efi

# Verify
ls -lh /efi/EFI/Linux/
```

### Restore pacman.conf manually

If the automated restore script fails or you need fine-grained control:

```bash
# View the restore script
cat /usr/local/bin/cachyos-pacman-conf-restore.sh

# Run it
sudo /usr/local/bin/cachyos-pacman-conf-restore.sh

# Or manually diff and merge
diff /etc/pacman.conf.bak.20260507-190508 /etc/pacman.conf
```

Key differences between pre- and post-migration `pacman.conf`:

1. **Architecture line:** Pre-migration was `Architecture = auto`. Post-migration is `Architecture = auto x86_64 x86_64_v3`.
2. **CachyOS repo sections:** Post-migration has `[cachyos]`, `[cachyos-extra]`, etc. sections.
3. **IgnorePkg:** Post-migration adds `walker walker-bin elephant elephant-files` to prevent CachyOS from overwriting Omarchy-managed packages.

To revert to pure Arch, restore the backup and ensure Architecture reads `Architecture = auto`.

### Common rollback.sh error scenarios

**"backup tarball not found"**
The script expects the tarball at the hardcoded path. Verify it exists:
```bash
ls -lh /var/backups/migration-pre-W0-20260507-184104.tar.zst
```
If it's been moved, pass the path explicitly or use the manual steps above.

**"pacman: command failed"**
Usually a keyring issue. Fix it:
```bash
sudo pacman -S --noconfirm archlinux-keyring
sudo pacman -Syy
```
Then re-run the script or continue with manual steps.

**"mkinitcpio preset not found"**
The kernel package was already removed but the script is trying to rebuild it. Skip that step and proceed manually from the next step in the relevant scenario above.

**Script exits partway through**
Check the exit code and last output line. Each scenario's manual steps above map directly to what the script does, so you can pick up from where it stopped.

---

## Post-Rollback Checklist

After any rollback scenario, run through this:

```bash
# 1. Correct kernel running
uname -r

# 2. Pacman databases healthy
sudo pacman -Syy

# 3. No broken packages
sudo pacman -Dk

# 4. NVIDIA driver loaded
lsmod | grep nvidia

# 5. Hyprland starts (if testing from TTY)
# Just check the service/session is available, don't need to restart

# 6. Network up
ping -c 2 archlinux.org

# 7. Disk not full (rollback can temporarily use extra space)
df -h /
```

---

## Getting Help

If you're stuck:

- **Arch Wiki — Pacman:** https://wiki.archlinux.org/title/Pacman
- **Arch Wiki — Mkinitcpio:** https://wiki.archlinux.org/title/Mkinitcpio
- **CachyOS Wiki:** https://wiki.cachyos.org
- **Omarchy source:** `~/.local/share/omarchy/`

For NVIDIA-specific boot failures:
```bash
journalctl -b -1 | grep -iE "nvidia|drm|modeset" | tail -30
```
