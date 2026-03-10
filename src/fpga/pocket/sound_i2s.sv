// MIT License

// Copyright (c) 2022 Adam Gastineau

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
////////////////////////////////////////////////////////////////////////////////

// A very simple audio i2s bridge to APF, based on their example code
module sound_i2s #(
    parameter CHANNEL_WIDTH = 16,
    parameter SIGNED_INPUT  = 0
) (
    input wire audio_sclk,

    // Left and right audio channels
    input wire [CHANNEL_WIDTH - 1:0] audio_l,
    input wire [CHANNEL_WIDTH - 1:0] audio_r,

    output reg audio_lrck,
    output reg audio_dac
);
  //
  // audio i2s generator
  //

  reg audgen_nextsamp;

  // shift out audio data as I2S
  // 32 total bits per channel, but only 16 active bits at the start and then 16 dummy bits
  //
  // synchronize audio samples coming from the core

  localparam CHANNEL_LEFT_HIGH = 16;
  localparam CHANNEL_RIGHT_HIGH = 16 + CHANNEL_LEFT_HIGH;

  // Width of channel with signed component
  localparam SIGNED_CHANNEL_WIDTH = SIGNED_INPUT ? CHANNEL_WIDTH : CHANNEL_WIDTH + 1;

  // Can center unsigned in signed interval by flipping high bit
  wire [CHANNEL_WIDTH - 1:0] sign_converted_audio_l = {
    audio_l[CHANNEL_WIDTH-1:CHANNEL_WIDTH-1], audio_l[CHANNEL_WIDTH-2:0]
  };

  wire [CHANNEL_WIDTH - 1:0] sign_converted_audio_r = {
    audio_r[CHANNEL_WIDTH-1:CHANNEL_WIDTH-1], audio_r[CHANNEL_WIDTH-2:0]
  };

  wire [31:0] audgen_sampdata;

  assign audgen_sampdata[CHANNEL_LEFT_HIGH-1:CHANNEL_LEFT_HIGH-CHANNEL_WIDTH]   = SIGNED_INPUT ? audio_l : sign_converted_audio_l;
  assign audgen_sampdata[CHANNEL_RIGHT_HIGH-1:CHANNEL_RIGHT_HIGH-CHANNEL_WIDTH] = SIGNED_INPUT ? audio_r : sign_converted_audio_r;

  generate
    if (15 - SIGNED_CHANNEL_WIDTH > 0) begin
      assign audgen_sampdata[31-SIGNED_CHANNEL_WIDTH:16] = 0;
      assign audgen_sampdata[15-SIGNED_CHANNEL_WIDTH:0]  = 0;
    end
  endgenerate

  // sync_fifo #(
  //     .WIDTH(32)
  // ) sync_fifo (
  //     .clk_write(clk_audio),
  //     .clk_read (audio_sclk),

  //     .write_en(write_en),
  //     .data(audgen_sampdata),
  //     .data_s(audgen_sampdata_s)
  // );

  // reg write_en = 0;
  // reg [CHANNEL_WIDTH - 1:0] prev_left;
  // reg [CHANNEL_WIDTH - 1:0] prev_right;

  // // Mark write when necessary
  // always @(posedge clk_audio) begin
  //   prev_left  <= audio_l;
  //   prev_right <= audio_r;

  //   write_en   <= 0;

  //   if (audio_l != prev_left || audio_r != prev_right) begin
  //     write_en <= 1;
  //   end
  // end

  // wire [31:0] audgen_sampdata_s;

  reg [31:0] audgen_sampshift;
  reg [ 4:0] audio_lrck_cnt;
  always @(posedge audio_sclk) begin
    // output the next bit
    audio_dac <= audgen_sampshift[31];

    // 48khz * 64
    audio_lrck_cnt <= audio_lrck_cnt + 1'b1;
    if (audio_lrck_cnt == 31) begin
      // switch channels
      audio_lrck <= ~audio_lrck;

      // Reload sample shifter
      if (~audio_lrck) begin
        audgen_sampshift <= audgen_sampdata;
      end
    end else if (audio_lrck_cnt < 16) begin
      // only shift for 16 clocks per channel
      audgen_sampshift <= {audgen_sampshift[30:0], 1'b0};
    end
  end

  initial begin
    // Verify parameters
    if (CHANNEL_WIDTH > 16) begin
      $error("CHANNEL_WIDTH must be <= 16. Received %d", CHANNEL_WIDTH);
    end

    if (SIGNED_INPUT != 0 && SIGNED_INPUT != 1) begin
      $error("SIGNED_INPUT must be 0 or 1. Received %d", SIGNED_INPUT);
    end
  end
endmodule
