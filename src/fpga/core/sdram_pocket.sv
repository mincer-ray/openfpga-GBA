//
// sdram_pocket.sv — Dual-channel SDRAM controller for Analogue Pocket
//
// Ch1: ROM burst-4 reads (64-bit) + single 16-bit writes for ROM loading
// Ch2: EWRAM 32-bit reads/writes (burst-4 read, capture first 2 words;
//       two sequential WRITEs for 32-bit write)
//
// Based on GBA_MiSTer sdram.sv (Sorgelig, GPL-3.0).
// Originally simplified to 1-channel for ROM only. Ch2 re-added to move
// EWRAM from slow PSRAM (~25 cycle latency) to fast SDRAM (~8 cycles),
// eliminating CPU cycle starvation that caused audio pitch warble.
//
// Pocket SDRAM: AS4C32M16MSA-6BIN — 512 Mbit (64 MB), 16-bit, 166 MHz max
// Configuration: CAS latency 2, burst length 4, sequential access
//
// Address map:
//   Ch1 ROM:   DWORD addr 0x000000 - 0x7FFFFF (up to 32 MB)
//   Ch2 EWRAM: DWORD addr 0x800000 - 0x80FFFF (256 KB)
//
// Copyright (c) 2015-2019 Sorgelig (original 3-channel design)
// Modified 2026 for Analogue Pocket
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

module sdram_pocket (
    input  wire        clk,          // ~100 MHz system clock
    input  wire        reset,        // Active-high reset (active while PLL not locked)

    // Ch1: ROM reads (active during gameplay)
    input  wire        rd_req,       // Read request pulse
    input  wire [24:0] rd_addr,      // DWORD address (25-bit -> 32 MB byte addressable)
    output reg  [31:0] rd_data,      // First dword (valid when rd_ready=1)
    output reg  [31:0] rd_data_second, // Second dword (valid 1 cycle after rd_ready=1)
    output reg         rd_ready,     // Read data valid pulse

    // Ch1: ROM loading writes (active during boot)
    input  wire        wr_req,       // Write request pulse
    input  wire [24:0] wr_addr,      // WORD address (25-bit -> 64 MB byte addressable)
    input  wire [15:0] wr_data,      // 16-bit write data

    // Ch2: EWRAM read/write (active during gameplay)
    input  wire        ch2_rd,       // Read request pulse
    input  wire        ch2_wr,       // Write request pulse
    input  wire [24:0] ch2_addr,     // DWORD address
    input  wire [31:0] ch2_din,      // 32-bit write data
    output reg  [31:0] ch2_dout,     // 32-bit read data (valid when ch2_ready=1)
    output reg         ch2_ready,    // Ch2 operation complete pulse

    // Ready signal — high when init complete and controller can accept requests
    output wire        sdram_ready,

    // Write pending — high when a ch1 write is latched but not yet serviced
    output wire        wr_pending,

    // Physical SDRAM pins
    output wire [12:0] dram_a,
    output wire  [1:0] dram_ba,
    inout  reg  [15:0] dram_dq,
    output wire  [1:0] dram_dqm,
    output wire        dram_clk,
    output wire        dram_cke,
    output wire        dram_ras_n,
    output wire        dram_cas_n,
    output wire        dram_we_n
);

// ============================================================
// SDRAM Configuration (matches MiSTer GBA exactly)
// ============================================================

localparam BURST_COUNT    = 4;
localparam BURST_CODE     = 3'b010;
localparam ACCESS_TYPE    = 1'b0;     // Sequential
localparam CAS_LATENCY    = 3'd2;
localparam OP_MODE        = 2'b00;
localparam NO_WRITE_BURST = 1'b1;

localparam [12:0] MODE = {3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_CODE};

// 200 µs power-up delay at 100 MHz = 20000 cycles; 256 is conservative min
localparam STARTUP_CYCLES      = 14'd256;
// SDRAM: 8192 rows refreshed in 64 ms → 64e6 ns / 8192 = 7812.5 ns per row
// At 100.66 MHz (9.93 ns period): 7812.5 / 9.93 ≈ 787 cycles; 780 adds margin
localparam CYCLES_PER_REFRESH  = 14'd780;
// Saturated counter initial value so first refresh fires after startup
localparam STARTUP_REFRESH_MAX = 14'b11111111111111;

// ============================================================
// Command Encoding: {nRAS, nCAS, nWE} (nCS tied low)
// ============================================================

localparam CMD_NOP          = 3'b111;
localparam CMD_ACTIVE       = 3'b011;
localparam CMD_READ         = 3'b101;
localparam CMD_WRITE        = 3'b100;
localparam CMD_PRECHARGE    = 3'b010;
localparam CMD_AUTO_REFRESH = 3'b001;
localparam CMD_LOAD_MODE    = 3'b000;

// ============================================================
// Output Registers
// ============================================================

reg  [12:0] sd_addr;
reg   [1:0] sd_ba;
reg   [2:0] command;

assign dram_ras_n = command[2];
assign dram_cas_n = command[1];
assign dram_we_n  = command[0];
assign dram_cke   = 1'b1;
assign dram_a     = sd_addr;
assign dram_ba    = sd_ba;
assign dram_dqm   = sd_addr[12:11];

// ============================================================
// State Machine
// ============================================================

localparam STATE_STARTUP  = 4'd0;
localparam STATE_IDLE     = 4'd1;
localparam STATE_WAIT     = 4'd2;   // tRCD wait after ACTIVATE
localparam STATE_RW       = 4'd3;   // Issue READ or WRITE command
localparam STATE_IDLE_5   = 4'd4;
localparam STATE_IDLE_4   = 4'd5;
localparam STATE_IDLE_3   = 4'd6;
localparam STATE_IDLE_2   = 4'd7;
localparam STATE_IDLE_1   = 4'd8;   // Check refresh before returning to IDLE
localparam STATE_RFSH     = 4'd9;
localparam STATE_CH2_WR2  = 4'd10;  // Second 16-bit WRITE for ch2 32-bit writes

reg  [3:0] state = STATE_STARTUP;
reg [13:0] refresh_count = STARTUP_REFRESH_MAX - STARTUP_CYCLES;

assign sdram_ready = (state != STATE_STARTUP);
assign wr_pending  = wr_rq;

// ============================================================
// Internal Registers
// ============================================================

reg        req_pending      = 0;
reg        req_is_write     = 0;
reg        req_is_ch2       = 0;  // Current request is ch2 (EWRAM)
reg        req_is_ch2_write = 0;  // Current request is ch2 write
reg [24:0] req_addr         = 0;
reg [15:0] req_wdata        = 0;

localparam CAPTURE_DELAY = CAS_LATENCY + BURST_COUNT; // 2 + 4 = 6
reg [CAPTURE_DELAY:0] data_ready_delay = 0;
reg        capture_is_ch2   = 0;  // Read data should go to ch2_dout
reg [15:0] dq_reg           = 0;
reg [12:0] cas_addr         = 0;

// Ch1 sticky request latches
reg        wr_rq      = 0;
reg [24:0] wr_rq_addr = 0;
reg [15:0] wr_rq_data = 0;
reg        rd_rq      = 0;

// Ch2 sticky request latches
reg        ch2_rd_rq   = 0;
reg        ch2_wr_rq   = 0;
reg [24:0] ch2_rq_addr = 0;
reg [31:0] ch2_rq_din  = 0;

// ============================================================
// Main State Machine
// ============================================================

always @(posedge clk) begin
    // Defaults
    dram_dq    <= 16'hZZZZ;
    command    <= CMD_NOP;
    rd_ready   <= 0;
    ch2_ready  <= 0;

    refresh_count <= refresh_count + 1'd1;

    data_ready_delay <= data_ready_delay >> 1;

    dq_reg <= dram_dq;

    // Capture burst data — route to ch1 or ch2 based on capture_is_ch2
    // Burst-4 returns 4 words. Ch2 uses first 2 (one DWORD), ch1 uses all 4.
    // capture_is_ch2 stays set through all 4 words to suppress spurious rd_ready.
    if (data_ready_delay[3]) begin
        if (capture_is_ch2) ch2_dout[15:0]  <= dq_reg;
        else                rd_data[15:0]   <= dq_reg;
    end
    if (data_ready_delay[2]) begin
        if (capture_is_ch2) begin
            ch2_dout[31:16] <= dq_reg;
            ch2_ready       <= 1;
        end else begin
            rd_data[31:16]  <= dq_reg;
        end
    end
    if (data_ready_delay[1]) begin
        if (!capture_is_ch2) begin
            rd_data_second[15:0] <= dq_reg;
            rd_ready             <= 1;
        end
    end
    if (data_ready_delay[0]) begin
        if (!capture_is_ch2) begin
            rd_data_second[31:16] <= dq_reg;
        end
        capture_is_ch2 <= 0; // Clear after all burst words processed
    end

    // Sticky request latches (MiSTer pattern)
    if (wr_req && state != STATE_STARTUP) begin
        wr_rq      <= 1;
        wr_rq_addr <= wr_addr;
        wr_rq_data <= wr_data;
    end
    rd_rq <= rd_rq | rd_req;

    // Ch2 sticky latches
    if (ch2_rd) begin
        ch2_rd_rq  <= 1;
        ch2_rq_addr <= ch2_addr;
    end
    if (ch2_wr) begin
        ch2_wr_rq  <= 1;
        ch2_rq_addr <= ch2_addr;
        ch2_rq_din  <= ch2_din;
    end

    // Dequeue into processing pipeline
    // Priority: ch1 read > ch1 write > ch2 (read or write)
    if (!req_pending && state == STATE_IDLE) begin
        if (rd_rq | rd_req) begin
            req_pending      <= 1;
            req_is_write     <= 0;
            req_is_ch2       <= 0;
            req_is_ch2_write <= 0;
            req_addr         <= {rd_addr[23:0], 1'b0};
            rd_rq            <= 0;
        end else if (wr_rq) begin
            req_pending      <= 1;
            req_is_write     <= 1;
            req_is_ch2       <= 0;
            req_is_ch2_write <= 0;
            req_addr         <= wr_rq_addr;
            req_wdata        <= wr_rq_data;
            wr_rq            <= 0;
        end else if (ch2_rd_rq) begin
            req_pending      <= 1;
            req_is_write     <= 0;
            req_is_ch2       <= 1;
            req_is_ch2_write <= 0;
            req_addr         <= {ch2_rq_addr[23:0], 1'b0};
            ch2_rd_rq        <= 0;
        end else if (ch2_wr_rq) begin
            req_pending      <= 1;
            req_is_write     <= 1;
            req_is_ch2       <= 1;
            req_is_ch2_write <= 1;
            req_addr         <= {ch2_rq_addr[23:0], 1'b0};
            ch2_rq_din       <= ch2_rq_din; // Hold write data
            ch2_wr_rq        <= 0;
        end
    end

    case (state)
        // --------------------------------------------------------
        // Startup / Initialization
        // --------------------------------------------------------
        STATE_STARTUP: begin
            sd_addr <= 0;
            sd_ba   <= 0;

            if (refresh_count == (STARTUP_REFRESH_MAX - 63)) begin
                command     <= CMD_PRECHARGE;
                sd_addr[10] <= 1'b1;
            end
            if (refresh_count == (STARTUP_REFRESH_MAX - 55)) begin
                command <= CMD_AUTO_REFRESH;
            end
            if (refresh_count == (STARTUP_REFRESH_MAX - 47)) begin
                command <= CMD_AUTO_REFRESH;
            end
            if (refresh_count == (STARTUP_REFRESH_MAX - 39)) begin
                command <= CMD_LOAD_MODE;
                sd_addr <= MODE;
            end
            if (refresh_count == 0) begin
                state         <= STATE_IDLE;
                refresh_count <= 0;
            end
        end

        // --------------------------------------------------------
        // Idle — Service pending requests or refresh
        // --------------------------------------------------------
        STATE_IDLE: begin
            if (refresh_count > (CYCLES_PER_REFRESH << 1)) begin
                state <= STATE_IDLE_1;
            end else if (req_pending) begin
                command <= CMD_ACTIVE;
                sd_addr <= req_addr[24:12];
                sd_ba   <= req_addr[11:10];

                if (req_is_ch2 && req_is_ch2_write) begin
                    // Ch2 write: no auto-precharge on first WRITE
                    cas_addr <= {2'b00, 1'b0, req_addr[9:0]};
                end else if (req_is_write) begin
                    // Ch1 single-word write: auto-precharge
                    cas_addr <= {2'b00, 1'b1, req_addr[9:0]};
                end else begin
                    // Read (ch1 or ch2): burst-aligned, auto-precharge
                    cas_addr <= {2'b00, 1'b1, req_addr[9:1], 1'b0};
                end

                state <= STATE_WAIT;
            end
        end

        // --------------------------------------------------------
        // Wait — tRCD (RAS to CAS delay)
        // --------------------------------------------------------
        STATE_WAIT: state <= STATE_RW;

        // --------------------------------------------------------
        // Read/Write — Issue CAS command
        // --------------------------------------------------------
        STATE_RW: begin
            sd_addr <= cas_addr;

            if (req_is_ch2 && req_is_ch2_write) begin
                // Ch2 32-bit write: first word (low 16 bits)
                command <= CMD_WRITE;
                dram_dq <= ch2_rq_din[15:0];
                state   <= STATE_CH2_WR2;
            end else if (req_is_write) begin
                // Ch1 16-bit write
                command     <= CMD_WRITE;
                dram_dq     <= req_wdata;
                req_pending <= 0;
                state       <= STATE_IDLE_5;
            end else begin
                // Read (ch1 or ch2)
                command     <= CMD_READ;
                req_pending <= 0;
                if (req_is_ch2) capture_is_ch2 <= 1;
                data_ready_delay[CAPTURE_DELAY] <= 1;
                state       <= STATE_IDLE_5;
            end
        end

        // --------------------------------------------------------
        // Ch2 write: second word (high 16 bits)
        // --------------------------------------------------------
        STATE_CH2_WR2: begin
            command     <= CMD_WRITE;
            dram_dq     <= ch2_rq_din[31:16];
            sd_addr     <= {2'b00, 1'b1, cas_addr[9:1], 1'b1}; // Auto-precharge, column+1
            req_pending <= 0;
            ch2_ready   <= 1;
            state       <= STATE_IDLE_5;
        end

        // --------------------------------------------------------
        // Post-operation idle chain
        // --------------------------------------------------------
        STATE_IDLE_5: state <= STATE_IDLE_4;
        STATE_IDLE_4: state <= STATE_IDLE_3;
        STATE_IDLE_3: state <= STATE_IDLE_2;
        STATE_IDLE_2: state <= STATE_IDLE_1;

        STATE_IDLE_1: begin
            state <= STATE_IDLE;
            if (refresh_count > CYCLES_PER_REFRESH) begin
                state   <= STATE_RFSH;
                command <= CMD_AUTO_REFRESH;
                refresh_count <= refresh_count - CYCLES_PER_REFRESH + 1'd1;
            end
        end

        // --------------------------------------------------------
        // Refresh
        // --------------------------------------------------------
        STATE_RFSH: begin
            state <= STATE_IDLE_5;
        end
    endcase

    // Reset
    if (reset) begin
        state            <= STATE_STARTUP;
        refresh_count    <= STARTUP_REFRESH_MAX - STARTUP_CYCLES;
        command          <= CMD_NOP;
        dram_dq          <= 16'hZZZZ;
        rd_ready         <= 0;
        ch2_ready        <= 0;
        data_ready_delay <= 0;
        capture_is_ch2   <= 0;
        req_pending      <= 0;
        wr_rq            <= 0;
        rd_rq            <= 0;
        ch2_rd_rq        <= 0;
        ch2_wr_rq        <= 0;
    end
end

// ============================================================
// DDR Clock Output (0deg outclock -> 180deg SDRAM_CLK, matches MiSTer)
// ============================================================

altddio_out #(
    .extend_oe_disable   ("OFF"),
    .intended_device_family ("Cyclone V"),
    .invert_output       ("OFF"),
    .lpm_hint            ("UNUSED"),
    .lpm_type            ("altddio_out"),
    .oe_reg              ("UNREGISTERED"),
    .power_up_high       ("OFF"),
    .width               (1)
) sdramclk_ddr (
    .datain_h  (1'b0),
    .datain_l  (1'b1),
    .outclock  (clk),
    .dataout   (dram_clk),
    .aclr      (1'b0),
    .aset      (1'b0),
    .oe        (1'b1),
    .outclocken(1'b1),
    .sclr      (1'b0),
    .sset      (1'b0)
);

endmodule
