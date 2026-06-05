library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all;   

entity gba_drawer_mode0 is
   port 
   (
      clk100               : in  std_logic;                     
                           
      drawline             : in  std_logic;
      busy                 : out std_logic := '0';
      
      lockspeed            : in  std_logic;
      pixelpos             : in  integer range 0 to 511;
      
      ypos                 : in  integer range 0 to 159;
      ypos_mosaic          : in  integer range 0 to 159;
      mapbase              : in  unsigned(4 downto 0);
      tilebase             : in  unsigned(1 downto 0);
      hicolor              : in  std_logic;
      mosaic               : in  std_logic;
      Mosaic_H_Size        : in  unsigned(3 downto 0);
      screensize           : in  unsigned(1 downto 0);
      scrollX              : in  unsigned(8 downto 0);
      scrollY              : in  unsigned(8 downto 0);
      
      pixel_we             : out std_logic := '0';
      pixeldata            : buffer std_logic_vector(15 downto 0) := (others => '0');
      pixel_x              : out integer range 0 to 239;
      
      PALETTE_Drawer_addr  : out integer range 0 to 127;
      PALETTE_Drawer_data  : in  std_logic_vector(31 downto 0);
      PALETTE_Drawer_valid : in  std_logic;
      
      VRAM_Drawer_addr     : out integer range 0 to 16383;
      VRAM_Drawer_data     : in  std_logic_vector(31 downto 0);
      VRAM_Drawer_valid    : in  std_logic
   );
end entity;

architecture arch of gba_drawer_mode0 is
   
   type tVRAMState is
   (
      IDLE,
      CALCBASE,
      CALCADDR1,
      CALCADDR2,
      CALCADDR3,
      WAITREAD_TILE,
      CALCCOLORADDR,
      WAITREAD_COLOR,
      FETCHDONE
   );
   signal vramfetch    : tVRAMState := IDLE;
   
   type tPALETTEState is
   (
      IDLE,
      STARTREAD,
      WAITREAD
   );
   signal palettefetch : tPALETTEState := IDLE;
  
   signal VRAM_byteaddr        : unsigned(16 downto 0) := (others => '0'); 
   signal vram_readwait        : integer range 0 to 2;
                               
   signal PALETTE_byteaddr     : std_logic_vector(8 downto 0) := (others => '0');
   signal palette_readwait     : integer range 0 to 2;
                               
   signal mapbaseaddr          : integer;
   signal tilebaseaddr         : integer;
                               
   signal x_cnt                : integer range 0 to 239;
   signal y_scrolled           : integer range 0 to 1023; 
   signal offset_y             : integer range 0 to 1023; 
   signal scroll_x_mod         : integer range 256 to 512; 
   signal scroll_y_mod         : integer range 256 to 512; 
                               
   signal x_scrolled           : integer range 0 to 1023;
   signal scrollX_reg          : unsigned(8 downto 0) := (others => '0');
   signal tileindex            : integer range 0 to 4095;
                               
   signal tileinfo             : std_logic_vector(15 downto 0) := (others => '0');
   signal pixeladdr_base       : integer range 0 to 524287;
                               
   signal colordata            : std_logic_vector(7 downto 0) := (others => '0');
   signal VRAM_lastcolor_addr  : unsigned(14 downto 0) := (others => '0');
   signal VRAM_lastcolor_data  : std_logic_vector(31 downto 0) := (others => '0');
   signal VRAM_lastcolor_valid : std_logic := '0';
   
   signal mosaik_cnt           : integer range 0 to 15 := 0;
   
begin 

   mapbaseaddr  <= to_integer(shift_left(resize(mapbase, 16), 11));
   tilebaseaddr <= to_integer(shift_left(resize(tilebase, 16), 14));
   
   VRAM_Drawer_addr <= to_integer(VRAM_byteaddr(15 downto 2));
   PALETTE_Drawer_addr <= to_integer(unsigned(PALETTE_byteaddr(8 downto 2)));
  
   -- vramfetch
   process (clk100)
    variable tileindex_var  : integer range 0 to 4095;
    variable x_scrolled_var : integer range 0 to 1023;
    variable pixeladdr      : integer range 0 to 524287;
    variable scroll_sum_u   : unsigned(9 downto 0);
    variable x_scrolled_u   : unsigned(9 downto 0);
    variable y_scrolled_u   : unsigned(9 downto 0);
    variable x_mod256       : integer range 0 to 255;
    variable x_tile_col     : integer range 0 to 31;
    variable pixel_x_byte   : integer range 0 to 7;
    variable y_tile_row     : unsigned(2 downto 0);
   begin
      if rising_edge(clk100) then
      
         case (vramfetch) is
         
            when IDLE =>
               if (drawline = '1') then
                  busy            <= '1';
                  vramfetch       <= CALCBASE;
                  if (mosaic = '1') then
                     y_scrolled <= ypos_mosaic + to_integer(scrollY);
                  else
                     y_scrolled <= ypos + to_integer(scrollY);
                  end if;
                  offset_y     <= 32;
                  scroll_x_mod <= 256;
                  scroll_y_mod <= 256;
                  case (to_integer(screensize)) is
                     when 1 => scroll_x_mod <= 512;
                     when 2 => scroll_y_mod <= 512;
                     when 3 => scroll_x_mod <= 512; scroll_y_mod <= 512;
                     when others => null;
                  end case;
                  x_cnt     <= 0;
                  scrollX_reg <= scrollX;
                  VRAM_lastcolor_valid <= '0'; -- invalidate fetch cache
               elsif (palettefetch = IDLE) then
                  busy         <= '0';
               end if;
               
            when CALCBASE =>
               vramfetch    <= CALCADDR1;
               y_scrolled_u := to_unsigned(y_scrolled, 10);
               if (scroll_y_mod = 256) then
                  y_scrolled <= to_integer(y_scrolled_u(7 downto 0));
               else
                  y_scrolled <= to_integer(y_scrolled_u(8 downto 0));
               end if;
               offset_y <= to_integer(shift_left(resize(y_scrolled_u(7 downto 3), 10), 5));
               
            when CALCADDR1 =>
               if (pixelpos >= x_cnt or lockspeed = '0') then
                  vramfetch    <= CALCADDR2;
                  scroll_sum_u := to_unsigned(x_cnt, 10) + resize(scrollX_reg, 10);
                  if (scroll_x_mod = 256) then
                     x_scrolled <= to_integer(scroll_sum_u(7 downto 0));
                  else
                     x_scrolled <= to_integer(scroll_sum_u(8 downto 0));
                  end if;
               end if;
   
            when CALCADDR2 =>
               tileindex_var  := 0;
               x_scrolled_var := x_scrolled;
               x_scrolled_u   := to_unsigned(x_scrolled, 10);
               x_mod256       := to_integer(x_scrolled_u(7 downto 0));
               if (x_scrolled >= 256 or (y_scrolled >= 256 and to_integer(screensize) = 2)) then
                  tileindex_var  := tileindex_var + 1024;
                  x_scrolled_var := x_mod256;
                  x_scrolled     <= x_mod256;
               end if;
               if (y_scrolled >= 256 and to_integer(screensize) = 3) then
                  tileindex_var := tileindex_var + 2048;
               end if;
               x_scrolled_u := to_unsigned(x_scrolled_var, 10);
               x_tile_col   := to_integer(x_scrolled_u(7 downto 3));
               tileindex_var := tileindex_var + offset_y + x_tile_col;
               tileindex     <= tileindex_var;
               vramfetch     <= CALCADDR3;

            when CALCADDR3 =>
               VRAM_byteaddr <= to_unsigned(mapbaseaddr, VRAM_byteaddr'length) + shift_left(to_unsigned(tileindex, VRAM_byteaddr'length), 1);
               vramfetch     <= WAITREAD_TILE;
               vram_readwait <= 2;
            
            when WAITREAD_TILE =>
               if (vram_readwait > 0) then
                  vram_readwait <= vram_readwait - 1;
               elsif (VRAM_Drawer_valid = '1') then
                  if (VRAM_byteaddr(1) = '1') then
                     tileinfo <= VRAM_Drawer_data(31 downto 16);
                     if (hicolor = '0') then
                        pixeladdr_base <= tilebaseaddr + to_integer(shift_left(resize(unsigned(VRAM_Drawer_data(25 downto 16)), 19), 5));
                     else
                        pixeladdr_base <= tilebaseaddr + to_integer(shift_left(resize(unsigned(VRAM_Drawer_data(25 downto 16)), 19), 6));
                     end if;
                  else
                     tileinfo <= VRAM_Drawer_data(15 downto 0);
                     if (hicolor = '0') then
                        pixeladdr_base <= tilebaseaddr + to_integer(shift_left(resize(unsigned(VRAM_Drawer_data(9 downto 0)), 19), 5));
                     else
                        pixeladdr_base <= tilebaseaddr + to_integer(shift_left(resize(unsigned(VRAM_Drawer_data(9 downto 0)), 19), 6));
                     end if;
                  end if;
                  vramfetch  <= CALCCOLORADDR;
               end if;
                
            when CALCCOLORADDR => 
               vramfetch    <= WAITREAD_COLOR;
               x_scrolled_u := to_unsigned(x_scrolled, 10);
               y_scrolled_u := to_unsigned(y_scrolled, 10);

               if (hicolor = '0') then
                  pixel_x_byte := to_integer(x_scrolled_u(2 downto 1));
               else
                  pixel_x_byte := to_integer(x_scrolled_u(2 downto 0));
               end if;

               if (tileinfo(10) = '1') then -- hoz flip
                  if (hicolor = '0') then
                     pixeladdr := pixeladdr_base + (3 - pixel_x_byte);
                  else
                     pixeladdr := pixeladdr_base + (7 - pixel_x_byte);
                  end if;
               else
                  pixeladdr := pixeladdr_base + pixel_x_byte;
               end if;

               if (tileinfo(11) = '1') then -- vert flip
                  y_tile_row := to_unsigned(7, 3) - y_scrolled_u(2 downto 0);
               else
                  y_tile_row := y_scrolled_u(2 downto 0);
               end if;
               if (hicolor = '0') then
                  pixeladdr := pixeladdr + to_integer(shift_left(resize(y_tile_row, 6), 2));
               else
                  pixeladdr := pixeladdr + to_integer(shift_left(resize(y_tile_row, 6), 3));
               end if;

               VRAM_byteaddr <= to_unsigned(pixeladdr, VRAM_byteaddr'length);
               vramfetch     <= WAITREAD_COLOR;
               vram_readwait <= 2;
               
            when WAITREAD_COLOR =>
               if (VRAM_lastcolor_valid = '1' and VRAM_lastcolor_addr = VRAM_byteaddr(VRAM_byteaddr'left downto 2)) then
                  case (VRAM_byteaddr(1 downto 0)) is
                     when "00" => colordata <= VRAM_lastcolor_data(7  downto 0);
                     when "01" => colordata <= VRAM_lastcolor_data(15 downto 8);
                     when "10" => colordata <= VRAM_lastcolor_data(23 downto 16);
                     when "11" => colordata <= VRAM_lastcolor_data(31 downto 24);
                     when others => null;
                  end case;
                  vramfetch  <= FETCHDONE;
               elsif (vram_readwait > 0) then
                  vram_readwait <= vram_readwait - 1;
               elsif (VRAM_Drawer_valid = '1') then
                  VRAM_lastcolor_addr  <= VRAM_byteaddr(VRAM_byteaddr'left downto 2);
                  VRAM_lastcolor_data  <= VRAM_Drawer_data;
                  VRAM_lastcolor_valid <= '1';
                  case (VRAM_byteaddr(1 downto 0)) is
                     when "00" => colordata <= VRAM_Drawer_data(7  downto 0);
                     when "01" => colordata <= VRAM_Drawer_data(15 downto 8);
                     when "10" => colordata <= VRAM_Drawer_data(23 downto 16);
                     when "11" => colordata <= VRAM_Drawer_data(31 downto 24);
                     when others => null;
                  end case;
                  vramfetch  <= FETCHDONE;
               end if;
            
            when FETCHDONE =>
               if (palettefetch = IDLE) then
                  if (x_cnt < 239) then
                     vramfetch <= CALCADDR1;
                     x_cnt     <= x_cnt + 1;
                  else
                     vramfetch <= IDLE;
                  end if;
               end if;
         
         end case;
      
      end if;
   end process;
   
   -- palette
   process (clk100)
      variable x_scrolled_u : unsigned(9 downto 0);
   begin
      if rising_edge(clk100) then
      
         pixel_we      <= '0';
      
         if (drawline = '1') then
            mosaik_cnt    <= 15;  -- first pixel must fetch new data
            pixeldata(15) <= '1';
         end if;
      
         case (palettefetch) is
         
            when IDLE =>
               if (vramfetch = FETCHDONE) then
               
                  pixel_x          <= x_cnt;
               
                  if (mosaik_cnt < Mosaic_H_Size and mosaic = '1') then
                     mosaik_cnt <= mosaik_cnt + 1;
                     pixel_we   <= not pixeldata(15);
                  else
                     mosaik_cnt       <= 0;
                     
                     palettefetch     <= STARTREAD; 
                     if (hicolor = '0') then
                        x_scrolled_u := to_unsigned(x_scrolled, 10);
                        if ((tileinfo(10) = '1' and x_scrolled_u(0) = '0') or (tileinfo(10) = '0' and x_scrolled_u(0) = '1')) then
                           PALETTE_byteaddr <= tileinfo(15 downto 12) & colordata(7 downto 4) & '0';
                           if (colordata(7 downto 4) = x"0") then -- transparent
                              palettefetch  <= IDLE;
                              pixeldata(15) <= '1';
                           end if;
                        else
                           PALETTE_byteaddr <= tileinfo(15 downto 12) & colordata(3 downto 0) & '0';
                           if (colordata(3 downto 0) = x"0") then -- transparent
                              palettefetch  <= IDLE;
                              pixeldata(15) <= '1';
                           end if;
                        end if;
                     else
                        PALETTE_byteaddr <= colordata & '0';
                        if (colordata = x"00") then -- transparent
                           palettefetch  <= IDLE;
                           pixeldata(15) <= '1';
                        end if;
                     end if;
                  end if;
               end if;
               
            when STARTREAD => 
               palettefetch     <= WAITREAD;
               palette_readwait <= 2;
            
            when WAITREAD =>
               if (palette_readwait > 0) then
                  palette_readwait <= palette_readwait - 1;
               elsif (PALETTE_Drawer_valid = '1') then
                  palettefetch  <= IDLE;
                  pixel_we      <= '1';
                  if (PALETTE_byteaddr(1) = '1') then
                     pixeldata <= '0' & PALETTE_Drawer_data(30 downto 16);
                  else
                     pixeldata <= '0' & PALETTE_Drawer_data(14 downto 0);
                  end if;
               end if;

         
         end case;
      
      end if;
   end process;

end architecture;




