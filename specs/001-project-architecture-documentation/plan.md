# Implementation Plan: Project Architecture Documentation

**Branch**: `001-project-architecture-documentation` | **Date**: 2026-04-25 | **Spec**: `specs/001-project-architecture-documentation/spec.md`  
**Input**: Feature specification from `/specs/001-project-architecture-documentation/spec.md`

## Summary

Document the existing openfpga-GBA repository as a brownfield hardware project. The implementation creates spec-kit governance artifacts, a numbered documentation spec, and a comprehensive architecture guide that traces OpenFPGA package metadata, APF shell logic, Quartus build flow, and the MiSTer-derived GBA subsystem.

## Technical Context

**Language/Version**: SystemVerilog, Verilog, VHDL, Tcl, Bash, Python 3  
**Primary Dependencies**: Quartus 21.1, Docker image `raetro/quartus:21.1`, Analogue Pocket openFPGA framework, spec-kit CLI  
**Storage**: FPGA SDRAM, PSRAM, BRAM/register RAM, OpenFPGA data slots, save files, generated reports  
**Testing**: Documentation review; RTL builds use Quartus via `./scripts/build.sh`  
**Target Platform**: Analogue Pocket openFPGA on Cyclone V `5CEBA4F23C8`  
**Project Type**: FPGA hardware core and OpenFPGA package  
**Performance Goals**: Meet Quartus timing for Pocket clocks; preserve GBA timing behavior and Pocket video/audio output cadence  
**Constraints**: Smaller FPGA than MiSTer target; generated bitstream must be byte-bit-reversed; OpenFPGA metadata must match RTL bridge addresses  
**Scale/Scope**: Single FPGA core package with APF shell, GBA SoC implementation, package metadata, build scripts, and CI/release automation

## Constitution Check

The documentation plan complies with the constitution by making behavior traceable to source files, preserving compatibility-sensitive addresses and save behavior, documenting fit/timing constraints, maintaining spec-kit artifacts, and avoiding RTL changes.

## Project Structure

### Documentation (this feature)

```text
specs/001-project-architecture-documentation/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
└── tasks.md
```

### Source Code (repository root)

```text
.specify/
├── memory/constitution.md
├── scripts/bash/
├── templates/
└── integrations/

.opencode/command/
└── speckit.*.md

docs/
└── ARCHITECTURE.md

src/fpga/
├── apf/
├── build/
├── core/
└── gba/

pkg/
├── Assets/gba/common/
├── Cores/mincer_ray.GBA/
└── Platforms/

scripts/
└── build, bitstream, timing, and seed-sweep helpers
```

**Structure Decision**: Keep durable architecture documentation in `docs/ARCHITECTURE.md` because it is repository-level knowledge, and keep spec-kit process artifacts under `specs/001-project-architecture-documentation/` so future documentation work can be planned and validated through spec-kit.

## Complexity Tracking

No constitution violations. The added documentation structure follows spec-kit defaults and does not alter RTL or package behavior.
