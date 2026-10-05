// Adapts data_unloader's level-held read request to one PSRAM transaction.
// The returned word remains stable until data_unloader finishes sampling it.

`timescale 1ns/1ps
`default_nettype none

module save_psram_unloader (
    input  wire        clk,
    input  wire        reset_n,

    input  wire        unloader_read_en,
    input  wire [21:0] unloader_addr,
    output reg  [15:0] unloader_data = 16'd0,

    input  wire        psram_busy,
    input  wire        psram_read_avail,
    input  wire [15:0] psram_data,
    output wire        psram_read_en,
    output reg  [21:0] psram_addr = 22'd0
);

    localparam [1:0] READ_IDLE   = 2'd0;
    localparam [1:0] READ_LAUNCH = 2'd1;
    localparam [1:0] READ_WAIT   = 2'd2;
    localparam [1:0] READ_HOLD   = 2'd3;

    reg [1:0] read_state = READ_IDLE;

    assign psram_read_en = read_state == READ_LAUNCH;

    always @(posedge clk) begin
        if (!reset_n) begin
            read_state     <= READ_IDLE;
            psram_addr     <= 22'd0;
            unloader_data  <= 16'd0;
        end else begin
            case (read_state)
                READ_IDLE: begin
                    if (unloader_read_en && !psram_busy) begin
                        psram_addr <= unloader_addr;
                        read_state <= READ_LAUNCH;
                    end
                end

                READ_LAUNCH: begin
                    read_state <= READ_WAIT;
                end

                READ_WAIT: begin
                    if (psram_read_avail) begin
                        unloader_data <= psram_data;
                        read_state <= READ_HOLD;
                    end
                end

                READ_HOLD: begin
                    if (!unloader_read_en)
                        read_state <= READ_IDLE;
                end

                default: read_state <= READ_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
