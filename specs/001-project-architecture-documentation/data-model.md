# Data Model: Project Architecture Documentation

## Architecture Guide

**Path**: `docs/ARCHITECTURE.md`

**Purpose**: Maintainer-facing source map of the repository.

**Key attributes**:
- Project identity and target hardware.
- Directory layout and ownership.
- OpenFPGA package metadata and bridge addresses.
- Build, CI, release, timing, and generated artifact flows.
- APF shell and `core_top` integration responsibilities.
- Memory, save, RTC, save-state, video, audio, input, and GBA subsystem descriptions.
- Known omissions and implementation caveats.

## Spec-Kit Constitution

**Path**: `.specify/memory/constitution.md`

**Purpose**: Durable rules for future spec and documentation maintenance.

**Key attributes**:
- Source-traceability requirement.
- Pocket/MiSTer compatibility boundaries.
- Fit/timing constraints.
- Spec-kit maintenance rules.
- Minimal-change governance.

## Brownfield Documentation Spec

**Path**: `specs/001-project-architecture-documentation/`

**Purpose**: Captures the requirement, implementation approach, research, and maintenance tasks for this documentation effort.

**Key attributes**:
- `spec.md`: user scenarios, functional requirements, success criteria.
- `plan.md`: technical context and structure decision.
- `research.md`: findings and alternatives.
- `data-model.md`: documentation artifact model.
- `quickstart.md`: instructions for using and maintaining the docs.
- `tasks.md`: completed and future maintenance task checklist.

## OpenFPGA Package Metadata

**Path**: `pkg/Cores/mincer_ray.GBA/*.json`, `pkg/Platforms/gba.json`

**Purpose**: Defines how the Analogue Pocket discovers the core, requests data slots, exposes video modes, maps controls, and writes interact menu settings.

**Key attributes**:
- Core identity and bitstream filename.
- Data slots for ROM, BIOS, and save data.
- Input mappings for GBA buttons plus fast-forward and turbo.
- Interact variables for reset, fast-forward mode, turbo mode, and forced RTC.
- Video scaler modes and platform metadata.

## Generated Build Artifacts

**Paths**: `src/fpga/build/output_files/`, `build_output/`, `pkg/Cores/mincer_ray.GBA/bitstream.rbf_r`, release ZIPs.

**Purpose**: Outputs from local, CI, release, and seed-sweep build flows.

**Key attributes**:
- Raw Quartus `ap_core.rbf`.
- Reversed Pocket `bitstream.rbf_r`.
- Quartus fit/STA/flow reports.
- Custom timing reports.
- Release ZIP containing package tree.
