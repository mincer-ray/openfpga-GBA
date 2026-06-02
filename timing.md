# GBA Timing Closure Notes

Date: 2026-06-02

## Summary

The timing issue on `master` was initially concentrated in the GPU drawer/video path. A diagnostic timing exception probe showed that if internal `gba_gpu_drawer` paths were removed from the 6x single-cycle budget, the design essentially closed at slow 0C. That did not justify a timing exception by itself, because it did not prove the real sampling latency of those paths, but it did prove where the pressure was.

The final solution did not use a false-path or multicycle exception. It closed timing with real HDL cleanup in the GPU drawer, a same-cycle duplicate CPU memory-response path, and a fitter seed change from `6` to `8`.

Final verified build result from `./scripts/build.sh`:

| Check | Result |
| --- | ---: |
| Worst setup | `+0.068 ns`, `sys_pll`, Slow 1100mV 85C |
| Slow 0C setup | `+0.090 ns`, `sys_pll`, 0 violations |
| Worst hold | `+0.120 ns`, `sys_pll`, Fast 1100mV 0C |
| Worst TNS | `+0.000 ns` |
| SDRAM read setup | `+0.102 ns` |
| SDRAM write setup | `+2.867 ns` |

Final bitstream:

```text
pkg/Cores/mincer_ray.GBA/bitstream.rbf_r
```

This bitstream was also copied to the SD card beta core:

```text
/Volumes/Untitled/Cores/beta.GBA/bitstream.rbf_r
```

## Starting Point

The starting slow 0C timing result on current `master` was:

```text
Baseline worst setup: -0.432 ns
```

A quick diagnostic STA-only probe temporarily removed internal `gba_gpu_drawer` paths from the 6x single-cycle timing analysis. That probe reported:

```text
After GPU drawer timing probe: +0.019 ns
Violations: 0
Report: build_output/reports/ap_core.sta.gpu_exception_probe_0c.rpt
```

That strongly supported the theory that GPU drawer/video logic was the primary failing region. The important caveat is that this was not a valid fix. It only proved that relaxing/removing those paths made timing pass; it did not prove that the hardware can safely sample those paths later.

## Step-by-Step Work

### 1. Tried narrowing merge logic

The first experiment targeted `gba_drawer_merge.vhd`, because early failing paths included merge/OBJ/video logic.

Result:

```text
Slow 0C worsened to about -0.557 ns
Slow 85C detailed worst was about -0.498 ns
```

Conclusion:

The attempted merge narrowing was counterproductive. It was reverted. The final solution does not include changes to `gba_drawer_merge.vhd`.

### 2. Cleaned up OBJ affine address math

File:

```text
src/fpga/gba/gba_drawer_obj.vhd
```

Problem:

The OBJ affine per-pixel address path used integer division, modulo, and multiplication on fixed-point coordinates:

```text
realX / RESMULTACCDIV
realY / RESMULTACCDIV
xxx mod 8
yyy mod 8
yyy / 8
```

For this Pocket build, `RESMULT=1`, so affine coordinates are effectively 8.8 fixed-point values. That means the integer pixel coordinate and fractional/tile fields can be extracted with bit slices instead of inferred dividers and multipliers.

Change:

The affine path now converts the fixed-point integer coordinates to signed vectors and slices the needed fields:

```text
realX_s    := to_signed(realX, 24)
realY_s    := to_signed(realY, 24)
aff_x_pix  := unsigned(realX_s(13 downto 8))
aff_y_pix  := unsigned(realY_s(13 downto 8))
aff_x_frac := aff_x_pix(2 downto 0)
aff_y_frac := aff_y_pix(2 downto 0)
aff_x_tile := aff_x_pix(5 downto 3)
aff_y_tile := aff_y_pix(5 downto 3)
```

The bounds checks now compare against fixed-point limits:

```text
realX >= sizeX * 256
realY >= sizeY * 256
```

The address components are built by assigning shifted bit slices into `pixeladdr_x_aff*` signals, rather than multiplying and dividing inside the per-pixel path.

Intermediate result:

```text
DSP count dropped from 32 to 30
Worst path moved away from the original merge/video path and into mode0 divider-style logic
```

This confirmed that the GPU path was real timing pressure, but more cleanup was needed.

### 3. Cleaned up mode0 background drawer math

File:

```text
src/fpga/gba/gba_drawer_mode0.vhd
```

Problem:

Mode0 had several constant-power-of-two operations written as integer multiplication, division, or modulo:

```text
mapbase * 2048
tilebase * 0x4000
x mod 256
x / 8
tileindex * 2
tile_number * 32
tile_number * 64
y mod 8
```

Change:

These were rewritten as shifts and slices:

```text
mapbaseaddr  <= shift_left(mapbase, 11)
tilebaseaddr <= shift_left(tilebase, 14)
x_scrolled   <= scroll_sum_u(7 downto 0) or scroll_sum_u(8 downto 0)
x_tile_col   <= x_scrolled_u(7 downto 3)
VRAM addr     <= mapbaseaddr + (tileindex << 1)
```

The horizontal and vertical flip address math was also changed to use sliced pixel fields instead of runtime division/modulo. The palette nibble select now checks bit 0 of `x_scrolled` directly instead of using `x_scrolled mod 2`.

Intermediate result:

```text
DSP count dropped from 30 to 26
Slow 85C detailed WNS reached about -0.016 ns
Slow 0C WNS reached about -0.254 ns
Worst path moved out of the GPU and into memorymux/CPU-ish logic
```

This was the key shift: after the GPU cleanup, the GPU was no longer the top failing region.

### 4. Reverted the merge experiment and kept OBJ/mode0 cleanup

The merge narrowing experiment was reverted, while the OBJ and mode0 changes were kept.

Result:

```text
Slow 0C setup WNS: -0.232 ns
TNS: -1.756 ns
```

The detailed 0C report showed the new top paths were mostly `memorymux` to CPU response paths and an SDRAM address path. GPU paths were now positive.

Conclusion:

The GPU theory was supported: the original bottleneck was in the GPU drawer/video logic. Once that was reduced, the next bottlenecks appeared elsewhere.

### 5. Rejected a registered top-level memory response experiment

An experiment tried registering the top-level memory response path.

Result:

```text
Slow 85C setup WNS: about -0.447 ns
Slow 0C setup WNS: about -0.272 ns
TNS: about -8.948 ns
```

Conclusion:

This was a bad direction. It also risked changing bus latency, so it was reverted.

### 6. Added same-cycle CPU-specific `mem_bus_done_cpu`

Files:

```text
src/fpga/gba/gba_memorymux.vhd
src/fpga/gba/gba_top.vhd
```

Problem:

After the GPU cleanup, a major remaining failing path was the memorymux `mem_bus_done` response feeding CPU-side logic. The goal was to reduce routing/fanout pressure without changing bus latency.

Change:

`gba_memorymux` now has a second output:

```text
mem_bus_done_cpu : out std_logic
```

Both `mem_bus_done` and `mem_bus_done_cpu` are driven in the same clocked process, in the same cycle, through a local helper procedure:

```text
procedure set_mem_bus_done(value : std_logic) is
begin
   mem_bus_done     <= value;
   mem_bus_done_cpu <= value;
end procedure;
```

Both outputs are preserved:

```text
attribute preserve of mem_bus_done     : signal is true;
attribute preserve of mem_bus_done_cpu : signal is true;
```

At top level, only the CPU consumes the duplicate:

```text
cpu_bus_done <= mem_bus_done_cpu;
```

DMA, savestates, debug, and the other memory clients continue using the original `mem_bus_done`.

Result:

```text
Slow 85C setup WNS: -0.045 ns
Slow 0C setup WNS: -0.035 ns
Hold worst: +0.121 ns
```

This was the best valid HDL state before seed exploration. The original memorymux-to-CPU violation was gone, and the remaining violations were very small CPU/DMA placement-sensitive paths.

### 7. Rejected a DMA cycle split experiment

An experiment split `new_cycles`/`new_cycles_valid` for DMA.

Result:

```text
Slow 85C setup WNS: -0.616 ns
Slow 0C setup WNS: -0.850 ns
TNS: -2.690 ns
```

Conclusion:

The split made timing much worse and increased logic. It was reverted.

### 8. Rejected higher placement effort

File:

```text
src/fpga/build/ap_core.qsf
```

Experiment:

```text
PLACEMENT_EFFORT_MULTIPLIER 2.0 -> 4.0
```

Result:

```text
Slow 85C setup WNS: -0.554 ns
Slow 0C setup WNS: -0.546 ns
TNS: -3.810 ns
```

Conclusion:

Higher placement effort was not helpful for this netlist/seed. It was reverted to `2.0`.

### 9. Swept fitter seeds

The near-closing valid state was only missing by a few hundredths of a nanosecond, so a fitter seed sweep was the next low-risk lever.

Seed 7 result:

```text
Slow 85C setup WNS: -0.150 ns
Slow 0C setup WNS: -0.367 ns
TNS: -0.185 / -0.675
```

Seed 8 result:

```text
Slow 85C setup WNS: +0.068 ns
Slow 0C setup WNS: +0.090 ns
TNS: 0.000 / 0.000
SDRAM read: +0.102 ns
SDRAM write: +2.867 ns
```

Seed 8 was promoted in:

```text
src/fpga/build/ap_core.qsf
```

Final assignment:

```text
set_global_assignment -name SEED 8
```

### 10. Added persistent detailed slow 0C reporting

File:

```text
scripts/sta_custom_report.tcl
```

Change:

The custom STA script now also emits a detailed 0C setup report:

```text
build_output/reports/ap_core.sta.paths_setup_current_0c.rpt
```

It explicitly switches to the slow 0C operating condition, emits the report, then switches back to slow 85C:

```text
set_operating_conditions 8_slow_1100mv_0c
report_timing -setup -npaths 120 -detail full_path -file $out_setup_0c
set_operating_conditions 8_slow_1100mv_85c
```

This makes the previously diagnostic 0C view part of the normal build report set.

## Final Build Verification

Final command:

```text
./scripts/build.sh
```

Final summary:

```text
Setup worst:     +0.068 ns  sys_pll      (Slow 1100mV 85C)
Setup best:    +112.161 ns  sys_pll      (Fast 1100mV 0C)
Hold worst:      +0.120 ns  sys_pll      (Fast 1100mV 0C)
TNS worst:       +0.000 ns

Per-clock worst setup:
  bridge_spiclk   +10.541 ns  (Slow 1100mV 85C)
  audio_pll       +70.864 ns  (Slow 1100mV 0C)
  clk_74a          +2.571 ns  (Slow 1100mV 85C)
  sdram_clk        +2.867 ns  (Slow 1100mV 85C)
  sys_pll          +0.068 ns  (Slow 1100mV 85C)

Timing met.
```

Final generated reports:

```text
build_output/reports/ap_core.sta.paths_setup.rpt
build_output/reports/ap_core.sta.paths_setup_current_0c.rpt
build_output/reports/ap_core.sta.paths_hold.rpt
build_output/reports/ap_core.sta.clock_summary.rpt
build_output/reports/ap_core.sta.sdram_read.rpt
build_output/reports/ap_core.sta.sdram_write.rpt
```

## What This Proves

The original theory was correct in the useful sense: GPU drawer/video logic was the primary reason current `master` did not close at slow 0C. The diagnostic false-path probe made timing pass, and real HDL cleanup in OBJ/mode0 moved the top failures out of the GPU.

The final closure also showed that the GPU was not the only timing-sensitive area once the first bottleneck was removed. After GPU cleanup, the critical paths moved to CPU/memorymux/DMA-adjacent logic. The same-cycle `mem_bus_done_cpu` duplicate removed the worst memorymux-to-CPU pressure, and seed 8 handled the remaining small placement-sensitive miss.

## What This Does Not Prove

This work does not prove that a blanket SDC exception on GPU drawer paths is safe. The false-path probe was only diagnostic.

This work also does not prove functional correctness by simulation or gameplay testing. The final verification was full Quartus build plus STA. The `mem_bus_done_cpu` change is intended to be behavior-preserving because it duplicates the same registered value in the same cycle, but it should still be treated as an HDL change worth runtime smoke testing.

## Final Changed Files

```text
scripts/sta_custom_report.tcl
src/fpga/build/ap_core.qsf
src/fpga/gba/gba_drawer_mode0.vhd
src/fpga/gba/gba_drawer_obj.vhd
src/fpga/gba/gba_memorymux.vhd
src/fpga/gba/gba_top.vhd
```

