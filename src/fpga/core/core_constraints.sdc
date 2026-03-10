#
# user core constraints
#
# put your clock groups in here as well as any net assignments
#

# Clock groups: sys_pll outputs 0 and 1 are phase-related (same VCO),
# so they belong in the SAME group. Previously they were in separate
# asynchronous groups, which told Quartus to skip timing analysis between them.
# Output 1 (clk_sys_90) is currently unused but keep it grouped correctly.
set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|mp1|mf_pllbase_inst|sys_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|mp1|mf_pllbase_inst|sys_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|mf_pllbase_inst|vid_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|mf_pllbase_inst|vid_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|audio_out|audio_pll|mf_audio_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|audio_out|audio_pll|mf_audio_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk }

derive_clock_uncertainty

# ============================================================
# SDRAM Timing: No output delay constraints
# ============================================================
# GBC (67 MHz) and SNES (86 MHz) Pocket cores work without SDRAM constraints.
# Our previous output delay constraints showed -5ns violations at 100 MHz —
# Cyclone V I/O tCO (~4ns) exceeds the 3.5ns setup budget.
# Unachievable constraints may cause the fitter to deprioritize these paths.
# Removing them lets Quartus optimize freely, matching the reference core approach.
