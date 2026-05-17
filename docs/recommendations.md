# Optional Post-Migration Recommendations

These are CachyOS-recommended tweaks that the migration script intentionally does **not** apply automatically because they modify the kernel command line or other invasive boot-time state. Apply them manually if you want a small additional performance bump after a successful migration and reboot.

Each recommendation lists what it does, why CachyOS recommends it, the exact commands to apply it, and how to revert.

---

## R1: Disable kernel zswap (`zswap.enabled=0`)

**What it does**: Disables the kernel's in-RAM compressed swap cache (`zswap`) so the system uses only `zram` for compressed swap.

**Why**: CachyOS ships a `zram-generator.conf` via `cachyos-settings` which configures a `/dev/zram0` block device for compressed swap. With both `zswap` (kernel-level) and `zram` (block-device-level) active, pages get compressed twice or compete for the same pressure-relief role. CachyOS's official recommendation is to disable `zswap` entirely and let `zram` handle compressed swap on its own. The benefit is reduced CPU overhead on memory pressure and more predictable swap behavior under load.

**Applies to**: Every machine that has `cachyos-settings` installed (i.e. every machine this migration script touched), regardless of GPU or CPU.

**How to verify your current state**:

```bash
cat /proc/cmdline | tr ' ' '\n' | grep -E '^zswap' || echo "zswap.enabled NOT set (kernel default: enabled)"
swapon --show
```

If you see `/dev/zram0` in `swapon --show` and `zswap.enabled` is **not** present in `/proc/cmdline`, you have the redundancy this recommendation fixes.

### How to apply

The procedure depends on which bootloader and kernel-image format you use. Omarchy ships **Limine + UKI** by default; the section below covers that case. If you switched to a different setup, adapt accordingly.

#### Limine + UKI (Omarchy default)

The kernel command line for a UKI is baked into the `.efi` image at `mkinitcpio` time. To add `zswap.enabled=0`, append it to the cmdline file that `mkinitcpio` consumes, then regenerate the UKI.

1. **Locate the cmdline source**. Omarchy typically uses `/etc/kernel/cmdline` if present, otherwise the cmdline is composed from `/etc/default/limine` or the mkinitcpio preset. Check both:

   ```bash
   ls -l /etc/kernel/cmdline /etc/default/limine 2>/dev/null
   cat /etc/mkinitcpio.d/linux-cachyos-bore.preset 2>/dev/null
   ```

2. **Back up** the file you will edit:

   ```bash
   sudo cp /etc/kernel/cmdline /etc/kernel/cmdline.bak.$(date +%s)
   ```

3. **Append** `zswap.enabled=0` to the cmdline (single line, space-separated). Example final cmdline:

   ```
   quiet splash cryptdevice=PARTUUID=...:root root=/dev/mapper/root zswap.enabled=0 rw rootfstype=ext4
   ```

4. **Regenerate the UKI**:

   ```bash
   sudo mkinitcpio -p linux-cachyos-bore
   ```

5. **Reboot** and verify:

   ```bash
   grep -o 'zswap.enabled=0' /proc/cmdline && echo "OK: zswap disabled"
   ```

### How to revert

```bash
sudo cp /etc/kernel/cmdline.bak.<timestamp> /etc/kernel/cmdline
sudo mkinitcpio -p linux-cachyos-bore
# reboot
```

### Why this is not automated by `migrate.sh`

Editing the kernel command line is a Tollgate-2-level change: a typo or stray character can render the system unbootable. The script's two existing tollgates (pre-flight checks, post-install UKI verification) do not cover cmdline-content correctness, only file-presence and signature checks. Rather than expand the trust boundary, this recommendation stays manual so the user reviews the exact cmdline string before regenerating the UKI.

---
