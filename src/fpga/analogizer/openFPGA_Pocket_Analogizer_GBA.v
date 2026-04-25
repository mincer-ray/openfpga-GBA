// Stripped-down Analogizer wrapper for the GBA core.
// Supports RGBS, RGsB, and Y/C (NTSC/PAL) output only.
// No scandoubler, no HQ2x, no SNAC, no YPbPr.
// Saves ~1,100 ALMs vs the full openFPGA_Pocket_Analogizer.v.
//
// analog_video_type bits[2:0] (bit[3]=Pocket-OFF, handled upstream):
//   0 = RGBS     (RGB + composite sync on HS pin)
//   1 = RGsB     (RGB + composite sync on G/VS pin — SOG switch ON)
//   2 = (unused, falls through to RGBS default)
//   3 = Y/C NTSC
//   4 = Y/C PAL
//   5-7 = (unused scandoubler modes, fall through to RGBS default)

`default_nettype none
`timescale 1ns / 1ps

module openFPGA_Pocket_Analogizer #(
    parameter MASTER_CLK_FREQ = 50_000_000,
    parameter LINE_LENGTH     = 256   // unused, kept for compatibility
) (
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire        i_ena,
    // Video interface
    input  wire        video_clk,
    input  wire [3:0]  analog_video_type,
    input  wire [7:0]  R,
    input  wire [7:0]  G,
    input  wire [7:0]  B,
    input  wire        Hblank,   // unused (no scandoubler)
    input  wire        Vblank,   // unused
    input  wire        BLANKn,
    input  wire        Hsync,
    input  wire        Vsync,
    input  wire        Csync,
    // Y/C chroma encoder
    input  wire [39:0] CHROMA_PHASE_INC,
    input  wire        PALFLAG,
    // Scandoubler — unused, kept for port compatibility
    input  wire        ce_pix,
    input  wire        scandoubler,
    input  wire [2:0]  fx,
    // SNAC — unused
    input  wire        conf_AB,
    input  wire [4:0]  game_cont_type,
    output wire [15:0] p1_btn_state,
    output wire [31:0] p1_joy_state,
    output wire [15:0] p2_btn_state,
    output wire [31:0] p2_joy_state,
    output wire [15:0] p3_btn_state,
    output wire [15:0] p4_btn_state,
    // PSX rumble — unused
    input  wire [1:0]  i_VIB_SW1,
    input  wire [7:0]  i_VIB_DAT1,
    input  wire [1:0]  i_VIB_SW2,
    input  wire [7:0]  i_VIB_DAT2,
    output wire        busy,
    // Cartridge port (Analogizer)
    inout  wire [7:0]  cart_tran_bank2,
    output wire        cart_tran_bank2_dir,
    inout  wire [7:0]  cart_tran_bank3,
    output wire        cart_tran_bank3_dir,
    inout  wire [7:0]  cart_tran_bank1,
    output wire        cart_tran_bank1_dir,
    inout  wire [7:4]  cart_tran_bank0,
    output wire        cart_tran_bank0_dir,
    inout  wire        cart_tran_pin30,
    output wire        cart_tran_pin30_dir,
    output wire        cart_pin30_pwroff_reset,
    inout  wire        cart_tran_pin31,
    output wire        cart_tran_pin31_dir,
    // Debug — unused
    output wire [3:0]  DBG_TX,
    output wire        o_stb
);

// Tie off unused output ports
assign p1_btn_state = 16'h0;
assign p1_joy_state = 32'h0;
assign p2_btn_state = 16'h0;
assign p2_joy_state = 32'h0;
assign p3_btn_state = 16'h0;
assign p4_btn_state = 16'h0;
assign busy         = 1'b0;
assign DBG_TX       = 4'h0;
assign o_stb        = 1'b0;

// Y/C encoder (used for modes 3 and 4)
wire [23:0] yc_o;
wire        yc_cs;
yc_out yc_out (
    .clk      (i_clk),
    .PHASE_INC(CHROMA_PHASE_INC),
    .PAL_EN   (PALFLAG),
    .hsync    (Hsync),
    .vsync    (Vsync),
    .csync    (Csync),
    .din      ({R & {8{BLANKn}}, G & {8{BLANKn}}, B & {8{BLANKn}}}),
    .dout     (yc_o),
    .hsync_o  (),
    .vsync_o  (),
    .csync_o  (yc_cs)
);

// Video output mux — select based on lower 3 bits (bit[3] is Pocket-OFF, gated upstream)
reg [5:0] Rout, Gout, Bout /* synthesis preserve */;
reg HsyncOut, VsyncOut, BLANKnOut /* synthesis preserve */;

always @(*) begin
    case (analog_video_type[2:0])
        3'h1: begin // RGsB — composite sync on G (SOG switch ON)
            Rout      = R[7:2] & {6{BLANKn}};
            Gout      = G[7:2] & {6{BLANKn}};
            Bout      = B[7:2] & {6{BLANKn}};
            HsyncOut  = 1'b1;
            VsyncOut  = Csync;
            BLANKnOut = BLANKn;
        end
        3'h3, 3'h4: begin // Y/C NTSC (3) or PAL (4)
            Rout      = yc_o[23:18];
            Gout      = yc_o[15:10];
            Bout      = yc_o[7:2];
            HsyncOut  = yc_cs;
            VsyncOut  = 1'b1;
            BLANKnOut = 1'b1;
        end
        default: begin // 0=RGBS, and fallback for unused modes
            Rout      = R[7:2] & {6{BLANKn}};
            Gout      = G[7:2] & {6{BLANKn}};
            Bout      = B[7:2] & {6{BLANKn}};
            HsyncOut  = Csync;
            VsyncOut  = 1'b1;
            BLANKnOut = BLANKn;
        end
    endcase
end

// Cartridge port tri-state buffers
// BK0 — SNAC conf pins (unused here, drive high as safe output)
assign cart_tran_bank0     = (i_rst | ~i_ena) ? 4'hf : 4'hf;
assign cart_tran_bank0_dir = (i_rst | ~i_ena) ? 1'b1 : 1'b1;
// BK3 — {R[5:0], HS, VS}
assign cart_tran_bank3     = (i_rst | ~i_ena) ? 8'hzz : {Rout[5:0], HsyncOut, VsyncOut};
assign cart_tran_bank3_dir = (i_rst | ~i_ena) ? 1'b0  : 1'b1;
// BK2 — {B[0], BLANKn, G[5:0]}
assign cart_tran_bank2     = (i_rst | ~i_ena) ? 8'hzz : {Bout[0], BLANKnOut, Gout[5:0]};
assign cart_tran_bank2_dir = (i_rst | ~i_ena) ? 1'b0  : 1'b1;
// BK1 — {2'b00 (SNAC unused), CLK, B[5:1]}
assign cart_tran_bank1     = (i_rst | ~i_ena) ? 8'hzz : {2'b00, video_clk, Bout[5:1]};
assign cart_tran_bank1_dir = (i_rst | ~i_ena) ? 1'b0  : 1'b1;
// PIN30 / PIN31 — unused in video-only mode
assign cart_tran_pin30         = 1'bz;
assign cart_tran_pin30_dir     = 1'b0;
assign cart_pin30_pwroff_reset = (i_rst | ~i_ena) ? 1'b0 : 1'b1;
assign cart_tran_pin31         = 1'bz;
assign cart_tran_pin31_dir     = 1'b0;

endmodule
