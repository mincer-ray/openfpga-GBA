# Analogizer Integration — Research Reference

This document captures what is known about the `openFPGA_Pocket_Analogizer` module and what it will take to integrate it into this core. It is the technical foundation for the Analogizer spec and plan.

---

## What the Analogizer Is

The **Analogizer** is a hardware adapter by RndMnkIII that plugs into the Pocket's cartridge port and exposes:
- An **ADV7123 DAC** for analog video out: RGBS (15kHz), RGsB, YPbPr (component), Y/C (S-Video), composite, and Scandoubler RGBHV
- A **SNAC port** for wired controller input via DB15, NES, SNES, PCEngine, and PSX connectors

The adapter repo and specifications are at `https://github.com/RndMnkIII/Analogizer`. An example GBC integration (closest to GBA) is at `https://github.com/RndMnkIII/Analogizer_openfpga-GBC`.

All existing Analogizer cores feed the module native pre-scaled video — not the Pocket scaler output. For this core that means tapping `video_adapter.sv`'s sync outputs and the GBA framebuffer pixel data.

---

## What Is Already in Place

From `core.json`:
- `"cartridge_adapter": -1` — currently disabled. Must be changed to `0` before Analogizer will work.

From `core_top.sv`:
- The physical cartridge bus is currently safe-driven/tri-stated (no conflicts to remove).
- Cart pin groups `cart_tran_bank0–3`, `cart_tran_pin30/31` all flow through `apf_top` → `core_top` already — they are the pins the Analogizer adapter uses.

From `interact.json` / bridge registers in `core_top.sv` — these addresses are **already occupied**:

| Address | Use |
|---------|-----|
| `0xF0000000` | Core reset trigger |
| `0x80` | Fast-forward mode |
| `0x84` | Force RTC |
| `0x88` | Turbo mode |
| `0xF8xxxxxx` | APF command bridge (`core_bridge_cmd.v`) |

The standard Analogizer setting address is `0xA0000000` — this is **free**.

Bridge read decode in `core_top.sv` already handles `0x2xxxxxxx`, `0x4xxxxxxx`, `0xF8xxxxxx`. A new arm for `0xA0000000` must be added.

---

## The `openFPGA_Pocket_Analogizer` Module

The module is instantiated in `core_top.sv` (one level below `apf_top`, as recommended). It handles all DAC driving, Y/C encoding, scandoubler, and SNAC polling internally. Callers supply:

### Input signals

| Signal | Width | Description |
|--------|-------|-------------|
| `i_clk` | 1 | System clock (use `clk_sys`) |
| `i_rst` | 1 | Active-high reset |
| `i_ena` | 1 | Module enable |
| `analog_video_type` | 4 | Selected output mode from menu [13:10] |
| `R`, `G`, `B` | 8 each | RGB — supply 6-bit GBA channels left-shifted to 8-bit (`{r5..r0, 2'b0}`) |
| `HBlank`, `VBlank` | 1 each | Blanking signals |
| `BLANKn` | 1 | Active-low composite blank (high during active pixels) |
| `Hsync`, `Vsync` | 1 each | Sync signals |
| `Csync` | 1 | Composite sync |
| `video_clk` | 1 | Pixel clock for ADV7123 — use `clk_vid` (8.388608 MHz) or `clk_vid / 2` (4.194 MHz) |
| `PALFLAG` | 1 | 0 = NTSC (correct for GBA) |
| `CHROMA_PHASE_INC` | 40 | Color subcarrier accumulator — see calculation below |
| `COLORBURST_RANGE` | 27 | Color burst range — see calculation below |
| `ce_divider` | 3 | Scandoubler divider (set to 1 for GBA's single-clock pixels at 4.194 MHz) |
| `conf_AB` | 1 | SNAC A/B switch |
| `game_cont_type` | 5 | SNAC controller type from menu [4:0] |

### Output signals

| Signal | Width | Description |
|--------|-------|-------------|
| `p1_btn_state` – `p4_btn_state` | 16 each | SNAC button states |

### Cart port passthrough

All `cart_tran_*` signals from `apf_top` must be wired through `core_top` to this module rather than being safe-driven. The module takes exclusive ownership of those pins.

---

## Video Signals Available in `core_top.sv`

`video_adapter.sv` already produces raster timing on `clk_vid`. Its outputs available to tap:

```
video_rgb   [23:0]  — 8-bit per channel RGB (already processed from GBA's RGB666)
video_de            — data enable (active pixels)
video_hs            — horizontal sync
video_vs            — vertical sync
video_skip          — scaler gating (not needed for Analogizer)
```

For Analogizer:
- **RGB**: extract `video_rgb[23:16]` (R), `[15:8]` (G), `[7:0]` (B) — already 8-bit expanded
- **HBlank**: `~video_de` (de-asserted during blanking)
- **VBlank**: derive from `video_vs` or from the vertical counter inside `video_adapter` (may need to expose)
- **BLANKn**: `video_de` (high during active, which is active-low blank inverted)
- **Hsync / Vsync**: `video_hs` / `video_vs`
- **Csync**: XOR of `video_hs` and `video_vs` (standard composite sync generation)

`video_adapter.sv` does not currently export its internal vertical counter for a clean `VBlank` signal. One option: expose a `video_vblank` output from `video_adapter`, driven by the `v_cnt >= 160` region of the 228-line frame. Alternatively derive it from `video_vs` with a known line count.

**Clock for Analogizer video**: `clk_vid` (8.388608 MHz) — the video domain clock that `video_adapter` uses.

---

## GBA-Specific Chroma Calculations

Y/C and composite outputs require `CHROMA_PHASE_INC` and `COLORBURST_RANGE` tuned to the core's pixel clock.

**GBA pixel clock**: 4.194304 MHz (= `clk_vid` / 2 = 8.388608 / 2)

**NTSC color subcarrier**: 3.579545 MHz

```
CHROMA_PHASE_INC = round((fsc / fpixel) * 2^32)
                 = round((3.579545 / 4.194304) * 4294967296)
                 ≈ 3,664,818,944  (0xDA1DCA00 approximately)
```

This is the same calculation used by every Analogizer core. The GBC Analogizer reference is a useful cross-check since the GBC pixel clock is similarly in the ~4 MHz range.

For `COLORBURST_RANGE`: this is a smaller constant also derived from pixel clock / subcarrier ratio, used to control burst gating. Refer to the GBC Analogizer `core_top.sv` for the exact formula — replicate with GBA's 4.194304 MHz pixel clock.

---

## Vertical Resolution on CRT

The GBA outputs 160 active lines out of a 228-line frame. On a 15 kHz CRT expecting NTSC's 262 total lines, this will display as a letterboxed strip vertically positioned in the top portion of the screen.

Options:
1. **Accept letterboxing**: simplest, most timing-accurate. The black bars are significant (~40% of screen height).
2. **Pad blank lines**: add 34 blank lines above and below to hit 228 active display lines → fills more of 262-line frame. Requires modifying the vertical counter in `video_adapter.sv` or adding a separate Analogizer timing generator.
3. **Integer scale 2×**: double the 160 lines to 320 → exceeds 262-line NTSC. Requires separate logic. Not recommended for v1.

For v1, accept letterboxing. Document the limitation.

---

## Interact Menu Additions

Three settings blocks added to `interact.json`, all under the single address `0xA0000000`:

```json
{
  "id": "analogizer_settings",
  "address": "0xA0000000",
  "type": "list",
  "persist": true,
  "name": "Analogizer Video Out",
  "options": [
    { "value": 0, "name": "Off" },
    { "value": 1024, "name": "RGBS" },
    { "value": 2048, "name": "RGsB" },
    ...
  ]
}
```

The 14-bit register `analogizer_settings[13:0]` encodes three fields:
- `[4:0]` — SNAC controller type
- `[9:6]` — SNAC controller assignment  
- `[13:10]` — Video output mode

Refer to the GBC Analogizer `interact.json` for the exact option list and values — these are standardized across all Analogizer cores.

---

## Bridge Register Additions

In `core_top.sv`, add to the `clk_74a` domain write handler:
```verilog
32'hA0000000: analogizer_settings <= bridge_wr_data[13:0];
```

Add to `bridge_rd_data` decode:
```verilog
32'hA0000000: bridge_rd_data <= {18'h0, analogizer_settings};
```

Synchronize to `clk_sys`:
```verilog
reg  [13:0] analogizer_settings = 0;
wire [13:0] analogizer_settings_s;
synch_3 #(.WIDTH(14)) sync_analogizer(analogizer_settings, analogizer_settings_s, clk_sys);

wire [4:0] snac_game_cont_type  = analogizer_settings_s[4:0];
wire [3:0] snac_cont_assignment = analogizer_settings_s[9:6];
wire [3:0] analogizer_video_type = analogizer_settings_s[13:10];
```

---

## SNAC Controller Input

The Analogizer `p1_btn_state` format (standardized across all cores):
```
{Start, Select, R3, L3, R2, L2, R1, L1, Y, X, B, A, Right, Left, Down, Up}
```

GBA mapping:
- GBA Start ← `p1_btn_state[9]`
- GBA Select ← `p1_btn_state[8]`
- GBA R ← `p1_btn_state[5]` (R1)
- GBA L ← `p1_btn_state[4]` (L1)
- GBA B ← `p1_btn_state[1]`
- GBA A ← `p1_btn_state[0]`
- D-pad ← `p1_btn_state[3:0]` (Right/Left/Down/Up)

The SNAC input must be muxed with Pocket button input — when a SNAC controller is assigned to P1, it replaces (or optionally supplements) Pocket controls.

---

## Resource Budget

**Current utilization (v0.4.0 shipped build):**

```
Logic utilization (in ALMs) : 16,259 / 18,480 ( 88 % )
Total registers              : 22,710
Total block memory bits      : 2,056,675 / 3,153,920 ( 65 % )
Total DSP Blocks             : 32 / 66 ( 48 % )
```

Only **~2,221 ALMs free** (~12%). The Analogizer module typically adds **2,000–4,000 ALMs** (scandoubler + Y/C encoder + SNAC logic). This is extremely tight — the integration will almost certainly require cutting something from the existing core to make room.

**Candidates for removal to free ALMs:**

| Feature | Estimated savings | Risk |
|---------|------------------|------|
| Save states | ~1,000–2,000 ALMs (gba_savestates.vhd + save_state_controller.sv) | High — popular feature |
| Fast-forward lockspeed override | Modest | Low |
| Debug output registers | Small | Negligible |
| RTC force option | Small | Low |

The most likely trade-off is dropping save states for the Analogizer build and shipping it as a **separate bitstream** variant alongside the standard build (which already exists as `variants.json`). This is the same pattern used by the NES Analogizer core.

Block memory (65%) and DSP (48%) have comfortable headroom — those are not the constraint.

---

## Key External References

| Resource | URL |
|----------|-----|
| Analogizer repo + wiki | `https://github.com/RndMnkIII/Analogizer` |
| Analogizer specifications | `https://github.com/RndMnkIII/Analogizer/blob/main/specification/Analogizer_specifications.md` |
| GBC Analogizer core (closest reference) | `https://github.com/RndMnkIII/Analogizer_openfpga-GBC` |
| NES Analogizer core | `https://github.com/RndMnkIII/openfpga-NES-Analogizer` |
| SNES Analogizer core | `https://github.com/RndMnkIII/openfpga-SNES-Analogizer` |
| Supported cores + config guide | `https://github.com/RndMnkIII/Analogizer/wiki/Supported-Cores-and-How-to-Configure-Them` |
| Analogue openFPGA developer docs | `https://www.analogue.co/developer/docs/overview` |
