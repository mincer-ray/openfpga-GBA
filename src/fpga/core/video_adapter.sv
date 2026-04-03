// video_adapter.sv — GBA framebuffer + raster scan generator for Analogue Pocket
//
// The GBA GPU writes pixels at arbitrary addresses into a 240x160 framebuffer.
// This module stores those writes in BRAM and reads them out in raster scan order
// with proper sync timing for the Pocket's scaler (Aristotle).
//
// Clocking:
//   clk_sys (~100.66 MHz) — GPU framebuffer writes
//   clk_vid (~8.39 MHz)   — Raster scan, video output (= video_rgb_clock)
//
// The raster scan advances on vid_ce pulses (clk_vid/2 = 4.194304 MHz = exact
// GBA dot clock). video_skip gates the scaler to only process vid_ce cycles,
// so it sees exactly 240 active pixels per line.
//
// Timing:  308 dots/line (240 active + 68 blank)
//          228 lines/frame (160 active + 68 blank)
//          Frame rate: 4,194,304 / (308 x 228) = 59.7275 Hz

module video_adapter (
    input  wire        clk_sys,       // ~100.66 MHz — GPU write domain
    input  wire        clk_vid,       // ~8.39 MHz — video output domain
    input  wire        reset,         // Active high — hold until PLL locked

    // GBA GPU framebuffer write interface (clk_sys domain)
    input  wire [15:0] pixel_addr,    // 0-38399 (linear: row*240 + col)
    input  wire [17:0] pixel_data,    // {R[5:0], G[5:0], B[5:0]}
    input  wire        pixel_we,
    input  wire [95:0] debug_overlay, // temporary on-screen link debug panel

    // Video output to APF scaler (clk_vid domain)
    output reg  [23:0] video_rgb,
    output reg         video_de,
    output reg         video_vs,
    output reg         video_hs,
    output reg         video_skip
);

    // === Raster Scan Timing Parameters ===
    localparam H_ACTIVE = 240;
    localparam H_FP     = 10;     // Front porch
    localparam H_SYNC   = 20;     // Sync pulse width
    localparam H_BP     = 38;     // Back porch
    localparam H_TOTAL  = 308;    // 240 + 10 + 20 + 38

    localparam V_ACTIVE = 160;
    localparam V_FP     = 5;
    localparam V_SYNC   = 5;
    localparam V_BP     = 58;
    localparam V_TOTAL  = 228;    // 160 + 5 + 5 + 58
    localparam DEBUG_COLS = 16;
    localparam DEBUG_ROWS = 6;
    localparam DEBUG_BOX  = 10;
    localparam DEBUG_STEP = 12;
    localparam DEBUG_PAD  = 1;
    localparam DEBUG_ORIGIN_X = 4;
    localparam DEBUG_ORIGIN_Y = 4;
    localparam DEBUG_PANEL_W  = DEBUG_COLS * DEBUG_STEP + (DEBUG_PAD * 2);
    localparam DEBUG_PANEL_H  = DEBUG_ROWS * DEBUG_STEP + (DEBUG_PAD * 2);

    // === Framebuffer (dual-clock BRAM) ===
    // 38,400 x 18-bit ~ 86 KB ~ 30 M10K blocks
    // Port A (clk_sys): GPU writes at arbitrary addresses
    // Port B (clk_vid): Raster scan reads linearly
    reg [17:0] framebuffer [0:38399];

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
    wire active    = (h_count < H_ACTIVE) & (v_count < V_ACTIVE);
    wire hs_region = (h_count >= H_ACTIVE + H_FP) &
                     (h_count <  H_ACTIVE + H_FP + H_SYNC);
    wire vs_region = (v_count >= V_ACTIVE + V_FP) &
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

    // Stage 1: delay active/sync by 1 clk_vid cycle to match BRAM latency
    reg active_d1;
    reg hs_d1, vs_d1;
    reg hs_d2, vs_d2;
    reg [8:0] h_count_d1;
    reg [7:0] v_count_d1;

    always @(posedge clk_vid) begin
        if (reset) begin
            active_d1 <= 0;
            hs_d1 <= 0;
            vs_d1 <= 0;
            hs_d2 <= 0;
            vs_d2 <= 0;
            h_count_d1 <= 0;
            v_count_d1 <= 0;
        end else begin
            active_d1 <= active;
            hs_d1     <= hs_region;
            vs_d1     <= vs_region;
            hs_d2     <= hs_d1;
            vs_d2     <= vs_d1;
            h_count_d1 <= h_count;
            v_count_d1 <= v_count;
        end
    end

    wire [23:0] video_rgb_next      = !active_d1 ? 24'd0 : {r8, g8, b8};
    wire debug_panel_active = active_d1 &&
                              (h_count_d1 >= DEBUG_ORIGIN_X) &&
                              (h_count_d1 < (DEBUG_ORIGIN_X + DEBUG_PANEL_W)) &&
                              (v_count_d1 >= DEBUG_ORIGIN_Y) &&
                              (v_count_d1 < (DEBUG_ORIGIN_Y + DEBUG_PANEL_H));
    wire [8:0] debug_panel_x = h_count_d1 - DEBUG_ORIGIN_X;
    wire [7:0] debug_panel_y = v_count_d1 - DEBUG_ORIGIN_Y;
    wire debug_border = debug_panel_active &&
                        ((debug_panel_x == 0) || (debug_panel_x == DEBUG_PANEL_W - 1) ||
                         (debug_panel_y == 0) || (debug_panel_y == DEBUG_PANEL_H - 1));
    wire debug_inner = debug_panel_active && !debug_border;
    wire [7:0] debug_cell_x = debug_panel_x - DEBUG_PAD;
    wire [7:0] debug_cell_y = debug_panel_y - DEBUG_PAD;
    wire [3:0] debug_col = debug_cell_x / DEBUG_STEP;
    wire [2:0] debug_row = debug_cell_y / DEBUG_STEP;
    wire [3:0] debug_x_mod = debug_cell_x % DEBUG_STEP;
    wire [3:0] debug_y_mod = debug_cell_y % DEBUG_STEP;
    wire debug_cell_active = debug_inner &&
                             (debug_col < DEBUG_COLS) &&
                             (debug_cell_y < (DEBUG_ROWS * DEBUG_STEP)) &&
                             (debug_x_mod < DEBUG_BOX) &&
                             (debug_y_mod < DEBUG_BOX);
    wire [6:0] debug_index_wide = (debug_row * DEBUG_COLS) + debug_col;
    wire [6:0] debug_index = debug_index_wide[6:0];
    wire       debug_bit = debug_overlay[debug_index];
    wire [23:0] debug_cell_rgb = (debug_row == 3'd5) ?
                                 (debug_bit ? 24'hFF6060 : 24'h402020) :
                                 (debug_row == 3'd4) ?
                                 (debug_bit ? 24'h4080FF : 24'h203050) :
                                 (debug_row == 3'd3) ?
                                 (debug_bit ? 24'hFF40A0 : 24'h402040) :
                                 (debug_row == 3'd2) ?
                                 (debug_bit ? 24'h00D8FF : 24'h203040) :
                                 (debug_row == 3'd1) ?
                                 (debug_bit ? 24'hFFB000 : 24'h303030) :
                                 (debug_bit ? 24'h00FF66 : 24'h202020);
    wire [23:0] video_rgb_debug = debug_border ? 24'hFFFFFF :
                                  debug_cell_active ? debug_cell_rgb :
                                  debug_panel_active ? 24'h000000 :
                                  video_rgb_next;

    // Stage 2: output registers with sync edge detection
    always @(posedge clk_vid) begin
        if (reset) begin
            video_rgb  <= 24'd0;
            video_de   <= 1'b0;
            video_hs   <= 1'b0;
            video_vs   <= 1'b0;
            video_skip <= 1'b0;
        end else begin
            video_rgb  <= video_rgb_debug;
            video_de   <= active_d1;
            video_hs   <= hs_d1 & ~hs_d2;    // Rising edge -> single clk_vid pulse
            video_vs   <= vs_d1 & ~vs_d2;    // Rising edge -> single clk_vid pulse
            video_skip <= ~vid_ce;
        end
    end

endmodule
