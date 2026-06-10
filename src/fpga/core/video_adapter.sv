// video_adapter.sv — GBA SDRAM frame-slot scanout for Analogue Pocket
//
// The GBA GPU writes pixels at arbitrary addresses into SDRAM-backed frame slots.
// This module scans a stable presented frame through small line buffers with
// proper sync timing for the Pocket's scaler (Aristotle).
//
// Clocking:
//   clk_sys (~100.66 MHz) — GPU pixel writes
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

    // GBA GPU pixel write interface (clk_sys domain)
    input  wire [15:0] pixel_addr,    // 0-38399 (linear: row*240 + col)
    input  wire [17:0] pixel_data,    // {R[5:0], G[5:0], B[5:0]}
    input  wire        pixel_we,
    input  wire        frame_complete,

    // Opportunistic SDRAM frame-slot write path (clk_sys domain).
    // Active scanout uses drained SDRAM lines; missed lines are output as black.
    input  wire        video_sdram_busy,
    output reg         video_sdram_wr,
    output reg  [24:0] video_sdram_addr,
    output reg  [15:0] video_sdram_data,
    output reg  [31:0] shadow_frame_counts,
    output reg  [31:0] shadow_fifo_status,

    // SDRAM line prefetch path (clk_sys request/response).
    input  wire        video_sdram_rd_busy,
    output reg         video_sdram_rd,
    output reg  [24:0] video_sdram_rd_addr,
    input  wire [63:0] video_sdram_rd_data,
    input  wire        video_sdram_rd_ready,
    output reg  [31:0] scanout_status,
    output reg  [31:0] arbitration_status,

    // Video output to APF scaler (clk_vid domain)
    output reg  [23:0] video_rgb,
    output reg         video_de,
    output reg         video_vs,
    output reg         video_hs,
    output reg         video_skip,

    // Debug/status: {presented_toggle, pending_valid, display_frame[1:0],
    //                pending_frame[1:0], write_frame[1:0]}
    output reg  [7:0]  frame_status
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

    // SDRAM framebuffer slots, word-addressed RGB565. Scanout reads drained
    // slots through line buffers and blanks any line that misses its deadline.
    // Four physical slots give Phase 6 one spare slot beyond display/pending/write,
    // so a newer completed frame can replace pending without immediately reusing
    // the old pending slot across the video-clock CDC boundary.
    localparam [24:0] VIDEO_FB_WORD_BASE = 25'h1C00000;
    localparam [24:0] VIDEO_SLOT_WORDS   = 25'd38400; // 240 * 160
    localparam        SHADOW_FIFO_DEPTH   = 512;
    localparam [9:0]  SHADOW_FIFO_FULL    = 10'd512;
    localparam [5:0]  VIDEO_BURSTS_PER_LINE = 6'd60; // 240 pixels / 4 pixels per burst

    function automatic [24:0] frame_slot_base(input [1:0] frame);
    begin
        case (frame)
            2'd0: frame_slot_base = VIDEO_FB_WORD_BASE;
            2'd1: frame_slot_base = VIDEO_FB_WORD_BASE + VIDEO_SLOT_WORDS;
            2'd2: frame_slot_base = VIDEO_FB_WORD_BASE + (VIDEO_SLOT_WORDS * 2);
            default: frame_slot_base = VIDEO_FB_WORD_BASE + (VIDEO_SLOT_WORDS * 3);
        endcase
    end
    endfunction

    function automatic [1:0] choose_write_frame(
        input [1:0] current,
        input [3:0] unavailable
    );
    begin
        if (!unavailable[0])
            choose_write_frame = 2'd0;
        else if (!unavailable[1])
            choose_write_frame = 2'd1;
        else if (!unavailable[2])
            choose_write_frame = 2'd2;
        else if (!unavailable[3])
            choose_write_frame = 2'd3;
        else
            choose_write_frame = current;
    end
    endfunction

    function automatic [16:0] line_word_offset(input [7:0] line);
        reg [16:0] line_ext;
    begin
        line_ext = {9'd0, line};
        line_word_offset = (line_ext << 8) - (line_ext << 4); // line * 240
    end
    endfunction

    // === Presentation State ===
    // The write-frame owner lives in clk_sys so SDRAM frame-slot writes follow
    // the pixel stream while display-frame promotion stays in clk_vid.
    reg       frame_complete_toggle;
    reg [1:0] write_frame_sys;
    reg [1:0] completed_frame_sys;
    reg [1:0] display_frame_sys_meta;
    reg [1:0] display_frame_sys;
    reg       pending_valid_sys;
    reg [1:0] pending_frame_sys;
    reg [2:0] frame_presented_sync_sys;
    reg       drain_candidate_valid_sys;
    reg [1:0] drain_candidate_frame_sys;
    reg       frame_close_pending;
    reg [3:0] frame_quiet_count;

    reg       pending_valid;
    reg [1:0] pending_frame;
    reg [1:0] display_frame;
    reg       frame_presented_toggle;
    wire [15:0] pixel_data_rgb565 = {pixel_data[17:13], pixel_data[11:6], pixel_data[5:1]};
    wire [24:0] pixel_shadow_addr = frame_slot_base(write_frame_sys) + {9'd0, pixel_addr};

    // Small write FIFO for SDRAM frame-slot updates. If it fills, pixels are
    // dropped from the SDRAM copy only; dirty copies are not made presentable.
    reg [40:0] shadow_fifo [0:SHADOW_FIFO_DEPTH-1];
    reg  [8:0] shadow_fifo_wr_ptr;
    reg  [8:0] shadow_fifo_rd_ptr;
    reg  [9:0] shadow_fifo_count;
    reg [15:0] shadow_frame_queued;
    reg [15:0] shadow_frame_dropped;
    reg [15:0] shadow_frame_drained;
    reg        last_shadow_frame_clean;
    reg        shadow_drop_seen;

    wire shadow_fifo_empty = (shadow_fifo_count == 10'd0);
    wire shadow_fifo_full  = (shadow_fifo_count == SHADOW_FIFO_FULL);
    wire shadow_fifo_push  = pixel_we & !shadow_fifo_full;
    wire shadow_fifo_drop  = pixel_we & shadow_fifo_full;
    wire shadow_fifo_pop   = !video_sdram_busy & !shadow_fifo_empty;
    wire [15:0] shadow_frame_queued_next =
        shadow_frame_queued + (shadow_fifo_push ? 16'd1 : 16'd0);
    wire [15:0] shadow_frame_dropped_next =
        shadow_frame_dropped + (shadow_fifo_drop ? 16'd1 : 16'd0);
    wire shadow_frame_clean = (shadow_frame_dropped_next == 16'd0);

    // === Raster Scan Counters (clk_vid domain, advance on vid_ce) ===
    reg [8:0] h_count;  // 0 to 307
    reg [7:0] v_count;  // 0 to 227

    // A frame slot becomes safe for SDRAM scanout only after all queued writes
    // for completed frames have drained through the low-priority path.
    reg [3:0] slot_ready_sys;
    reg [3:0] slot_drain_pending;
    wire      commit_drained_slots = shadow_fifo_empty && !video_sdram_busy;

    localparam [3:0] FRAME_SEAL_QUIET_CYCLES = 4'd8;
    wire [3:0] display_frame_bit_sys = (4'b0001 << display_frame_sys);
    wire [3:0] pending_frame_bit_sys = (4'b0001 << pending_frame_sys);
    wire [3:0] write_frame_bit = (4'b0001 << write_frame_sys);
    wire [3:0] unavailable_write_slots =
        display_frame_bit_sys | write_frame_bit | slot_drain_pending |
        (pending_valid_sys ? pending_frame_bit_sys : 4'b0000);
    wire [1:0] next_write_frame_sys =
        choose_write_frame(write_frame_sys, unavailable_write_slots);
    wire       write_slot_reused = (next_write_frame_sys == write_frame_sys);
    wire [3:0] next_write_frame_bit = (4'b0001 << next_write_frame_sys);
    wire       accept_completed_frame = shadow_frame_clean && !write_slot_reused;
    wire       seal_completed_frame =
        frame_close_pending && !pixel_we &&
        (frame_quiet_count == FRAME_SEAL_QUIET_CYCLES);
    wire [3:0] committed_ready_slots =
        commit_drained_slots ? (slot_ready_sys | slot_drain_pending) :
                               slot_ready_sys;
    wire [3:0] committed_drain_slots =
        commit_drained_slots ? 4'b0000 : slot_drain_pending;

    // Raw bridge debug at 0x9C after clk_74a sync:
    // [31] any SDRAM copy dropped, [30] last frame copy clean,
    // [29] write path busy, [28] read path busy, [27:24] ready slots,
    // [23:20] drain-pending slots, [19:18] display slot,
    // [17:16] last clean completed slot, [15:14] write slot,
    // [13:12] line-fetch state, [11:2] write FIFO level.

    // Two dual-clock line buffers. Port A is filled from SDRAM in clk_sys;
    // Port B is scanned by the video clock. Depth is 256 to map cleanly.
    reg        linebuf0_wr;
    reg        linebuf1_wr;
    reg  [7:0] linebuf_wr_addr;
    reg [15:0] linebuf_wr_data;
    wire [15:0] linebuf0_sys_q;
    wire [15:0] linebuf1_sys_q;
    wire [15:0] linebuf0_vid_q;
    wire [15:0] linebuf1_vid_q;
    wire  [7:0] linebuf_rd_addr = h_count[7:0];

    bram_block_dp #(.DATA(16), .ADDR(8)) sdram_linebuf0 (
        .a_clk  ( clk_sys ),
        .a_wr   ( linebuf0_wr ),
        .a_addr ( linebuf_wr_addr ),
        .a_din  ( linebuf_wr_data ),
        .a_dout ( linebuf0_sys_q ),
        .b_clk  ( clk_vid ),
        .b_wr   ( 1'b0 ),
        .b_addr ( linebuf_rd_addr ),
        .b_din  ( 16'd0 ),
        .b_dout ( linebuf0_vid_q )
    );

    bram_block_dp #(.DATA(16), .ADDR(8)) sdram_linebuf1 (
        .a_clk  ( clk_sys ),
        .a_wr   ( linebuf1_wr ),
        .a_addr ( linebuf_wr_addr ),
        .a_din  ( linebuf_wr_data ),
        .a_dout ( linebuf1_sys_q ),
        .b_clk  ( clk_vid ),
        .b_wr   ( 1'b0 ),
        .b_addr ( linebuf_rd_addr ),
        .b_din  ( 16'd0 ),
        .b_dout ( linebuf1_vid_q )
    );

    // Line prefetch request crosses from clk_vid to clk_sys as a toggle.
    reg       prefetch_toggle_vid;
    reg [7:0] prefetch_line_vid;
    reg [1:0] prefetch_frame_vid;
    reg [2:0] prefetch_toggle_sync;
    reg [7:0] prefetch_line_sync_1;
    reg [7:0] prefetch_line_sync_2;
    reg [1:0] prefetch_frame_sync_1;
    reg [1:0] prefetch_frame_sync_2;

    wire prefetch_request_sys = prefetch_toggle_sync[2] ^ prefetch_toggle_sync[1];

    localparam LF_IDLE   = 2'd0;
    localparam LF_REQ    = 2'd1;
    localparam LF_WAIT   = 2'd2;
    localparam LF_UNPACK = 2'd3;

    reg [1:0]  line_fetch_state;
    reg [7:0]  line_fetch_line;
    reg [1:0]  line_fetch_frame;
    reg [5:0]  line_fetch_burst;
    reg [1:0]  line_unpack_index;
    reg [63:0] line_fetch_data;
    reg [24:0] line_fetch_base_addr;
    reg        line_ready_toggle_sys;
    reg [7:0]  line_ready_line_sys;
    reg [1:0]  line_ready_frame_sys;

    wire [7:0] line_fetch_pixel_index = {line_fetch_burst, 2'b00} +
                                         {6'd0, line_unpack_index};
    wire [15:0] line_unpack_word =
        (line_unpack_index == 2'd0) ? line_fetch_data[15:0] :
        (line_unpack_index == 2'd1) ? line_fetch_data[31:16] :
        (line_unpack_index == 2'd2) ? line_fetch_data[47:32] :
                                      line_fetch_data[63:48];

    // Port A: GPU write (clk_sys domain)
    always @(posedge clk_sys) begin
        if (reset) begin
            frame_complete_toggle <= 1'b0;
            write_frame_sys       <= 2'd0;
            completed_frame_sys   <= 2'd0;
            display_frame_sys_meta <= 2'd0;
            display_frame_sys     <= 2'd0;
            pending_valid_sys     <= 1'b0;
            pending_frame_sys     <= 2'd0;
            frame_presented_sync_sys <= 3'b000;
            drain_candidate_valid_sys <= 1'b0;
            drain_candidate_frame_sys <= 2'd0;
            frame_close_pending   <= 1'b0;
            frame_quiet_count     <= 4'd0;
            video_sdram_wr        <= 1'b0;
            video_sdram_addr      <= 25'd0;
            video_sdram_data      <= 16'd0;
            video_sdram_rd        <= 1'b0;
            video_sdram_rd_addr   <= 25'd0;
            shadow_frame_counts   <= 32'd0;
            shadow_fifo_status    <= 32'd0;
            arbitration_status    <= 32'd0;
            shadow_fifo_wr_ptr    <= 9'd0;
            shadow_fifo_rd_ptr    <= 9'd0;
            shadow_fifo_count     <= 10'd0;
            shadow_frame_queued   <= 16'd0;
            shadow_frame_dropped  <= 16'd0;
            shadow_frame_drained  <= 16'd0;
            last_shadow_frame_clean <= 1'b0;
            shadow_drop_seen      <= 1'b0;
            slot_ready_sys        <= 4'b0000;
            slot_drain_pending    <= 4'b0000;
            linebuf0_wr           <= 1'b0;
            linebuf1_wr           <= 1'b0;
            linebuf_wr_addr       <= 8'd0;
            linebuf_wr_data       <= 16'd0;
            prefetch_toggle_sync  <= 3'b000;
            prefetch_line_sync_1  <= 8'd0;
            prefetch_line_sync_2  <= 8'd0;
            prefetch_frame_sync_1 <= 2'd0;
            prefetch_frame_sync_2 <= 2'd0;
            line_fetch_state      <= LF_IDLE;
            line_fetch_line       <= 8'd0;
            line_fetch_frame      <= 2'd0;
            line_fetch_burst      <= 6'd0;
            line_unpack_index     <= 2'd0;
            line_fetch_data       <= 64'd0;
            line_fetch_base_addr  <= 25'd0;
            line_ready_toggle_sys <= 1'b0;
            line_ready_line_sys   <= 8'd0;
            line_ready_frame_sys  <= 2'd0;
        end else begin
            display_frame_sys_meta <= display_frame;
            display_frame_sys      <= display_frame_sys_meta;
            frame_presented_sync_sys <= {frame_presented_sync_sys[1:0],
                                         frame_presented_toggle};
            video_sdram_wr         <= 1'b0;
            video_sdram_rd         <= 1'b0;
            linebuf0_wr            <= 1'b0;
            linebuf1_wr            <= 1'b0;
            shadow_fifo_status     <= {6'd0, shadow_fifo_count, shadow_frame_drained};
            prefetch_toggle_sync   <= {prefetch_toggle_sync[1:0], prefetch_toggle_vid};
            prefetch_line_sync_1   <= prefetch_line_vid;
            prefetch_line_sync_2   <= prefetch_line_sync_1;
            prefetch_frame_sync_1  <= prefetch_frame_vid;
            prefetch_frame_sync_2  <= prefetch_frame_sync_1;
            arbitration_status     <= {shadow_drop_seen, last_shadow_frame_clean,
                                       video_sdram_busy, video_sdram_rd_busy,
                                       slot_ready_sys, slot_drain_pending,
                                       display_frame_sys, completed_frame_sys,
                                       write_frame_sys, line_fetch_state,
                                       shadow_fifo_count, 2'b00};

            if ((frame_presented_sync_sys[2] ^ frame_presented_sync_sys[1]) &&
                pending_valid_sys && (pending_frame_sys == display_frame_sys)) begin
                pending_valid_sys <= 1'b0;
            end

            if (frame_complete) begin
                frame_close_pending <= 1'b1;
                frame_quiet_count   <= 4'd0;
            end else if (frame_close_pending) begin
                if (pixel_we) begin
                    frame_quiet_count <= 4'd0;
                end else if (frame_quiet_count < FRAME_SEAL_QUIET_CYCLES) begin
                    frame_quiet_count <= frame_quiet_count + 1'b1;
                end
            end

            if (shadow_fifo_pop) begin
                {video_sdram_addr, video_sdram_data} <= shadow_fifo[shadow_fifo_rd_ptr];
                video_sdram_wr                       <= 1'b1;
                shadow_fifo_rd_ptr                   <= shadow_fifo_rd_ptr + 1'b1;
                shadow_frame_drained                 <= shadow_frame_drained + 1'b1;
            end

            if (shadow_fifo_push) begin
                shadow_fifo[shadow_fifo_wr_ptr] <= {pixel_shadow_addr, pixel_data_rgb565};
                shadow_fifo_wr_ptr              <= shadow_fifo_wr_ptr + 1'b1;
                shadow_frame_queued             <= shadow_frame_queued + 1'b1;
            end else if (shadow_fifo_drop) begin
                shadow_frame_dropped <= shadow_frame_dropped + 1'b1;
                shadow_drop_seen     <= 1'b1;
            end

            case ({shadow_fifo_push, shadow_fifo_pop})
                2'b10: shadow_fifo_count <= shadow_fifo_count + 1'b1;
                2'b01: shadow_fifo_count <= shadow_fifo_count - 1'b1;
                default: shadow_fifo_count <= shadow_fifo_count;
            endcase

            if (commit_drained_slots) begin
                slot_ready_sys     <= slot_ready_sys | slot_drain_pending;
                slot_drain_pending <= 4'b0000;

                if (drain_candidate_valid_sys) begin
                    completed_frame_sys        <= drain_candidate_frame_sys;
                    frame_complete_toggle      <= ~frame_complete_toggle;
                    pending_frame_sys          <= drain_candidate_frame_sys;
                    pending_valid_sys          <= 1'b1;
                    drain_candidate_valid_sys  <= 1'b0;
                end
            end

            case (line_fetch_state)
                LF_IDLE: begin
                    if (prefetch_request_sys) begin
                        line_fetch_line      <= prefetch_line_sync_2;
                        line_fetch_frame     <= prefetch_frame_sync_2;
                        line_fetch_burst     <= 6'd0;
                        line_fetch_base_addr <= frame_slot_base(prefetch_frame_sync_2) +
                                                {8'd0, line_word_offset(prefetch_line_sync_2)};
                        line_fetch_state     <= LF_REQ;
                    end
                end

                LF_REQ: begin
                    if (!video_sdram_rd_busy) begin
                        video_sdram_rd      <= 1'b1;
                        video_sdram_rd_addr <= line_fetch_base_addr +
                                               {17'd0, line_fetch_burst, 2'b00};
                        line_fetch_state    <= LF_WAIT;
                    end
                end

                LF_WAIT: begin
                    if (video_sdram_rd_ready) begin
                        line_fetch_data   <= video_sdram_rd_data;
                        line_unpack_index <= 2'd0;
                        line_fetch_state  <= LF_UNPACK;
                    end
                end

                LF_UNPACK: begin
                    linebuf_wr_addr <= line_fetch_pixel_index;
                    linebuf_wr_data <= line_unpack_word;
                    if (line_fetch_line[0])
                        linebuf1_wr <= 1'b1;
                    else
                        linebuf0_wr <= 1'b1;

                    if (line_unpack_index == 2'd3) begin
                        if (line_fetch_burst == VIDEO_BURSTS_PER_LINE - 6'd1) begin
                            line_ready_line_sys   <= line_fetch_line;
                            line_ready_frame_sys  <= line_fetch_frame;
                            line_ready_toggle_sys <= ~line_ready_toggle_sys;
                            line_fetch_state      <= LF_IDLE;
                        end else begin
                            line_fetch_burst  <= line_fetch_burst + 1'b1;
                            line_fetch_state  <= LF_REQ;
                        end
                    end else begin
                        line_unpack_index <= line_unpack_index + 1'b1;
                    end
                end

                default: line_fetch_state <= LF_IDLE;
            endcase

            if (seal_completed_frame) begin
                // Close the frame only after the drawer's pixel-write pipeline
                // has gone quiet, then publish it after its SDRAM copy drains.
                if (accept_completed_frame) begin
                    drain_candidate_frame_sys <= write_frame_sys;
                    drain_candidate_valid_sys <= 1'b1;
                end
                write_frame_sys       <= next_write_frame_sys;
                shadow_frame_counts   <= {shadow_frame_dropped_next,
                                          shadow_frame_queued_next};
                shadow_fifo_status    <= {6'd0, shadow_fifo_count, shadow_frame_drained};
                last_shadow_frame_clean <= shadow_frame_clean;
                shadow_frame_queued   <= 16'd0;
                shadow_frame_dropped  <= 16'd0;
                shadow_frame_drained  <= 16'd0;
                frame_close_pending   <= 1'b0;
                frame_quiet_count     <= 4'd0;
                slot_ready_sys        <= committed_ready_slots &
                                          ~next_write_frame_bit & ~write_frame_bit;
                slot_drain_pending    <= (committed_drain_slots &
                                           ~next_write_frame_bit &
                                           ~write_frame_bit) |
                                          (accept_completed_frame ? write_frame_bit : 4'b0000);
            end
        end
    end

    // === Video Clock Enable (clk_vid / 2 = GBA dot clock) ===
    reg vid_ce;
    always @(posedge clk_vid) begin
        if (reset)
            vid_ce <= 0;
        else
            vid_ce <= ~vid_ce;
    end

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

    wire output_frame_boundary = vid_ce &
                                 (h_count == H_TOTAL - 1) &
                                 (v_count == V_TOTAL - 1);

    reg [3:0] slot_ready_sync_1;
    reg [3:0] slot_ready_sync_2;
    reg [2:0] line_ready_toggle_sync;
    reg [7:0] line_ready_line_sync_1;
    reg [7:0] line_ready_line_sync_2;
    reg [1:0] line_ready_frame_sync_1;
    reg [1:0] line_ready_frame_sync_2;
    reg       sdram_line_valid0;
    reg       sdram_line_valid1;
    reg [7:0] sdram_line_valid_line0;
    reg [7:0] sdram_line_valid_line1;
    reg [1:0] sdram_line_valid_frame0;
    reg [1:0] sdram_line_valid_frame1;
    reg       scan_line_valid;

    wire line_ready_edge_vid = line_ready_toggle_sync[2] ^ line_ready_toggle_sync[1];
    wire prepare_output_frame = vid_ce & (h_count == 9'd0) & (v_count == V_TOTAL - 1);
    wire pending_frame_ready = pending_valid && slot_ready_sync_2[pending_frame];
    wire [1:0] prefetch_frame_target =
        ((v_count == V_TOTAL - 1) && pending_frame_ready) ? pending_frame : display_frame;
    wire prefetch_frame_ready = slot_ready_sync_2[prefetch_frame_target];
    wire sdram_line_valid_now =
        slot_ready_sync_2[display_frame] &&
        (v_count[0] ?
         (sdram_line_valid1 && (sdram_line_valid_line1 == v_count) &&
          (sdram_line_valid_frame1 == display_frame)) :
         (sdram_line_valid0 && (sdram_line_valid_line0 == v_count) &&
          (sdram_line_valid_frame0 == display_frame)));

    always @(posedge clk_vid) begin
        if (reset) begin
            slot_ready_sync_1      <= 4'b0000;
            slot_ready_sync_2      <= 4'b0000;
            line_ready_toggle_sync <= 3'b000;
            line_ready_line_sync_1 <= 8'd0;
            line_ready_line_sync_2 <= 8'd0;
            line_ready_frame_sync_1 <= 2'd0;
            line_ready_frame_sync_2 <= 2'd0;
            sdram_line_valid0      <= 1'b0;
            sdram_line_valid1      <= 1'b0;
            sdram_line_valid_line0 <= 8'd0;
            sdram_line_valid_line1 <= 8'd0;
            sdram_line_valid_frame0 <= 2'd0;
            sdram_line_valid_frame1 <= 2'd0;
            scan_line_valid        <= 1'b0;
            prefetch_toggle_vid    <= 1'b0;
            prefetch_line_vid      <= 8'd0;
            prefetch_frame_vid     <= 2'd0;
        end else begin
            slot_ready_sync_1      <= slot_ready_sys;
            slot_ready_sync_2      <= slot_ready_sync_1;
            line_ready_toggle_sync <= {line_ready_toggle_sync[1:0], line_ready_toggle_sys};
            line_ready_line_sync_1 <= line_ready_line_sys;
            line_ready_line_sync_2 <= line_ready_line_sync_1;
            line_ready_frame_sync_1 <= line_ready_frame_sys;
            line_ready_frame_sync_2 <= line_ready_frame_sync_1;

            if (vid_ce && (h_count == 9'd0) && (v_count == V_TOTAL - 1)) begin
                sdram_line_valid0 <= 1'b0;
                sdram_line_valid1 <= 1'b0;
            end

            if (line_ready_edge_vid) begin
                if (line_ready_line_sync_2[0]) begin
                    sdram_line_valid1       <= 1'b1;
                    sdram_line_valid_line1  <= line_ready_line_sync_2;
                    sdram_line_valid_frame1 <= line_ready_frame_sync_2;
                end else begin
                    sdram_line_valid0       <= 1'b1;
                    sdram_line_valid_line0  <= line_ready_line_sync_2;
                    sdram_line_valid_frame0 <= line_ready_frame_sync_2;
                end
            end

            if (vid_ce && (h_count == 9'd0)) begin
                scan_line_valid <= (v_count < V_ACTIVE) && sdram_line_valid_now;
            end

            if (vid_ce && (h_count == 9'd0)) begin
                if ((v_count < V_ACTIVE - 1) && slot_ready_sync_2[display_frame]) begin
                    prefetch_line_vid  <= v_count + 1'b1;
                    prefetch_frame_vid <= display_frame;
                    prefetch_toggle_vid <= ~prefetch_toggle_vid;
                end else if ((v_count == V_TOTAL - 1) && prefetch_frame_ready) begin
                    prefetch_line_vid  <= 8'd0;
                    prefetch_frame_vid <= prefetch_frame_target;
                    prefetch_toggle_vid <= ~prefetch_toggle_vid;
                end
            end
        end
    end

    reg [2:0] frame_complete_sync;
    reg [1:0] completed_frame_sync_1;
    reg [1:0] completed_frame_sync_2;
    reg [1:0] write_frame_sync_1;
    reg [1:0] write_frame_sync_2;
    reg [1:0] present_frame;
    reg       present_valid;
    wire      present_frame_still_pending =
        present_valid && pending_valid && (pending_frame == present_frame) &&
        slot_ready_sync_2[present_frame];

    always @(posedge clk_vid) begin
        if (reset) begin
            frame_complete_sync    <= 3'b000;
            completed_frame_sync_1 <= 2'd0;
            completed_frame_sync_2 <= 2'd0;
            write_frame_sync_1     <= 2'd0;
            write_frame_sync_2     <= 2'd0;
            pending_valid          <= 1'b0;
            pending_frame          <= 2'd0;
            display_frame          <= 2'd0;
            present_frame          <= 2'd0;
            present_valid          <= 1'b0;
            frame_presented_toggle <= 1'b0;
            frame_status           <= 8'd0;
        end else begin
            frame_complete_sync <= {frame_complete_sync[1:0], frame_complete_toggle};
            completed_frame_sync_1 <= completed_frame_sys;
            completed_frame_sync_2 <= completed_frame_sync_1;
            write_frame_sync_1     <= write_frame_sys;
            write_frame_sync_2     <= write_frame_sync_1;

            if (prepare_output_frame) begin
                present_frame <= prefetch_frame_target;
                present_valid <= pending_frame_ready;
            end

            if (output_frame_boundary) begin
                present_valid <= 1'b0;
            end

            if (output_frame_boundary && present_frame_still_pending) begin
                display_frame          <= present_frame;
                pending_valid          <= 1'b0;
                frame_presented_toggle <= ~frame_presented_toggle;
            end

            if (frame_complete_sync[2] ^ frame_complete_sync[1]) begin
                pending_frame <= completed_frame_sync_2;
                pending_valid <= 1'b1;
            end

            frame_status <= {frame_presented_toggle, pending_valid,
                             display_frame, pending_frame, write_frame_sync_2};
        end
    end

    // === Active Area & Sync Region Detection ===
    wire active    = (h_count < H_ACTIVE) & (v_count < V_ACTIVE);
    wire hs_region = (h_count >= H_ACTIVE + H_FP) &
                     (h_count <  H_ACTIVE + H_FP + H_SYNC);
    wire vs_region = (v_count >= V_ACTIVE + V_FP) &
                     (v_count <  V_ACTIVE + V_FP + V_SYNC);

    // === Line-buffer scanout (clk_vid domain) ===
    reg        sdram_line_valid_d1;
    always @(posedge clk_vid) begin
        if (reset) begin
            sdram_line_valid_d1 <= 1'b0;
        end else if (active) begin
            sdram_line_valid_d1 <= scan_line_valid;
        end else begin
            sdram_line_valid_d1 <= 1'b0;
        end
    end

    // === Color Expansion: RGB565 -> 24-bit ===
    wire [15:0] sdram_pixel_rgb565 = v_count[0] ? linebuf1_vid_q : linebuf0_vid_q;
    wire [7:0] sr8 = {sdram_pixel_rgb565[15:11], sdram_pixel_rgb565[15:13]};
    wire [7:0] sg8 = {sdram_pixel_rgb565[10:5],  sdram_pixel_rgb565[10:9]};
    wire [7:0] sb8 = {sdram_pixel_rgb565[4:0],   sdram_pixel_rgb565[4:2]};

    // === Output Pipeline (2-stage, clk_vid domain) ===

    // Stage 1: delay active/sync by 1 clk_vid cycle to match line-buffer latency
    reg active_d1;
    reg hs_d1, vs_d1;
    reg hs_d2, vs_d2;
    reg [8:0] h_count_d1;
    reg [7:0] v_count_d1;
    reg [15:0] scanout_sdram_pixels;
    reg [15:0] scanout_missed_pixels;
    wire use_sdram_pixel = active_d1 && sdram_line_valid_d1;

    always @(posedge clk_vid) begin
        if (reset) begin
            active_d1 <= 0;
            hs_d1 <= 0;
            vs_d1 <= 0;
            hs_d2 <= 0;
            vs_d2 <= 0;
            h_count_d1 <= 9'd0;
            v_count_d1 <= 8'd0;
            scanout_sdram_pixels <= 16'd0;
            scanout_missed_pixels <= 16'd0;
            scanout_status <= 32'd0;
        end else begin
            active_d1 <= active;
            hs_d1     <= hs_region;
            vs_d1     <= vs_region;
            hs_d2     <= hs_d1;
            vs_d2     <= vs_d1;
            h_count_d1 <= h_count;
            v_count_d1 <= v_count;

            if (output_frame_boundary) begin
                scanout_status <= {scanout_missed_pixels, scanout_sdram_pixels};
                scanout_sdram_pixels <= 16'd0;
                scanout_missed_pixels <= 16'd0;
            end else if (active_d1) begin
                if (use_sdram_pixel)
                    scanout_sdram_pixels <= scanout_sdram_pixels + 1'b1;
                else
                    scanout_missed_pixels <= scanout_missed_pixels + 1'b1;
            end
        end
    end

    // Stage 2: output registers with sync edge detection
    wire [23:0] base_video_rgb =
        (active_d1 && use_sdram_pixel) ? {sr8, sg8, sb8} : 24'd0;

    always @(posedge clk_vid) begin
        if (reset) begin
            video_rgb  <= 24'd0;
            video_de   <= 1'b0;
            video_hs   <= 1'b0;
            video_vs   <= 1'b0;
            video_skip <= 1'b0;
        end else begin
            video_rgb  <= base_video_rgb;
            video_de   <= active_d1;
            video_hs   <= hs_d1 & ~hs_d2;    // Rising edge -> single clk_vid pulse
            video_vs   <= vs_d1 & ~vs_d2;    // Rising edge -> single clk_vid pulse
            video_skip <= ~vid_ce;
        end
    end

endmodule
