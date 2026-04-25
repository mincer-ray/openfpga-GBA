# Feature Specification: Project Architecture Documentation

**Feature Branch**: `001-project-architecture-documentation`  
**Created**: 2026-04-25  
**Status**: Draft  
**Input**: User description: "Document exactly how this project is structured, how it works and what it is. Use github/spec-kit to write and maintain the documentation. Go down every rabbit hole, flesh out every aspect of how this project works."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Understand the Repository (Priority: P1)

A maintainer can open a single architecture document and understand what the project is, what hardware it targets, how the major directories fit together, and which files implement each subsystem.

**Why this priority**: Without a top-level map, future changes to a hardware core are risky because source responsibilities are split across APF shell logic, SystemVerilog bridge code, VHDL GBA logic, package metadata, and scripts.

**Independent Test**: A reader can identify the top-level Quartus project, APF wrapper, GBA top, package metadata, and build outputs without reading source code first.

**Acceptance Scenarios**:

1. **Given** a new contributor, **When** they read the architecture guide, **Then** they can explain the path from OpenFPGA loading a ROM to the GBA core reading it from SDRAM.
2. **Given** a maintainer debugging saves, **When** they read the architecture guide, **Then** they can find the save metadata, PSRAM packing logic, RTC append behavior, and save-size datatable update.

---

### User Story 2 - Maintain Documentation Through Spec-Kit (Priority: P2)

A maintainer can use spec-kit artifacts to understand documentation governance, scope, validation expectations, and the source of truth for future documentation updates.

**Why this priority**: The user explicitly requested spec-kit so the documentation is maintained as a living specification, not only as a one-off Markdown write-up.

**Independent Test**: The repo contains `.specify/` project memory and a numbered spec directory that describe how the architecture documentation is governed and validated.

**Acceptance Scenarios**:

1. **Given** a future architecture change, **When** a maintainer checks spec-kit memory and this spec, **Then** they know the documentation must remain source-traceable and behavior-focused.
2. **Given** a documentation-only update, **When** it is reviewed, **Then** reviewers can compare changed claims against source paths listed in the architecture guide.

---

### User Story 3 - Trace Build and Release Behavior (Priority: P3)

A maintainer can understand local build, CI build, release packaging, generated artifacts, and known automation caveats.

**Why this priority**: This project ships an FPGA bitstream and OpenFPGA package. Incorrect build or package documentation can produce unusable Pocket releases even if RTL is correct.

**Independent Test**: A reader can locate the Docker/Quartus build flow, raw and reversed bitstream paths, release ZIP contents, custom timing reports, and seed sweep tooling.

**Acceptance Scenarios**:

1. **Given** a local development checkout, **When** a maintainer reads the docs, **Then** they know to run `./scripts/build.sh` and where the generated `bitstream.rbf_r` lands.
2. **Given** a release workflow run, **When** a maintainer reads the docs, **Then** they know the version bump is committed but the generated bitstream is packaged in the release ZIP rather than committed.

### Edge Cases

- Documentation must distinguish present generated files from absent generated artifacts in a fresh checkout.
- Documentation must not claim unimplemented features, including link cable, gyroscope, solar sensor, cheats, rewind, and non-default color correction.
- RTC save-size behavior must mention that RTC data is appended and affects compatibility with cores that expect standard save sizes.
- Spec-kit initialization may add agent command files under `.opencode/`; these are project workflow files, not runtime RTL.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The repo MUST contain spec-kit scaffolding and project governance memory.
- **FR-002**: The repo MUST contain a numbered spec directory for the architecture documentation effort.
- **FR-003**: The architecture guide MUST describe repository layout, OpenFPGA package metadata, local scripts, CI/release workflows, Quartus project entry points, APF integration, core bridge logic, memory systems, save/RTC behavior, video/audio/input paths, save states, and the MiSTer-derived GBA subsystem.
- **FR-004**: The architecture guide MUST call out intentionally omitted or stubbed capabilities.
- **FR-005**: The architecture guide MUST map package bridge addresses and interact menu addresses to RTL behavior.
- **FR-006**: The architecture guide MUST describe generated artifacts and the difference between raw Quartus RBF and Pocket reversed RBF.
- **FR-007**: The documentation MUST include enough file references that future maintainers can verify claims against source.

### Key Entities *(include if feature involves data)*

- **Architecture Guide**: Maintained human-readable source map in `docs/ARCHITECTURE.md`.
- **Spec-Kit Memory**: Project principles in `.specify/memory/constitution.md`.
- **OpenFPGA Package**: Metadata and assets under `pkg/` that define how Pocket discovers and loads the core.
- **APF Shell**: Verilog/SystemVerilog integration layer that connects Pocket hardware, bridge commands, memory, video, audio, and controller inputs to the GBA core.
- **GBA Core**: MiSTer-derived VHDL subsystem under `src/fpga/gba/`.
- **Build Artifacts**: Quartus reports, raw RBF, reversed RBF, release ZIP, and CI artifacts generated by scripts/workflows.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A maintainer can answer where ROM, save, BIOS, and save-state data enter the RTL by reading the docs alone.
- **SC-002**: A maintainer can identify the source file responsible for each major subsystem listed in FR-003.
- **SC-003**: A maintainer can explain why PSRAM, SDRAM Ch1, and SDRAM Ch2 are used differently.
- **SC-004**: A maintainer can distinguish shipped features from omitted/stubbed features.

## Assumptions

- The documentation describes the current checked-out source tree, not historical MiSTer behavior except where the source comments or README identify MiSTer heritage.
- Documentation-only validation can be performed by reading files and checking git status; a Quartus build is not required unless RTL changes are made.
- The spec-kit artifacts are committed as project-maintenance files so future agents can use `/speckit.*` commands.
