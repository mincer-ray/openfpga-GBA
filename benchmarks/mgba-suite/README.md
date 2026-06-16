# mGBA Suite Pocket Benchmark Workflow

This directory contains the reproducible pieces for the save-file benchmark
path described in `debug.md`.

## Upstream Reference

The upstream suite is kept outside this repository's tracked tree:

```bash
mkdir -p reference/repos
git clone https://github.com/mgba-emu/suite.git reference/repos/mgba-suite
git -C reference/repos/mgba-suite checkout 2a8eca19d896720cfcd6a2da400f7ab722ddd60c
```

Apply the autorun/report patch:

```bash
git -C reference/repos/mgba-suite apply ../../../benchmarks/mgba-suite/mgba-suite-bench.patch
```

In this workspace the clone already lives at `reference/repos/mgba-suite` and
has this patch applied in its working tree.

## Build Autorun ROM With Docker

Docker is the simplest path because the upstream suite builds cleanly in
`devkitpro/devkitarm`:

```bash
./scripts/build_mgba_bench_rom.sh
```

The script clones the suite if needed, applies `mgba-suite-bench.patch` if it is
not already applied, builds with `BENCH_AUTORUN=1`, and writes:

```text
build_output/mgba-suite/suite-bench.gba
```

Override the image if needed:

```bash
MGBA_BENCH_DOCKER_IMAGE=devkitpro/devkitarm ./scripts/build_mgba_bench_rom.sh
```

## Build Autorun ROM Locally

The suite uses devkitARM/libgba. From the upstream clone:

```bash
cd reference/repos/mgba-suite
make clean
make BENCH_AUTORUN=1 BENCH_SUITE_COMMIT="$(git rev-parse HEAD)"
```

The output ROM is `reference/repos/mgba-suite/suite.gba`.

## Regenerate Test Manifest

`test-manifest.json` is used by the parser to rehydrate suite and test names
from the compact save bitsets. Regenerate it only when changing the upstream
suite checkout or suite patch in a way that changes test ordering:

```bash
python3 scripts/generate_mgba_suite_manifest.py
```

## Run On Pocket

1. Copy `suite.gba` to the Pocket SD card where the GBA core can launch it.
2. Boot it with the current GBA core.
3. Wait for the screen to show `Benchmark report ready`.
4. Exit the core cleanly so the normal Save data slot is unloaded.
5. Copy the generated `.sav` for the ROM back to the workstation.

No FPGA changes or sidecar data slot are required for this path.

## Report Format

The patched ROM writes a 64 KB SRAM save with this header:

```text
0x0000  16 bytes  "GBA_BENCH_V1" plus NUL padding
0x0010   4 bytes  Payload length, little endian
0x0014   4 bytes  CRC32 of payload
0x0018   4 bytes  Flags, bit 0 means truncated
0x001C   4 bytes  Payload offset, currently 0x20
0x0020   N bytes  Newline-delimited compact records
```

The payload records include:

- `m 4 mgba-suite-pocket-save <suite_commit>`: schema, format name, and
  upstream suite commit.
- `s <suite_id> <test_count> <passes> <total> <pass_bitset_hex>`: per-suite
  test pass bitset plus suite pass totals. Each hex nibble stores four tests,
  least-significant bit first, where `1` means that test passed.
- `f <suite_id> <test_id> <subtest_id> <message>`: compact failure detail from
  `savprintf()`, preserving expected/actual text such as
  `Got 0x00000000 vs 0xFFFFFFFF: FAIL`.
- `t <passes> <total> <truncated>`: aggregate pass totals and truncation flag.
- `d`: completion marker.

Passing subtests are not logged one by one. The parser rehydrates suite and test
names from `test-manifest.json`, uses the bitsets to recover the full failed
test list, and keeps the compact `f` rows for the diagnostic expected/actual
data that matters when a test fails. The ROM buffers the report in EWRAM while
tests run, reserves tail space for suite totals and the final marker, then
byte-writes the finished report into SRAM so the Pocket save file contains clean
contiguous bytes.

## Parse Results

Structured autorun report:

```bash
python3 scripts/parse_mgba_bench_save.py /path/to/suite.sav
python3 scripts/parse_mgba_bench_save.py /path/to/suite.sav --json > build_output/mgba-suite/latest.json
python3 scripts/parse_mgba_bench_save.py /path/to/suite.sav --csv > build_output/mgba-suite/latest-failures.csv
```

The parser exits nonzero if the header, CRC, compact payload, truncation flag, or
completion marker indicates an incomplete/corrupt report. Use
`--allow-incomplete` when inspecting a partial run.
