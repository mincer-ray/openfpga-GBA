// Shared APF write ingress with a causally ordered completion fence.
// Whole 32-bit bridge writes cross the CDC atomically, then emerge as two
// ordered 16-bit memory-domain transactions.

`timescale 1ns/1ps
`default_nettype none

module apf_write_ingress #(
    parameter integer ROM_WRITE_DELAY  = 20,
    parameter integer SAVE_WRITE_DELAY = 20,
    parameter integer BIOS_WRITE_DELAY = 4
) (
    input  wire        clk_74a,
    input  wire        clk_memory,

    input  wire        bridge_wr,
    input  wire        bridge_endian_little,
    input  wire [31:0] bridge_addr,
    input  wire [31:0] bridge_wr_data,
    input  wire        completion_request,

    output reg         write_valid = 1'b0,
    output reg  [1:0]  write_dest  = 2'd0,
    output reg  [27:0] write_addr  = 28'd0,
    output reg  [15:0] write_data  = 16'd0,
    input  wire        write_ready,

    output reg         fence_valid = 1'b0,
    input  wire        fence_ready,
    output reg         fence_done = 1'b0,
    output wire        write_busy
);

  localparam integer FIFO_WIDTH = 63;
  localparam [1:0] DEST_ROM  = 2'd1;
  localparam [1:0] DEST_SAVE = 2'd2;
  localparam [1:0] DEST_BIOS = 2'd3;

  reg prev_bridge_wr = 1'b0;
  reg prev_completion_request = 1'b0;
  reg fence_pending = 1'b0;
  reg fence_enqueued = 1'b0;

  wire bridge_region_valid = bridge_addr[31:28] == 4'h1 ||
                             bridge_addr[31:28] == 4'h2 ||
                             bridge_addr[31:28] == 4'h3;
  wire bridge_write_start = ~prev_bridge_wr && bridge_wr && bridge_region_valid;
  wire completion_rise = completion_request && !prev_completion_request;
  wire [31:0] normalized_bridge_data = bridge_endian_little ? bridge_wr_data : {
      bridge_wr_data[7:0], bridge_wr_data[15:8],
      bridge_wr_data[23:16], bridge_wr_data[31:24]
  };

  wire fifo_full;
  wire fifo_empty;
  wire [FIFO_WIDTH-1:0] fifo_out;
  reg fifo_read_req = 1'b0;
  wire enqueue_data = bridge_write_start && !fifo_full;
  wire enqueue_fence = fence_pending && !bridge_write_start && !fifo_full;
  wire fifo_write_req = enqueue_data || enqueue_fence;
  wire [1:0] bridge_dest = bridge_addr[29:28];
  wire [FIFO_WIDTH-1:0] fifo_in = enqueue_fence ?
      {1'b1, 2'd0, 32'd0, 28'd0} :
      {1'b0, bridge_dest, normalized_bridge_data, bridge_addr[27:0]};

  always @(posedge clk_74a) begin
    prev_bridge_wr <= bridge_wr;
    prev_completion_request <= completion_request;

    if (completion_rise)
      fence_pending <= 1'b1;
    if (enqueue_fence) begin
      fence_pending <= 1'b0;
      fence_enqueued <= 1'b1;
    end

    // synthesis translate_off
    if (bridge_write_start && fifo_full)
      $fatal(1, "APF ingress overflow at address %08x", bridge_addr);
    if (bridge_write_start && fence_enqueued)
      $fatal(1, "APF startup write arrived after completion fence: %08x", bridge_addr);
    // synthesis translate_on
  end

  dcfifo ingress_fifo (
      .data(fifo_in),
      .rdclk(clk_memory),
      .rdreq(fifo_read_req),
      .wrclk(clk_74a),
      .wrreq(fifo_write_req),
      .q(fifo_out),
      .rdempty(fifo_empty),
      .wrfull(fifo_full)
  );
  defparam ingress_fifo.clocks_are_synchronized = "FALSE",
      ingress_fifo.intended_device_family = "Cyclone V", ingress_fifo.lpm_numwords = 8,
      ingress_fifo.lpm_showahead = "OFF", ingress_fifo.lpm_type = "dcfifo",
      ingress_fifo.lpm_width = FIFO_WIDTH, ingress_fifo.lpm_widthu = 3,
      ingress_fifo.overflow_checking = "OFF", ingress_fifo.rdsync_delaypipe = 5,
      ingress_fifo.underflow_checking = "OFF", ingress_fifo.use_eab = "ON",
      ingress_fifo.wrsync_delaypipe = 5;

  localparam [3:0] READ_IDLE         = 4'd0;
  localparam [3:0] READ_POP         = 4'd1;
  localparam [3:0] READ_LATCH       = 4'd2;
  localparam [3:0] READ_FIRST       = 4'd3;
  localparam [3:0] READ_FIRST_DELAY = 4'd4;
  localparam [3:0] READ_SECOND      = 4'd5;
  localparam [3:0] READ_LAST_DELAY  = 4'd6;
  localparam [3:0] READ_FENCE       = 4'd7;

  reg [3:0] read_state = READ_IDLE;
  reg [27:0] word_addr = 28'd0;
  reg [31:0] word_data = 32'd0;
  reg [5:0] delay_count = 6'd0;

  function automatic [5:0] write_delay(input [1:0] destination);
    begin
      case (destination)
        DEST_ROM:  write_delay = ROM_WRITE_DELAY[5:0];
        DEST_SAVE: write_delay = SAVE_WRITE_DELAY[5:0];
        DEST_BIOS: write_delay = BIOS_WRITE_DELAY[5:0];
        default:   write_delay = 6'd4;
      endcase
    end
  endfunction

  always @(posedge clk_memory) begin
    fence_done <= 1'b0;

    case (read_state)
      READ_IDLE: begin
        fifo_read_req <= 1'b0;
        write_valid <= 1'b0;
        fence_valid <= 1'b0;
        if (!fifo_empty) begin
          fifo_read_req <= 1'b1;
          read_state <= READ_POP;
        end
      end

      READ_POP: begin
        fifo_read_req <= 1'b0;
        read_state <= READ_LATCH;
      end

      READ_LATCH: begin
        if (fifo_out[62]) begin
          fence_valid <= 1'b1;
          write_valid <= 1'b0;
          read_state <= READ_FENCE;
        end else begin
          word_addr  <= fifo_out[27:0];
          word_data  <= fifo_out[59:28];
          write_dest <= fifo_out[61:60];
          write_addr <= fifo_out[27:0];
          write_data <= fifo_out[43:28];
          write_valid <= 1'b1;
          fence_valid <= 1'b0;
          read_state <= READ_FIRST;
        end
      end

      READ_FIRST: begin
        if (write_ready) begin
          write_valid <= 1'b0;
          delay_count <= write_delay(write_dest) - 1'b1;
          read_state <= READ_FIRST_DELAY;
        end
      end

      READ_FIRST_DELAY: begin
        if (delay_count <= 1) begin
          write_addr <= word_addr + 28'd2;
          write_data <= word_data[31:16];
          write_valid <= 1'b1;
          read_state <= READ_SECOND;
        end else begin
          delay_count <= delay_count - 1'b1;
        end
      end

      READ_SECOND: begin
        if (write_ready) begin
          write_valid <= 1'b0;
          delay_count <= write_delay(write_dest) - 1'b1;
          read_state <= READ_LAST_DELAY;
        end
      end

      READ_LAST_DELAY: begin
        if (delay_count == 0)
          read_state <= READ_IDLE;
        else
          delay_count <= delay_count - 1'b1;
      end

      READ_FENCE: begin
        if (fence_ready) begin
          fence_valid <= 1'b0;
          fence_done <= 1'b1;
          read_state <= READ_IDLE;
        end
      end

      default: begin
        fifo_read_req <= 1'b0;
        write_valid <= 1'b0;
        fence_valid <= 1'b0;
        read_state <= READ_IDLE;
      end
    endcase
  end

  assign write_busy = fence_pending || (read_state != READ_IDLE) || !fifo_empty;

  // synthesis translate_off
  initial begin
    if (ROM_WRITE_DELAY < 4 || ROM_WRITE_DELAY > 63)
      $fatal(1, "ROM_WRITE_DELAY must be between 4 and 63");
    if (SAVE_WRITE_DELAY < 4 || SAVE_WRITE_DELAY > 63)
      $fatal(1, "SAVE_WRITE_DELAY must be between 4 and 63");
    if (BIOS_WRITE_DELAY < 4 || BIOS_WRITE_DELAY > 63)
      $fatal(1, "BIOS_WRITE_DELAY must be between 4 and 63");
  end
  // synthesis translate_on

endmodule

`default_nettype wire
