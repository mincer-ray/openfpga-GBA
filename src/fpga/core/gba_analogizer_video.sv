// gba_analogizer_video.sv
//
// Analogizer-only CRT raster generator for the GBA core.
//
// This module shares video_adapter's existing framebuffer read port via
// time-division: video_adapter reads on vid_ce=1 cycles, this module reads on
// vid_ce=0 cycles. The shared port only returns one source pixel every two
// clk_vid cycles, so this module prefetches each 240-pixel GBA line into a
// small ping-pong line buffer before rasterizing it at CRT pixel rate.
//
// Timing target (clk_vid = 8.388608 MHz, H_TOTAL=536, V_TOTAL=262):
//   H_rate = 8.388608 / 536 = 15.65 kHz
//   V_rate = 15.65 kHz / 262 = 59.7 Hz
//
// scale_mode input (from interact.json 0x8C, synced to clk_vid in core_top):
//   0 = Debug 1x       240 output clocks, full GBA columns 0..239.
//   1 = Aspect/Normal  320 output clocks, nearest-neighbor GBA columns 0..239.
//   2 = Wide/Overscan  448 output clocks, full GBA columns 0..239.
//   3 = Aspect/Blend   320 output clocks, horizontally interpolated.
//   4 = Blend +12.5%   360x180 output clocks, horizontally interpolated.

`default_nettype none

module gba_analogizer_video #(
    parameter bit SYNC_ACTIVE_LOW = 1'b0,

    parameter int SRC_W = 240,
    parameter int SRC_H = 160,

    parameter int H_TOTAL  = 536,
    parameter int H_ACTIVE = 480,
    parameter int H_FP     = 4,
    parameter int H_SYNC   = 40,
    parameter int H_BP     = H_TOTAL - H_ACTIVE - H_FP - H_SYNC,

    parameter int V_TOTAL  = 262,
    parameter int V_ACTIVE = 160,
    parameter int V_TOP    = 51,
    parameter int V_FP     = 48,
    parameter int V_SYNC   = 3,

    parameter bit TEST_PATTERN = 1'b0
) (
    input  wire        clk_vid,
    input  wire        reset,
    input  wire [2:0]  scale_mode,   // 0=Debug 1x, 1=Aspect/Normal, 2=Wide/Overscan, 3/4=Blend

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

    // ---- Scale mode decode ----
    localparam [9:0] IMG_W_DEBUG  = 10'd240;
    localparam [9:0] IMG_W_NORMAL = 10'd320;
    localparam [9:0] IMG_W_WIDE   = 10'd448;
    localparam [9:0] IMG_W_LARGE  = 10'd360;
    localparam [8:0] IMG_H_NORMAL = 9'd160;
    localparam [8:0] IMG_H_LARGE  = 9'd180;
    localparam [9:0] LP_H_ACTIVE  = H_ACTIVE;
    localparam [10:0] LP_SRC_W    = SRC_W;

    wire mode_debug = (scale_mode == 3'd0);
    wire mode_wide  = (scale_mode == 3'd2);
    wire mode_large = (scale_mode == 3'd4);
    wire mode_blend = (scale_mode == 3'd3) || mode_large;

    wire [9:0] image_width = mode_debug ? IMG_W_DEBUG :
                             mode_wide  ? IMG_W_WIDE  :
                             mode_large ? IMG_W_LARGE :
                                          IMG_W_NORMAL;
    wire [9:0] image_left  = (LP_H_ACTIVE - image_width) >> 1;
    wire [8:0] image_height = mode_large ? IMG_H_LARGE : IMG_H_NORMAL;
    wire [8:0] image_top = V_TOP - ((image_height - IMG_H_NORMAL) >> 1);

    function automatic [8:0] scale_y_to_src;
        input [8:0] out_y;
        input       large_mode;
        reg   [4:0] repeats;
        begin
            if (!large_mode) begin
                scale_y_to_src = out_y;
            end else begin
                if      (out_y <= 9'd7)   repeats = 5'd0;
                else if (out_y <= 9'd16)  repeats = 5'd1;
                else if (out_y <= 9'd25)  repeats = 5'd2;
                else if (out_y <= 9'd34)  repeats = 5'd3;
                else if (out_y <= 9'd43)  repeats = 5'd4;
                else if (out_y <= 9'd52)  repeats = 5'd5;
                else if (out_y <= 9'd61)  repeats = 5'd6;
                else if (out_y <= 9'd70)  repeats = 5'd7;
                else if (out_y <= 9'd79)  repeats = 5'd8;
                else if (out_y <= 9'd88)  repeats = 5'd9;
                else if (out_y <= 9'd97)  repeats = 5'd10;
                else if (out_y <= 9'd106) repeats = 5'd11;
                else if (out_y <= 9'd115) repeats = 5'd12;
                else if (out_y <= 9'd124) repeats = 5'd13;
                else if (out_y <= 9'd133) repeats = 5'd14;
                else if (out_y <= 9'd142) repeats = 5'd15;
                else if (out_y <= 9'd151) repeats = 5'd16;
                else if (out_y <= 9'd160) repeats = 5'd17;
                else if (out_y <= 9'd169) repeats = 5'd18;
                else if (out_y <= 9'd178) repeats = 5'd19;
                else                       repeats = 5'd20;
                scale_y_to_src = out_y - repeats;
            end
        end
    endfunction

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
    // h_active is the blanking/sync visible band. image_width is the scaled
    // GBA image inside that band.
    wire h_active = (h_count < H_ACTIVE);
    wire active_v = (v_count >= image_top) && (v_count < image_top + image_height);
    wire [8:0] output_y = v_count - image_top;
    wire [8:0] src_y = scale_y_to_src(output_y, mode_large);

    // active_h: centred image window within h_active.
    wire active_h = (h_count >= image_left) && (h_count < image_left + image_width);
    wire active   = active_h && active_v;

    wire hsync_region =
        (h_count >= H_ACTIVE + H_FP) &&
        (h_count <  H_ACTIVE + H_FP + H_SYNC);

    wire vsync_region =
        (v_count >= V_TOP + V_ACTIVE + V_FP) &&
        (v_count <  V_TOP + V_ACTIVE + V_FP + V_SYNC);

    // ---- Line-buffer prefetch ----
    (* ramstyle = "MLAB" *) reg [17:0] linebuf [0:511];

    reg        prefetch_active;
    reg        prefetch_buf;
    reg [8:0]  prefetch_x;
    reg [8:0]  prefetch_y;
    reg        pending_valid;
    reg        pending_buf;
    reg [8:0]  pending_x;

    wire prefetch_line_candidate =
        (v_count >= image_top - 1'b1) && (v_count < image_top + image_height - 1'b1);
    wire [8:0] prefetch_output_y = v_count - (image_top - 1'b1);
    wire [8:0] prefetch_line_y = scale_y_to_src(prefetch_output_y, mode_large);
    wire prefetch_line_repeats_current = active_v && (prefetch_line_y == src_y);
    wire prefetch_line = prefetch_line_candidate && !prefetch_line_repeats_current;

    // prefetch_y * 240 via shift-subtract (256 - 16 = 240)
    wire [16:0] prefetch_y_times_240 =
        ({8'd0, prefetch_y} << 8) - ({8'd0, prefetch_y} << 4);
    wire [16:0] prefetch_addr_calc = prefetch_y_times_240 + prefetch_x;

    assign fb_rd_addr = (prefetch_active && (prefetch_x < SRC_W)) ?
                        prefetch_addr_calc[15:0] : 16'd0;

    always @(posedge clk_vid) begin
        if (reset) begin
            prefetch_active <= 1'b0;
            prefetch_buf    <= 1'b0;
            prefetch_x      <= '0;
            prefetch_y      <= '0;
            pending_valid   <= 1'b0;
            pending_buf     <= 1'b0;
            pending_x       <= '0;
        end else begin
            if (h_count == 10'd0) begin
                prefetch_active <= prefetch_line;
                prefetch_buf    <= prefetch_line_y[0];
                prefetch_x      <= '0;
                prefetch_y      <= prefetch_line_y;
            end

            if (fb_rd_valid && pending_valid) begin
                pending_valid <= 1'b0;
                if (pending_x == SRC_W - 1)
                    prefetch_active <= 1'b0;
                else
                    prefetch_x <= pending_x + 1'b1;
            end else if (!fb_rd_valid && prefetch_active && (prefetch_x < SRC_W)) begin
                pending_valid <= 1'b1;
                pending_buf   <= prefetch_buf;
                pending_x     <= prefetch_x;
            end
        end
    end

    // ---- Source pixel mapping from line buffer ----
    reg [8:0]  src_x_r;
    reg [9:0]  scale_phase;

    wire first_image_pixel = active_h && (h_count == image_left);
    wire [8:0] src_x = first_image_pixel ? 9'd0 : src_x_r;

    wire [10:0] scale_phase_base = {1'b0, (first_image_pixel ? 10'd0 : scale_phase)};
    wire [10:0] scale_phase_sum = scale_phase_base + LP_SRC_W;
    wire        scale_step_src  = (scale_phase_sum >= {1'b0, image_width});
    wire [10:0] scale_phase_sub = scale_phase_sum - {1'b0, image_width};
    wire [9:0]  scale_phase_next = scale_step_src ? scale_phase_sub[9:0] : scale_phase_sum[9:0];
    wire [8:0]  src_x_next = (scale_step_src && (src_x < SRC_W - 1)) ?
                             (src_x + 1'b1) : src_x;
    wire [8:0]  src_x_blend_next = (src_x < SRC_W - 1) ? (src_x + 1'b1) : src_x;

    wire [10:0] blend_q1 = {1'b0, image_width[9:2]};
    wire [10:0] blend_q2 = {1'b0, image_width[9:1]};
    wire [10:0] blend_q3 = blend_q1 + blend_q2;
    wire [1:0] blend_weight_next = (scale_phase_base < blend_q1) ? 2'd0 :
                                   (scale_phase_base < blend_q2) ? 2'd1 :
                                   (scale_phase_base < blend_q3) ? 2'd2 :
                                                                    2'd3;

    always @(posedge clk_vid) begin
        if (reset) begin
            src_x_r     <= '0;
            scale_phase <= '0;
        end else if (active_h) begin
            scale_phase <= scale_phase_next;
            src_x_r     <= src_x_next;
        end else begin
            src_x_r     <= '0;
            scale_phase <= '0;
        end
    end

    wire       output_buf = src_y[0];
    wire [8:0] linebuf_wr_addr = {pending_buf, pending_x[7:0]};
    wire [8:0] linebuf_rd_addr_next = {
        active_v ? output_buf : 1'b0,
        (active_h ? src_x[7:0] : 8'd0)
    };
    wire [8:0] linebuf_rd_addr_blend_next = {
        active_v ? output_buf : 1'b0,
        (active_h ? src_x_blend_next[7:0] : 8'd0)
    };

    reg [8:0]  linebuf_rd_addr;
    reg [8:0]  linebuf_rd_addr_blend;
    reg [1:0]  linebuf_rd_weight;
    reg [17:0] pixel_read;
    reg [17:0] pixel_blend_read;
    reg [1:0]  pixel_weight;
    always @(posedge clk_vid) begin
        if (reset) begin
            linebuf_rd_addr <= '0;
            linebuf_rd_addr_blend <= '0;
            linebuf_rd_weight <= '0;
        end else begin
            linebuf_rd_addr <= linebuf_rd_addr_next;
            linebuf_rd_addr_blend <= linebuf_rd_addr_blend_next;
            linebuf_rd_weight <= blend_weight_next;
        end
    end

    always @(posedge clk_vid) begin
        if (fb_rd_valid && pending_valid)
            linebuf[linebuf_wr_addr] <= fb_rd_data;

        pixel_read       <= linebuf[linebuf_rd_addr];
        pixel_blend_read <= linebuf[linebuf_rd_addr_blend];
        pixel_weight     <= linebuf_rd_weight;
    end

    // 6-bit per channel → 8-bit (replicate top 2 bits into bottom 2)
    wire [7:0] r8 = {pixel_read[17:12], pixel_read[17:16]};
    wire [7:0] g8 = {pixel_read[11:6],  pixel_read[11:10]};
    wire [7:0] b8 = {pixel_read[5:0],   pixel_read[5:4]};

    wire [7:0] r8_blend = {pixel_blend_read[17:12], pixel_blend_read[17:16]};
    wire [7:0] g8_blend = {pixel_blend_read[11:6],  pixel_blend_read[11:10]};
    wire [7:0] b8_blend = {pixel_blend_read[5:0],   pixel_blend_read[5:4]};

    function automatic [7:0] interp8;
        input [7:0] a;
        input [7:0] b;
        input [1:0] weight;
        begin
            case (weight)
                2'd1: interp8 = (({2'b00, a} << 1) + {2'b00, a} + {2'b00, b} + 10'd2) >> 2;
                2'd2: interp8 = ({1'b0, a} + {1'b0, b} + 9'd1) >> 1;
                2'd3: interp8 = ({2'b00, a} + ({2'b00, b} << 1) + {2'b00, b} + 10'd2) >> 2;
                default: interp8 = a;
            endcase
        end
    endfunction

    wire [23:0] blended_rgb = {
        interp8(r8, r8_blend, pixel_weight),
        interp8(g8, g8_blend, pixel_weight),
        interp8(b8, b8_blend, pixel_weight)
    };

    // ---- Optional sync test pattern ----
    wire [23:0] test_rgb =
        (h_count < (H_ACTIVE / 4) * 1) ? 24'hFF0000 :
        (h_count < (H_ACTIVE / 4) * 2) ? 24'h00FF00 :
        (h_count < (H_ACTIVE / 4) * 3) ? 24'h0000FF :
                                          24'hFFFFFF;

    wire [23:0] source_rgb = TEST_PATTERN ? test_rgb :
                             mode_blend   ? blended_rgb :
                                            {r8, g8, b8};

    // ---- Output registers ----

    always @(posedge clk_vid) begin
        if (reset) begin
            rgb    <= 24'h000000;
            hblank <= 1'b1;
            vblank <= 1'b1;
            blankn <= 1'b0;
            hsync  <= SYNC_ACTIVE_LOW ? 1'b1 : 1'b0;
            vsync  <= SYNC_ACTIVE_LOW ? 1'b1 : 1'b0;
            csync  <= SYNC_ACTIVE_LOW ? 1'b1 : 1'b0;
        end else begin
            rgb    <= active ? source_rgb : 24'h000000;
            hblank <= ~h_active;
            vblank <= ~active_v;
            blankn <= active;

            if (SYNC_ACTIVE_LOW) begin
                hsync <= ~hsync_region;
                vsync <= ~vsync_region;
                csync <= ~(hsync_region ^ vsync_region);
            end else begin
                hsync <= hsync_region;
                vsync <= vsync_region;
                csync <=  hsync_region ^ vsync_region;
            end
        end
    end

    assign video_clk = clk_vid;
    assign ce_pix    = 1'b1;

endmodule

`default_nettype wire
