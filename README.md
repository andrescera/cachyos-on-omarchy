# cachyos-on-omarchy

> Layer CachyOS optimizations onto your Omarchy installation — safely, reversibly, with autodetection.

## What this does

Adds to your existing Omarchy setup:
- **CachyOS package repositories** with x86-64-v3 optimized packages (if your CPU supports it)
- **linux-cachyos-bore kernel** — the BORE (Burst-Oriented Response Enhancer) scheduler kernel
- **Automatic NVIDIA companion** — detects your GPU generation and installs the matching driver companion (RTX 20xx+: nvidia-open; GTX 10xx/900: 580xx-dkms; GTX 700: 470xx-dkms; Kepler/older: nouveau)
- **cachyos-settings** — Ananicy-CPP process scheduler, zram swap, tuned sysctl values, IO scheduler optimization
- A **pacman hook** that auto-restores CachyOS repo blocks if `omarchy-update` overwrites `pacman.conf`

Your Omarchy desktop, display server, and shell remain intact.

## What this does NOT do

- Does **not** install or reinstall Omarchy itself
- Does **not** install a display manager or modify login flow
- Does **not** replace your shell (fish/bash) or install paru
- Does **not** install cachyos-hyprland-settings, cachyos-fish-config, or cachyos-zsh-config (incompatible with Omarchy)
- Does **not** install scx-* schedulers, tealdeer, or other optional CachyOS packages
- Does **not** touch your home directory or user data
- Does **not** support GRUB, systemd-boot, or non-UKI Limine (hard requirement: Limine + `ENABLE_UKI=yes`)
- Does **not** support btrfs snapshots unless `snapper` is already configured
- Does **not** work on ARM or non-x86_64 architectures

## Prerequisites

- **Omarchy** >= 3.0 installed and working
- **Limine** bootloader (Omarchy's default)
- **UKI mode** enabled (`ENABLE_UKI=yes` in `/etc/default/limine`)
- **Root filesystem**: btrfs or ext4
- **Disk space**: >= 4 GB free on `/`, >= 500 MB free on `/boot`
- **Internet access** to `mirror.cachyos.org`
- Running as **non-root user** with sudo access

## Usage

```bash
# 1. Clone the repository
git clone https://github.com/andrescera/cachyos-on-omarchy.git
cd cachyos-on-omarchy

# 2. Read the code first (recommended)
less migrate.sh
less lib/preflight.sh

# 3. Dry-run to preview what will happen
./migrate.sh --dry-run

# 4. Run the migration
./migrate.sh

# 5. Reboot when prompted, then verify
./migrate.sh --verify
```

## Rollback

If something goes wrong, use the rollback script:

```bash
# List all rollback scenarios
./rollback.sh --list

# Preview a rollback (no changes)
./rollback.sh --scenario 2 --dry-run

# Execute a rollback
./rollback.sh --scenario 2
```

See [docs/rollback.md](docs/rollback.md) for full scenario documentation.

## All flags

### migrate.sh

| Flag | Description |
|---|---|
| `--dry-run` | Preview what would happen without making any changes |
| `--help` | Show usage |
| `--resume PHASE` | Resume from a specific phase: `preflight`, `repos`, `kernel`, `settings`, `verify` |
| `--version` | Show version |
| `--verify` | Run post-reboot verification (Tollgate 3) |

### rollback.sh

| Flag | Description |
|---|---|
| `--scenario N` | Run rollback scenario N (2-5). Scenario 1 is manual. |
| `--dry-run` | Preview rollback actions without making any changes |
| `--help` | Show usage |
| `--list` | List all rollback scenarios with descriptions |

## Known limitations

- **CachyOS package name drift**: CachyOS occasionally renames or reorganizes packages. If a package name in this script becomes stale, the migration will abort with a clear error.
- **Unknown GPU**: If your GPU's PCI device ID is not in the lookup table, NO NVIDIA driver is installed (safe failure). Install manually if needed.
- **Single-kernel safety**: This script does not install a fallback kernel. Consider installing `linux` or `linux-lts` alongside `linux-cachyos-bore` as a fallback.
- **No ARM support**: x86_64 only.
- **Only btrfs and ext4**: Other root filesystems are not supported and will abort in preflight.

## License

MIT — see [LICENSE](LICENSE)

## Disclaimer

> **This is community/unofficial software.** It is not affiliated with, endorsed by, or supported by the CachyOS or Omarchy projects.
>
> **Use at your own risk.** Installing a new bootloader-integrated kernel is a potentially system-altering operation. Always have working backups and a rescue medium. The authors are not responsible for data loss, unbootable systems, or any other damage resulting from the use of this software.
>
> Always run `./migrate.sh --dry-run` first and review the output before running the actual migration.
