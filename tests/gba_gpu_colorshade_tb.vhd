-- Numerical regression against the original MiSTer lookup tables and matrices.
-- From build_output/colorshade-test:
-- ghdl -a --std=08 ../../src/fpga/gba/gba_gpu_colorshade.vhd ../../tests/gba_gpu_colorshade_tb.vhd
-- ghdl -e --std=08 gba_gpu_colorshade_tb
-- ghdl -r --std=08 gba_gpu_colorshade_tb --assert-level=error
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity gba_gpu_colorshade_tb is end;
architecture test of gba_gpu_colorshade_tb is
   type t_shade_lookup_linear_ram is array(0 to 127) of integer range 0 to 1023;
   constant shade_lookup_linear_ram : t_shade_lookup_linear_ram :=
   (
      -- 2.2
        0,   1,   2,   6,  11,  17,  26,  36,
       49,  63,  79,  98, 118, 141, 166, 193,
      223, 255, 289, 325, 364, 405, 449, 495,
      544, 595, 649, 705, 763, 825, 888, 955,

      -- 1.6
        0,    4,   12,   23,   37,   53,   70,   90,
      111,  135,  159,  185,  213,  242,  273,  305,
      338,  372,  408,  445,  483,  522,  562,  604,
      646,  690,  735,  780,  827,  875,  924,  973,

      -- 1.6
        0,    4,   12,   23,   37,   53,   70,   90,
      111,  135,  159,  185,  213,  242,  273,  305,
      338,  372,  408,  445,  483,  522,  562,  604,
      646,  690,  735,  780,  827,  875,  924,  973,

      -- 1.4
        0,    8,   21,   37,   56,   76,   98,  122,
      147,  173,  201,  230,  259,  290,  322,  355,
      388,  422,  458,  494,  530,  568,  606,  645,
      685,  725,  766,  807,  849,  892,  936,  979
   );

   type t_shade_mult_ram is array(0 to 35) of integer range -1023 to 1023;
   constant shade_mult_ram : t_shade_mult_ram :=
   (
      -- shader gba-color
      865, 174, -015,
       92, 696,  236,
      164,  87,  773,

      -- shader gba-color
      865, 174, -015,
       92, 696,  236,
      164,  87,  773,

      -- shader nds-color
       850,  205, -031,
       107,  666,  251,
       107,  134,  783,

      -- shader vba-color (supposed to be done at 1.4 gamma not 1.6)
       758,  266,    0,
        82,  696,  246,
        82,  246,  696
   );

   type t_shade_lookup_rgb_border_ram is array(0 to 255) of integer range 0 to 1023;
   constant shade_lookup_rgb_border_ram : t_shade_lookup_rgb_border_ram :=
   (
      -- 2.2
        0,   1,   2,   3,   4,   5,   6,   8,
       11,  14,  17,  21,  26,  31,  36,  42,
       49,  55,  63,  71,  79,  88,  98, 108,
      118, 129, 141, 153, 166, 179, 193, 208,
      223, 238, 255, 271, 289, 307, 325, 344,
      364, 384, 405, 427, 449, 472, 495, 519,
      544, 569, 595, 621, 649, 676, 705, 734,
      763, 794, 825, 856, 888, 921, 955, 989,

      -- 1.6
        0,    1,    4,    8,   12,   17,   23,   30,
       37,   44,   53,   61,   70,   80,   90,  100,
      111,  123,  135,  147,  159,  172,  185,  199,
      213,  228,  242,  257,  273,  289,  305,  321,
      338,  355,  372,  390,  408,  426,  445,  464,
      483,  502,  522,  542,  562,  583,  604,  625,
      646,  668,  690,  712,  735,  757,  780,  804,
      827,  851,  875,  899,  924,  948,  973,  999,

      -- 1.6
        0,    1,    4,    8,   12,   17,   23,   30,
       37,   44,   53,   61,   70,   80,   90,  100,
      111,  123,  135,  147,  159,  172,  185,  199,
      213,  228,  242,  257,  273,  289,  305,  321,
      338,  355,  372,  390,  408,  426,  445,  464,
      483,  502,  522,  542,  562,  583,  604,  625,
      646,  668,  690,  712,  735,  757,  780,  804,
      827,  851,  875,  899,  924,  948,  973,  999,

		-- 1.4
        0,    3,    8,   14,   21,   29,   37,   46,
       56,   66,   76,   87,   98,  110,  122,  134,
      147,  160,  173,  187,  201,  215,  230,  244,
      259,  275,  290,  306,  322,  338,  355,  371,
      388,  405,  422,  440,  458,  475,  494,  512,
      530,  549,  568,  587,  606,  625,  645,  665,
      685,  705,  725,  745,  766,  786,  807,  828,
      849,  871,  892,  914,  936,  957,  979,  1002
   );


   signal clk : std_logic := '0';
   signal mode : std_logic_vector(2 downto 0) := "000";
   signal input_data : std_logic_vector(14 downto 0) := (others => '0');
   signal input_we : std_logic := '0';
   signal input_addr, output_addr : integer range 0 to 38399 := 0;
   signal input_x, output_x : integer range 0 to 239 := 0;
   signal input_y, output_y : integer range 0 to 159 := 0;
   signal input_2x, output_2x : integer range 0 to 479 := 0;
   signal output_data : std_logic_vector(17 downto 0);
   signal output_we : std_logic;

   function expected(pixel, preset : integer) return integer is
      type triple is array(0 to 2) of integer;
      variable rgb, linear_rgb : triple;
      variable mixed, level, result : integer := 0;
   begin
      rgb := (pixel / 1024, (pixel / 32) mod 32, pixel mod 32);
      for channel in 0 to 2 loop
         if preset = 0 or preset > 4 then
            level := rgb(channel) * 2 + rgb(channel) / 16;
         else
            for c in 0 to 2 loop
               linear_rgb(c) := shade_lookup_linear_ram((preset - 1) * 32 + rgb(c));
            end loop;
            mixed := 0;
            for c in 0 to 2 loop
               mixed := mixed + linear_rgb(c) * shade_mult_ram((preset - 1) * 9 + channel * 3 + c);
            end loop;
            mixed := mixed / 1024;
            if mixed < 0 then mixed := 0; end if;
            if mixed > 1023 then mixed := 1023; end if;
            level := 0;
            for threshold in 1 to 63 loop
               if mixed > shade_lookup_rgb_border_ram((preset - 1) * 64 + threshold) then
                  level := threshold;
               end if;
            end loop;
         end if;
         result := result * 64 + level;
      end loop;
      return result;
   end;
begin
   clk <= not clk after 5 ns;
   dut : entity work.gba_gpu_colorshade
   port map (
      clk100 => clk, shade_mode => mode,
      pixel_in_x => input_x, pixel_in_2x => input_2x,
      pixel_in_y => input_y, pixel_in_addr => input_addr,
      pixel_in_data => input_data, pixel_in_we => input_we,
      pixel_out_x => output_x, pixel_out_2x => output_2x,
      pixel_out_y => output_y, pixel_out_addr => output_addr,
      pixel_out_data => output_data, pixel_out_we => output_we
   );

   stimulus : process
      type int_pipe is array(0 to 5) of integer;
      variable addr_pipe, color_pipe, we_pipe : int_pipe := (others => -1);
      variable sample_count : integer := 0;
      procedure tick(pixel, check_mode : integer; write_pixel : boolean := true) is
         variable addr : integer;
      begin
         wait until falling_edge(clk);
         addr := sample_count mod 38400;
         input_addr <= addr;
         input_x <= addr mod 240;
         input_y <= addr / 240;
         input_2x <= (addr mod 240) * 2;
         input_data <= std_logic_vector(to_unsigned(pixel, 15));
         input_we <= '0';
         if write_pixel then input_we <= '1'; end if;
         for i in 5 downto 1 loop
            addr_pipe(i) := addr_pipe(i - 1);
            color_pipe(i) := color_pipe(i - 1);
            we_pipe(i) := we_pipe(i - 1);
         end loop;
         addr_pipe(0) := addr;
         color_pipe(0) := -1;
         if check_mode >= 0 then color_pipe(0) := expected(pixel, check_mode); end if;
         we_pipe(0) := 0;
         if write_pixel then we_pipe(0) := 1; end if;
         wait until rising_edge(clk);
         wait for 1 ns;
         if sample_count >= 5 then
            assert output_addr = addr_pipe(5) report "Pixel address lost or duplicated" severity failure;
            assert output_x = addr_pipe(5) mod 240 and output_y = addr_pipe(5) / 240
               and output_2x = (addr_pipe(5) mod 240) * 2 report "Coordinates misaligned" severity failure;
            assert (output_we = '1') = (we_pipe(5) = 1) report "Write enable misaligned" severity failure;
            if color_pipe(5) >= 0 then
               assert to_integer(unsigned(output_data)) = color_pipe(5)
                  report "Color mismatch at sample " & integer'image(sample_count) &
                         " mode " & integer'image(check_mode) severity failure;
            end if;
         end if;
         sample_count := sample_count + 1;
      end;
      procedure settle(preset : integer) is
      begin
         -- Drain previously checked pixels before changing the mode.
         for i in 0 to 5 loop tick(32767, -1); end loop;
         mode <= std_logic_vector(to_unsigned(preset, 3));
         for i in 0 to 149 loop
            if i >= 10 and i <= 120 then
               tick((i * 997) mod 32768, 0, i mod 3 /= 0);
            else
               tick((i * 997) mod 32768, -1, i mod 3 /= 0);
            end if;
         end loop;
      end;
   begin
      for preset in 0 to 7 loop
         settle(preset);
         for pixel in 0 to 32767 loop
            tick(pixel, preset, pixel mod 7 /= 0);
         end loop;
         report "All 32768 colors passed for mode " & integer'image(preset);
      end loop;
      -- Change settings faster than the table loader can finish.
      for i in 0 to 5 loop tick(0, -1); end loop;
      for i in 0 to 199 loop
         mode <= std_logic_vector(to_unsigned(i mod 8, 3));
         tick((i * 997) mod 32768, -1, i mod 3 /= 0);
      end loop;
      -- Let the final interrupted load finish before testing convergence.
      for i in 0 to 299 loop tick(0, -1); end loop;
      settle(2);
      for pixel in 0 to 32767 loop tick(pixel, 2); end loop;
      for i in 0 to 5 loop tick(0, 2, false); end loop;
      report "PASS: all modes, invalid settings, bubbles, and rapid mode changes";
      stop;
      wait;
   end process;
end;
