#!/bin/bash
set -euo pipefail

# Generate the UKI fixture files for verify-uki.sh tests.
#
# Each file is exactly 60 MB of zero bytes so that:
#   - Check 1's 50 MB minimum-size guard passes.
#   - The sha512 is reproducible across machines, so it can be baked into
#     `tests/fixtures/limine-conf/valid-with-bore.conf` and matched by
#     `verify_uki_safety`'s Check 3.
#
# Expected sha512 of every generated file:
#   4e1785ba884f01349c66c82c5f3b72b5c216d26a2d598e9689f47e0214358228b6d2ba7d06873c8004e76545ad8cec41f09159ad3400fae6544390acb9f5c5e0
#
# Re-run after a fresh clone or whenever the fixture .efi files are missing.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for name in test_linux-cachyos-bore.efi test_linux.efi; do
  dd if=/dev/zero of="${DIR}/${name}" bs=1M count=60 status=none
  printf '  wrote %s\n' "${DIR}/${name}"
done

printf 'sha512 (must match valid-with-bore.conf):\n'
sha512sum "${DIR}"/*.efi
