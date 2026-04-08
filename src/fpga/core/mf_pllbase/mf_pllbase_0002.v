// mf_pllbase_0002.v — Cyclone V Fractional-N PLL for GBA core
//
// Input:  74.25 MHz (Pocket clk_74a)
//
// Unified PLL (sys_pll_i) — all four clocks from a single fractional PLL:
//   Out 0:  100.663296 MHz (0 deg)          — GBA system clock (6 * 2^24 Hz)
//   Out 1:  100.663296 MHz (~248 deg, 6831 ps) — SDRAM clock (DDR-forwarded to dram_clk pin)
//   Out 2:  8.388608 MHz (0 deg)            — Video pixel clock (2× GBA dot clock)
//   Out 3:  8.388608 MHz (90 deg)           — Video pixel clock (DDR)
//   Out 4:  Unused (reserved)
//
// VCO = 6 × 100,663,296 = 603,979,776 Hz (fractional-N)
// C0=6, C1=6 (phase-shifted), C2=72, C3=72 (phase-shifted)
// Single PLL frees the second fPLL for future use.

`timescale 1ns/10ps
module mf_pllbase_0002 (
	input  wire refclk,
	input  wire rst,
	output wire outclk_0,
	output wire outclk_1,
	output wire outclk_2,
	output wire outclk_3,
	output wire outclk_4,
	output wire locked
);

	// All four clocks from a single fractional PLL.
	// VCO = 6 × 100,663,296 = 603,979,776 Hz
	// C0=6 → 100.663296 MHz, C1=6 → 100.663296 MHz (~248°, 6831 ps)
	// C2=72 → 8.388608 MHz,  C3=72 → 8.388608 MHz (90°)
	// This frees the second fPLL, allowing SDRAM phase tuning.

	// ---- Unified PLL — sys + vid from single VCO ----
	altera_pll #(
		.fractional_vco_multiplier("true"),
		.reference_clock_frequency("74.25 MHz"),
		.operation_mode("normal"),
		.number_of_clocks(4),
		.output_clock_frequency0("100.663296 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("100.663296 MHz"),
		.phase_shift1("6831 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("8.388608 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("8.388608 MHz"),
		.phase_shift3("29802 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("0 MHz"),
		.phase_shift4("0 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("0 MHz"),
		.phase_shift5("0 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),
		.phase_shift6("0 ps"),
		.duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),
		.phase_shift7("0 ps"),
		.duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),
		.phase_shift8("0 ps"),
		.duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),
		.phase_shift9("0 ps"),
		.duty_cycle9(50),
		.output_clock_frequency10("0 MHz"),
		.phase_shift10("0 ps"),
		.duty_cycle10(50),
		.output_clock_frequency11("0 MHz"),
		.phase_shift11("0 ps"),
		.duty_cycle11(50),
		.output_clock_frequency12("0 MHz"),
		.phase_shift12("0 ps"),
		.duty_cycle12(50),
		.output_clock_frequency13("0 MHz"),
		.phase_shift13("0 ps"),
		.duty_cycle13(50),
		.output_clock_frequency14("0 MHz"),
		.phase_shift14("0 ps"),
		.duty_cycle14(50),
		.output_clock_frequency15("0 MHz"),
		.phase_shift15("0 ps"),
		.duty_cycle15(50),
		.output_clock_frequency16("0 MHz"),
		.phase_shift16("0 ps"),
		.duty_cycle16(50),
		.output_clock_frequency17("0 MHz"),
		.phase_shift17("0 ps"),
		.duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) sys_pll_i (
		.rst      (rst),
		.outclk   ({outclk_3, outclk_2, outclk_1, outclk_0}),
		.locked   (locked),
		.fboutclk ( ),
		.fbclk    (1'b0),
		.refclk   (refclk)
	);

	assign outclk_4 = 1'b0;

endmodule
