// video_adapter.sv - GBA framebuffer + raster scan generator for Analogue Pocket
//
// The GBA GPU writes pixels at arbitrary addresses into a 240x160 framebuffer.
// This module stores those writes in BRAM and reads them out in raster scan order
// with proper sync timing for the Pocket's scaler (Aristotle).
//
// Clocking:
//   clk_sys (~100.66 MHz) - GPU framebuffer writes
//   clk_vid (~8.39 MHz)   - Raster scan, video output (= video_rgb_clock)
//
// The raster scan advances on vid_ce pulses (clk_vid/2 = 4.194304 MHz = exact
// GBA dot clock). video_skip gates the scaler to only process vid_ce cycles,
// so it sees exactly 240 active pixels per line.
//
// Timing:  308 dots/line (240 active + 68 blank)
//          228 lines/frame (160 active + 68 blank)
//          Frame rate: 4,194,304 / (308 x 228) = 59.7275 Hz

module video_adapter (
    input  wire        clk_sys,       // ~100.66 MHz - GPU write domain
    input  wire        clk_vid,       // ~8.39 MHz - video output domain
    input  wire        reset,         // Active high - hold until PLL locked

    // GBA GPU framebuffer write interface (clk_sys domain)
    input  wire [15:0] pixel_addr,    // 0-38399 (linear: row*240 + col)
    input  wire [17:0] pixel_data,    // {R[5:0], G[5:0], B[5:0]}
    input  wire        pixel_we,

    // Video output to APF scaler (clk_vid domain)
    output reg  [23:0] video_rgb,
    output reg         video_de,
    output reg         video_vs,
    output reg         video_hs,
    output reg         video_skip
);

    // === Raster Scan Timing Parameters ===
    localparam int unsigned H_ACTIVE = 240;
    localparam int unsigned H_FP     = 10;
    localparam int unsigned H_SYNC   = 20;
    localparam int unsigned H_BP     = 38;
    localparam int unsigned H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;

    localparam int unsigned V_ACTIVE = 160;
    localparam int unsigned V_FP     = 5;
    localparam int unsigned V_SYNC   = 5;
    localparam int unsigned V_BP     = 58;
    localparam int unsigned V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;

    localparam int unsigned FB_PIXELS = H_ACTIVE * V_ACTIVE;

    // === Framebuffer (dual-clock BRAM) ===
    // 38,400 x 18-bit ~ 86 KB ~ 30 M10K blocks
    // Port A (clk_sys): GPU writes at arbitrary addresses
    // Port B (clk_vid): Raster scan reads linearly
    reg [17:0] framebuffer [0:FB_PIXELS - 1];

    // Port A: GPU write (clk_sys domain)
    always @(posedge clk_sys) begin
        if (pixel_we)
            framebuffer[pixel_addr] <= pixel_data;
    end

    // === Video Clock Enable (clk_vid / 2 = GBA dot clock) ===
    reg vid_ce;
    always @(posedge clk_vid) begin
        if (reset)
            vid_ce <= 0;
        else
            vid_ce <= ~vid_ce;
    end

    // === Raster Scan Counters (clk_vid domain, advance on vid_ce) ===
    reg [8:0] h_count;  // 0 to 307
    reg [7:0] v_count;  // 0 to 227

    always @(posedge clk_vid) begin
        if (reset) begin
            h_count <= 0;
            v_count <= 0;
        end else if (vid_ce) begin
            if (h_count == H_TOTAL - 1) begin
                h_count <= 0;
                if (v_count == V_TOTAL - 1)
                    v_count <= 0;
                else
                    v_count <= v_count + 1'b1;
            end else begin
                h_count <= h_count + 1'b1;
            end
        end
    end

    // === Active Area & Sync Region Detection ===
    wire active    = (h_count < H_ACTIVE) && (v_count < V_ACTIVE);
    wire hs_region = (h_count >= H_ACTIVE + H_FP) &&
                     (h_count <  H_ACTIVE + H_FP + H_SYNC);
    wire vs_region = (v_count >= V_ACTIVE + V_FP) &&
                     (v_count <  V_ACTIVE + V_FP + V_SYNC);

    // === Port B: Framebuffer Read (clk_vid domain) ===
    wire [15:0] read_addr = v_count * H_ACTIVE + h_count;

    reg [17:0] pixel_read;
    always @(posedge clk_vid) begin
        if (active)
            pixel_read <= framebuffer[read_addr];
    end

    // === Color Expansion: 6-bit -> 8-bit ===
    // Replicate top 2 bits into bottom 2 for full [0..255] range
    wire [7:0] r8 = {pixel_read[17:12], pixel_read[17:16]};
    wire [7:0] g8 = {pixel_read[11:6],  pixel_read[11:10]};
    wire [7:0] b8 = {pixel_read[5:0],   pixel_read[5:4]};

    // === Output Pipeline (2-stage, clk_vid domain) ===

    reg active_d1;
    reg [1:0] hs_pipe;
    reg [1:0] vs_pipe;

    always @(posedge clk_vid) begin
        if (reset) begin
            active_d1 <= 0;
            hs_pipe   <= 2'b00;
            vs_pipe   <= 2'b00;
        end else begin
            active_d1 <= active;
            hs_pipe   <= {hs_pipe[0], hs_region};
            vs_pipe   <= {vs_pipe[0], vs_region};
        end
    end

    // Stage 2: output registers with sync edge detection
    always @(posedge clk_vid) begin
        if (reset) begin
            video_rgb  <= 24'd0;
            video_de   <= 1'b0;
            video_hs   <= 1'b0;
            video_vs   <= 1'b0;
            video_skip <= 1'b0;
        end else begin
            video_rgb  <= active_d1 ? {r8, g8, b8} : 24'd0;
            video_de   <= active_d1;
            video_hs   <= hs_pipe[0] & ~hs_pipe[1];
            video_vs   <= vs_pipe[0] & ~vs_pipe[1];
            video_skip <= ~vid_ce;
        end
    end

endmodule
