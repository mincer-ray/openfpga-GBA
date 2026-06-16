#
# user core constraints
#
# put your clock groups in here as well as any net assignments
#

# ============================================================
# SDRAM Timing Constraints
# ============================================================
# SDRAM: AS4C32M16MSA-6BIN (512 Mbit, 166 MHz max, -6 speed grade)
# dram_clk is DDR-forwarded from PLL outclk_1 (~248° phase, 6831 ps).
#
# Write path (FPGA → SDRAM):
#   tDS = 1.5 ns  (data/address/command setup to CLK)
#   tDH = 0.8 ns  (data/address/command hold after CLK)
#
# Read path (SDRAM → FPGA), CAS latency 2:
#   tAC = 6.0 ns  (access time from CLK, max)
#   tOH = 2.5 ns  (output hold from CLK, min)

# Generated clock on SDRAM CLK output pin
# IMPORTANT: This must be defined BEFORE set_clock_groups below,
# so the fitter knows about sdram_clk during timing-driven optimization.
create_generated_clock -name sdram_clk \
  -source [get_pins {ic|mp1|mf_pllbase_inst|sys_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  [get_ports {dram_clk}]

# Clock groups: sys_pll outputs 0 and 1 are phase-related (same VCO),
# so they belong in the SAME group. Output 1 (clk_sys_90, ~248° phase)
# is DDR-forwarded to the SDRAM CLK pin via altddio_out in the IOE.
# sdram_clk (generated on dram_clk port) is derived from general[1]
# and must be in the same group.
# All four core clocks (sys 0°, sys 270°, vid 0°, vid 90°) now come from
# a single fPLL (sys_pll_i), freeing the second fPLL for SDRAM phase tuning.
# Video outputs (general[2], general[3]) cross through a framebuffer to
# the sys_clk domain, so they are treated as asynchronous.
set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|mp1|mf_pllbase_inst|sys_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|mp1|mf_pllbase_inst|sys_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk \
          sdram_clk } \
 -group { ic|mp1|mf_pllbase_inst|sys_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|mf_pllbase_inst|sys_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|audio_out|audio_pll|mf_audio_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|audio_out|audio_pll|mf_audio_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk }

derive_clock_uncertainty

# Write path: output delay for all SDRAM outputs relative to sdram_clk
set_output_delay -clock sdram_clk -max 1.5 \
  [get_ports {dram_a[*] dram_ba[*] dram_dq[*] dram_dqm[*] dram_ras_n dram_cas_n dram_we_n dram_cke}]
set_output_delay -clock sdram_clk -min -0.8 \
  [get_ports {dram_a[*] dram_ba[*] dram_dq[*] dram_dqm[*] dram_ras_n dram_cas_n dram_we_n dram_cke}]

# Read path: input delay for DQ relative to sdram_clk
# tAC = 6.0 ns max (access time from CLK, CL=2)
# tOH = 2.5 ns min (output hold from CLK)
set_input_delay -clock sdram_clk -max 6.0 [get_ports {dram_dq[*]}]
set_input_delay -clock sdram_clk -min 2.5 [get_ports {dram_dq[*]}]

# ============================================================
# CRAM0 Timing Constraints
# ============================================================
# Cellular PSRAM is used in asynchronous multiplexed-address mode:
#   - clk_sys launches the CRAM control/address/data pins.
#   - cram0_clk is held low.
#   - ADV# latches address/CE after a minimum two-cycle latch phase.
#
# External latch requirements from the CRAM async interface:
#   tAVS = 5 ns  (address setup before ADV# high)
#   tCVS = 7 ns  (CE# setup before ADV# high)
#   tAVH = 2 ns  (address hold after ADV# high)
#
# The controller keeps address/CE/ADV active for at least two clk_sys cycles
# before ADV# rises, then holds address DQ for one more clk_sys cycle. These
# constraints are FPGA-side timing budgets that keep CRAM paths visible to
# TimeQuest; they are not a full external-memory timing model with board/package
# delay and relative pin-to-pin analysis.
# Budget each FPGA output path against the external requirement it participates in.
set clk_sys_clock [get_clocks {ic|mp1|mf_pllbase_inst|sys_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]

set CRAM0_CLK_SYS_PERIOD_NS [get_clock_info -period $clk_sys_clock]
set CRAM0_LATCH_CYCLES 2
set CRAM0_ADDR_HOLD_CYCLES 1
set CRAM0_TAVS_NS 5.0
set CRAM0_TCVS_NS 7.0
set CRAM0_TAVH_NS 2.0

set CRAM0_ADDR_OUTPUT_MAX_NS [expr {$CRAM0_CLK_SYS_PERIOD_NS * $CRAM0_LATCH_CYCLES - $CRAM0_TAVS_NS}]
set CRAM0_CE_OUTPUT_MAX_NS [expr {$CRAM0_CLK_SYS_PERIOD_NS * $CRAM0_LATCH_CYCLES - $CRAM0_TCVS_NS}]
set CRAM0_ADV_OUTPUT_MAX_NS [expr {$CRAM0_CLK_SYS_PERIOD_NS * $CRAM0_ADDR_HOLD_CYCLES - $CRAM0_TAVH_NS}]
set CRAM0_OTHER_OUTPUT_MAX_NS $CRAM0_CE_OUTPUT_MAX_NS

set cram0_addr_output_ports [get_ports {cram0_a[*] cram0_dq[*]}]
set cram0_ce_output_ports [get_ports {cram0_ce0_n cram0_ce1_n}]
set cram0_adv_output_port [get_ports {cram0_adv_n}]
set cram0_other_output_ports [get_ports {cram0_clk cram0_cre cram0_lb_n cram0_oe_n cram0_ub_n cram0_we_n}]
set cram0_output_ports [get_ports {cram0_a[*] cram0_adv_n cram0_ce0_n cram0_ce1_n cram0_clk cram0_cre cram0_dq[*] cram0_lb_n cram0_oe_n cram0_ub_n cram0_we_n}]
set cram0_input_ports [get_ports {cram0_dq[*] cram0_wait}]

set_max_delay $CRAM0_ADDR_OUTPUT_MAX_NS -from $clk_sys_clock -to $cram0_addr_output_ports
set_max_delay $CRAM0_CE_OUTPUT_MAX_NS -from $clk_sys_clock -to $cram0_ce_output_ports
set_max_delay $CRAM0_ADV_OUTPUT_MAX_NS -from $clk_sys_clock -to $cram0_adv_output_port
set_max_delay $CRAM0_OTHER_OUTPUT_MAX_NS -from $clk_sys_clock -to $cram0_other_output_ports
set_min_delay 0.000 -from $clk_sys_clock -to $cram0_output_ports

# Read data is sampled by clk_sys after the controller's async access wait.
# Keep the FPGA-side input path bounded to one clk_sys cycle.
set_max_delay $CRAM0_CLK_SYS_PERIOD_NS -from $cram0_input_ports -to $clk_sys_clock
set_min_delay 0.000 -from $cram0_input_ports -to $clk_sys_clock

# Non-SDRAM top-level I/O timing coverage:
# These APF/platform interfaces are not signed off with external setup/hold
# delays here. They are either protocol/wait-state timed, source-synchronous
# to fixed platform wiring, or handled by the APF bridge logic. Marking them
# false path keeps TimeQuest's "fully constrained" check focused on the paths
# this core actually constrains instead of reporting intentionally unmanaged
# board-level I/O.
set_false_path -from [get_ports { \
  bridge_1wire bridge_spimiso bridge_spimosi bridge_spiss \
  port_tran_sck port_tran_sd port_tran_si \
}]

set_false_path -to [get_ports { \
  bridge_1wire bridge_spimiso bridge_spimosi \
  port_tran_sck port_tran_sck_dir port_tran_sd port_tran_sd_dir port_tran_so \
  scal_auddac scal_audlrck scal_audmclk scal_clk scal_de scal_hs scal_skip \
  scal_vid[*] scal_vs \
}]

# Multicycle path for SDRAM read capture:
# With ~248° phase (6831 ps), the sdram_clk edge is ~6.8 ns after sys_clk.
# The next sys_clk edge is only ~3.1 ns later (9934 - 6831 ps), which is
# less than tAC (6 ns) — data is NOT valid yet. It is captured on the
# 2nd sys_clk edge (~13 ns after sdram_clk). Multicycle setup of 2
# gives the fitter this relaxed timing window.
set_multicycle_path -setup -from [get_clocks {sdram_clk}] \
  -to [get_clocks {ic|mp1|mf_pllbase_inst|sys_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] 2
set_multicycle_path -hold -from [get_clocks {sdram_clk}] \
  -to [get_clocks {ic|mp1|mf_pllbase_inst|sys_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] 1

# Savestate internal bus pipeline:
# The address fan-out from gba_savestates to hundreds of eProcReg_gba
# instances takes ~10.7 ns (combinational decode MUX), exceeding the
# 9.93 ns clock period.  The RTL gates done_r/dout_r capture with
# bus_wait, ensuring Adr is stable for a full extra cycle before
# sampling.  On the write side, a settle state separates the Adr
# change from the ena pulse.  Both give the decode 2 full clock
# periods (~20 ns) to resolve.
#
# Read path: Adr → combinational decode → done_r / dout_r
set_multicycle_path -setup 2 \
  -from [get_registers {*igba_savestates|internal_bus_out.Adr*}] \
  -to   [get_registers {*igba_savestates|done_r}]
set_multicycle_path -hold 1 \
  -from [get_registers {*igba_savestates|internal_bus_out.Adr*}] \
  -to   [get_registers {*igba_savestates|done_r}]
set_multicycle_path -setup 2 \
  -from [get_registers {*igba_savestates|internal_bus_out.Adr*}] \
  -to   [get_registers {*igba_savestates|dout_r[*]}]
set_multicycle_path -hold 1 \
  -from [get_registers {*igba_savestates|internal_bus_out.Adr*}] \
  -to   [get_registers {*igba_savestates|dout_r[*]}]
# Write path: Adr → address compare in eProcReg_gba → Dout_buffer
set_multicycle_path -setup 2 \
  -from [get_registers {*igba_savestates|internal_bus_out.Adr*}] \
  -to   [get_registers {*eProcReg_gba*Dout_buffer*}]
set_multicycle_path -hold 1 \
  -from [get_registers {*igba_savestates|internal_bus_out.Adr*}] \
  -to   [get_registers {*eProcReg_gba*Dout_buffer*}]
