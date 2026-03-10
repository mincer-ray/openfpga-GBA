// Audio PLL: 74.25 MHz -> 12.288 MHz (MCLK) + 3.072 MHz (SCLK)
// Copied from openfpga-GBC (Fractional-N PLL, Cyclone V)

`timescale 1 ps / 1 ps
module mf_audio_pll (
		input  wire  refclk,   //  refclk.clk
		input  wire  rst,      //   reset.reset
		output wire  outclk_0, // outclk0.clk  (12.288 MHz MCLK)
		output wire  outclk_1, // outclk1.clk  (3.072 MHz SCLK)
		output wire  locked    //  locked.export
	);

	mf_audio_pll_0002 mf_audio_pll_inst (
		.refclk   (refclk),
		.rst      (rst),
		.outclk_0 (outclk_0),
		.outclk_1 (outclk_1),
		.locked   (locked)
	);

endmodule
