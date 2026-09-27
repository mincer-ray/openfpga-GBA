// RTC persistence loader for the dedicated Pocket sidecar and the legacy
// footer appended by older releases.  Accepted writes are stored first and
// validated only after the shared APF ingress completion fence has drained.

`timescale 1ns/1ps
`default_nettype none

module rtc_persistence (
    input  wire        clk,
    input  wire        reset_n,

    input  wire        loader_accept,
    input  wire [27:0] loader_addr,
    input  wire [15:0] loader_data,
    input  wire [23:0] save_size,
    input  wire        finalize_load,

    input  wire [31:0] host_epoch,
    input  wire [41:0] host_savedtime,

    output reg  [31:0] loaded_timestamp,
    output reg  [41:0] loaded_savedtime,
    output reg         load_complete,
    output reg         sidecar_record_valid,
    output reg         legacy_record_valid
);

    localparam [41:0] DEFAULT_SAVEDTIME =
        {8'h00, 5'h01, 6'h01, 3'd0, 6'h00, 7'h00, 7'h00};

    wire loader_is_save = loader_addr[27:24] == 4'h0;
    wire loader_is_rtc  = loader_addr[27:24] == 4'h1;
    wire [23:0] loader_offset = loader_addr[23:0];
    wire [23:0] legacy_offset = loader_offset - save_size;
    wire sidecar_accept = loader_accept && loader_is_rtc &&
        loader_offset < 24'd16 && !loader_offset[0];
    wire legacy_accept = loader_accept && loader_is_save &&
        loader_offset >= save_size && loader_offset < save_size + 24'd16 &&
        !legacy_offset[0];
    wire [2:0] accepted_index = legacy_accept ?
        legacy_offset[3:1] : loader_offset[3:1];

    // The seen masks, rather than RAM contents, define completeness. Repeated
    // writes intentionally overwrite the same word so validation observes the
    // final accepted value.
    reg [7:0] sidecar_seen;
    reg [7:0] legacy_seen;
    (* ramstyle = "M10K, no_rw_check" *) reg [15:0] record_ram [0:15];
    wire [3:0] record_write_addr = {legacy_accept, accepted_index};
    reg  [3:0] record_read_addr;
    reg [15:0] record_read_data;

    always @(posedge clk) begin
        if (reset_n && (sidecar_accept || legacy_accept))
            record_ram[record_write_addr] <= loader_data;
        record_read_data <= record_ram[record_read_addr];
    end

    function automatic bcd_time_valid(input [41:0] value);
        reg [1:0] leap_mod4;
        reg leap_year;
        reg year_valid;
        reg month_valid;
        reg month_is_february;
        reg month_has_30_days;
        reg day_valid;
        reg hms_valid;
    begin
        leap_mod4 = {value[38], 1'b0} + value[35:34];
        leap_year = leap_mod4 == 2'b00;
        year_valid = value[41:38] <= 4'd9 && value[37:34] <= 4'd9;
        month_valid = (!value[33] && value[32:29] >= 4'd1 &&
                       value[32:29] <= 4'd9) ||
                      (value[33] && value[32:29] <= 4'd2);
        month_is_february = !value[33] && value[32:29] == 4'd2;
        month_has_30_days = (!value[33] &&
                             (value[32:29] == 4'd4 ||
                              value[32:29] == 4'd6 ||
                              value[32:29] == 4'd9)) ||
                            (value[33] && value[32:29] == 4'd1);
        day_valid = value[26:23] <= 4'd9 && value[28:23] != 6'd0;
        if (month_is_february)
            day_valid = day_valid &&
                (value[28:27] < 2'd2 ||
                 (value[28:27] == 2'd2 &&
                  value[26:23] <= (leap_year ? 4'd9 : 4'd8)));
        else if (month_has_30_days)
            day_valid = day_valid &&
                (value[28:27] < 2'd3 ||
                 (value[28:27] == 2'd3 && value[26:23] == 4'd0));
        else
            day_valid = day_valid &&
                (value[28:27] < 2'd3 ||
                 (value[28:27] == 2'd3 && value[26:23] <= 4'd1));
        hms_valid = value[17:14] <= 4'd9 &&
                    (value[19:18] < 2'd2 ||
                     (value[19:18] == 2'd2 && value[17:14] <= 4'd3)) &&
                    value[13:11] <= 3'd5 && value[10:7] <= 4'd9 &&
                    value[6:4] <= 3'd5 && value[3:0] <= 4'd9;
        bcd_time_valid = year_valid && month_valid && day_valid &&
                         value[22:20] <= 3'd6 && hms_valid;
    end
    endfunction

    localparam [3:0] V_IDLE    = 4'd0;
    localparam [3:0] V_WAIT    = 4'd1;
    localparam [3:0] V_CAPTURE = 4'd2;
    localparam [3:0] V_CHECK   = 4'd3;
    localparam [3:0] V_SELECT  = 4'd4;
    localparam [3:0] V_DONE    = 4'd5;

    reg [3:0] state;
    reg bank;
    reg [2:0] word_index;
    reg [31:0] scratch_timestamp;
    reg [41:0] scratch_savedtime;
    reg scratch_format_error;

    wire scratch_timestamp_valid = scratch_timestamp != 32'd0 &&
                                   scratch_timestamp != 32'hFFFF_FFFF;
    wire scratch_valid = scratch_timestamp_valid &&
                         !scratch_format_error &&
                         bcd_time_valid(scratch_savedtime);
    wire host_savedtime_valid = bcd_time_valid(host_savedtime);

    always @(posedge clk) begin
        if (!reset_n) begin
            sidecar_seen <= 8'd0;
            legacy_seen <= 8'd0;
            sidecar_record_valid <= 1'b0;
            legacy_record_valid <= 1'b0;
            loaded_timestamp <= 32'd0;
            loaded_savedtime <= 42'd0;
            load_complete <= 1'b0;
            state <= V_IDLE;
            bank <= 1'b0;
            word_index <= 3'd0;
            record_read_addr <= 4'd0;
            scratch_timestamp <= 32'd0;
            scratch_savedtime <= 42'd0;
            scratch_format_error <= 1'b0;
        end else begin
            if (sidecar_accept)
                sidecar_seen[accepted_index] <= 1'b1;
            if (legacy_accept)
                legacy_seen[accepted_index] <= 1'b1;

            case (state)
                V_IDLE: if (finalize_load) begin
                    bank <= 1'b0;
                    word_index <= 3'd0;
                    record_read_addr <= 4'd0;
                    scratch_timestamp <= 32'd0;
                    scratch_savedtime <= 42'd0;
                    scratch_format_error <= 1'b0;
                    state <= V_WAIT;
                end

                V_WAIT: state <= V_CAPTURE;

                V_CAPTURE: begin
                    case (word_index)
                        3'd0: scratch_timestamp[15:0] <= record_read_data;
                        3'd1: scratch_timestamp[31:16] <= record_read_data;
                        3'd2: scratch_savedtime[15:0] <= record_read_data;
                        3'd3: scratch_savedtime[31:16] <= record_read_data;
                        3'd4: begin
                            scratch_savedtime[41:32] <= record_read_data[9:0];
                            if (record_read_data[15:10] != 6'd0)
                                scratch_format_error <= 1'b1;
                        end
                        default: if (record_read_data != 16'd0)
                            scratch_format_error <= 1'b1;
                    endcase
                    if (word_index == 3'd7)
                        state <= V_CHECK;
                    else begin
                        word_index <= word_index + 3'd1;
                        record_read_addr <= {bank, word_index + 3'd1};
                        state <= V_WAIT;
                    end
                end

                V_CHECK: begin
                    if (!bank) begin
                        sidecar_record_valid <= sidecar_seen == 8'hFF && scratch_valid;
                        // Keep the sidecar candidate directly in the selected
                        // output bank. A valid legacy candidate may overwrite
                        // it later; otherwise V_SELECT retains it or falls back.
                        loaded_timestamp <= scratch_timestamp;
                        loaded_savedtime <= scratch_savedtime;
                        bank <= 1'b1;
                        word_index <= 3'd0;
                        record_read_addr <= 4'h8;
                        scratch_timestamp <= 32'd0;
                        scratch_savedtime <= 42'd0;
                        scratch_format_error <= 1'b0;
                        state <= V_WAIT;
                    end else begin
                        legacy_record_valid <= legacy_seen == 8'hFF && scratch_valid;
                        state <= V_SELECT;
                    end
                end

                V_SELECT: begin
                    // A valid legacy footer wins deliberately: it is migration
                    // state written by an older core and may be newer than an
                    // already-existing sidecar.
                    if (legacy_record_valid) begin
                        loaded_timestamp <= scratch_timestamp;
                        loaded_savedtime <= scratch_savedtime;
                    end else if (!sidecar_record_valid) begin
                        loaded_timestamp <= host_epoch;
                        loaded_savedtime <= host_savedtime_valid ?
                                            host_savedtime : DEFAULT_SAVEDTIME;
                    end
                    load_complete <= 1'b1;
                    state <= V_DONE;
                end

                default: state <= V_DONE;
            endcase
        end
    end

endmodule

`default_nettype wire
