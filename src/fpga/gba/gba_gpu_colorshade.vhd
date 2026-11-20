library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all;   

entity gba_gpu_colorshade is
   port 
   (
      clk100               : in    std_logic;  
      
      shade_mode           : in    std_logic_vector(2 downto 0); -- 0 = off, 1..4 modes

      pixel_in_x           : in    integer range 0 to 239;
      pixel_in_2x          : in    integer range 0 to 479;
      pixel_in_y           : in    integer range 0 to 159;
      pixel_in_addr        : in    integer range 0 to 38399;
      pixel_in_data        : in    std_logic_vector(14 downto 0);  
      pixel_in_we          : in    std_logic := '0';
                  
      pixel_out_x          : out   integer range 0 to 239;
      pixel_out_2x         : out   integer range 0 to 479;
      pixel_out_y          : out   integer range 0 to 159;
      pixel_out_addr       : out   integer range 0 to 38399;
      pixel_out_data       : out   std_logic_vector(17 downto 0);  
      pixel_out_we         : out   std_logic := '0'
   );
end entity;

architecture arch of gba_gpu_colorshade is

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
   
   type t_shade_lookup_linear is array(0 to 31) of integer range 0 to 1023;
   signal shade_lookup_linear : t_shade_lookup_linear;
   
   type t_shade_mult is array(0 to 8) of integer range -1023 to 1023;
   signal shade_mult : t_shade_mult := (others => 0);
   
   -- Precompute the inverse-gamma thresholds into ROM. This is identical
   -- to the original strict-greater-than comparator search, but avoids a
   -- writable 64-entry table and three large comparator/multiplexer trees.
   type t_shade_lookup_rgb is array(0 to 4095) of integer range 0 to 63;
   function make_rgb_lookup return t_shade_lookup_rgb is
      variable result : t_shade_lookup_rgb := (others => 0);
   begin
      for mode in 0 to 3 loop
         for value in 0 to 1023 loop
            for level in 1 to 63 loop
               if value > shade_lookup_rgb_border_ram(mode * 64 + level) then
                  result(mode * 1024 + value) := level;
               end if;
            end loop;
         end loop;
      end loop;
      return result;
   end function;
   constant shade_lookup_rgb : t_shade_lookup_rgb := make_rgb_lookup;
   signal rgb_bank : integer range 0 to 3 := 0;

   -- shade loading
   signal shade_on       : std_logic := '0';
   signal shade_mode_act : std_logic_vector(2 downto 0) := "000";
   signal shade_mode_valid : std_logic_vector(2 downto 0);

   -- Keep bypass pixels aligned with the six-stage correction pipeline.
   -- Suppress correction while tables load and until that pipeline refills.
   type t_raw_pipe is array(1 to 5) of std_logic_vector(14 downto 0);
   signal raw_pipe : t_raw_pipe;
   signal shade_ready : std_logic_vector(1 to 5) := (others => '0');
   
   type tstate is
   (
      IDLE,
      READ_VALUE,
      WRITE_VALUE
   );
   signal state : tstate := IDLE;
   
   signal linear_count   : integer range 0 to 31;
   signal mult_count     : integer range 0 to 8;
   signal rgb_count      : integer range 0 to 63;
   
   signal linear_address : integer range 0 to 127;
   signal mult_address   : integer range 0 to 35;
   
   signal linear_value   : integer range 0 to 1023;
   signal mult_value     : integer range -1023 to 1023;
   
   -- shade processing
   signal pixel_1_x      : integer range 0 to 239;
   signal pixel_1_2x     : integer range 0 to 479;
   signal pixel_1_y      : integer range 0 to 159;
   signal pixel_1_addr   : integer range 0 to 38399;
   signal pixel_1_we     : std_logic := '0';
   signal color_linear_1 : integer range 0 to 1023;
   signal color_linear_2 : integer range 0 to 1023;
   signal color_linear_3 : integer range 0 to 1023;
   
   signal pixel_2_x      : integer range 0 to 239;
   signal pixel_2_2x     : integer range 0 to 479;
   signal pixel_2_y      : integer range 0 to 159;
   signal pixel_2_addr   : integer range 0 to 38399;
   signal pixel_2_we     : std_logic := '0';
   type t_shade_precalc is array(1 to 3, 1 to 3) of integer range -1048575 to 1048575;
   signal shade_precalc : t_shade_precalc := (others => (others => 0));
   
   signal pixel_3_x      : integer range 0 to 239;
   signal pixel_3_2x     : integer range 0 to 479;
   signal pixel_3_y      : integer range 0 to 159;
   signal pixel_3_addr   : integer range 0 to 38399;
   signal pixel_3_we     : std_logic := '0';
   type t_shade_linear is array(1 to 3) of integer range -2047 to 2047;
   signal shade_linear : t_shade_linear;
   
   signal pixel_4_x     : integer range 0 to 239;
   signal pixel_4_2x    : integer range 0 to 479;
   signal pixel_4_y     : integer range 0 to 159;
   signal pixel_4_addr  : integer range 0 to 38399;
   signal pixel_4_we    : std_logic := '0';
   type t_clip_linear is array(1 to 3) of integer range 0 to 1023;
   signal clip_linear : t_clip_linear;
   
   signal pixel_5_x     : integer range 0 to 239;
   signal pixel_5_2x    : integer range 0 to 479;
   signal pixel_5_y     : integer range 0 to 159;
   signal pixel_5_addr  : integer range 0 to 38399;
   signal pixel_5_we    : std_logic := '0';
   signal pixel_5_data : std_logic_vector(17 downto 0);
   

begin

   shade_mode_valid <= shade_mode when unsigned(shade_mode) <= 4 else "000";

   -- load shading
   process (clk100)
   begin
      if rising_edge(clk100) then

         shade_on <= '0';
         if (state = IDLE and shade_mode_act = shade_mode_valid and shade_mode_valid /= "000") then
            shade_on <= '1';
         end if;
         
         case state is
            
            when IDLE =>
               if (shade_mode_act /= shade_mode_valid) then
                  shade_mode_act <= shade_mode_valid;
                  if (shade_mode_valid /= "000") then
                     state          <= READ_VALUE;
                     linear_count   <= 0;
                     mult_count     <= 0;
                     rgb_count      <= 0;
                     linear_address <= (to_integer(unsigned(shade_mode_valid)) - 1) * 32;
                     mult_address   <= (to_integer(unsigned(shade_mode_valid)) - 1) * 9;
                     rgb_bank       <= to_integer(unsigned(shade_mode_valid)) - 1;
                  end if;
               end if;
         
            when READ_VALUE =>
               state        <= WRITE_VALUE;
               linear_value <= shade_lookup_linear_ram(linear_address);
               mult_value   <= shade_mult_ram(mult_address);
               
            when WRITE_VALUE =>
               shade_lookup_linear(linear_count)  <= linear_value;
               shade_mult(mult_count)             <= mult_value;
               if (rgb_count < 63) then
                  state <= READ_VALUE;
                  if (linear_count < 31) then
                     linear_count   <= linear_count + 1;
                     linear_address <= linear_address + 1;
                  end if;
                  if (mult_count < 8) then
                     mult_count   <= mult_count + 1;
                     mult_address <= mult_address + 1;
                  end if;
                  rgb_count   <= rgb_count + 1;
               else
                  state <= IDLE;
               end if;
         
         end case;
         
      end if;
   end process;

   -- process shading
   process (clk100)
   begin
      if rising_edge(clk100) then

         raw_pipe(1) <= pixel_in_data;
         shade_ready(1) <= shade_on;
         for i in 2 to 5 loop
            raw_pipe(i) <= raw_pipe(i - 1);
            shade_ready(i) <= shade_ready(i - 1);
         end loop;

         -- clock 1 - lookup linear color
         pixel_1_x    <= pixel_in_x;   
         pixel_1_2x   <= pixel_in_2x;   
         pixel_1_y    <= pixel_in_y;   
         pixel_1_addr <= pixel_in_addr;
         pixel_1_we   <= pixel_in_we;
         
         color_linear_1 <= shade_lookup_linear(to_integer(unsigned(pixel_in_data(14 downto 10))));
         color_linear_2 <= shade_lookup_linear(to_integer(unsigned(pixel_in_data( 9 downto  5))));
         color_linear_3 <= shade_lookup_linear(to_integer(unsigned(pixel_in_data( 4 downto  0))));
         
         -- clock 2 - precalc shades
         pixel_2_x    <= pixel_1_x;   
         pixel_2_2x   <= pixel_1_2x;   
         pixel_2_y    <= pixel_1_y;   
         pixel_2_addr <= pixel_1_addr;
         pixel_2_we   <= pixel_1_we;
         
         shade_precalc(1, 1) <= shade_mult(0) * color_linear_1;
         shade_precalc(1, 2) <= shade_mult(1) * color_linear_2;
         shade_precalc(1, 3) <= shade_mult(2) * color_linear_3;
         shade_precalc(2, 1) <= shade_mult(3) * color_linear_1;
         shade_precalc(2, 2) <= shade_mult(4) * color_linear_2;
         shade_precalc(2, 3) <= shade_mult(5) * color_linear_3;
         shade_precalc(3, 1) <= shade_mult(6) * color_linear_1;
         shade_precalc(3, 2) <= shade_mult(7) * color_linear_2;
         shade_precalc(3, 3) <= shade_mult(8) * color_linear_3;
         
         -- clock 3 - apply shading
         pixel_3_x    <= pixel_2_x;   
         pixel_3_2x   <= pixel_2_2x;   
         pixel_3_y    <= pixel_2_y;   
         pixel_3_addr <= pixel_2_addr;
         pixel_3_we   <= pixel_2_we;
         
         shade_linear(1) <=  (shade_precalc(1, 1) + shade_precalc(1, 2) + shade_precalc(1, 3)) / 1024;
         shade_linear(2) <=  (shade_precalc(2, 1) + shade_precalc(2, 2) + shade_precalc(2, 3)) / 1024;
         shade_linear(3) <=  (shade_precalc(3, 1) + shade_precalc(3, 2) + shade_precalc(3, 3)) / 1024;
         
         -- clock 4 - clip
         pixel_4_x    <= pixel_3_x;   
         pixel_4_2x   <= pixel_3_2x;   
         pixel_4_y    <= pixel_3_y;   
         pixel_4_addr <= pixel_3_addr;
         pixel_4_we   <= pixel_3_we;
         
         for c in 1 to 3 loop
            if (shade_linear(c) < 0) then 
               clip_linear(c) <= 0; 
            elsif (shade_linear(c) > 1023) then 
               clip_linear(c) <= 1023; 
            else 
               clip_linear(c) <= shade_linear(c); 
            end if;
         end loop;
                   
         -- clock 5 - synchronous inverse-gamma ROM reads
         pixel_5_x     <= pixel_4_x;
         pixel_5_2x    <= pixel_4_2x;
         pixel_5_y     <= pixel_4_y;
         pixel_5_addr  <= pixel_4_addr;
         pixel_5_we    <= pixel_4_we;
         for c in 1 to 3 loop
            pixel_5_data((3 - c) * 6 + 5 downto (3 - c) * 6) <=
               std_logic_vector(to_unsigned(shade_lookup_rgb(rgb_bank * 1024 + clip_linear(c)), 6));
         end loop;

         -- clock 6 - metadata has the same latency in every mode
         pixel_out_x    <= pixel_5_x;
         pixel_out_2x   <= pixel_5_2x;
         pixel_out_y    <= pixel_5_y;
         pixel_out_addr <= pixel_5_addr;
         pixel_out_we   <= pixel_5_we;

         if (shade_on = '1' and shade_ready(5) = '1') then
            pixel_out_data <= pixel_5_data;
         else
            pixel_out_data <= raw_pipe(5)(14 downto 10) & raw_pipe(5)(14) & raw_pipe(5)(9 downto 5) & raw_pipe(5)(9) & raw_pipe(5)(4 downto 0) & raw_pipe(5)(4);
         end if;
         
      end if;
   end process;
   

   
   
end architecture;





