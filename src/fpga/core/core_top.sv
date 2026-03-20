//
// GBA core top-level for Analogue Pocket
//
// Wraps MiSTer gba_top.vhd with Pocket APF bridge, SDRAM, PSRAM,
// video adapter, audio I2S, and input mapping.
//

`default_nettype none

module core_top (

//
// physical connections
//

///////////////////////////////////////////////////
// clock inputs 74.25mhz. not phase aligned, so treat these domains as asynchronous

input   wire            clk_74a, // mainclk1
input   wire            clk_74b, // mainclk1

///////////////////////////////////////////////////
// cartridge interface
// switches between 3.3v and 5v mechanically
// output enable for multibit translators controlled by pic32

// GBA AD[15:8]
inout   wire    [7:0]   cart_tran_bank2,
output  wire            cart_tran_bank2_dir,

// GBA AD[7:0]
inout   wire    [7:0]   cart_tran_bank3,
output  wire            cart_tran_bank3_dir,

// GBA A[23:16]
inout   wire    [7:0]   cart_tran_bank1,
output  wire            cart_tran_bank1_dir,

// GBA [7] PHI#
// GBA [6] WR#
// GBA [5] RD#
// GBA [4] CS1#/CS#
//     [3:0] unwired
inout   wire    [7:4]   cart_tran_bank0,
output  wire            cart_tran_bank0_dir,

// GBA CS2#/RES#
inout   wire            cart_tran_pin30,
output  wire            cart_tran_pin30_dir,
output  wire            cart_pin30_pwroff_reset,

// GBA IRQ/DRQ
inout   wire            cart_tran_pin31,
output  wire            cart_tran_pin31_dir,

// infrared
input   wire            port_ir_rx,
output  wire            port_ir_tx,
output  wire            port_ir_rx_disable,

// GBA link port
inout   wire            port_tran_si,
output  wire            port_tran_si_dir,
inout   wire            port_tran_so,
output  wire            port_tran_so_dir,
inout   wire            port_tran_sck,
output  wire            port_tran_sck_dir,
inout   wire            port_tran_sd,
output  wire            port_tran_sd_dir,

///////////////////////////////////////////////////
// cellular psram 0 and 1, two chips (64mbit x2 dual die per chip)

output  wire    [21:16] cram0_a,
inout   wire    [15:0]  cram0_dq,
input   wire            cram0_wait,
output  wire            cram0_clk,
output  wire            cram0_adv_n,
output  wire            cram0_cre,
output  wire            cram0_ce0_n,
output  wire            cram0_ce1_n,
output  wire            cram0_oe_n,
output  wire            cram0_we_n,
output  wire            cram0_ub_n,
output  wire            cram0_lb_n,

output  wire    [21:16] cram1_a,
inout   wire    [15:0]  cram1_dq,
input   wire            cram1_wait,
output  wire            cram1_clk,
output  wire            cram1_adv_n,
output  wire            cram1_cre,
output  wire            cram1_ce0_n,
output  wire            cram1_ce1_n,
output  wire            cram1_oe_n,
output  wire            cram1_we_n,
output  wire            cram1_ub_n,
output  wire            cram1_lb_n,

///////////////////////////////////////////////////
// sdram, 512mbit 16bit

output  wire    [12:0]  dram_a,
output  wire    [1:0]   dram_ba,
inout   wire    [15:0]  dram_dq,
output  wire    [1:0]   dram_dqm,
output  wire            dram_clk,
output  wire            dram_cke,
output  wire            dram_ras_n,
output  wire            dram_cas_n,
output  wire            dram_we_n,

///////////////////////////////////////////////////
// sram, 1mbit 16bit

output  wire    [16:0]  sram_a,
inout   wire    [15:0]  sram_dq,
output  wire            sram_oe_n,
output  wire            sram_we_n,
output  wire            sram_ub_n,
output  wire            sram_lb_n,

///////////////////////////////////////////////////
// vblank driven by dock for sync in a certain mode

input   wire            vblank,

///////////////////////////////////////////////////
// i/o to 6515D breakout usb uart

output  wire            dbg_tx,
input   wire            dbg_rx,

///////////////////////////////////////////////////
// i/o pads near jtag connector user can solder to

output  wire            user1,
input   wire            user2,

///////////////////////////////////////////////////
// RFU internal i2c bus

inout   wire            aux_sda,
output  wire            aux_scl,

///////////////////////////////////////////////////
// RFU, do not use
output  wire            vpll_feed,


//
// logical connections
//

///////////////////////////////////////////////////
// video, audio output to scaler
output  wire    [23:0]  video_rgb,
output  wire            video_rgb_clock,
output  wire            video_rgb_clock_90,
output  wire            video_de,
output  wire            video_skip,
output  wire            video_vs,
output  wire            video_hs,

output  wire            audio_mclk,
input   wire            audio_adc,
output  wire            audio_dac,
output  wire            audio_lrck,

///////////////////////////////////////////////////
// bridge bus connection
// synchronous to clk_74a
output  wire            bridge_endian_little,
input   wire    [31:0]  bridge_addr,
input   wire            bridge_rd,
output  reg     [31:0]  bridge_rd_data,
input   wire            bridge_wr,
input   wire    [31:0]  bridge_wr_data,

///////////////////////////////////////////////////
// controller data
//
// key bitmap:
//   [0]    dpad_up
//   [1]    dpad_down
//   [2]    dpad_left
//   [3]    dpad_right
//   [4]    face_a
//   [5]    face_b
//   [6]    face_x
//   [7]    face_y
//   [8]    trig_l1
//   [9]    trig_r1
//   [10]   trig_l2
//   [11]   trig_r2
//   [12]   trig_l3
//   [13]   trig_r3
//   [14]   face_select
//   [15]   face_start
//   [31:28] type
// joy values - unsigned
//   [ 7: 0] lstick_x
//   [15: 8] lstick_y
//   [23:16] rstick_x
//   [31:24] rstick_y
// trigger values - unsigned
//   [ 7: 0] ltrig
//   [15: 8] rtrig
//
input   wire    [31:0]  cont1_key,
input   wire    [31:0]  cont2_key,
input   wire    [31:0]  cont3_key,
input   wire    [31:0]  cont4_key,
input   wire    [31:0]  cont1_joy,
input   wire    [31:0]  cont2_joy,
input   wire    [31:0]  cont3_joy,
input   wire    [31:0]  cont4_joy,
input   wire    [15:0]  cont1_trig,
input   wire    [15:0]  cont2_trig,
input   wire    [15:0]  cont3_trig,
input   wire    [15:0]  cont4_trig

);

// not using the IR port, so turn off both the LED, and
// disable the receive circuit to save power
assign port_ir_tx = 0;
assign port_ir_rx_disable = 1;

// bridge endianness
assign bridge_endian_little = 0;

// cart is unused, so set all level translators accordingly
// directions are 0:IN, 1:OUT
assign cart_tran_bank3 = 8'hzz;
assign cart_tran_bank3_dir = 1'b0;
assign cart_tran_bank2 = 8'hzz;
assign cart_tran_bank2_dir = 1'b0;
assign cart_tran_bank1 = 8'hzz;
assign cart_tran_bank1_dir = 1'b0;
assign cart_tran_bank0 = 4'hf;
assign cart_tran_bank0_dir = 1'b1;
assign cart_tran_pin30 = 1'b0;
assign cart_tran_pin30_dir = 1'bz;
assign cart_pin30_pwroff_reset = 1'b0;
assign cart_tran_pin31 = 1'bz;
assign cart_tran_pin31_dir = 1'b0;

// link port is unused, set to input only to be safe
assign port_tran_so = 1'bz;
assign port_tran_so_dir = 1'b0;
assign port_tran_si = 1'bz;
assign port_tran_si_dir = 1'b0;
assign port_tran_sck = 1'bz;
assign port_tran_sck_dir = 1'b0;
assign port_tran_sd = 1'bz;
assign port_tran_sd_dir = 1'b0;

// ---- PSRAM Controller (EWRAM die 0 + Cart Saves die 1) ----
// Memory map on cram0:
//   Die 0 (ce0_n): EWRAM — 256 KB at offset 0x00000 - 0x3FFFF
//   Die 1 (ce1_n): Cart saves — 128 KB at offset 0x00000 - 0x1FFFF

wire        psram_busy;
wire        psram_read_avail;
wire [15:0] psram_data_out;

reg         psram_write_en;
reg         psram_read_en;
reg         psram_bank_sel;   // 0=die0 (EWRAM), 1=die1 (saves)
reg  [21:0] psram_addr;
reg  [15:0] psram_data_in;
reg         psram_write_high;
reg         psram_write_low;

psram #(
    .CLOCK_SPEED ( 100.66 )       // clk_sys ≈ 100.663296 MHz
) psram_cram0 (
    .clk            ( clk_sys ),

    .bank_sel       ( psram_bank_sel ),
    .addr           ( psram_addr ),

    .write_en       ( psram_write_en ),
    .data_in        ( psram_data_in ),
    .write_high_byte( psram_write_high ),
    .write_low_byte ( psram_write_low ),

    .read_en        ( psram_read_en ),
    .read_avail     ( psram_read_avail ),
    .data_out       ( psram_data_out ),

    .busy           ( psram_busy ),

    // Physical cram0 pins
    .cram_a         ( cram0_a ),
    .cram_dq        ( cram0_dq ),
    .cram_wait      ( cram0_wait ),
    .cram_clk       ( cram0_clk ),
    .cram_adv_n     ( cram0_adv_n ),
    .cram_cre       ( cram0_cre ),
    .cram_ce0_n     ( cram0_ce0_n ),
    .cram_ce1_n     ( cram0_ce1_n ),
    .cram_oe_n      ( cram0_oe_n ),
    .cram_we_n      ( cram0_we_n ),
    .cram_ub_n      ( cram0_ub_n ),
    .cram_lb_n      ( cram0_lb_n )
);

assign cram1_a = 'h0;
assign cram1_dq = {16{1'bZ}};
assign cram1_clk = 0;
assign cram1_adv_n = 1;
assign cram1_cre = 0;
assign cram1_ce0_n = 1;
assign cram1_ce1_n = 1;
assign cram1_oe_n = 1;
assign cram1_we_n = 1;
assign cram1_ub_n = 1;
assign cram1_lb_n = 1;

// ---- Save Data Loader/Unloader (→ PSRAM cram0 die 1) ----
// Save data loads from SD card to PSRAM die 1 at boot.
// Save data unloads from PSRAM die 1 to SD card on request.
// During gameplay, bus_out arbitration handles save read/write via PSRAM.
//
// PSRAM access priority (only one active at a time due to Pocket OS sequencing):
//   1. save_loader — during boot (before dataslot_allcomplete)
//   2. save_unloader — during save writeback (core paused by OS)
//   3. bus_out — during gameplay

wire        save_loader_wr;
wire [27:0] save_loader_addr;
wire [15:0] save_loader_data;

// Save data_loader — captures bridge writes at 0x2xxxxxxx → PSRAM die 1
data_loader #(
    .ADDRESS_MASK_UPPER_4   ( 4'h2 ),
    .ADDRESS_SIZE           ( 28 ),
    .OUTPUT_WORD_SIZE       ( 2 ),          // 16-bit output to match PSRAM width
    .WRITE_MEM_CLOCK_DELAY  ( 20 )          // Match PSRAM access time (~70ns)
) save_data_loader (
    .clk_74a            ( clk_74a ),
    .clk_memory         ( clk_sys ),

    .bridge_wr          ( bridge_wr ),
    .bridge_endian_little ( bridge_endian_little ),
    .bridge_addr        ( bridge_addr ),
    .bridge_wr_data     ( bridge_wr_data ),

    .write_en           ( save_loader_wr ),
    .write_addr         ( save_loader_addr ),
    .write_data         ( save_loader_data )
);

// Save data_unloader — serves bridge reads at 0x2xxxxxxx from PSRAM die 1
// The unloader expects fixed-latency reads. We use a small FSM to bridge
// the unloader's read_en/read_data interface to the PSRAM's busy/read_avail.
wire [31:0] save_read_bridge_data;
wire        save_unloader_rd;
wire [27:0] save_unloader_addr;
reg  [15:0] save_unloader_data;

data_unloader #(
    .ADDRESS_MASK_UPPER_4   ( 4'h2 ),
    .ADDRESS_SIZE           ( 28 ),
    .READ_MEM_CLOCK_DELAY   ( 20 ),         // Must cover PSRAM read latency
    .INPUT_WORD_SIZE        ( 2 )           // 16-bit input
) save_data_unloader (
    .clk_74a            ( clk_74a ),
    .clk_memory         ( clk_sys ),

    .bridge_rd          ( bridge_rd ),
    .bridge_endian_little ( bridge_endian_little ),
    .bridge_addr        ( bridge_addr ),
    .bridge_rd_data     ( save_read_bridge_data ),

    .read_en            ( save_unloader_rd ),
    .read_addr          ( save_unloader_addr ),
    .read_data          ( save_unloader_data )
);

// ---- PSRAM Access Mux ----
// Three sources can access PSRAM cram0:
//   1. save_loader_wr  — write save data to die 1 (boot)
//   2. save_unloader_rd — read save data from die 1 (save writeback)
//   3. bus_out FSM      — EWRAM (die 0) + saves (die 1) during gameplay
//
// The Pocket OS sequences these so they don't overlap:
//   - Boot: save_loader active, bus_out inactive (core not running)
//   - Gameplay: bus_out active, loader/unloader inactive
//   - Save writeback: unloader active, bus_out paused (core paused by OS)
//
// We use a simple priority mux. save_loader > save_unloader > bus_out_fsm.

// Internal PSRAM request signals from bus_out FSM
reg         busfsm_psram_write_en;
reg         busfsm_psram_read_en;
reg         busfsm_psram_bank_sel;
reg  [21:0] busfsm_psram_addr;
reg  [15:0] busfsm_psram_data_in;
reg         busfsm_psram_write_high;
reg         busfsm_psram_write_low;

// Save unloader read bridge — captures PSRAM read result for the unloader
// RTC region: addresses >= save_size_sys are served from RTC registers, not PSRAM
wire save_unload_is_rtc = (save_size_sys != 24'd0) &&
                          (save_unloader_addr[23:0] >= save_size_sys);

// RTC data mux for save unloader (word index from low bits of byte addr)
reg [15:0] rtc_unload_word;
always @(*) begin
    case (save_unloader_addr[3:1])
        3'd0: rtc_unload_word = rtc_timestamp_out[15:0];
        3'd1: rtc_unload_word = rtc_timestamp_out[31:16];
        3'd2: rtc_unload_word = rtc_savedtime_out[15:0];
        3'd3: rtc_unload_word = rtc_savedtime_out[31:16];
        3'd4: rtc_unload_word = {6'b0, rtc_savedtime_out[41:32]};
        default: rtc_unload_word = 16'd0;
    endcase
end

reg         save_unload_pending;
always @(posedge clk_sys) begin
    if (~pll_core_locked) begin
        save_unload_pending <= 0;
    end else begin
        if (save_unloader_rd) begin
            if (save_unload_is_rtc) begin
                // RTC region: serve directly from registers
                save_unloader_data <= rtc_unload_word;
            end else if (!psram_busy) begin
                save_unload_pending <= 1;
            end
        end
        if (psram_read_avail && save_unload_pending) begin
            save_unloader_data  <= psram_data_out;
            save_unload_pending <= 0;
        end
    end
end

// PSRAM mux: priority encode loader > unloader > bus_out
always @(*) begin
    if (save_loader_wr) begin
        // Save loader write → die 1
        psram_write_en   = 1;
        psram_read_en    = 0;
        psram_bank_sel   = 1;  // die 1
        psram_addr       = save_loader_addr[21:1]; // byte→word addr (drop bit 0)
        psram_data_in    = save_loader_data;
        psram_write_high = 1;
        psram_write_low  = 1;
    end else if (save_unloader_rd && !save_unload_pending && !save_unload_is_rtc) begin
        // Save unloader read → die 1 (skip for RTC region)
        psram_write_en   = 0;
        psram_read_en    = 1;
        psram_bank_sel   = 1;  // die 1
        psram_addr       = save_unloader_addr[21:1];
        psram_data_in    = 16'd0;
        psram_write_high = 1;
        psram_write_low  = 1;
    end else begin
        // bus_out FSM has PSRAM
        psram_write_en   = busfsm_psram_write_en;
        psram_read_en    = busfsm_psram_read_en;
        psram_bank_sel   = busfsm_psram_bank_sel;
        psram_addr       = busfsm_psram_addr;
        psram_data_in    = busfsm_psram_data_in;
        psram_write_high = busfsm_psram_write_high;
        psram_write_low  = busfsm_psram_write_low;
    end
end

// ---- bus_out Arbitration (EWRAM → PSRAM die 0, Saves → PSRAM die 1) ----
// gba_top bus_out interface for external memory (EWRAM + saves).
//
// bus_out_Adr carries Softmap flat offsets (NOT GBA CPU addresses).
// MiSTer Softmap generics (GBA.sv lines 529-532):
//   Softmap_GBA_FLASH_ADDR  = 0        → saves at offset 0x00000
//   Softmap_GBA_EEPROM_ADDR = 0        → saves at offset 0x00000
//   Softmap_GBA_WRam_ADDR   = 131072   → EWRAM at offset 0x20000
// Bit 17 cleanly separates: set = EWRAM (die 0), clear = saves (die 1).
//
// EWRAM: bus_out_Adr is a true DWORD address. Each DWORD = 2 PSRAM words.
//   Standard two-word access (low + high half).
//
// Saves: GBA core uses each CPU byte address as a DWORD address (1 byte per
//   DWORD, data in bus_out_Din[7:0]). We pack densely in PSRAM die 1:
//   save byte N → PSRAM word N/2, byte position N%2. This avoids 4× space
//   waste and keeps save_size_bytes matching actual save type sizes.
//
// Port directions (from gba_top.vhd):
//   bus_out_Din  (out) — write data FROM gba_top
//   bus_out_Dout (in)  — read data TO gba_top
//   bus_out_Adr  (out) — DWORD address
//   bus_out_rnw  (out) — 1=read, 0=write
//   bus_out_ena  (out) — request strobe
//   bus_out_done (in)  — acknowledgment

wire [31:0] bus_out_Din;    // Write data from gba_top (out from gba_top)
wire [31:0] bus_out_Dout;   // Read data to gba_top (in to gba_top)
wire [25:0] bus_out_Adr;    // Address from gba_top
wire        bus_out_rnw;    // 1=read, 0=write
wire        bus_out_ena;    // Request strobe
reg         bus_out_done;

// Arbitration state machine
localparam BUS_IDLE       = 3'd0;
localparam BUS_EWRAM_WAIT = 3'd1;  // Wait for SDRAM ch2 to complete EWRAM access
localparam BUS_DONE       = 3'd5;
localparam BUS_SAVE_REQ   = 3'd6;  // Issue single-byte PSRAM access (saves, packed)
localparam BUS_SAVE_WAIT  = 3'd7;  // Wait for PSRAM to complete (saves, packed)

reg  [2:0]  bus_state;
reg         bus_is_write;
reg  [21:0] bus_word_addr;   // PSRAM word address (for saves)
reg  [31:0] bus_wdata;
reg         bus_req_sent;    // Guard: wait 1 cycle for psram_busy to propagate
reg         bus_byte_sel;    // For packed save: 0=low byte, 1=high byte

// SDRAM ch2 request signals (EWRAM)
reg         sdram_ch2_rd;
reg         sdram_ch2_wr;
reg  [24:0] sdram_ch2_addr;
reg  [31:0] sdram_ch2_din;
wire [31:0] sdram_ch2_dout;
wire        sdram_ch2_ready;

reg  [31:0] bus_out_rdata;
assign bus_out_Dout = bus_out_rdata;

always @(posedge clk_sys) begin
    busfsm_psram_write_en  <= 0;
    busfsm_psram_read_en   <= 0;
    bus_out_done            <= 0;
    sdram_ch2_rd            <= 0;
    sdram_ch2_wr            <= 0;

    case (bus_state)
        BUS_IDLE: begin
            if (bus_out_ena) begin
                bus_is_write <= ~bus_out_rnw;
                bus_wdata    <= bus_out_Din;

                // Address decode via Softmap offset (bit 17 separates EWRAM from saves)
                if (bus_out_Adr[17]) begin
                    // EWRAM -> SDRAM ch2 (was PSRAM die 0, now ~3x faster)
                    // SDRAM DWORD address: 0x800000 + EWRAM offset
                    sdram_ch2_addr <= {1'b0, 1'b1, 7'b0, bus_out_Adr[15:0]};
                    if (bus_out_rnw) begin
                        sdram_ch2_rd <= 1;
                    end else begin
                        sdram_ch2_wr  <= 1;
                        sdram_ch2_din <= bus_out_Din;
                    end
                    bus_state <= BUS_EWRAM_WAIT;
                end else begin
                    // Save -> die 1: packed byte access via PSRAM
                    // GBA core uses byte addr as DWORD addr (1 byte per DWORD).
                    // We pack densely: save byte N → PSRAM byte N.
                    // PSRAM word = byte_addr / 2, byte_sel = byte_addr[0]
                    bus_word_addr <= {5'b0, bus_out_Adr[16:1]};
                    bus_byte_sel  <= bus_out_Adr[0];
                    bus_state <= BUS_SAVE_REQ;
                end
            end
        end

        // ---- EWRAM path: wait for SDRAM ch2 completion ----
        BUS_EWRAM_WAIT: begin
            if (sdram_ch2_ready) begin
                if (~bus_is_write)
                    bus_out_rdata <= sdram_ch2_dout;
                bus_state <= BUS_DONE;
            end
        end

        // ---- Save path (die 1): single-word packed byte access ----
        // GBA core stores 1 byte per DWORD addr. We pack into PSRAM:
        // save byte N → PSRAM word N/2, byte position N%2.
        // Writes use byte enables to avoid corrupting the adjacent byte.
        // Reads extract the correct byte and return in bus_out_Dout[7:0].
        BUS_SAVE_REQ: begin
            busfsm_psram_bank_sel <= 1'b1; // die 1
            busfsm_psram_addr     <= bus_word_addr;

            if (bus_is_write) begin
                busfsm_psram_write_en <= 1;
                if (bus_byte_sel) begin
                    // High byte of PSRAM word
                    busfsm_psram_data_in   <= {bus_wdata[7:0], 8'h00};
                    busfsm_psram_write_high <= 1;
                    busfsm_psram_write_low  <= 0;
                end else begin
                    // Low byte of PSRAM word
                    busfsm_psram_data_in   <= {8'h00, bus_wdata[7:0]};
                    busfsm_psram_write_high <= 0;
                    busfsm_psram_write_low  <= 1;
                end
            end else begin
                busfsm_psram_read_en    <= 1;
                busfsm_psram_write_high <= 1;
                busfsm_psram_write_low  <= 1;
            end

            bus_req_sent <= 1;
            bus_state <= BUS_SAVE_WAIT;
        end

        BUS_SAVE_WAIT: begin
            if (bus_req_sent) begin
                bus_req_sent <= 0;
            end else if (!psram_busy) begin
                if (!bus_is_write) begin
                    if (bus_byte_sel)
                        bus_out_rdata <= {24'h0, psram_data_out[15:8]};
                    else
                        bus_out_rdata <= {24'h0, psram_data_out[7:0]};
                end
                bus_state <= BUS_DONE;
            end
        end

        BUS_DONE: begin
            bus_out_done <= 1;
            bus_state    <= BUS_IDLE;
        end

        default: bus_state <= BUS_IDLE;
    endcase

    if (~pll_core_locked) begin
        bus_state    <= BUS_IDLE;
        bus_out_done <= 0;
        bus_req_sent <= 0;
    end
end

// ---- SDRAM Controller (ROM + EWRAM + Save State staging) ----
// Ch1: ROM reads from gba_top (OR save state staging reads during load Phase 2)
//      ROM loading writes from data_loader (OR staging writes during load Phase 1)
// Ch2: EWRAM reads/writes from bus_out FSM
wire        sdram_rd_ready;
wire [31:0] sdram_rd_data;
wire [31:0] sdram_rd_data_second;

// GBA core ROM read signals (from gba_top)
wire        sdram_read_req_gba;
wire [24:0] sdram_read_addr_gba;

// Write interface — from ROM data_loader (active during boot)
wire        rom_loader_wr;
wire [27:0] rom_loader_addr;
wire [15:0] rom_loader_data;

// Save state staging SDRAM signals (from save_state_controller)
wire        ss_sdram_wr_req;
wire [24:0] ss_sdram_wr_addr;
wire [15:0] ss_sdram_wr_data;
wire        ss_sdram_rd_req;
wire [24:0] ss_sdram_rd_addr;
wire        ss_serving_active;

// Mux SDRAM ch1 write port: ROM loader OR save state staging writes
// ROM loading only at boot, staging writes only during gameplay. No overlap.
wire        sdram_wr_req_mux  = rom_loader_wr    | ss_sdram_wr_req;
wire [24:0] sdram_wr_addr_mux = ss_sdram_wr_req  ? ss_sdram_wr_addr : rom_loader_addr[25:1];
wire [15:0] sdram_wr_data_mux = ss_sdram_wr_req  ? ss_sdram_wr_data : rom_loader_data;

// Mux SDRAM ch1 read port: ROM reads OR staging reads
// During Phase 2 core is paused (sleep_savestate), no ROM reads conflict.
wire        sdram_rd_req_mux  = ss_serving_active ? ss_sdram_rd_req     : sdram_read_req_gba;
wire [24:0] sdram_rd_addr_mux = ss_serving_active ? ss_sdram_rd_addr    : sdram_read_addr_gba;

wire sdram_ready;
wire sdram_wr_pending;

sdram_pocket sdram (
    .clk            ( clk_sys ),
    .reset          ( ~pll_core_locked ),

    // Ch1: Read interface — registered mux between ROM and save state staging
    .rd_req         ( sdram_rd_req_mux ),
    .rd_addr        ( sdram_rd_addr_mux ),
    .rd_data        ( sdram_rd_data ),
    .rd_data_second ( sdram_rd_data_second ),
    .rd_ready       ( sdram_rd_ready ),

    // Ch1: Write interface — muxed between ROM loader and staging writes
    .wr_req         ( sdram_wr_req_mux ),
    .wr_addr        ( sdram_wr_addr_mux ),
    .wr_data        ( sdram_wr_data_mux ),

    // Ch2: EWRAM read/write — from bus_out FSM
    .ch2_rd         ( sdram_ch2_rd ),
    .ch2_wr         ( sdram_ch2_wr ),
    .ch2_addr       ( sdram_ch2_addr ),
    .ch2_din        ( sdram_ch2_din ),
    .ch2_dout       ( sdram_ch2_dout ),
    .ch2_ready      ( sdram_ch2_ready ),

    // Ready signal — high when SDRAM init complete
    .sdram_ready    ( sdram_ready ),
    .wr_pending     ( sdram_wr_pending ),

    // Physical SDRAM pins
    .dram_a         ( dram_a ),
    .dram_ba        ( dram_ba ),
    .dram_dq        ( dram_dq ),
    .dram_dqm       ( dram_dqm ),
    .dram_clk       ( dram_clk ),
    .dram_cke       ( dram_cke ),
    .dram_ras_n     ( dram_ras_n ),
    .dram_cas_n     ( dram_cas_n ),
    .dram_we_n      ( dram_we_n )
);

// ROM data_loader — captures bridge writes at 0x1xxxxxxx, outputs 16-bit words
data_loader #(
    .ADDRESS_MASK_UPPER_4   ( 4'h1 ),
    .ADDRESS_SIZE           ( 28 ),
    .OUTPUT_WORD_SIZE       ( 2 ),          // 16-bit output to match SDRAM width
    .WRITE_MEM_CLOCK_DELAY  ( 20 )          // ~20 clk_sys cycles between writes
) rom_data_loader (
    .clk_74a            ( clk_74a ),
    .clk_memory         ( clk_sys ),

    .bridge_wr          ( bridge_wr ),
    .bridge_endian_little ( bridge_endian_little ),
    .bridge_addr        ( bridge_addr ),
    .bridge_wr_data     ( bridge_wr_data ),

    .write_en           ( rom_loader_wr ),
    .write_addr         ( rom_loader_addr ),
    .write_data         ( rom_loader_data )
);

// Track ROM size — capture last byte address written during loading.
// MiSTer captures ioctl_addr at falling edge of cart_download; ioctl_addr
// is incremented after each write, so it points past the last byte.
// We emulate this: (last_byte_addr + 2) >> 2 gives past-the-end DWORD index.
reg [25:0] last_rom_byte_addr;
always @(posedge clk_sys) begin
    if (~pll_core_locked)
        last_rom_byte_addr <= 0;
    else if (rom_loader_wr)
        last_rom_byte_addr <= rom_loader_addr[25:0];
end
wire [24:0] max_rom_addr = (last_rom_byte_addr + 26'd2) >> 2;

// ---- Save Type Detection (MiSTer shift register during ROM download) ----
// Watches rom_loader_wr/data/addr during boot — no SDRAM reads needed.
// Detection results are ready by the time dataslot_allcomplete fires.
wire        det_flash_1m;
wire [31:0] detected_cart_id;
wire        det_cart_id_valid;

save_type_detector save_det (
    .clk             ( clk_sys ),
    .reset           ( ~pll_core_locked ),

    // ROM download stream from data_loader
    .rom_wr          ( rom_loader_wr ),
    .rom_data        ( rom_loader_data ),
    .rom_addr        ( rom_loader_addr ),

    // Results
    .flash_1m        ( det_flash_1m ),
    .cart_id         ( detected_cart_id ),
    .cart_id_valid   ( det_cart_id_valid )
);

// ---- Cart Quirk Database ----
// After save_type_detector captures cart_id, look up game-specific quirks.
// Quirk outputs feed gba_top ports in Step 5.5.
wire        quirk_sram;
wire        quirk_gpio;       // → specialmodule
wire        quirk_memory_remap; // → memory_remap
wire        quirk_sprite;     // → maxpixels

cart_quirks quirks (
    .clk           ( clk_sys ),
    .cart_id       ( detected_cart_id ),
    .valid         ( det_cart_id_valid ),
    .sram_quirk    ( quirk_sram ),
    .gpio_quirk    ( quirk_gpio ),
    .tilt_quirk    (),
    .solar_quirk   (),
    .memory_remap  ( quirk_memory_remap ),
    .sprite_quirk  ( quirk_sprite )
);

// ---- RTC Clock Domain Crossing ----
// Pocket OS sends RTC via bridge command 0x0090 (clk_74a domain).
// CDC epoch seconds to clk_sys for gba_top's RTC_timestampIn/RTC_timestampNew.
wire [31:0] rtc_epoch_s;
wire        rtc_new_s;

sync_fifo #(.WIDTH(32)) rtc_sync (
    .clk_write   ( clk_74a ),
    .clk_read    ( clk_sys ),
    .write_en    ( rtc_valid ),
    .data        ( rtc_epoch_seconds ),
    .data_s      ( rtc_epoch_s ),
    .write_en_s  ( rtc_new_s )
);

// CDC for Pocket BCD date/time (used as fallback when no save RTC exists)
wire [63:0] rtc_bcd_s;
wire        rtc_bcd_new_s;

sync_fifo #(.WIDTH(64)) rtc_bcd_sync (
    .clk_write   ( clk_74a ),
    .clk_read    ( clk_sys ),
    .write_en    ( rtc_valid ),
    .data        ( {rtc_date_bcd, rtc_time_bcd} ),
    .data_s      ( rtc_bcd_s ),
    .write_en_s  ( rtc_bcd_new_s )
);

// ---- RTC Persistence ----
// RTC data is appended as 5 x 16-bit words (10 bytes) after cart save data.
// During boot load: snoop save_loader for RTC region, capture into registers.
// During save writeback: override unloader data for RTC region addresses.

// RTC outputs from gba_top (active during gameplay)
wire [31:0] rtc_timestamp_out;
wire [41:0] rtc_savedtime_out;
wire        rtc_inuse;

// Save size in clk_sys domain (cart save only, excludes RTC bytes)
// sram_quirk games may still use EEPROM for saves (e.g. Dragon Ball Z titles),
// so use the default 64 KB to ensure EEPROM data is persisted.
wire [23:0] save_size_sys = det_flash_1m  ? 24'h02_0000 :  // 128 KB
                                            24'h01_0000;   // 64 KB

// RTC data captured during save loading
reg [31:0] rtc_loaded_timestamp;
reg [41:0] rtc_loaded_savedtime;
reg        rtc_data_captured;

// Snoop save_loader writes for RTC region (bytes beyond save_size_sys)
always @(posedge clk_sys) begin
    if (~pll_core_locked) begin
        rtc_data_captured    <= 0;
        rtc_loaded_timestamp <= 32'd0;
        rtc_loaded_savedtime <= 42'd0;
    end else if (save_loader_wr && save_size_sys != 24'd0) begin
        if (save_loader_addr[23:0] == save_size_sys)
            begin rtc_loaded_timestamp[15:0] <= save_loader_data; rtc_data_captured <= 1; end
        if (save_loader_addr[23:0] == save_size_sys + 24'd2)
            rtc_loaded_timestamp[31:16] <= save_loader_data;
        if (save_loader_addr[23:0] == save_size_sys + 24'd4)
            rtc_loaded_savedtime[15:0] <= save_loader_data;
        if (save_loader_addr[23:0] == save_size_sys + 24'd6)
            rtc_loaded_savedtime[31:16] <= save_loader_data;
        if (save_loader_addr[23:0] == save_size_sys + 24'd8)
            rtc_loaded_savedtime[41:32] <= save_loader_data[9:0];
    end else if (!rtc_data_captured && dataslot_allcomplete_s && rtc_bcd_received) begin
        // No save RTC data — seed from Pocket's real-time clock
        rtc_loaded_savedtime <= {
            rtc_bcd_s[55:48],     // [41:34] year BCD
            rtc_bcd_s[44:40],     // [33:29] month BCD (5b)
            rtc_bcd_s[37:32],     // [28:23] day BCD (6b)
            rtc_bcd_s[26:24],     // [22:20] weekday (3b)
            rtc_bcd_s[21:16],     // [19:14] hour BCD (6b)
            rtc_bcd_s[14:8],      // [13:7]  minute BCD (7b)
            rtc_bcd_s[6:0]        // [6:0]   second BCD (7b)
        };
        rtc_loaded_timestamp <= rtc_epoch_s;  // matches current time -> diffSeconds = 0
        rtc_data_captured    <= 1;            // allows rtc_save_loaded to fire
    end
end

// Track whether OS has sent RTC epoch time (0x0090 arrives AFTER 0x008F/allcomplete)
reg rtc_epoch_received;
always @(posedge clk_sys) begin
    if (~pll_core_locked)
        rtc_epoch_received <= 0;
    else if (rtc_new_s)
        rtc_epoch_received <= 1;
end

// Track whether Pocket BCD date/time has arrived (for fallback when no save RTC)
reg rtc_bcd_received;
always @(posedge clk_sys) begin
    if (~pll_core_locked)
        rtc_bcd_received <= 0;
    else if (rtc_bcd_new_s)
        rtc_bcd_received <= 1;
end

// Assert rtc_save_loaded after boot completes, RTC data captured, AND epoch received.
// All three are levels (stay high once set), so order of 0x008F vs 0x0090 doesn't matter.
// This ensures RTC_timestamp is valid before gba_gpioRTCSolarGyro computes diffSeconds.
reg rtc_save_loaded;
always @(posedge clk_sys) begin
    if (~pll_core_locked)
        rtc_save_loaded <= 0;
    else if (dataslot_allcomplete_s && rtc_data_captured && rtc_epoch_received)
        rtc_save_loaded <= 1;
end

// ---- CDC: dataslot_allcomplete → clk_sys ----
wire dataslot_allcomplete_s;
synch_3 s_allcomplete(dataslot_allcomplete, dataslot_allcomplete_s, clk_sys);

// ---- GBA Reset ----
// Core stays in reset until PLL locks AND all data slots finish loading.
// Save detection and quirk lookup complete during download (before allcomplete).
// reset_n is in clk_74a domain — synchronize to clk_sys before use.
wire reset_n_s;
synch_3 s_reset_n(reset_n, reset_n_s, clk_sys);

wire core_reset_s;
synch_3 s_core_reset(core_reset, core_reset_s, clk_sys);

wire reset_gba = ~pll_core_locked | ~dataslot_allcomplete_s | ~reset_n_s | core_reset_s;

// ---- BIOS Loading via data_loader → gba_top internal BRAM ----
// BIOS (16 KB) loads from data slot 4 at address 0x3xxxxxxx
// data_loader outputs 16-bit words; 16→32 converter feeds gba_top's bios_wr port
wire        bios_loader_wr;
wire [27:0] bios_loader_addr;
wire [15:0] bios_loader_data;

data_loader #(
    .ADDRESS_MASK_UPPER_4   ( 4'h3 ),      // 0x3xxxxxxx (BIOS slot)
    .ADDRESS_SIZE           ( 28 ),
    .OUTPUT_WORD_SIZE       ( 2 ),          // 16-bit output
    .WRITE_MEM_CLOCK_DELAY  ( 4 )           // BRAM is fast, minimal delay
) bios_data_loader (
    .clk_74a            ( clk_74a ),
    .clk_memory         ( clk_sys ),

    .bridge_wr          ( bridge_wr ),
    .bridge_endian_little ( bridge_endian_little ),
    .bridge_addr        ( bridge_addr ),
    .bridge_wr_data     ( bridge_wr_data ),

    .write_en           ( bios_loader_wr ),
    .write_addr         ( bios_loader_addr ),
    .write_data         ( bios_loader_data )
);

// BIOS 16→32 converter — gba_top has internal 4096×32-bit BIOS BRAM.
// data_loader outputs 16-bit words; we buffer pairs to write 32-bit.
reg [15:0] bios_buf;
reg [31:0] bios_32_data;
reg [11:0] bios_32_addr;
reg        bios_32_wr;

always @(posedge clk_sys) begin
    bios_32_wr <= 0;
    if (bios_loader_wr) begin
        if (bios_loader_addr[1]) begin  // Second 16-bit word → write 32-bit
            bios_32_data <= {bios_loader_data, bios_buf};
            bios_32_addr <= bios_loader_addr[13:2];
            bios_32_wr   <= 1;
        end else begin
            bios_buf <= bios_loader_data;  // First 16-bit word → buffer
        end
    end
end

// Track whether BIOS was loaded
reg bios_loaded;
always @(posedge clk_sys) begin
    if (~pll_core_locked)
        bios_loaded <= 0;
    else if (bios_loader_wr)
        bios_loaded <= 1;
end

// tie off SRAM — inactive
assign sram_a = 'h0;
assign sram_dq = {16{1'bZ}};
assign sram_oe_n  = 1;
assign sram_we_n  = 1;
assign sram_ub_n  = 1;
assign sram_lb_n  = 1;

assign dbg_tx = 1'bZ;
assign user1 = 1'bZ;
assign aux_scl = 1'bZ;
assign vpll_feed = 1'bZ;


// ============================================================
// Section 1: PLL & Clock Generation
// ============================================================

wire    clk_sys;            // ~100.66 MHz — GBA core domain
wire    clk_sys_90;         // ~100.66 MHz, 270 deg — SDRAM DDR outclock (→ 90° SDRAM_CLK)
wire    clk_vid;            // 8.388608 MHz — video pixel clock (2× GBA dot clock)
wire    clk_vid_90;         // 8.388608 MHz, 90 deg — video DDR
wire    pll_core_locked;
wire    pll_core_locked_s;
synch_3 s01(pll_core_locked, pll_core_locked_s, clk_74a);

mf_pllbase mp1 (
    .refclk     ( clk_74a ),
    .rst        ( 0 ),
    .outclk_0   ( clk_sys ),
    .outclk_1   ( clk_sys_90 ),
    .outclk_2   ( clk_vid ),
    .outclk_3   ( clk_vid_90 ),
    .locked     ( pll_core_locked )
);


// ============================================================
// Section 2: Bridge Command Handler
// ============================================================

wire            reset_n;
wire    [31:0]  cmd_bridge_rd_data;

wire            status_boot_done  = pll_core_locked_s;
wire            status_setup_done = pll_core_locked_s;
wire            status_running    = reset_n;

wire            dataslot_requestread;
wire    [15:0]  dataslot_requestread_id;
wire            dataslot_requestread_ack = 1;
wire            dataslot_requestread_ok = 1;

wire            dataslot_requestwrite;
wire    [15:0]  dataslot_requestwrite_id;
wire    [31:0]  dataslot_requestwrite_size;
wire            dataslot_requestwrite_ack = 1;
wire            dataslot_requestwrite_ok = 1;

wire            dataslot_update;
wire    [15:0]  dataslot_update_id;
wire    [31:0]  dataslot_update_size;

wire            dataslot_allcomplete;

wire    [31:0]  rtc_epoch_seconds;
wire    [31:0]  rtc_date_bcd;
wire    [31:0]  rtc_time_bcd;
wire            rtc_valid;

wire            savestate_supported = 1;
wire    [31:0]  savestate_addr = 32'h40000000;
wire    [31:0]  savestate_size = 32'h60D18;       // 0x18346 addr-units × 4 bytes
wire    [31:0]  savestate_maxloadsize = 32'h60D18;

wire            savestate_start;
wire            savestate_start_ack;
wire            savestate_start_busy;
wire            savestate_start_ok;
wire            savestate_start_err;

wire            savestate_load;
wire            savestate_load_ack;
wire            savestate_load_busy;
wire            savestate_load_ok;
wire            savestate_load_err;

wire            osnotify_inmenu;

reg             target_dataslot_read;
reg             target_dataslot_write;
reg             target_dataslot_getfile;
reg             target_dataslot_openfile;

wire            target_dataslot_ack;
wire            target_dataslot_done;
wire    [2:0]   target_dataslot_err;

reg     [15:0]  target_dataslot_id;
reg     [31:0]  target_dataslot_slotoffset;
reg     [31:0]  target_dataslot_bridgeaddr;
reg     [31:0]  target_dataslot_length;

wire    [31:0]  target_buffer_param_struct;
wire    [31:0]  target_buffer_resp_struct;

wire    [9:0]   datatable_addr;
wire            datatable_wren;
wire    [31:0]  datatable_data;
wire    [31:0]  datatable_q;

// Datatable Port A drive registers (one-shot write FSM drives these)
reg  [9:0]  datatable_addr_r;
reg         datatable_wren_r;
reg  [31:0] datatable_data_r;

assign datatable_addr = datatable_addr_r;
assign datatable_wren = datatable_wren_r;
assign datatable_data = datatable_data_r;

core_bridge_cmd icb (

    .clk                    ( clk_74a ),
    .reset_n                ( reset_n ),

    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_rd              ( bridge_rd ),
    .bridge_rd_data         ( cmd_bridge_rd_data ),
    .bridge_wr              ( bridge_wr ),
    .bridge_wr_data         ( bridge_wr_data ),

    .status_boot_done       ( status_boot_done ),
    .status_setup_done      ( status_setup_done ),
    .status_running         ( status_running ),

    .dataslot_requestread       ( dataslot_requestread ),
    .dataslot_requestread_id    ( dataslot_requestread_id ),
    .dataslot_requestread_ack   ( dataslot_requestread_ack ),
    .dataslot_requestread_ok    ( dataslot_requestread_ok ),

    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
    .dataslot_requestwrite_ack  ( dataslot_requestwrite_ack ),
    .dataslot_requestwrite_ok   ( dataslot_requestwrite_ok ),

    .dataslot_update            ( dataslot_update ),
    .dataslot_update_id         ( dataslot_update_id ),
    .dataslot_update_size       ( dataslot_update_size ),

    .dataslot_allcomplete   ( dataslot_allcomplete ),

    .rtc_epoch_seconds      ( rtc_epoch_seconds ),
    .rtc_date_bcd           ( rtc_date_bcd ),
    .rtc_time_bcd           ( rtc_time_bcd ),
    .rtc_valid              ( rtc_valid ),

    .savestate_supported    ( savestate_supported ),
    .savestate_addr         ( savestate_addr ),
    .savestate_size         ( savestate_size ),
    .savestate_maxloadsize  ( savestate_maxloadsize ),

    .savestate_start        ( savestate_start ),
    .savestate_start_ack    ( savestate_start_ack ),
    .savestate_start_busy   ( savestate_start_busy ),
    .savestate_start_ok     ( savestate_start_ok ),
    .savestate_start_err    ( savestate_start_err ),

    .savestate_load         ( savestate_load ),
    .savestate_load_ack     ( savestate_load_ack ),
    .savestate_load_busy    ( savestate_load_busy ),
    .savestate_load_ok      ( savestate_load_ok ),
    .savestate_load_err     ( savestate_load_err ),

    .osnotify_inmenu        ( osnotify_inmenu ),

    .target_dataslot_read       ( target_dataslot_read ),
    .target_dataslot_write      ( target_dataslot_write ),
    .target_dataslot_getfile    ( target_dataslot_getfile ),
    .target_dataslot_openfile   ( target_dataslot_openfile ),

    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err ),

    .target_dataslot_id         ( target_dataslot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),

    .target_buffer_param_struct ( target_buffer_param_struct ),
    .target_buffer_resp_struct  ( target_buffer_resp_struct ),

    .datatable_addr         ( datatable_addr ),
    .datatable_wren         ( datatable_wren ),
    .datatable_data         ( datatable_data ),
    .datatable_q            ( datatable_q )

);


// ============================================================
// Section 3: Bridge Read Mux
// ============================================================

wire [31:0] ss_bridge_rd_data;

always @(*) begin
    casex (bridge_addr)
    32'h2xxxxxxx: begin
        bridge_rd_data <= save_read_bridge_data;
    end
    32'h4xxxxxxx: begin
        bridge_rd_data <= ss_bridge_rd_data;
    end
    32'hF8xxxxxx: begin
        bridge_rd_data <= cmd_bridge_rd_data;
    end
    default: begin
        bridge_rd_data <= 0;
    end
    endcase
end


// ---- Datatable write: communicate save size to Pocket OS ----
// Continuously write save size to datatable[5] (save slot at data_slots index 2).
// The Pocket OS reads this value on core exit to determine save writeback size.
// Must be continuous (not one-shot) because the Pocket may write to the same
// datatable address via port B during its own bookkeeping, overwriting a one-shot value.
// Matches the pattern used by the GBC reference core (budude2/openfpga-GBC).
// All logic in clk_74a domain (same clock as mf_datatable).

// CDC: flash_1m, sram_quirk, gpio_quirk from clk_sys → clk_74a (stable after download)
wire flash_1m_s;
synch_3 flash_1m_sync (
    .i   ( det_flash_1m ),
    .o   ( flash_1m_s ),
    .clk ( clk_74a )
);

wire gpio_quirk_s;
synch_3 gpio_quirk_sync (
    .i   ( quirk_gpio ),
    .o   ( gpio_quirk_s ),
    .clk ( clk_74a )
);

// Save size for datatable (Pocket-specific: must declare size at boot)
// MiSTer determines save_sz at runtime from bus activity; we can't do that.
// Use safe upper bounds based on flash_1m:
//   flash_1m   → 131072 (128K Flash, packed 1:1 in PSRAM die 1)
//   default    → 65536 (covers SRAM 32K, Flash 64K, EEPROM 8K — packed)
// sram_quirk games still get 64 KB: the quirk only disables SRAM/Flash at 0xE,
// but many (e.g. Dragon Ball Z titles) use EEPROM at 0xD for actual saves.
// bus_out FSM packs save bytes densely (1 byte per PSRAM byte), so these
// sizes match the actual save type sizes. No 4× DWORD expansion.
// Only add 16 bytes for RTC data when the game uses GPIO/RTC or force_rtc is on.
wire        rtc_active = gpio_quirk_s | force_rtc;
wire [31:0] save_size_bytes = flash_1m_s ? (32'h0002_0000 + (rtc_active ? 32'd16 : 32'd0)) :
                                           (32'h0001_0000 + (rtc_active ? 32'd16 : 32'd0));

// Continuously drive datatable port A with save size.
// Writing every cycle is intentional: the Pocket OS may write to the same
// datatable address via port B during bookkeeping, overwriting a one-shot value.
// Continuous writes ensure the core's value is always current when the OS reads
// it on core exit for save writeback. This is just a BRAM write port — no cost.
// Matches the pattern used by the GBC reference core (budude2/openfpga-GBC).
always @(posedge clk_74a) begin
    if (~pll_core_locked_s) begin
        datatable_addr_r <= 10'd0;
        datatable_data_r <= 32'd0;
        datatable_wren_r <= 1'b0;
    end else begin
        datatable_addr_r <= 10'd5;          // save slot index 2: 2*2+1 = 5
        datatable_data_r <= save_size_bytes;
        datatable_wren_r <= 1'b1;
    end
end


// ---- Interact menu config registers (clk_74a domain) ----
reg [1:0] ff_mode = 0;    // 0 = Hold, 1 = Toggle, 2 = Disabled
reg force_rtc = 0;        // 0 = Off, 1 = Force enable RTC/GPIO
reg [1:0] turbo_mode = 0; // 0 = Disabled, 1 = Turbo A, 2 = Turbo B

reg [13:0] reset_counter = 0;
wire       core_reset = (reset_counter != 0);

always @(posedge clk_74a) begin
    if (reset_counter != 0)
        reset_counter <= reset_counter - 1;

    if (bridge_wr) begin
        casex (bridge_addr)
        32'hF0000000: reset_counter <= 14'd8000;  // ~108 us at 74.25 MHz
        32'h80: ff_mode    <= bridge_wr_data[1:0];
        32'h84: force_rtc  <= bridge_wr_data[0];
        32'h88: turbo_mode <= bridge_wr_data[1:0];
        endcase
    end
end

// ---- CDC: ff_mode, force_rtc, turbo_mode → clk_sys ----
wire [1:0] ff_mode_s;
synch_3 #(.WIDTH(2)) ff_mode_sync(ff_mode, ff_mode_s, clk_sys);

wire force_rtc_s;
synch_3 force_rtc_sync(force_rtc, force_rtc_s, clk_sys);

wire [1:0] turbo_mode_s;
synch_3 #(.WIDTH(2)) turbo_mode_sync(turbo_mode, turbo_mode_s, clk_sys);

// ============================================================
// Section 4: Video Output — framebuffer + raster scan
// ============================================================

// Video clock: clk_vid (8.388608 MHz = 2× GBA dot clock) with DDR 90° phase
assign video_rgb_clock    = clk_vid;
assign video_rgb_clock_90 = clk_vid_90;

// Pixel interface — driven by gba_top
wire [15:0] pixel_out_addr;
wire [17:0] pixel_out_data;
wire        pixel_out_we;

video_adapter video_out (
    .clk_sys    ( clk_sys ),
    .clk_vid    ( clk_vid ),
    .reset      ( ~pll_core_locked ),

    .pixel_addr ( pixel_out_addr ),
    .pixel_data ( pixel_out_data ),
    .pixel_we   ( pixel_out_we ),

    .video_rgb  ( video_rgb ),
    .video_de   ( video_de ),
    .video_vs   ( video_vs ),
    .video_hs   ( video_hs ),
    .video_skip ( video_skip )
);


// ============================================================
// Section 5: Audio Output — audio_mixer with IIR filter + DC blocker
// GBA outputs 16-bit signed PCM stereo; audio_mixer handles
// filtering, clock-domain crossing, and I2S encoding.
// ============================================================

// Audio outputs — driven by gba_top
wire [15:0] sound_out_left;
wire [15:0] sound_out_right;

audio_mixer #(
    .DW     ( 16 ),
    .STEREO ( 1 )
) audio_out (
    .clk_74b    ( clk_74a ),
    .clk_audio  ( clk_sys ),
    .reset      ( reset_gba ),
    .vol_att    ( 4'd0 ),
    .mix        ( 2'd0 ),
    .is_signed  ( 1'b1 ),
    .core_l     ( fast_forward ? 16'h0 : sound_out_left ),
    .core_r     ( fast_forward ? 16'h0 : sound_out_right ),
    .audio_mclk ( audio_mclk ),
    .audio_lrck ( audio_lrck ),
    .audio_dac  ( audio_dac )
);


// ============================================================
// Section 6: Input Mapping
// Pocket cont1_key → GBA buttons (active-high for gba_top KeyX ports)
// ============================================================

// Synchronize cont1_key from clk_74a into clk_sys domain
wire [31:0] cont1_key_s;
synch_3 #(.WIDTH(32)) cont1_sync (
    .i   ( cont1_key ),
    .o   ( cont1_key_s ),
    .clk ( clk_sys )
);

// GBA buttons — active-high (1 = pressed), matching gba_top.vhd Key* ports
// Pocket cont1_key is also active-high, so no inversion needed
// Pocket bitmap: [0]=up [1]=down [2]=left [3]=right [4]=A [5]=B [6]=X [7]=Y [8]=L1 [9]=R1 [14]=sel [15]=start

// X button (bit 6) — Turbo, not a GBA button
wire x_button = cont1_key_s[6];

// Turbo: free-running counter, bit[20] toggles at ~48 Hz → ~24 presses/sec
reg [20:0] turbo_counter = 0;
always @(posedge clk_sys)
    turbo_counter <= turbo_counter + 1'd1;

wire turbo_pulse = turbo_counter[20];
wire turbo_a = (turbo_mode_s == 2'd1) && x_button && turbo_pulse;
wire turbo_b = (turbo_mode_s == 2'd2) && x_button && turbo_pulse;

wire key_a      = cont1_key_s[4] | turbo_a;
wire key_b      = cont1_key_s[5] | turbo_b;
wire key_select = cont1_key_s[14];
wire key_start  = cont1_key_s[15];
wire key_up     = cont1_key_s[0];
wire key_down   = cont1_key_s[1];
wire key_left   = cont1_key_s[2];
wire key_right  = cont1_key_s[3];
wire key_r      = cont1_key_s[9];
wire key_l      = cont1_key_s[8];

// Y button (bit 7) — Fast Forward, not a GBA button
// Hold mode: active while button pressed
// Toggle mode: press toggles on/off
// Disabled mode: fast forward button does nothing
wire ff_button = cont1_key_s[7];

reg ff_button_prev = 0;
reg ff_toggle_state = 0;

always @(posedge clk_sys) begin
    ff_button_prev <= ff_button;
    // Rising edge of button press toggles the state
    if (ff_button && !ff_button_prev)
        ff_toggle_state <= ~ff_toggle_state;
end

wire fast_forward = (ff_mode_s == 2'd2) ? 1'b0 :            // Disabled
                    (ff_mode_s == 2'd1) ? ff_toggle_state :  // Toggle
                    ff_button;                               // Hold (default)


// ============================================================
// Section 7: GBA Core Instantiation
// ============================================================

// ---- Save State Controller ----
// Bridges APF save state protocol to gba_savestates via SAVE_out bus.
// Uses SDRAM staging for load path (389 KB state >> 16 KB FIFO).

wire [63:0] ss_din;          // SAVE_out_Din  (data from gba_savestates during save)
wire [63:0] ss_dout;         // SAVE_out_Dout (data to gba_savestates during load)
wire [25:0] ss_addr;         // SAVE_out_Adr
wire        ss_rnw;          // SAVE_out_rnw
wire        ss_req;          // SAVE_out_ena
wire  [7:0] ss_be;           // SAVE_out_be
wire        ss_ack;          // SAVE_out_done
wire        ss_save;         // save_state trigger to gba_top
wire        ss_load;         // load_state trigger to gba_top
wire        ss_busy;         // savestate_busy from gba_top
wire        ss_loading;      // Phase 1+2 active — pause core to prevent SDRAM contention
wire        ss_load_done;    // load_done from gba_top

save_state_controller ss_ctrl (
    .clk_74a              ( clk_74a ),
    .clk_sys              ( clk_sys ),
    // APF bridge
    .bridge_wr            ( bridge_wr ),
    .bridge_rd            ( bridge_rd ),
    .bridge_endian_little ( bridge_endian_little ),
    .bridge_addr          ( bridge_addr ),
    .bridge_wr_data       ( bridge_wr_data ),
    .save_state_bridge_read_data ( ss_bridge_rd_data ),
    // APF save state signals
    .savestate_load       ( savestate_load ),
    .savestate_load_ack_s ( savestate_load_ack ),
    .savestate_load_busy_s( savestate_load_busy ),
    .savestate_load_ok_s  ( savestate_load_ok ),
    .savestate_load_err_s ( savestate_load_err ),
    .savestate_start      ( savestate_start ),
    .savestate_start_ack_s( savestate_start_ack ),
    .savestate_start_busy_s( savestate_start_busy ),
    .savestate_start_ok_s ( savestate_start_ok ),
    .savestate_start_err_s( savestate_start_err ),
    // GBA core save state bus
    .ss_save              ( ss_save ),
    .ss_load              ( ss_load ),
    .ss_din               ( ss_din ),
    .ss_dout              ( ss_dout ),
    .ss_addr              ( ss_addr ),
    .ss_rnw               ( ss_rnw ),
    .ss_req               ( ss_req ),
    .ss_be                ( ss_be ),
    .ss_ack               ( ss_ack ),
    .ss_busy              ( ss_busy ),
    .load_done            ( ss_load_done ),
    // SDRAM staging
    .sdram_wr_req         ( ss_sdram_wr_req ),
    .sdram_wr_addr        ( ss_sdram_wr_addr ),
    .sdram_wr_data        ( ss_sdram_wr_data ),
    .sdram_wr_pending     ( sdram_wr_pending ),
    .sdram_rd_req         ( ss_sdram_rd_req ),
    .sdram_rd_addr        ( ss_sdram_rd_addr ),
    .sdram_rd_data        ( sdram_rd_data ),
    .sdram_rd_data_second ( sdram_rd_data_second ),
    .sdram_rd_ready       ( ss_serving_active ? sdram_rd_ready : 1'b0 ),
    // Status
    .ss_serving_active    ( ss_serving_active ),
    .ss_loading           ( ss_loading )
);

gba_top #(
    .Softmap_GBA_FLASH_ADDR  (0),
    .Softmap_GBA_EEPROM_ADDR (0),
    .Softmap_GBA_WRam_ADDR   (131072),
    .Softmap_GBA_Gamerom_ADDR(0),
    .Softmap_SaveState_ADDR  (0),
    .turbosound              (1'b1)
) gba (
    .clk100              ( clk_sys ),
    // Settings
    .GBA_on              ( ~reset_gba ),
    .GBA_lockspeed       ( ~fast_forward ),
    .GBA_cputurbo        ( 1'b0 ),
    .GBA_flash_1m        ( det_flash_1m ),
    .CyclePrecalc        ( 16'd100 ),
    .Underclock          ( 2'b00 ),
    .MaxPakAddr          ( max_rom_addr ),
    .CyclesMissing       (),
    .CyclesVsyncSpeed    (),
    .SramFlashEnable     ( ~quirk_sram ),
    .memory_remap        ( quirk_memory_remap ),
    .increaseSSHeaderCount(1'b0),
    .save_state          ( ss_save ),
    .load_state          ( ss_load ),
    .maxpixels           ( quirk_sprite ),
    .specialmodule       ( quirk_gpio | force_rtc_s ),
    // solar/tilt/rumble removed to save ALMs
    .savestate_number    ( 0 ),
    // RTC
    .RTC_timestampNew    ( rtc_new_s ),
    .RTC_timestampIn     ( rtc_epoch_s ),
    .RTC_timestampSaved  ( rtc_loaded_timestamp ),
    .RTC_savedtimeIn     ( rtc_loaded_savedtime ),
    .RTC_saveLoaded      ( rtc_save_loaded ),
    .RTC_timestampOut    ( rtc_timestamp_out ),
    .RTC_savedtimeOut    ( rtc_savedtime_out ),
    .RTC_inuse           ( rtc_inuse ),
    // SDRAM (ROM reads — muxed with staging in sdram_pocket section)
    .sdram_read_ena      ( sdram_read_req_gba ),
    .sdram_read_done     ( ss_serving_active ? 1'b0 : sdram_rd_ready ),
    .sdram_read_addr     ( sdram_read_addr_gba ),
    .sdram_read_data     ( sdram_rd_data ),
    .sdram_second_dword  ( sdram_rd_data_second ),
    // External memory (EWRAM + saves via PSRAM)
    .bus_out_Din         ( bus_out_Din ),
    .bus_out_Dout        ( bus_out_Dout ),
    .bus_out_Adr         ( bus_out_Adr ),
    .bus_out_rnw         ( bus_out_rnw ),
    .bus_out_ena         ( bus_out_ena ),
    .bus_out_done        ( bus_out_done ),
    // Save state — connected to save_state_controller
    .SAVE_out_Din        ( ss_din ),
    .SAVE_out_Dout       ( ss_dout ),
    .SAVE_out_Adr        ( ss_addr ),
    .SAVE_out_rnw        ( ss_rnw ),
    .SAVE_out_ena        ( ss_req ),
    .SAVE_out_active     (),
    .SAVE_out_be         ( ss_be ),
    .SAVE_out_done       ( ss_ack ),
    // BIOS write (from 16→32 converter)
    .bios_wraddr         ( bios_32_addr ),
    .bios_wrdata         ( bios_32_data ),
    .bios_wr             ( bios_32_wr ),
    // Save detection outputs (unused — we detect externally)
    .save_eeprom         (),
    .save_sram           (),
    .save_flash          (),
    .load_done           ( ss_load_done ),
    .savestate_busy      ( ss_busy ),
    .sleep_external      ( ss_loading ),
    // Input
    .KeyA                ( key_a ),
    .KeyB                ( key_b ),
    .KeySelect           ( key_select ),
    .KeyStart            ( key_start ),
    .KeyRight            ( key_right ),
    .KeyLeft             ( key_left ),
    .KeyUp               ( key_up ),
    .KeyDown             ( key_down ),
    .KeyR                ( key_r ),
    .KeyL                ( key_l ),
    // AnalogTiltX/Y and Rumble removed (solar/gyro/tilt/rumble stripped)
    // Debug (unused)
    .GBA_BusAddr         ( 28'd0 ),
    .GBA_BusRnW          ( 1'b0 ),
    .GBA_BusACC          ( 2'b00 ),
    .GBA_BusWriteData    ( 32'd0 ),
    .GBA_BusReadData     (),
    .GBA_Bus_written     ( 1'b0 ),
    // Video
    .pixel_out_x         (),
    .pixel_out_y         (),
    .pixel_out_addr      ( pixel_out_addr ),
    .pixel_out_data      ( pixel_out_data ),
    .pixel_out_we        ( pixel_out_we ),
    // Audio
    .sound_out_left      ( sound_out_left ),
    .sound_out_right     ( sound_out_right ),
    // Debug outputs
    .debug_cpu_pc        (),
    .debug_cpu_mixed     (),
    .debug_irq           (),
    .debug_dma           (),
    .debug_mem           ()
);


endmodule
