//------------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileType: SOURCE
// SPDX-FileCopyrightText: (c) 2023, OpenGateware authors and contributors
//------------------------------------------------------------------------------
//
// Audio Filters
//
// Copyright (c) 2023, Marcus Andrade <marcus@opengateware.org>
// Copyright (c) 2020, Alexey Melnikov <pour.garbage@gmail.com>
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
// General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <http://www.gnu.org/licenses/>.
//
//------------------------------------------------------------------------------

`default_nettype none

module audio_filters
    #(
         parameter CLK_RATE = 12288000
     ) (
         input  wire        clk,
         input  wire        reset,

         input  wire  [4:0] att,

         input  wire        is_signed,
         input  wire  [1:0] mix,

         input  wire [15:0] core_l,
         input  wire [15:0] core_r,

         // Audio Output
         output wire [15:0] audio_l,
         output wire [15:0] audio_r
     );

    reg sample_rate = 0; //0 - 48KHz, 1 - 96KHz

    localparam integer SAMPLE_DIV_48 = CLK_RATE / 48000; // 256 @ 12.288MHz
    localparam integer SAMPLE_DIV_96 = CLK_RATE / 96000; // 128 @ 12.288MHz

    reg [8:0] sample_div = 0;
    wire [8:0] sample_reload = sample_rate ? (SAMPLE_DIV_96 - 1) : (SAMPLE_DIV_48 - 1);

    reg sample_ce;
    always @(posedge clk, posedge reset) begin
        if (reset) begin
            sample_div <= 0;
            sample_ce  <= 1'b0;
        end else if (sample_div == 0) begin
            sample_div <= sample_reload;
            sample_ce  <= 1'b1;
        end else begin
            sample_div <= sample_div - 1'b1;
            sample_ce  <= 1'b0;
        end
    end

    // CDC: 2-register stability check for clock domain crossing
    reg [15:0] cl,cr;
    always @(posedge clk) begin
        reg [15:0] cl1, cl2;
        reg [15:0] cr1, cr2;

        cl1 <= core_l;
        cl2 <= cl1;
        if(cl2 == cl1)
            cl <= cl2;

        cr1 <= core_r;
        cr2 <= cr1;
        if(cr2 == cr1)
            cr <= cr2;
    end

    // Convert unsigned to signed if needed
    wire [15:0] cl_signed = {~is_signed ^ cl[15], cl[14:0]};
    wire [15:0] cr_signed = {~is_signed ^ cr[15], cr[14:0]};

    // Startup mute to avoid pops
    reg a_en = 0;
    always @(posedge clk, posedge reset) begin
        reg [14:0] dly;

        if(reset) begin
            dly   <= 0;
            a_en  <= 0;
        end
        else if(sample_ce) begin
            if(!dly[13+sample_rate])
                dly <= dly + 1'd1;
            else
                a_en <= 1;
        end
    end

    // DC blocker (removes DC offset, prevents speaker pops)
    wire [15:0] adl;
    dc_blocker dcb_l
               (
                   .clk         ( clk         ),
                   .ce          ( sample_ce   ),
                   .sample_rate ( sample_rate ),
                   .mute        ( ~a_en       ),
                   .din         ( cl_signed   ),
                   .dout        ( adl         )
               );

    wire [15:0] adr;
    dc_blocker dcb_r
               (
                   .clk         ( clk         ),
                   .ce          ( sample_ce   ),
                   .sample_rate ( sample_rate ),
                   .mute        ( ~a_en       ),
                   .din         ( cr_signed   ),
                   .dout        ( adr         )
               );

    wire [15:0] audio_l_pre;
    wire [15:0] audio_l_mix;
    audio_mix audmix_l
              (
                  .clk         ( clk         ),
                  .ce          ( sample_ce   ),
                  .att         ( att         ),
                  .mix         ( mix         ),

                  .core_audio  ( adl         ),
                  .pre_in      ( audio_r_pre ),

                  .pre_out     ( audio_l_pre ),
                  .out         ( audio_l_mix )
              );

    wire [15:0] audio_r_pre;
    wire [15:0] audio_r_mix;
    audio_mix audmix_r
              (
                  .clk         ( clk         ),
                  .ce          ( sample_ce   ),
                  .att         ( att         ),
                  .mix         ( mix         ),

                  .core_audio  ( adr         ),
                  .pre_in      ( audio_l_pre ),

                  .pre_out     ( audio_r_pre ),
                  .out         ( audio_r_mix )
              );

    assign audio_l = audio_l_mix;
    assign audio_r = audio_r_mix;

endmodule
