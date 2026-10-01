// Coherent RTC sidecar exporter. The VHDL RTC publishes its timestamp and
// calendar through separate pipelines, so only promote a live pair after it
// has remained unchanged for sixteen subsequent clk_sys samples.

`timescale 1ns/1ps
`default_nettype none

module rtc_export (
    input  wire        clk,
    input  wire        reset_n,
    input  wire        load_complete,
    input  wire [31:0] loaded_timestamp,
    input  wire [41:0] loaded_savedtime,
    input  wire        rtc_save_loaded,
    input  wire [31:0] live_timestamp,
    input  wire [41:0] live_savedtime,
    input  wire        unloader_accept,
    input  wire [27:0] unloader_addr,
    output reg  [15:0] unloader_word
);

    reg initialized;
    reg [31:0] observed_timestamp;
    reg [41:0] observed_savedtime;
    reg [4:0] stable_samples;
    reg [31:0] qualified_timestamp;
    reg [41:0] qualified_savedtime;
    reg [31:0] snapshot_timestamp;
    reg [41:0] snapshot_savedtime;

    wire [23:0] unloader_offset = unloader_addr[23:0];
    wire live_matches_observed = live_timestamp == observed_timestamp &&
                                 live_savedtime == observed_savedtime;

    always @(posedge clk) begin
        if (!reset_n) begin
            initialized <= 1'b0;
            observed_timestamp <= 32'd0;
            observed_savedtime <= 42'd0;
            stable_samples <= 5'd0;
            qualified_timestamp <= 32'd0;
            qualified_savedtime <= 42'd0;
            snapshot_timestamp <= 32'd0;
            snapshot_savedtime <= 42'd0;
        end else begin
            if (load_complete && !initialized) begin
                initialized <= 1'b1;
                observed_timestamp <= loaded_timestamp;
                observed_savedtime <= loaded_savedtime;
                qualified_timestamp <= loaded_timestamp;
                qualified_savedtime <= loaded_savedtime;
                stable_samples <= 5'd0;
            end else if (initialized && rtc_save_loaded) begin
                if (!live_matches_observed) begin
                    observed_timestamp <= live_timestamp;
                    observed_savedtime <= live_savedtime;
                    stable_samples <= 5'd0;
                end else if (stable_samples < 5'd16) begin
                    stable_samples <= stable_samples + 5'd1;
                    if (stable_samples == 5'd15) begin
                        qualified_timestamp <= observed_timestamp;
                        qualified_savedtime <= observed_savedtime;
                    end
                end
            end

            if (unloader_accept && unloader_addr[27:24] == 4'h1 &&
                unloader_offset == 24'd0) begin
                snapshot_timestamp <= qualified_timestamp;
                snapshot_savedtime <= qualified_savedtime;
            end
        end
    end

    // Word zero is taken directly from the qualified pair on the snapshot
    // edge; later words come from the captured pair.
    always @(*) begin
        case (unloader_offset[3:1])
            3'd0: unloader_word = qualified_timestamp[15:0];
            3'd1: unloader_word = snapshot_timestamp[31:16];
            3'd2: unloader_word = snapshot_savedtime[15:0];
            3'd3: unloader_word = snapshot_savedtime[31:16];
            3'd4: unloader_word = {6'd0, snapshot_savedtime[41:32]};
            default: unloader_word = 16'd0;
        endcase
    end

endmodule

`default_nettype wire
