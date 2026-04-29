# openfpga-GBA Architecture

## What This Project Is

`openfpga-GBA` is an Analogue Pocket openFPGA core for Nintendo Game Boy Advance software. It is an LLM-assisted port of the MiSTer GBA core to the smaller Cyclone V FPGA inside the Analogue Pocket.

The project has two major halves:

- A Pocket/openFPGA shell that talks to the Analogue Pocket framework, loads ROM/BIOS/save data, drives SDRAM/PSRAM, handles save states, maps controls, and emits Pocket video/audio.
- A MiSTer-derived GBA hardware implementation that models the GBA CPU, memory map, DMA, timers, PPU/GPU, APU, input, GPIO/RTC, save media, and savestate internals.

The shipped package is an OpenFPGA core named `mincer_ray.GBA`. The generated runtime bitstream is `pkg/Cores/mincer_ray.GBA/bitstream.rbf_r`.

## Top-Level Repository Layout

```text
.
├── README.md                         # User-facing overview, install, build basics
├── generate.tcl                      # Quartus compile and custom report driver
├── scripts/                          # Local build, bitstream conversion, timing, seed sweep
├── pkg/                              # OpenFPGA package tree copied to SD card or release ZIP
├── src/fpga/apf/                     # Analogue Pocket framework wrapper and bridge helpers
├── src/fpga/core/                    # Pocket-specific core integration around the GBA core
├── src/fpga/gba/                     # MiSTer-derived GBA implementation in VHDL
├── src/fpga/build/                   # Active Quartus project/revision and pin/source assignments
├── .github/workflows/                # Branch build and release workflows
└── docs/                             # Maintainer documentation
```

## OpenFPGA Package

The package under `pkg/` is what gets copied to an Analogue Pocket SD card or zipped for release.

```text
pkg/
├── instructions.txt
├── Assets/gba/common/.gitkeep
├── Platforms/gba.json
├── Platforms/_images/gba.bin
└── Cores/mincer_ray.GBA/
    ├── core.json
    ├── data.json
    ├── input.json
    ├── interact.json
    ├── video.json
    ├── audio.json
    ├── variants.json
    ├── info.txt
    ├── icon.bin
    └── bitstream.rbf_r               # Generated, ignored in source control
```

### Core Identity

`pkg/Cores/mincer_ray.GBA/core.json` defines the core as an `APF_VER_1` OpenFPGA core for platform `gba`. Its metadata currently describes `GBA`, author `mincer_ray`, version `0.4.0`, release date `2026-04-09`, Pocket framework version `1.1`, sleep support, dock support, no analog dock output, no link-port hardware, and bitstream filename `bitstream.rbf_r`.

`pkg/Platforms/gba.json` identifies the platform as Nintendo Game Boy Advance, handheld, year 2001. `pkg/Platforms/_images/gba.bin` is the platform image.

### Data Slots and Bridge Addresses

`pkg/Cores/mincer_ray.GBA/data.json` declares the host-visible data slots. These addresses are consumed by `src/fpga/core/core_top.sv`.

| Slot | ID | Required | Address | Size | Runtime handling |
|---|---:|---|---|---|---|
| ROM | 1 | yes | `0x10000000` | up to `0x2000000` bytes | Loaded into SDRAM channel 1 and read by the GBA GamePak path |
| BIOS | 4 | no | `0x30000000` | exactly 16 KiB | Paired from 16-bit loader writes into 32-bit BIOS BRAM writes |
| Save | 10 | no | `0x20000000` | up to `0x20010` bytes | Loaded/unloaded through PSRAM die 1, with optional RTC bytes appended |

Save files accept `.sav` and `.srm`, are nonvolatile, and may grow beyond a standard GBA save when RTC data is appended.

### Controls and Menu Variables

`pkg/Cores/mincer_ray.GBA/input.json` maps Pocket controls to GBA controls:

- `A`, `B`, `Start`, `Select`, D-pad, `L`, and `R` map to the equivalent GBA controls.
- `Y` is `Fast Forward`.
- `X` is `Turbo`.

`pkg/Cores/mincer_ray.GBA/interact.json` exposes persistent or action menu variables:

| Menu item | Address | Behavior in `core_top.sv` |
|---|---|---|
| Reset Core | `0xF0000000` | Starts a soft reset pulse/counter |
| Fast Forward Mode | `0x80` | `0` hold, `1` toggle, `2` disabled |
| Turbo | `0x88` | `0` disabled, `1` turbo A, `2` turbo B |
| Force RTC (Dangerous) | `0x84` | Forces RTC special-module behavior and save-size append |

The README warning is important: forced RTC persists across games and can break games that do not expect RTC.

### Video, Audio, and Variants

`video.json` declares native `240x160` output with `3:2` aspect and several Pocket display mode IDs. `audio.json` only declares `APF_VER_1`. `variants.json` has no variants.

## Build and Release Flow

### Local Build

`scripts/build.sh` is the normal local entry point. It:

1. Runs Docker image `raetro/quartus:21.1` with the repo mounted at `/build`.
2. Runs `quartus_sh -t generate.tcl`.
3. Converts `src/fpga/build/output_files/ap_core.rbf` into `pkg/Cores/mincer_ray.GBA/bitstream.rbf_r` using `scripts/reverse_bitstream.py`.
4. Prints timing using `scripts/print_timing.sh` and `build_output/reports/ap_core.sta.clock_summary.rpt`.

The raw Quartus RBF is not the final Pocket bitstream. `reverse_bitstream.py` reverses bit order inside every byte and writes the `.rbf_r` file expected by OpenFPGA.

### Quartus Project

`generate.tcl` opens `src/fpga/build/gba_pocket.qpf` with revision `ap_core`, sets parallel processors to `4`, and runs `execute_flow -compile`. It then creates `build_output/reports/` and runs `scripts/sta_custom_report.tcl` through `quartus_sta`.

The active assignment file is `src/fpga/build/ap_core.qsf`. It sets:

- Top-level entity `apf_top`.
- Device `5CEBA4F23C8`.
- Raw binary file generation.
- Pin, I/O, source, QIP, SDC, and fitter settings.
- Seed `6` in the checked-in build QSF.

Other Quartus files exist as stubs or secondary revisions, including `src/fpga/ap_core.qsf`, `src/fpga/build/gba_pocket.qsf`, and `src/fpga/core/core.qsf`. The build flow uses `gba_pocket.qpf` revision `ap_core`.

### Timing Reports

`scripts/sta_custom_report.tcl` emits:

- `build_output/reports/ap_core.sta.paths_setup.rpt`
- `build_output/reports/ap_core.sta.paths_hold.rpt`
- `build_output/reports/ap_core.sta.clock_summary.rpt`
- `build_output/reports/ap_core.sta.sdram_write.rpt`
- `build_output/reports/ap_core.sta.sdram_read.rpt`

`scripts/print_timing.sh` summarizes worst setup slack, hold slack, total negative slack, per-clock setup slack, and Fmax information when the custom clock summary is present.

### CI and Release Workflows

`.github/workflows/build-branch.yml` runs on every branch push. It compiles with Docker, reverses the bitstream, uploads a `bitstream` artifact, extracts timing failures into `timing.txt`, and uploads timing/report artifacts.

`.github/workflows/build.yml` is a manual release workflow. It accepts `patch`, `minor`, or `major`, updates `core.json` version and release date, builds, reverses the bitstream, commits the version bump, tags `v<version>`, creates `mincer_ray.GBA_<version>.zip` from `pkg/`, and publishes a GitHub release. The generated bitstream is included in the release ZIP workspace output; it is not committed with the version bump.

### Seed Sweep

`scripts/seed_sweep.sh` and `scripts/seed_sweep_build.tcl` compile multiple Quartus seeds, collect timing/resource reports, choose a best seed by SDRAM timing and TNS heuristics, and copy the best raw RBF to `build_output/seed_sweep/best/ap_core.rbf`. The script prints the command needed to reverse that RBF into the package bitstream.

One caveat: `seed_sweep.sh` contains `sed -i ''`, which is BSD/macOS-style syntax and may not work on GNU/Linux without adjustment.

## APF Shell Layer

The APF shell is the hardware boundary between Analogue Pocket pins/protocols and the core-specific logic.

### `src/fpga/apf/apf_top.v`

`apf_top` is the top-level Quartus entity. It exposes the Pocket physical pins, generates a simple reset counter on `clk_74a`, converts 24-bit video/control signals into the Pocket scaler DDR interface, instantiates the SPI bridge, polls controller pads, and instantiates `core_top`.

Important responsibilities:

- Passes cartridge, link, IR, CRAM, SDRAM, SRAM, video, audio, SPI, and controller ports into `core_top`.
- Uses `mf_ddio_bidir_12` to serialize RGB and video control signals to the scaler bus.
- Instantiates `io_bridge_peripheral` for the Pocket SPI-to-bridge bus.
- Instantiates `io_pad_controller` for 1-wire controller polling.

### `src/fpga/apf/io_bridge_peripheral.v`

This module turns the Pocket SPI bridge into an addressable read/write bus with address, read, write, read-data, and write-data signals. It handles endian conversion and the bridge transaction state machine.

### `src/fpga/apf/io_pad_controller.v`

This module polls controller state using command `32'h4A10000C` and produces four controllers worth of key, joystick, and trigger words. `core_top.sv` currently uses controller 1.

### APF IP and Build ID

`apf.qip` includes the APF wrapper, bridge, pad controller, constraints, DDR bidirectional wrapper, and datatable RAM.

`build_id_gen.tcl` runs as a Quartus pre-flow script. It generates `src/fpga/apf/build_id.mif` with build date, build time, and a random unique word. `mf_datatable.v` initializes from this MIF, and `core_bridge_cmd.v` exposes datatable memory to the APF command system. `core_top.sv` continuously updates datatable index `5` with the current save size so the Pocket OS writes back the correct amount.

## Pocket Core Integration Layer

The main integration module is `src/fpga/core/core_top.sv`. It wraps the GBA core and owns Pocket-specific runtime behavior.

### Clocks and Reset

`core_top.sv` instantiates `mf_pllbase`, generated by `src/fpga/core/mf_pllbase.v` and `src/fpga/core/mf_pllbase/mf_pllbase_0002.v`.

Clock outputs are:

- `clk_sys`: about `100.663296 MHz`, used for GBA/core logic.
- `clk_sys_90`: phase-shifted SDRAM clock.
- `clk_vid`: `8.388608 MHz`, used by video output.
- `clk_vid_90`: phase-shifted video clock.

The GBA core is held reset until PLL lock, data slots are complete, APF reset is released, soft reset is inactive, and save memory is ready.

### Unused Physical Interfaces

The physical cartridge bus, IR, link port, CRAM1, and discrete SRAM are disabled, tri-stated, or safe-driven in `core_top.sv`. The core uses loaded ROM/save data rather than the Pocket cartridge slot.

### APF Command Bridge

`src/fpga/core/core_bridge_cmd.v` implements the host/target APF command window at `0xF8xxxxxx` and the datatable access window. It supports:

- Status query.
- Reset enter/exit.
- Data-slot read/write/update/all-complete commands.
- RTC epoch/date/time command.
- Save-state start/query and load/query.
- OS menu state notification.

`core_top.sv` muxes bridge reads from save unload, save-state reads, and command/status reads depending on bridge address ranges.

### ROM Loading and Reads

OpenFPGA writes ROM data to `0x1xxxxxxx`. `core_top.sv` feeds this through a ROM data loader and writes 16-bit words into SDRAM channel 1. It also tracks maximum ROM size from the last write.

During gameplay, the GBA core issues ROM reads through its SDRAM ROM interface. `core_top.sv` maps those to SDRAM channel 1 burst reads. Save-state staging can temporarily take over SDRAM channel 1, and GBA ROM read completion is suppressed while save-state service is active.

### BIOS Loading

OpenFPGA writes optional BIOS data to `0x3xxxxxxx`. The loader receives 16-bit writes, pairs them into 32-bit words, and drives `gba_top` BIOS write address/data/write-enable signals. The BIOS exact size is 16 KiB in `data.json`.

### Save Data, PSRAM, and RTC Persistence

Save data enters and exits through `0x2xxxxxxx`. The core uses external PSRAM controller `psram` on CRAM0 and stores packed save bytes in die 1.

The PSRAM mux priority is:

1. Save loader writes.
2. No-save clear fill.
3. Save unloader reads.
4. GBA save bus transactions.

If no save data arrives at boot, `core_top.sv` clears save PSRAM die 1 to `0xFFFF` so stale retained PSRAM does not leak into a new game.

RTC data is stored after regular save data. If a game is detected as RTC-capable, or if Force RTC is enabled, the reported save size adds 16 bytes for RTC persistence. The Pocket RTC command `0x0090` crosses into `clk_sys` and seeds epoch/date/time. If no RTC save data exists, the runtime RTC is seeded from Pocket time.

Save sizing is dynamic:

- `FLASH1M_V` detection selects 128 KiB Flash.
- Other save types use 64 KiB maximum.
- RTC-active saves add 16 bytes.
- The result is written to datatable index `5` for Pocket OS save handling.

### Save Type Detection and Cart Quirks

`src/fpga/core/save_type_detector.sv` watches the ROM loader stream. It detects 128 KiB Flash by searching for ASCII `FLASH1M_V` and captures the ROM cart ID from header bytes `0xAC-0xAF`.

`src/fpga/core/cart_quirks.sv` maps known cart IDs to special behavior flags. `core_top.sv` uses these flags for SRAM quirk handling, GPIO/RTC special module enabling, memory remap, and sprite-limit behavior. Tilt and solar quirk outputs exist but are not connected because those features were removed to save resources.

### SDRAM Controller

`src/fpga/core/sdram_pocket.sv` is a dual-channel SDRAM controller for the Pocket 512 Mbit, 16-bit SDRAM.

Channel 1 handles:

- ROM writes during loading.
- ROM burst reads during gameplay.
- Save-state staging writes/reads during load.

Channel 2 handles:

- GBA EWRAM 32-bit reads and writes.

The address map used by the controller comments is:

- Channel 1 ROM DWORD range `0x000000` to `0x7FFFFF`, up to 32 MiB ROM.
- Channel 2 EWRAM DWORD range starting at `0x800000`, 256 KiB.
- Save-state staging in `core_top.sv` starts at `0x810000`, after EWRAM.

The request priority is channel 1 read, channel 1 write, channel 2 read, then channel 2 write. The controller uses CAS latency 2, burst length 4, refresh around 780 cycles at the system clock, startup precharge/refresh/mode-load sequence, and DDR clock forwarding with `altddio_out`.

### External GBA Memory Bus

The MiSTer-derived `gba_top` exposes an external `bus_out` used for EWRAM and save media. `core_top.sv` handles this bus.

`bus_out_Adr[17]` selects the target:

- Set: EWRAM access through SDRAM channel 2.
- Clear: save-memory access through packed PSRAM die 1.

The save path packs the GBA core's one-byte-per-DWORD save protocol densely into PSRAM bytes.

### Video Output

`src/fpga/core/video_adapter.sv` converts GBA framebuffer writes into Pocket scaler raster output.

The GBA core emits:

- `pixel_out_addr`
- `pixel_out_data`
- `pixel_out_we`

`video_adapter` stores a `240x160` framebuffer in dual-clock inferred BRAM. On the video side, `clk_vid` is divided with `vid_ce` to the GBA dot cadence of `4.194304 MHz`. The timing model uses 308 dots per line and 228 lines per frame, with 240 active horizontal pixels and 160 active lines. RGB channels are expanded from 6 bits to 8 bits by bit replication, and the adapter outputs RGB, data enable, horizontal sync, vertical sync, and scaler skip.

### Audio Output

`core_top.sv` instantiates an external `audio_mixer` and feeds it signed 16-bit stereo samples from `gba_top`. Audio is muted during fast-forward.

### Input, Fast-Forward, and Turbo

Controller 1 state is synchronized into `clk_sys`. Pocket buttons map to GBA buttons, `X` controls turbo behavior, and `Y` controls fast-forward behavior. Fast-forward can operate as hold, toggle, or disabled based on the interact menu variable. Turbo can target A or B based on the menu variable.

### Save States

`src/fpga/core/save_state_controller.sv` bridges the APF save-state protocol to the GBA savestate bus.

The APF save-state address space starts at `0x40000000`. The controller presents a size of `0x60D18` bytes, derived from the GBA state entry count.

Save path:

- `gba_savestates` produces 64-bit entries.
- The controller splits them into 32-bit APF-readable pieces through a FIFO.
- APF drains data from `0x4xxxxxxx`.

Load path:

- APF writes 32-bit pieces to `0x4xxxxxxx`.
- The controller combines/drains them into SDRAM staging as 16-bit writes.
- It then services GBA savestate read requests from SDRAM staging.
- `ss_loading` pauses the GBA core through `sleep_external` during load/staging to avoid SDRAM contention.

The GBA savestate implementation saves the header last but loads it first, so `save_state_controller.sv` contains a header staging special case.

## MiSTer-Derived GBA Core

The VHDL subsystem under `src/fpga/gba/` implements the GBA hardware model. `src/fpga/gba/gba_top.vhd` is its top-level wrapper.

### `gba_top.vhd`

`gba_top` wires the CPU, memory mux, DMA, timers, sound, GPU, joypad, serial stubs, GPIO/RTC, reserved registers, savestate controller, interrupt registers, debug bus, SDRAM ROM read interface, external WRAM/save bus, BIOS writes, input, RTC, framebuffer, and audio.

It arbitrates debug, CPU, and DMA memory access into the memory mux. It collects interrupt sources and drives CPU IRQ. It produces the global GBA cycle pacing and `gba_step` timing used across submodules.

The reset entering most GBA submodules comes from `gba_savestates`, which means reset is tied to reset/restore sequencing rather than only an external reset pin.

### Internal Register Bus

`proc_bus_gba.vhd` defines the internal 32-bit register bus packages and the common `eProcReg_gba` register primitive. The primitive handles address decode, read/write behavior, byte enables, reset defaults, and one-cycle written pulses. Register-map packages such as `reggba_system.vhd`, `reggba_display.vhd`, `reggba_dma.vhd`, `reggba_timer.vhd`, `reggba_sound.vhd`, `reggba_keypad.vhd`, and `reggba_serial.vhd` define the GBA IO register maps used by subsystem modules.

### CPU

`gba_cpu.vhd` implements the ARM7TDMI-like CPU core with ARM/Thumb execution, banked registers, CPSR flags/modes, IRQ/halt behavior, wait-state and prefetch timing, and bus master generation. It exports CPU state through savestate registers.

### Memory Mux, BIOS, Cache, and Save Media

`gba_memorymux.vhd` is the central GBA address decoder and memory controller. It covers BIOS, IWRAM, EWRAM/external RAM bus, IO registers, palette RAM, VRAM, OAM, GamePak ROM through SDRAM/cache, SRAM/FLASH/EEPROM save media, and GPIO.

Related support:

- `gba_bios.vhd` is the BIOS RAM/ROM wrapper with runtime write port.
- `cache.vhd` is a direct-mapped GamePak ROM cache with two DWORDs per line and tag invalidation when the GBA is off.
- EEPROM and FLASH command/state handling lives in the memory mux and is included in savestate storage.

### DMA

`gba_dma.vhd` aggregates four DMA channels, priority/arbitration, shared DMA bus output, IRQ vector, DMA timing feedback to the CPU, last-read tracking, and EEPROM count handling.

`gba_dma_module.vhd` implements one DMA channel. It owns source, destination, count, and control registers; supports immediate, VBlank, HBlank, sound, and video timing; and runs a read/write FSM. GamePak DRQ is noted as not implemented.

### GPU and PPU Rendering

`gba_gpu.vhd` wraps timing and drawing. It exposes VRAM, OAM, palette memory ports and framebuffer pixel output. The optional `gba_gpu_colorshade.vhd` stage exists but is disabled; the active path directly expands 15-bit GBA color to 18-bit RGB.

`gba_gpu_timing.vhd` implements LCD timing, visible/HBlank/VBlank state, VCOUNT/DISPSTAT, HBlank/VBlank/LCDStat IRQs, DMA triggers, drawline/refpoint pulses, and VRAM blocking. The timing constants include visible-to-HBlank at 1008 cycles, HBlank length 224 cycles, and 228 total lines.

`gba_gpu_drawer.vhd` owns display registers and rendering arbitration. It coordinates background/object renderers, windows, mosaic, blending, palette/VRAM/OAM access, and layer merge.

Render helpers:

- `gba_drawer_mode0.vhd`: text/tile background rendering for modes 0/1 backgrounds, including scroll, mosaic, 4/8bpp, screen sizes, and VRAM fetch cache.
- `gba_drawer_mode2.vhd`: affine tile background rendering with ref points, dx/dy, wrapping, and mosaic.
- `gba_drawer_mode345.vhd`: bitmap modes 3/4/5 with frame select, affine coordinates, mosaic, palette lookup, and VRAM bank handling.
- `gba_drawer_obj.vhd`: sprite/OAM rendering with object windows, mosaic, mapping mode, HBlank-free/maxpixels controls, and mode-specific behavior.
- `gba_drawer_merge.vhd`: final layer composition with windows, priority, backdrop, alpha/brightness effects, and final 15-bit pixel output.

### Timers

`gba_timer.vhd` wraps four timer modules and chains count-up inputs. It exposes timer IRQs and timer 0/1 ticks used by sound DMA.

`gba_timer_module.vhd` implements reload/counter registers, prescaler, count-up mode, IRQ enable, start/stop, overflow tick, and savestate restoration.

### Sound

`gba_sound.vhd` is the APU top and mixer. It implements SOUNDCNT/SOUNDBIAS behavior, four PSG channels, two DMA FIFOs, master enable, and signed stereo output.

Sound submodules:

- `gba_sound_ch1.vhd`: parameterized square-wave channel, used for channel 1 with sweep and channel 2 without sweep.
- `gba_sound_ch3.vhd`: wave channel with wave RAM banks, length, sample rate, volume/force-volume, and trigger handling.
- `gba_sound_ch4.vhd`: noise channel with length/envelope and LFSR frequency parameters.
- `gba_sound_dma.vhd`: DMA audio FIFO A/B, timer-driven sample pop, DMA refill request, channel enables, volume, and savestate.

In lockspeed mode the sound tick follows GBA cycle accumulation. Outside lockspeed, a fixed divider prevents turbo from raising audio pitch.

### Joypad, Serial, GPIO, and RTC

`gba_joypad.vhd` implements KEYINPUT/KEYCNT and joypad IRQ generation.

`gba_serial.vhd` implements serial/link register stubs but not transfer logic. The top-level ignores serial IRQ because Pocket link cable behavior is not implemented.

`gba_gpioRTCSolarGyro.vhd` handles GamePak GPIO special behavior, primarily RTC protocol, timestamp/saved-time interface, RTC-in-use detection, and savestate of GPIO bits/state. The filename still mentions solar/gyro, but top-level comments and wiring indicate solar, tilt, and rumble behavior were stripped.

`gba_gpiodummy.vhd` is a minimal GPIO responder stub. `gba_reservedregs.vhd` responds to unimplemented/reserved IO ranges so accesses do not deadlock.

### Savestates Inside the GBA Core

`gba_savestates.vhd` captures internal registers and selected memory ranges, writes/reads external 64-bit savestate storage, drives global reset/load/sleep signals, and mirrors internal register state. It saves EWRAM, IWRAM, palette, VRAM, OAM, CPU, DMA, timers, sound, GPU, GPIO, EEPROM, FLASH, and related internal state according to the register map in `reg_savestates.vhd`.

The state size constant is `0x18346` 64-bit entries in the GBA VHDL. The APF bridge exposes the corresponding byte size through `save_state_controller.sv`.

### RAM and FIFO Primitives

The VHDL core uses generic synchronous memory helpers:

- `SyncRam.vhd`: single-port synchronous RAM.
- `SyncRamDual.vhd`: dual-port synchronous RAM.
- `SyncRamDualByteEnable.vhd`: dual-port RAM with byte enables.
- `SyncRamDualNotPow2.vhd`: dual-port RAM for non-power-of-two depths.
- `SyncFifo.vhd`: synchronous FIFO used by DMA sound FIFOs.

## End-to-End Runtime Flow

### Boot and Load

1. Pocket loads OpenFPGA metadata from `pkg/Cores/mincer_ray.GBA/` and platform metadata from `pkg/Platforms/gba.json`.
2. Pocket downloads ROM, optional BIOS, and optional save data through data slots.
3. `core_bridge_cmd.v` receives data-slot commands and all-complete status.
4. `core_top.sv` writes ROM to SDRAM Ch1, save data to PSRAM, and BIOS to GBA BIOS BRAM.
5. Save type and cart ID are detected while ROM data streams in.
6. RTC state is loaded from appended save data or seeded from Pocket time.
7. Reset releases when PLL, data slots, APF reset, soft reset, and save memory conditions are satisfied.

### Gameplay

1. `gba_top.vhd` runs on `clk_sys` with GBA cycle pacing.
2. CPU/DMA/debug traffic enters `gba_memorymux.vhd`.
3. GamePak ROM reads go through `cache.vhd` and SDRAM Ch1.
4. EWRAM and save bus transactions leave the VHDL core through `bus_out` and are serviced by `core_top.sv` through SDRAM Ch2 or PSRAM.
5. GPU rendering writes framebuffer pixels to `video_adapter.sv`, which emits Pocket scaler video.
6. APU samples go through `audio_mixer` to Pocket audio pins.
7. Controller state enters through APF pad polling and is mapped to GBA joypad inputs.

### Save and Exit

1. GBA save-media writes update packed PSRAM bytes.
2. Runtime RTC bytes are appended after normal save data when RTC is active.
3. Pocket reads save data back from `0x2xxxxxxx` using the size advertised through the datatable.

### Save State

1. APF save command starts `save_state_controller.sv`.
2. The GBA savestate block enumerates 64-bit entries.
3. The controller converts entries to APF-readable 32-bit words.
4. For load, APF writes 32-bit words, the controller stages them in SDRAM, pauses the core, and services GBA load requests.

## Omitted, Stubbed, and Constrained Features

The README and source comments identify features excluded to fit the smaller Analogue Pocket FPGA or because Pocket hardware support is absent:

- Link cable is not implemented. Serial registers exist as stubs and serial IRQ is not used.
- Gyroscope is not implemented.
- Solar sensor is not implemented.
- Rumble is stripped in top-level comments/wiring.
- Cheats are not implemented.
- Rewind is not implemented.
- Color correction outside default Pocket filters is not implemented.
- The optional GPU color shade pipeline exists but is disabled.
- GamePak IRQ and GamePak DRQ are noted as not implemented.

## Generated Files and Ignored Outputs

Fresh source checkouts should not be expected to contain generated build outputs. Important generated paths include:

- `src/fpga/build/output_files/ap_core.rbf`
- `pkg/Cores/mincer_ray.GBA/bitstream.rbf_r`
- `src/fpga/build/output_files/*.rpt`
- `src/fpga/build/output_files/*.summary`
- `build_output/reports/*.rpt`
- `src/fpga/apf/build_id.mif`
- `mincer_ray.GBA_<version>.zip`

These are either ignored or produced by local/CI/release flows.

## Maintenance Notes

- Keep `pkg/Cores/mincer_ray.GBA/data.json` bridge addresses aligned with `core_top.sv` address decoding.
- Keep `interact.json` menu addresses aligned with the write handling in `core_top.sv`.
- Update save-size documentation if `FLASH1M_V`, RTC append, or datatable behavior changes.
- Update omitted-feature documentation before advertising link, gyro, solar, rumble, cheats, rewind, or color-correction support.
- For RTL changes, prefer validating with `./scripts/build.sh` and reviewing Quartus timing/custom reports.
