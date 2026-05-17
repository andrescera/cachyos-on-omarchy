# cachyos-on-omarchy Test Suite

This directory contains the bats-core test suite for cachyos-on-omarchy.

## Running Tests

```bash
# Run all tests
bash tests/run.sh

# Or directly with bats
bats tests/*.bats

# Run a specific test file
bats tests/detect-gpu.bats
```

## Test Structure

### Test Files

- `detect-gpu.bats` - Tests for GPU detection logic
- `detect-cpu.bats` - Tests for CPU detection logic
- `detect-system.bats` - Tests for system detection logic
- `verify-uki.bats` - Tests for UKI verification logic

### Fixtures

Fixture files are stored in `tests/fixtures/` and organized by the command or file they simulate:

- `fixtures/lspci/` - Mock `lspci` output for GPU detection
- `fixtures/ldso/` - Mock `/etc/ld.so.conf.d/` files for SIMD level detection
- `fixtures/cpuinfo/` - Mock `/proc/cpuinfo` for CPU detection
- `fixtures/findmnt/` - Mock `findmnt` output for mount point detection
- `fixtures/limine-default/` - Mock default limine config
- `fixtures/limine-conf/` - Mock custom limine config

### Test Helpers

The `test_helper.bash` file provides common utilities:

- `assert_eq ACTUAL EXPECTED [MESSAGE]` - Assert equality
- `assert_match ACTUAL PATTERN [MESSAGE]` - Assert regex match
- `load_fixture PATH` - Load a fixture file from `fixtures/`
- `DRY_RUN=1` - Automatically set for all tests (safety mode)
- `PROJECT_ROOT` - Available for sourcing lib files

## Naming Conventions

Test files follow the pattern: `<function>-<case>.bats`

Example: `detect-gpu-nvidia.bats` would test GPU detection for NVIDIA cards.

## Safety

All tests run with `DRY_RUN=1` set automatically by `test_helper.bash`. This ensures that no actual system modifications occur during testing.

## Development

To add new tests:

1. Create a new `.bats` file in `tests/`
2. Add fixture files to `tests/fixtures/<category>/` as needed
3. Use `load_fixture` to load fixture data in tests
4. Use `assert_eq` and `assert_match` for assertions
5. Run `bash tests/run.sh` to verify
