# Quickstart: Maintaining Architecture Documentation

## Read the Current Architecture

Start with `docs/ARCHITECTURE.md`. Use it as the source map for the repo before editing RTL, scripts, or package metadata.

## Use Spec-Kit for Future Documentation Changes

1. Review `.specify/memory/constitution.md` for project documentation principles.
2. For a new behavior or architecture change, create or update a numbered directory under `specs/`.
3. Keep requirements in `spec.md`, implementation approach in `plan.md`, and concrete follow-up work in `tasks.md`.
4. Update `docs/ARCHITECTURE.md` when behavior, file ownership, build outputs, or package metadata changes.

## Validate Documentation-Only Changes

1. Check that every behavior claim points to current files or metadata.
2. Confirm generated artifacts are described as generated, not checked-in, unless they exist in the tree.
3. Confirm omitted features remain listed accurately.
4. Run `git status --short` to review added or changed files.

## Validate RTL or Build Changes

1. Run `./scripts/build.sh` when Docker and `raetro/quartus:21.1` are available.
2. Review `src/fpga/build/output_files/ap_core.sta.summary` and `build_output/reports/`.
3. Confirm `pkg/Cores/mincer_ray.GBA/bitstream.rbf_r` was regenerated from `ap_core.rbf` by `scripts/reverse_bitstream.py`.
4. Update documentation if bridge addresses, save sizes, memory arbitration, clocks, or package metadata changed.
