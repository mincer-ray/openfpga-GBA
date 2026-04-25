// gba_analogizer_video.sv
//
// Analogizer-only CRT raster generator for the GBA core.
//
// The duplicate framebuffer this originally used would exceed the device's
// M10K BRAM budget. Instead, this module shares video_adapter's existing
// framebuffer read port via time-division: video_adapter reads on vid_ce=1
// cycles, this module reads on vid_ce=0 cycles. No extra M10K required.
//
// Timing target (clk_vid = 8.388608 MHz):
//   H_TOTAL = 536  →  8.388608 / 536  ≈ 15.65 kHz
//   V_TOTAL = 262  →  15.65 kHz / 262 ≈ 59.73 Hz

`default_nettype none

module gba_analogizer_video #(
    parameter bit SYNC_ACTIVE_LOW = 1'b0,

    parameter int SRC_W = 240,
    parameter int SRC_H = 160,

    parameter int H_TOTAL  = 536,
    parameter int H_ACTIVE = 448,
    parameter int H_FP     = 16,
    parameter int H_SYNC   = 40,
    parameter int H_BP     = H_TOTAL - H_ACTIVE - H_FP - H_SYNC,

    parameter int V_TOTAL  = 262,
    parameter int V_ACTIVE = 160,
    parameter int V_TOP    = 51,
    parameter int V_FP     = 4,
    parameter int V_SYNC   = 3,

    parameter bit TEST_PATTERN = 1'b0
) (
    input  wire        clk_vid,
    input  wire        reset,

    // Shared framebuffer read port (from video_adapter, time-multiplexed)
    // video_adapter samples fb_rd_addr on vid_ce=0 cycles and returns data
    // in fb_rd_data on the next vid_ce=1 cycle (fb_rd_valid=1).
    output wire [15:0] fb_rd_addr,
    input  wire [17:0] fb_rd_data,
    input  wire        fb_rd_valid,   // = vid_ce from video_adapter

    // CRT video outputs (clk_vid domain)
    output reg  [23:0] rgb,
    output reg         hblank,
    output reg         vblank,
    output reg         blankn,
    output reg         hsync,
    output reg         vsync,
    output reg         csync,

    output wire        video_clk,
    output wire        ce_pix
);

    // ---- Raster counters ----
    reg [9:0] h_count;
    reg [8:0] v_count;

    wire end_of_line  = (h_count == H_TOTAL - 1);
    wire end_of_frame = (v_count == V_TOTAL - 1);

    always @(posedge clk_vid) begin
        if (reset) begin
            h_count <= '0;
            v_count <= '0;
        end else begin
            if (end_of_line) begin
                h_count <= '0;
                v_count <= end_of_frame ? '0 : v_count + 1'b1;
            end else begin
                h_count <= h_count + 1'b1;
            end
        end
    end

    // ---- Active / sync regions ----
    wire h_active = (h_count < H_ACTIVE);
    wire v_active = (v_count >= V_TOP) && (v_count < V_TOP + V_ACTIVE);
    wire active   = h_active && v_active;

    wire hsync_region =
        (h_count >= H_ACTIVE + H_FP) &&
        (h_count <  H_ACTIVE + H_FP + H_SYNC);

    wire vsync_region =
        (v_count >= V_TOP + V_ACTIVE + V_FP) &&
        (v_count <  V_TOP + V_ACTIVE + V_FP + V_SYNC);

    // ---- Horizontal nearest-neighbour scaler: H_ACTIVE output → SRC_W source ----
    reg [8:0]  src_x;
    reg [15:0] src_x_acc;

    wire [16:0] src_x_acc_next = src_x_acc + SRC_W;

    always @(posedge clk_vid) begin
        if (reset || end_of_line) begin
            src_x     <= '0;
            src_x_acc <= '0;
        end else if (h_active) begin
            if (src_x_acc_next >= H_ACTIVE) begin
                src_x_acc <= src_x_acc_next - H_ACTIVE;
                if (src_x < SRC_W - 1)
                    src_x <= src_x + 1'b1;
            end else begin
                src_x_acc <= src_x_acc_next[15:0];
            end
        end
    end

    wire [8:0] src_y = v_count - V_TOP;

    // src_y * 240 via shift-subtract (256 - 16 = 240)
    wire [16:0] src_y_times_240 =
        ({8'd0, src_y} << 8) - ({8'd0, src_y} << 4);
    wire [16:0] read_addr_calc = src_y_times_240 + src_x;

    // ---- Shared framebuffer read (via video_adapter time-multiplexed port) ----
    // Always present the current read address; video_adapter reads it on vid_ce=0
    // cycles and returns data on vid_ce=1 cycles (fb_rd_valid=1).
    assign fb_rd_addr = read_addr_calc[15:0];

    // Latch pixel whenever video_adapter delivers new data (vid_ce=1).
    // pixel_read holds its value between updates, which is correct because
    // src_x stays constant for ~1.87 consecutive output cycles on average.
    reg [17:0] pixel_read;
    always @(posedge clk_vid) begin
        if (reset)
            pixel_read <= '0;
        else if (fb_rd_valid)
            pixel_read <= fb_rd_data;
    end

    // 6-bit per channel → 8-bit
    wire [7:0] r8 = {pixel_read[17:12], pixel_read[17:16]};
    wire [7:0] g8 = {pixel_read[11:6],  pixel_read[11:10]};
    wire [7:0] b8 = {pixel_read[5:0],   pixel_read[5:4]};

    // ---- Optional sync test pattern ----
    wire [23:0] test_rgb =
        (h_count < (H_ACTIVE / 4) * 1) ? 24'hFF0000 :
        (h_count < (H_ACTIVE / 4) * 2) ? 24'h00FF00 :
        (h_count < (H_ACTIVE / 4) * 3) ? 24'h0000FF :
                                          24'hFFFFFF;

    wire [23:0] source_rgb = TEST_PATTERN ? test_rgb : {r8, g8, b8};

    // ---- Output pipeline ----
    reg active_d;
    reg hsync_region_d;
    reg vsync_region_d;

    always @(posedge clk_vid) begin
        if (reset) begin
            active_d       <= 1'b0;
            hsync_region_d <= 1'b0;
            vsync_region_d <= 1'b0;
            rgb    <= 24'h000000;
            hblank <= 1'b1;
            vblank <= 1'b1;
            blankn <= 1'b0;
            hsync  <= SYNC_ACTIVE_LOW ? 1'b1 : 1'b0;
            vsync  <= SYNC_ACTIVE_LOW ? 1'b1 : 1'b0;
            csync  <= SYNC_ACTIVE_LOW ? 1'b1 : 1'b0;
        end else begin
            active_d       <= active;
            hsync_region_d <= hsync_region;
            vsync_region_d <= vsync_region;

            rgb    <= active_d ? source_rgb : 24'h000000;
            hblank <= ~h_active;
            vblank <= ~v_active;
            blankn <= active_d;

            if (SYNC_ACTIVE_LOW) begin
                hsync <= ~hsync_region_d;
                vsync <= ~vsync_region_d;
                csync <= ~(hsync_region_d ^ vsync_region_d);
            end else begin
                hsync <= hsync_region_d;
                vsync <= vsync_region_d;
                csync <=  hsync_region_d ^ vsync_region_d;
            end
        end
    end

    assign video_clk = clk_vid;
    assign ce_pix    = 1'b1;

endmodule

`default_nettype wire
