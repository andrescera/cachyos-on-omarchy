# Pre-Release Validation Checklist

Complete ALL items before publishing a release.

## Static Analysis
- [ ] `shellcheck -x migrate.sh rollback.sh lib/*.sh` returns 0 warnings
- [ ] `bash -n migrate.sh rollback.sh lib/*.sh` returns exit 0
- [ ] `shellcheck tests/run.sh` returns 0

## Unit Tests
- [ ] `bats tests/` passes all 63+ tests, 0 failures
- [ ] Every fixture file in tests/fixtures/ is referenced by at least one test

## Integration Testing (this machine)
- [ ] `./migrate.sh --dry-run` exits 0 and detects: NVIDIA Ada, x86_64-v3, ext4, limine+UKI
- [ ] `./migrate.sh --dry-run` makes NO state changes (md5sum /etc/pacman.conf /boot/limine.conf unchanged)
- [ ] `./migrate.sh --help` documents every flag listed by --help output
- [ ] `./rollback.sh --scenario 2 --dry-run` exits 0 on this machine
- [ ] `./rollback.sh --scenario 5 --dry-run` exits 1 when running cachyos-bore (self-protection)

## Multi-Hardware Testing (manual, VM matrix)
- [ ] Tested on real Omarchy install with **btrfs** root filesystem
- [ ] Tested on real Omarchy install with **ext4** root filesystem
- [ ] At least 2 rollback scenarios tested in a VM (scenarios 2 and 4 recommended)
- [ ] VM matrix tested: btrfs+NVIDIA, btrfs+AMD, ext4+NVIDIA, ext4+Intel

## Documentation
- [ ] README.md contains all flags listed by `--help` for both scripts
- [ ] docs/rollback.md covers all 5 scenarios (1=manual, 2-5=automated)
- [ ] docs/gotchas.md covers all 8 Metis HIGH risks (R6-R13)
- [ ] Disclaimer is present in README.md

## Repository
- [ ] LICENSE file present with MIT text
- [ ] `git status` shows clean working tree before release
- [ ] GitHub repo is public (`gh repo view --json visibility`)
- [ ] Public GitHub repo explicitly approved by repository owner

---

## Appendix: Verification Commands

### shellcheck
```bash
cd ~/projects/cachyos-on-omarchy
shellcheck -x migrate.sh rollback.sh lib/*.sh
bash -n migrate.sh rollback.sh lib/*.sh
shellcheck tests/run.sh
```

### bats
```bash
bats tests/*.bats
# Expected: 63+ tests, 0 failures
```

### Integration smoke
```bash
BEFORE=$(md5sum /etc/pacman.conf /boot/limine.conf)
./migrate.sh --dry-run
AFTER=$(md5sum /etc/pacman.conf /boot/limine.conf)
diff <(echo "$BEFORE") <(echo "$AFTER")  # should be empty

./rollback.sh --list
./rollback.sh --scenario 2 --dry-run
./rollback.sh --scenario 5 --dry-run; echo "Exit: $?"  # should be 1 while on cachyos-bore
```

### Documentation checks
```bash
# All flags in README
for flag in $(./migrate.sh --help | grep -oE -- '--[a-z-]+' | sort -u); do
  grep -q -- "$flag" README.md && echo "✓ $flag" || echo "✗ MISSING $flag"
done

# Rollback scenarios
grep -cE '^## Scenario [1-5]' docs/rollback.md  # → 5

# Gotchas coverage
for risk in R6 R7 R8 R9 R10 R11 R12 R13; do
  grep -q "$risk" docs/gotchas.md && echo "✓ $risk" || echo "✗ MISSING $risk"
done

# License
grep -q 'MIT' LICENSE && echo "✓ MIT license present"
```

### Repository checks
```bash
git status  # → clean working tree
gh repo view andrescera/cachyos-on-omarchy --json visibility --jq .visibility  # → PUBLIC
```
