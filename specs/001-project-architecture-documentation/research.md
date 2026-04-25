# Research: Project Architecture Documentation

## Findings

### Spec-Kit Usage

Spec-kit is initialized in-place with the `opencode` integration. It provides `.specify/` shared scripts, templates, integration metadata, project memory, and `.opencode/command/speckit.*.md` slash-command prompts. This repo uses those artifacts for documentation governance and future spec-driven maintenance.

### Repository Shape

The project is an Analogue Pocket openFPGA port of the MiSTer GBA core. The source tree has four major responsibilities: APF platform shell in `src/fpga/apf/`, Pocket-specific core integration in `src/fpga/core/`, MiSTer-derived GBA logic in `src/fpga/gba/`, and package/build/release assets in `pkg/`, `scripts/`, `.github/`, and `generate.tcl`.

### Build Entry Point

The active Quartus project opens `src/fpga/build/gba_pocket.qpf` revision `ap_core` through `generate.tcl`. The build QSF sets top-level entity `apf_top`, targets Cyclone V `5CEBA4F23C8`, includes APF, core, support, and GBA sources, and enables raw RBF generation.

### Runtime Data Flow

OpenFPGA data slots load ROM, save, and BIOS data into bridge address windows. `core_top.sv` routes ROM to SDRAM Ch1, save data to packed PSRAM, BIOS data to the GBA BIOS BRAM, and save states through `save_state_controller.sv`. The GBA VHDL core receives controller input, RTC data, ROM read responses, external RAM/save bus responses, and emits framebuffer/audio/state bus activity.

### Documentation Scope Decision

The architecture guide should be source-map oriented rather than a tutorial only. The repo already has a concise README for users; the missing artifact is a maintainer-grade explanation of how the hardware, package metadata, and build automation interact.

## Alternatives Considered

- **Only expand README**: Rejected because the requested write-up is too detailed for an end-user landing page and would bury install/build basics.
- **Only use spec files**: Rejected because spec-kit artifacts describe requirements and maintenance process, while maintainers need a stable architecture guide they can browse directly.
- **Generate docs from source comments**: Rejected because the project mixes VHDL, SystemVerilog, Verilog, Tcl, Bash, Python, and JSON; generated comments would not explain cross-file behavior such as data-slot to RTL address mapping.

## Open Questions

- Whether future docs should include diagrams generated from source. The current implementation keeps diagrams textual to avoid adding tooling.
- Whether `.opencode/` should be wholly ignored for credentials. This initialization only adds spec-kit command files, so they are useful project artifacts, but future private agent state should not be committed.
