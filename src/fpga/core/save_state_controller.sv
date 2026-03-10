//
// save_state_controller.sv — Save state bridge for GBA on Analogue Pocket
//
// Handles APF save state protocol (bridge writes/reads, command handshake)
// and translates to gba_savestates' SAVE_out bus interface.
//
// SAVE path (core → APF): Flow-controlled via 64→32 save FIFO (same as GBC).
// LOAD path (APF → core): Two-phase SDRAM staging approach:
//   Phase 1: Bridge writes → load FIFO → drain to SDRAM staging area
//   Phase 2: gba_savestates reads → serve from SDRAM staging area
//
// SDRAM staging avoids load FIFO overflow (GBA state ~389 KB >> 16 KB FIFO).
// Based on openfpga-GBC save_state_controller.sv (budude2), extended with
// SDRAM staging for the larger GBA save state.
//

module save_state_controller (
    input wire clk_74a,
    input wire clk_sys,

    // APF Bridge
    input wire bridge_wr,
    input wire bridge_rd,
    input wire bridge_endian_little,
    input wire [31:0] bridge_addr,
    input wire [31:0] bridge_wr_data,
    output wire [31:0] save_state_bridge_read_data,

    // APF Save State command signals
    input  wire savestate_load,
    output wire savestate_load_ack_s,
    output wire savestate_load_busy_s,
    output wire savestate_load_ok_s,
    output wire savestate_load_err_s,

    input  wire savestate_start,
    output wire savestate_start_ack_s,
    output wire savestate_start_busy_s,
    output wire savestate_start_ok_s,
    output wire savestate_start_err_s,

    // GBA core save state bus (directly to gba_top SAVE_out_* ports)
    output reg        ss_save,
    output reg        ss_load,

    input  wire [63:0] ss_din,         // SAVE_out_Din  — data FROM gba_savestates (save)
    output reg  [63:0] ss_dout,        // SAVE_out_Dout — data TO gba_savestates (load)
    input  wire [25:0] ss_addr,        // SAVE_out_Adr
    input  wire        ss_rnw,         // SAVE_out_rnw
    input  wire        ss_req,         // SAVE_out_ena (request strobe)
    input  wire  [7:0] ss_be,          // SAVE_out_be
    output reg         ss_ack,         // SAVE_out_done (acknowledge)

    input  wire        ss_busy,        // savestate_busy from gba_top
    input  wire        load_done,      // load_done from gba_top

    // SDRAM staging ports (muxed onto ch1 in core_top.sv)
    output reg         sdram_wr_req,
    output reg  [24:0] sdram_wr_addr,
    output reg  [15:0] sdram_wr_data,
    input  wire        sdram_wr_pending,  // High while SDRAM write latch occupied

    output reg         sdram_rd_req,
    output reg  [24:0] sdram_rd_addr,
    input  wire [31:0] sdram_rd_data,
    input  wire [31:0] sdram_rd_data_second,
    input  wire        sdram_rd_ready,

    // Status
    output wire        ss_serving_active, // High during Phase 2 (read mux select)
    output wire        ss_loading         // High during Phase 1+2 (pause core to prevent SDRAM contention)
);

// ============================================================
// Constants
// ============================================================

// gba_savestates.vhd STATESIZE = 0x18346 (address units, 2 per 64-bit transfer)
// Total 64-bit transfers = 0x18346 / 2 = 0xC1A3
localparam [24:0] STAGING_BASE_DWORD = 25'h810000;  // After EWRAM (0x800000-0x80FFFF)
localparam [24:0] STAGING_BASE_WORD  = 25'h1020000; // STAGING_BASE_DWORD * 2 (WORD addr)
localparam [19:0] TOTAL_FIFO_ENTRIES = 20'hC1A3;     // 49571 64-bit transfers

// Header is saved LAST by gba_savestates but loaded FIRST.
// Sequential entry index for header = TOTAL_FIFO_ENTRIES - 1.
// DWORD offset = (TOTAL_FIFO_ENTRIES - 1) * 2 = 0x18344.
localparam [24:0] HEADER_STAGING_DWORD = STAGING_BASE_DWORD + 25'h18344;

// Minimum write spacing: 4 clk_sys cycles between SDRAM writes
// Actual gating uses sdram_wr_pending handshake to prevent write latch overflow
localparam WR_DELAY = 4'd3;  // Minimum spacing before checking wr_pending

// ============================================================
// CDC: APF command signals (clk_74a ↔ clk_sys)
// ============================================================

wire savestate_load_s;
wire savestate_start_s;

synch_3 #(.WIDTH(2)) savestate_in (
    .i   ({savestate_load, savestate_start}),
    .o   ({savestate_load_s, savestate_start_s}),
    .clk (clk_sys)
);

reg savestate_load_ack;
reg savestate_load_busy;
reg savestate_load_ok;
reg savestate_load_err;

reg savestate_start_ack;
reg savestate_start_busy;
reg savestate_start_ok;
reg savestate_start_err;

synch_3 #(.WIDTH(8)) savestate_out (
    .i ({
        savestate_load_ack,  savestate_load_busy,
        savestate_load_ok,   savestate_load_err,
        savestate_start_ack, savestate_start_busy,
        savestate_start_ok,  savestate_start_err
    }),
    .o ({
        savestate_load_ack_s,  savestate_load_busy_s,
        savestate_load_ok_s,   savestate_load_err_s,
        savestate_start_ack_s, savestate_start_busy_s,
        savestate_start_ok_s,  savestate_start_err_s
    }),
    .clk (clk_74a)
);

// ============================================================
// Load FIFO: bridge 32-bit writes (clk_74a) → 64-bit reads (clk_sys)
// ============================================================

wire        fifo_load_empty;
reg         fifo_load_read_req = 0;
wire [63:0] fifo_load_dout;
reg         fifo_load_clr = 0;

dcfifo_mixed_widths fifo_load (
    .data    (bridge_wr_data),
    .rdclk   (clk_sys),
    .rdreq   (fifo_load_read_req),
    .wrclk   (clk_74a),
    .wrreq   (bridge_wr && bridge_addr[31:28] == 4'h4),
    .q       (fifo_load_dout),
    .rdempty (fifo_load_empty),
    .aclr    (fifo_load_clr)
);
defparam fifo_load.intended_device_family = "Cyclone V",
    fifo_load.lpm_numwords = 512,
    fifo_load.lpm_showahead = "OFF",
    fifo_load.lpm_type = "dcfifo_mixed_widths",
    fifo_load.lpm_width = 32,
    fifo_load.lpm_widthu = 9,
    fifo_load.lpm_widthu_r = 8,
    fifo_load.lpm_width_r = 64,
    fifo_load.overflow_checking = "ON",
    fifo_load.rdsync_delaypipe = 5,
    fifo_load.underflow_checking = "ON",
    fifo_load.use_eab = "ON",
    fifo_load.wrsync_delaypipe = 5,
    fifo_load.write_aclr_synch = "ON";

// ============================================================
// Save FIFO: gba_savestates 64-bit writes (clk_sys) → bridge 32-bit reads (clk_74a)
// ============================================================

reg  fifo_save_write_req;
reg  fifo_save_read_req;

wire fifo_save_rd_empty;
wire fifo_save_wr_empty;

dcfifo_mixed_widths fifo_save (
    .data    (ss_din),
    .rdclk   (clk_74a),
    .rdreq   (fifo_save_read_req),
    .wrclk   (clk_sys),
    .wrreq   (fifo_save_write_req),
    .q       ({
        save_state_bridge_read_data[7:0],
        save_state_bridge_read_data[15:8],
        save_state_bridge_read_data[23:16],
        save_state_bridge_read_data[31:24]
    }),
    .rdempty (fifo_save_rd_empty),
    .wrempty (fifo_save_wr_empty),
    .aclr    (1'b0)
);
defparam fifo_save.intended_device_family = "Cyclone V",
    fifo_save.lpm_numwords = 4,
    fifo_save.lpm_showahead = "OFF",
    fifo_save.lpm_type = "dcfifo_mixed_widths",
    fifo_save.lpm_width = 64,
    fifo_save.lpm_widthu = 2,
    fifo_save.lpm_widthu_r = 3,
    fifo_save.lpm_width_r = 32,
    fifo_save.overflow_checking = "ON",
    fifo_save.rdsync_delaypipe = 5,
    fifo_save.underflow_checking = "ON",
    fifo_save.use_eab = "ON",
    fifo_save.wrsync_delaypipe = 5;

// ============================================================
// Bridge Read — save path (clk_74a domain)
// When bridge reads 0x4xxxxxxx, serve data from save FIFO
// ============================================================

reg         prev_bridge_rd;
reg  [1:0]  save_read_state = 0;
reg  [20:0] last_unloader_addr = 21'hFFFF;

wire [27:0] bridge_save_addr = bridge_addr[27:0];

localparam SAVE_RD_NONE = 0;
localparam SAVE_RD_REQ  = 1;

always @(posedge clk_74a) begin
    prev_bridge_rd <= bridge_rd;

    if (bridge_rd && ~prev_bridge_rd && bridge_addr[31:28] == 4'h4) begin
        if (~fifo_save_rd_empty && bridge_save_addr[22:2] != last_unloader_addr) begin
            save_read_state <= SAVE_RD_REQ;
            fifo_save_read_req <= 1;
            last_unloader_addr <= bridge_save_addr[22:2];
        end
    end

    case (save_read_state)
        SAVE_RD_REQ: begin
            save_read_state <= SAVE_RD_NONE;
            fifo_save_read_req <= 0;
        end
    endcase
end

// ============================================================
// Main State Machine (clk_sys domain)
// ============================================================

// State encoding
localparam S_NONE              = 5'd0;

// Save path states (core → APF via save FIFO)
localparam S_SAVE_BUSY         = 5'd1;
localparam S_SAVE_WAIT_REQ     = 5'd2;
localparam S_SAVE_WAIT_REQ_DLY = 5'd3;
localparam S_SAVE_WAIT_ACK     = 5'd4;

// Staging states — Phase 1: drain load FIFO → SDRAM
localparam S_STAGE_FIFO_RD     = 5'd10;
localparam S_STAGE_FIFO_WAIT   = 5'd11;  // Wait for dcfifo Q output (showahead OFF)
localparam S_STAGE_FIFO_LATCH  = 5'd15;
localparam S_STAGE_WR          = 5'd12;
localparam S_STAGE_WR_WAIT     = 5'd13;
localparam S_STAGE_IDLE        = 5'd14;

// Load states — Phase 2: serve from SDRAM → gba_savestates
localparam S_LOAD_TRIGGER      = 5'd20;
localparam S_LOAD_SERVE        = 5'd21;
localparam S_LOAD_SDRAM_RD     = 5'd22;
localparam S_LOAD_SDRAM_WAIT   = 5'd23;
localparam S_LOAD_SDRAM_LATCH  = 5'd24;
localparam S_LOAD_ACK          = 5'd25;
localparam S_LOAD_WAIT_DONE    = 5'd26;
localparam S_LOAD_COMPLETE     = 5'd27;

reg [4:0] state = S_NONE;

// Staging registers
reg [63:0] staging_buffer;                // Latched FIFO output / SDRAM read buffer
reg [24:0] staging_wr_addr;              // Current WORD write address
reg  [1:0] staging_word_idx;             // 0-3: which 16-bit word of 64-bit dword
reg [19:0] staging_fifo_count;           // Number of 64-bit entries drained
reg  [3:0] staging_wr_delay;             // Write spacing counter
reg [24:0] latched_load_addr;            // SDRAM DWORD address for Phase 2 reads

// Control flags
reg        save_state_loading = 0;       // Load sequence active
reg        savestate_load_cmd = 0;       // APF load command received
reg        staging_complete = 0;         // All data written to SDRAM
reg        load_done_seen = 0;           // gba_savestates signaled load_done

// FIFO clear counter — dcfifo with write_aclr_synch="ON" and wrsync_delaypipe=5
// requires aclr held long enough for synchronizer propagation (~5 wrclk = ~7 clk_sys).
// 16 clk_sys cycles provides safe margin.
reg  [3:0] fifo_clr_count = 0;

// Post-clear settling counter — after aclr drops, rdempty flag needs additional
// cycles to propagate through rdsync_delaypipe before it's reliable.
reg  [3:0] fifo_settle_count = 0;

// Edge detection
reg        prev_savestate_start = 0;
reg        prev_savestate_load = 0;
reg        prev_ss_busy = 0;

// Phase 2 mux control
assign ss_serving_active = (state >= S_LOAD_TRIGGER && state <= S_LOAD_COMPLETE);

// Core pause during load — prevents SDRAM read contention during Phase 1 staging,
// which would starve writes and overflow the load FIFO on read-heavy games (e.g. F-Zero).
assign ss_loading = save_state_loading;

always @(posedge clk_sys) begin
    prev_ss_busy         <= ss_busy;
    prev_savestate_start <= savestate_start_s;
    prev_savestate_load  <= savestate_load_s;

    // Default pulse signals to 0
    ss_load             <= 0;
    ss_save             <= 0;
    ss_ack              <= 0;
    fifo_save_write_req <= 0;
    fifo_load_read_req  <= 0;
    sdram_wr_req        <= 0;
    sdram_rd_req        <= 0;

    // Track load_done from gba_savestates
    if (load_done)
        load_done_seen <= 1;

    // Decrement write delay counter
    if (staging_wr_delay > 0)
        staging_wr_delay <= staging_wr_delay - 4'd1;

    // FIFO clear counter — hold fifo_load_clr for enough cycles
    if (fifo_clr_count > 0) begin
        fifo_clr_count <= fifo_clr_count - 4'd1;
        fifo_load_clr  <= 1;
    end else begin
        fifo_load_clr  <= 0;
    end

    // Post-clear settling — wait for rdempty to stabilize after aclr drops
    if (fifo_settle_count > 0)
        fifo_settle_count <= fifo_settle_count - 4'd1;
    if (fifo_clr_count == 4'd1)  // clr about to drop next cycle
        fifo_settle_count <= 4'd8;

    // ----------------------------------------------------------------
    // Detect FIFO data arrival → start staging (only when idle)
    // ----------------------------------------------------------------
    if (state == S_NONE && ~fifo_load_empty && ~save_state_loading
            && fifo_settle_count == 0) begin
        state              <= S_STAGE_FIFO_RD;
        save_state_loading <= 1;
        staging_wr_addr    <= STAGING_BASE_WORD;
        staging_fifo_count <= 20'd0;
        staging_complete   <= 0;
        savestate_load_cmd <= 0;
        load_done_seen     <= 0;
        staging_buffer     <= 64'd0;
    end

    // ----------------------------------------------------------------
    // Detect save start command (rising edge)
    // ----------------------------------------------------------------
    if (savestate_start_s && ~prev_savestate_start) begin
        state                <= S_SAVE_BUSY;
        savestate_start_ack  <= 1;
        savestate_start_ok   <= 0;
        savestate_start_err  <= 0;
        savestate_load_ok    <= 0;
        savestate_load_err   <= 0;
        ss_save              <= 1;
        save_state_loading   <= 0;  // Reset in case we were stuck in staging
    end

    // ----------------------------------------------------------------
    // Detect load command from APF (rising edge)
    // ----------------------------------------------------------------
    if (savestate_load_s && ~prev_savestate_load) begin
        savestate_load_cmd  <= 1;
        savestate_load_ack  <= 1;
        savestate_load_ok   <= 0;
        savestate_load_err  <= 0;
        savestate_start_ok  <= 0;
        savestate_start_err <= 0;
    end

    case (state)

        // ============================================================
        // SAVE path: flow-controlled via save FIFO (identical to GBC)
        // ============================================================

        S_SAVE_BUSY: begin
            // Hold ack until bridge drops savestate_start (proper CDC handshake).
            // clk_sys ack pulse (1 cycle = ~10 ns) is shorter than clk_74a period
            // (~13.5 ns) and can be missed by synch_3. Holding until start drops
            // guarantees the bridge sees it.
            if (~savestate_start_s)
                savestate_start_ack <= 0;

            savestate_start_busy <= 1;

            if (ss_req) begin
                // First request from gba_savestates
                state                <= S_SAVE_WAIT_REQ_DLY;
                fifo_save_write_req  <= 1;
                savestate_start_busy <= 0;
                savestate_start_ok   <= 1;
            end
        end

        S_SAVE_WAIT_REQ: begin
            if (ss_req) begin
                state               <= S_SAVE_WAIT_REQ_DLY;
                fifo_save_write_req <= 1;
            end else if (prev_ss_busy && ~ss_busy) begin
                // gba_savestates finished saving
                state <= S_NONE;
            end
        end

        S_SAVE_WAIT_REQ_DLY: begin
            // 1-cycle delay for FIFO empty flag to propagate
            state <= S_SAVE_WAIT_ACK;
        end

        S_SAVE_WAIT_ACK: begin
            // Wait for bridge to read from save FIFO (flow control)
            if (fifo_save_wr_empty) begin
                state  <= S_SAVE_WAIT_REQ;
                ss_ack <= 1;
            end
        end

        // ============================================================
        // STAGE Phase 1: Drain load FIFO → SDRAM staging area
        // ============================================================

        S_STAGE_FIFO_RD: begin
            if (~fifo_load_empty) begin
                // Read next 64-bit entry from FIFO
                fifo_load_read_req <= 1;
                state <= S_STAGE_FIFO_WAIT;
            end else if (staging_complete && savestate_load_cmd) begin
                // All data staged and APF load command received → Phase 2
                state <= S_LOAD_TRIGGER;
            end else begin
                // FIFO empty, wait for more data or load command
                state <= S_STAGE_IDLE;
            end
        end

        S_STAGE_FIFO_WAIT: begin
            // dcfifo with showahead OFF needs 2 cycles from rdreq to valid Q.
            // Cycle 1 (S_STAGE_FIFO_RD): rdreq pulse.
            // Cycle 2 (here): FIFO processes read, Q updating internally.
            // Cycle 3 (S_STAGE_FIFO_LATCH): Q output valid.
            state <= S_STAGE_FIFO_LATCH;
        end

        S_STAGE_FIFO_LATCH: begin
            // FIFO Q output now valid (2 cycles after rdreq pulse)
            staging_buffer   <= fifo_load_dout;
            staging_word_idx <= 2'd0;
            state            <= S_STAGE_WR;
        end

        S_STAGE_WR: begin
            // Write current 16-bit word to SDRAM
            sdram_wr_req  <= 1;
            sdram_wr_addr <= staging_wr_addr;

            case (staging_word_idx)
                2'd0: sdram_wr_data <= staging_buffer[15:0];
                2'd1: sdram_wr_data <= staging_buffer[31:16];
                2'd2: sdram_wr_data <= staging_buffer[47:32];
                2'd3: sdram_wr_data <= staging_buffer[63:48];
            endcase

            staging_wr_addr  <= staging_wr_addr + 25'd1;
            staging_wr_delay <= WR_DELAY;
            state            <= S_STAGE_WR_WAIT;
        end

        S_STAGE_WR_WAIT: begin
            if (staging_wr_delay == 0 && !sdram_wr_pending) begin
                if (staging_word_idx == 2'd3) begin
                    // All 4 words of this 64-bit entry written
                    staging_fifo_count <= staging_fifo_count + 20'd1;
                    if (staging_fifo_count + 20'd1 >= TOTAL_FIFO_ENTRIES)
                        staging_complete <= 1;
                    // Back to drain more FIFO entries
                    state <= S_STAGE_FIFO_RD;
                end else begin
                    // Next 16-bit word
                    staging_word_idx <= staging_word_idx + 2'd1;
                    state            <= S_STAGE_WR;
                end
            end
        end

        S_STAGE_IDLE: begin
            // Waiting for FIFO data or staging completion + load command
            if (~fifo_load_empty) begin
                state <= S_STAGE_FIFO_RD;
            end else if (staging_complete && savestate_load_cmd) begin
                state <= S_LOAD_TRIGGER;
            end
        end

        // ============================================================
        // LOAD Phase 2: Serve data from SDRAM to gba_savestates
        // ============================================================

        S_LOAD_TRIGGER: begin
            // Pulse ss_load to start gba_savestates load sequence
            // gba_savestates: IDLE → LOAD_WAITSETTLE (sleep_savestate='1', core pauses)
            ss_load             <= 1;
            savestate_load_ack  <= 0;
            savestate_load_busy <= 1;
            state               <= S_LOAD_SERVE;
        end

        S_LOAD_SERVE: begin
            if (prev_ss_busy && ~ss_busy) begin
                // gba_savestates finished (busy fell)
                state <= S_LOAD_WAIT_DONE;
            end else if (ss_req) begin
                // gba_savestates requesting data at ss_addr (bus_out_Adr).
                // GBA saves header LAST but loads it FIRST, so we must use
                // address-based reads, not sequential.
                //
                // Save order: internals at Adr=2 (entry 0), ..., header at Adr=0 (last entry).
                // SDRAM staging: entry I at DWORD addr STAGING_BASE_DWORD + I*2.
                //
                // Mapping from ss_addr to SDRAM DWORD address:
                //   ss_addr == 0: header → last entry → HEADER_STAGING_DWORD
                //   ss_addr >= 2: entry (ss_addr/2 - 1) → STAGING_BASE_DWORD + ss_addr - 2
                if (ss_addr[25:1] == 25'd0)
                    latched_load_addr <= HEADER_STAGING_DWORD;
                else
                    latched_load_addr <= STAGING_BASE_DWORD + {1'b0, ss_addr[23:0]} - 25'd2;
                state <= S_LOAD_SDRAM_RD;
            end
        end

        S_LOAD_SDRAM_RD: begin
            // Issue burst-4 read at computed DWORD address
            sdram_rd_req  <= 1;
            sdram_rd_addr <= latched_load_addr;
            state         <= S_LOAD_SDRAM_WAIT;
        end

        S_LOAD_SDRAM_WAIT: begin
            if (sdram_rd_ready) begin
                // rd_data valid now; rd_data_second[31:16] valid NEXT cycle
                staging_buffer[31:0] <= sdram_rd_data;
                state <= S_LOAD_SDRAM_LATCH;
            end
        end

        S_LOAD_SDRAM_LATCH: begin
            // rd_data_second fully valid now (1 cycle after rd_ready)
            // Apply byte swap: reverse bytes within each 32-bit half
            // Same transform as GBC FIFO→ss_dout path
            ss_dout <= {
                sdram_rd_data_second[7:0],  sdram_rd_data_second[15:8],
                sdram_rd_data_second[23:16], sdram_rd_data_second[31:24],
                staging_buffer[7:0],  staging_buffer[15:8],
                staging_buffer[23:16], staging_buffer[31:24]
            };
            state <= S_LOAD_ACK;
        end

        S_LOAD_ACK: begin
            ss_ack <= 1;
            state  <= S_LOAD_SERVE;
        end

        S_LOAD_WAIT_DONE: begin
            // gba_savestates done — clean up
            state          <= S_LOAD_COMPLETE;
            fifo_load_clr  <= 1;       // Start FIFO clear immediately
            fifo_clr_count <= 4'd15;   // Hold for 15 more cycles (16 total)
        end

        S_LOAD_COMPLETE: begin
            // fifo_load_clr managed by fifo_clr_count counter
            savestate_load_busy <= 0;
            save_state_loading  <= 0;

            if (load_done_seen) begin
                savestate_load_ok  <= 1;
                savestate_load_err <= 0;
            end else begin
                // Header check failed or other error
                savestate_load_ok  <= 0;
                savestate_load_err <= 1;
            end

            state <= S_NONE;
        end

    endcase
end

endmodule
