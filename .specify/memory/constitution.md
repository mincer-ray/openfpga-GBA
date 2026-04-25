# openfpga-GBA Constitution

## Core Principles

### I. Hardware Behavior Is the Source of Truth

Documentation and future specs must describe observable Analogue Pocket and GBA-core behavior, not just file layout. Any claim about reset timing, memory mapping, save data, RTC handling, video, audio, or bus protocol must be traceable to source files, package metadata, or build scripts.

### II. Preserve Pocket and MiSTer Compatibility Boundaries

Changes must respect both sides of the project: the MiSTer-derived GBA implementation and the Analogue Pocket openFPGA shell. Compatibility-sensitive behavior includes OpenFPGA data-slot addresses, save file sizing, RTC append data, APF command handling, SDRAM/PSRAM arbitration, controller mapping, and generated bitstream naming.

### III. Fit, Timing, and Resource Constraints Are Product Requirements

The Analogue Pocket FPGA is smaller than the MiSTer target, so omitted features and implementation shortcuts must be documented as deliberate constraints. Any feature work must account for Quartus fit, timing closure, SDRAM timing margins, and generated report output.

### IV. Documentation Must Stay Executable Through Spec-Kit

Meaningful architecture changes must update the relevant spec-kit artifacts under `specs/` and the maintained project documentation under `docs/`. Specifications must be concrete enough that an agent or maintainer can trace requirements to implementation files and validation steps.

### V. Minimal, Auditable Changes

Prefer small, source-local changes over broad rewrites. For hardware logic, avoid compatibility shims unless required by shipped save data, OpenFPGA metadata, Pocket framework behavior, or existing ROM compatibility.

## Project Constraints

The target platform is Analogue Pocket openFPGA using Cyclone V device `5CEBA4F23C8`. The build flow is Quartus 21.1 via Docker image `raetro/quartus:21.1`, with raw `ap_core.rbf` converted to Pocket `bitstream.rbf_r` by reversing bit order within each byte.

The packaged core must keep OpenFPGA metadata and RTL bridge addresses in sync. ROM data uses `0x10000000`, save data uses `0x20000000`, BIOS data uses `0x30000000`, save states use `0x40000000`, APF host commands use `0xF8xxxxxx`, and interact menu writes use their documented addresses.

The core intentionally excludes link cable, gyroscope, solar sensor, cheats, rewind, and non-default color correction. Documentation must not imply these are implemented.

## Development Workflow

Use spec-kit for durable project knowledge. For new capabilities, create or update a numbered spec directory with `spec.md`, `plan.md`, validation notes, and task breakdowns as appropriate. For brownfield documentation, keep `docs/ARCHITECTURE.md` synchronized with the relevant source and package files.

Validation for logic changes should include at least a Quartus build or a documented reason it could not be run. Documentation-only changes should be reviewed for internal link/path accuracy and consistency with current source files.

## Governance

This constitution governs spec-kit artifacts and maintenance documentation for this repository. Amendments must update this file, note the changed principle or constraint, and adjust active specs if they conflict.

**Version**: 1.0.0 | **Ratified**: 2026-04-25 | **Last Amended**: 2026-04-25
