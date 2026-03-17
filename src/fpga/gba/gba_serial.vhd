library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;
use work.pReg_gba_serial.all;

entity gba_serial is
   port
   (
      clk100            : in    std_logic;
      gb_bus            : inout proc_bus_gb_type := ((others => 'Z'), (others => 'Z'), (others => 'Z'), 'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');

      new_cycles        : in  unsigned(7 downto 0);
      new_cycles_valid  : in  std_logic;
      new_exact_cycle   : in  std_logic;

      IRP_Serial        : out std_logic := '0';

      -- Normal mode I/O (SO/SI/SCK pins)
      serial_data_out   : out std_logic := '1';  -- SO pin
      serial_data_in    : in  std_logic;          -- SI pin
      serial_clk_out    : out std_logic := '1';   -- SCK output (when master)
      serial_clk_in     : in  std_logic;          -- SCK input (when slave)
      serial_int_clock  : out std_logic := '0';   -- 1 = internal clock (SCK is output)

      -- Multi-player mode I/O (SD/SC pins)
      serial_sd_out     : out std_logic := '1';   -- SD data output (UART)
      serial_sd_in      : in  std_logic;          -- SD data input (UART)
      serial_sd_dir     : out std_logic := '0';   -- 0=input, 1=output
      serial_sc_out     : out std_logic := '1';   -- SC handshake output
      serial_sc_in      : in  std_logic;          -- SC handshake input
      serial_sc_dir     : out std_logic := '0';   -- 0=input, 1=output

      -- Link role from interact menu (active in multi-player mode)
      link_is_parent    : in  std_logic
   );
end entity;

architecture arch of gba_serial is

   signal REG_SIODATA32   : std_logic_vector(SIODATA32  .upper downto SIODATA32  .lower) := (others => '0');
   signal REG_SIOMULTI2   : std_logic_vector(SIOMULTI2  .upper downto SIOMULTI2  .lower) := (others => '0');
   signal REG_SIOMULTI3   : std_logic_vector(SIOMULTI3  .upper downto SIOMULTI3  .lower) := (others => '0');
   signal REG_SIOCNT      : std_logic_vector(SIOCNT     .upper downto SIOCNT     .lower) := (others => '0');
   signal REG_SIOMLT_SEND : std_logic_vector(SIOMLT_SEND.upper downto SIOMLT_SEND.lower) := (others => '0');
   signal REG_SIODATA8    : std_logic_vector(SIODATA8   .upper downto SIODATA8   .lower) := (others => '0');
   signal REG_RCNT        : std_logic_vector(RCNT       .upper downto RCNT       .lower) := (others => '0');
   signal REG_IR          : std_logic_vector(IR         .upper downto IR         .lower) := (others => '0');
   signal REG_JOYCNT      : std_logic_vector(JOYCNT     .upper downto JOYCNT     .lower) := (others => '0');
   signal REG_JOY_RECV    : std_logic_vector(JOY_RECV   .upper downto JOY_RECV   .lower) := (others => '0');
   signal REG_JOY_TRANS   : std_logic_vector(JOY_TRANS  .upper downto JOY_TRANS  .lower) := (others => '0');
   signal REG_JOYSTAT     : std_logic_vector(JOYSTAT    .upper downto JOYSTAT    .lower) := (others => '0');

   signal SIOCNT_READBACK : std_logic_vector(SIOCNT     .upper downto SIOCNT     .lower) := (others => '0');
   signal SIOCNT_written  : std_logic;

   signal RCNT_READBACK   : std_logic_vector(RCNT       .upper downto RCNT       .lower) := (others => '0');

   -- SIODATA32 readback — serves reads for SIODATA32 (0x120, 32-bit),
   -- SIOMULTI0 (0x120, lower 16-bit), and SIOMULTI1 (0x122, upper 16-bit)
   signal REG_SIODATA32_READBACK : std_logic_vector(31 downto 0) := (others => '0');
   signal SIODATA32_written      : std_logic;

   -- SIODATA8 / SIOMLT_SEND readback (0x12A, 16-bit)
   signal REG_SIODATA8_READBACK : std_logic_vector(15 downto 0) := (others => '0');
   signal SIODATA8_written      : std_logic;

   -- Normal mode transfer state
   signal SIO_start       : std_logic := '0';
   signal cycles          : unsigned(11 downto 0) := (others => '0');
   signal bitcount        : integer range 0 to 31 := 0;
   signal shift_reg       : std_logic_vector(31 downto 0) := (others => '0');
   signal transfer_bits   : integer range 0 to 31 := 7;
   signal received_data   : std_logic_vector(31 downto 0) := (others => '0');

   -- Normal mode external clock edge detection
   signal sck_sync        : std_logic_vector(2 downto 0) := (others => '0');
   signal sck_rise        : std_logic;
   signal sck_fall        : std_logic;
   signal int_clk_phase   : std_logic := '0';

   -- Multi-player mode state
   signal multi_mode      : std_logic;
   signal multi_active    : std_logic := '0';
   signal multi_sending   : std_logic := '0';
   signal multi_startbit  : std_logic := '0';
   signal multi_bitcount  : integer range 0 to 18 := 0;
   signal multi_cycles    : unsigned(11 downto 0) := (others => '0');
   signal multi_speed     : integer range 145 to 1747 := 145;
   signal multi_tx_reg    : std_logic_vector(17 downto 0) := (others => '1');
   signal multi_rx_reg    : std_logic_vector(17 downto 0) := (others => '1');
   signal multi_sd_out_r  : std_logic := '1';

   -- SC input synchronizer for child to detect parent's SC going LOW
   signal sc_sync         : std_logic_vector(2 downto 0) := (others => '1');

   -- SD input synchronizer
   signal sd_sync         : std_logic_vector(2 downto 0) := (others => '1');

begin

   -- SIODATA32 at 0x120 (32-bit) — also serves SIOMULTI0 (lower 16) and SIOMULTI1 (upper 16)
   iSIODATA32   : entity work.eProcReg_gba generic map (SIODATA32  ) port map  (clk100, gb_bus, REG_SIODATA32_READBACK, REG_SIODATA32, SIODATA32_written);
   -- SIOMULTI0/1 instances removed — handled by SIODATA32 readback at same address
   iSIOMULTI2   : entity work.eProcReg_gba generic map (SIOMULTI2  ) port map  (clk100, gb_bus, x"FFFF"               , REG_SIOMULTI2  );
   iSIOMULTI3   : entity work.eProcReg_gba generic map (SIOMULTI3  ) port map  (clk100, gb_bus, x"FFFF"               , REG_SIOMULTI3  );
   iSIOCNT      : entity work.eProcReg_gba generic map (SIOCNT     ) port map  (clk100, gb_bus, SIOCNT_READBACK       , REG_SIOCNT     , SIOCNT_written);
   iSIOMLT_SEND : entity work.eProcReg_gba generic map (SIOMLT_SEND) port map  (clk100, gb_bus, REG_SIOMLT_SEND       , REG_SIOMLT_SEND);
   iSIODATA8    : entity work.eProcReg_gba generic map (SIODATA8   ) port map  (clk100, gb_bus, REG_SIODATA8_READBACK , REG_SIODATA8   , SIODATA8_written);
   iRCNT        : entity work.eProcReg_gba generic map (RCNT       ) port map  (clk100, gb_bus, RCNT_READBACK         , REG_RCNT       );
   iIR          : entity work.eProcReg_gba generic map (IR         ) port map  (clk100, gb_bus, REG_IR         , REG_IR         );
   iJOYCNT      : entity work.eProcReg_gba generic map (JOYCNT     ) port map  (clk100, gb_bus, REG_JOYCNT     , REG_JOYCNT     );
   iJOY_RECV    : entity work.eProcReg_gba generic map (JOY_RECV   ) port map  (clk100, gb_bus, REG_JOY_RECV   , REG_JOY_RECV   );
   iJOY_TRANS   : entity work.eProcReg_gba generic map (JOY_TRANS  ) port map  (clk100, gb_bus, REG_JOY_TRANS  , REG_JOY_TRANS  );
   iJOYSTAT     : entity work.eProcReg_gba generic map (JOYSTAT    ) port map  (clk100, gb_bus, REG_JOYSTAT    , REG_JOYSTAT    );

   -- Mode detection
   multi_mode <= '1' when REG_SIOCNT(13) = '1' and REG_RCNT(15) = '0' else '0';

   -- SIOCNT readback: different layout for Normal vs Multi-Player mode
   SIOCNT_READBACK <=
      -- Multi-player: [15:14]=reg, [13]=1, [12]=0, [11:8]=reg, [7]=busy, [6]=error(0),
      --               [5:4]=ID, [3]=SD(1=connected), [2]=SI(0=parent,1=child), [1:0]=baud
      REG_SIOCNT(15 downto 8) & multi_active & '0' & '0' & (not link_is_parent) & '1' & (not link_is_parent) & REG_SIOCNT(1 downto 0)
      when multi_mode = '1' else
      -- Normal: [15:8]=reg, [7]=start, [6:3]=reg, [2]=SI pin, [1:0]=reg
      REG_SIOCNT(15 downto 8) & SIO_start & REG_SIOCNT(6 downto 3) & serial_data_in & REG_SIOCNT(1 downto 0);

   -- RCNT readback: lower bits reflect pin states in multi-player mode
   RCNT_READBACK <=
      REG_RCNT(15 downto 4) & multi_sd_out_r & (not link_is_parent) & '1' & '1'
      when multi_mode = '1' else
      REG_RCNT;

   -- Normal mode: expose internal clock select for SCK direction
   serial_int_clock <= REG_SIOCNT(0) when multi_mode = '0' else '0';

   -- Normal mode external clock edge detect
   sck_rise <= '1' when sck_sync(2) = '0' and sck_sync(1) = '1' else '0';
   sck_fall <= '1' when sck_sync(2) = '1' and sck_sync(1) = '0' else '0';

   -- Multi-player SD output
   serial_sd_out <= multi_sd_out_r;

   process (clk100)
   begin
      if rising_edge(clk100) then

         IRP_Serial <= '0';

         -- Synchronize external inputs
         sck_sync <= sck_sync(1 downto 0) & serial_clk_in;
         sc_sync  <= sc_sync(1 downto 0) & serial_sc_in;
         sd_sync  <= sd_sync(1 downto 0) & serial_sd_in;

         -- Baud rate divisor lookup (always computed, used by multi-player)
         case REG_SIOCNT(1 downto 0) is
            when "00"   => multi_speed <= 1747; -- 9600 baud
            when "01"   => multi_speed <=  436; -- 38400 baud
            when "10"   => multi_speed <=  291; -- 57600 baud
            when "11"   => multi_speed <=  145; -- 115200 baud
            when others => null;
         end case;

         if (multi_mode = '1') then
            -- ============================================================
            -- MULTI-PLAYER MODE (SIOCNT[13]=1, RCNT[15]=0)
            -- UART on SD pin, SC as handshake, 2-player only
            -- Follows GBA2P MiSTer reference implementation
            -- ============================================================

            -- SC output: LOW when transfer active, HIGH when idle
            if (multi_active = '1') then
               serial_sc_out <= '0';
            else
               serial_sc_out <= '1';
            end if;

            -- SC direction: parent drives, child reads
            serial_sc_dir <= link_is_parent;

            -- SD direction: output when sending, input otherwise
            serial_sd_dir <= multi_sending;

            -- Cycle counting for baud rate timing
            if (new_exact_cycle = '1') then
               multi_cycles <= multi_cycles + 1;
            elsif (multi_sending = '1') then
               -- ===== UART TRANSMIT =====
               if (multi_cycles >= multi_speed) then
                  multi_cycles <= multi_cycles - multi_speed;

                  -- Output MSB of TX shift register, shift left
                  multi_sd_out_r <= multi_tx_reg(17);
                  multi_tx_reg   <= multi_tx_reg(16 downto 0) & '1';

                  if (multi_bitcount = 17) then
                     -- All 18 bits sent (start + 16 data + stop)
                     multi_bitcount <= 0;
                     multi_sending  <= '0';

                     if (link_is_parent = '0') then
                        -- Child is done after sending (already received parent data)
                        if (REG_SIOCNT(14) = '1') then
                           IRP_Serial <= '1';
                        end if;
                     end if;
                  else
                     multi_bitcount <= multi_bitcount + 1;
                  end if;
               end if;

            else
               -- ===== UART RECEIVE =====
               if (multi_startbit = '0') then
                  -- Waiting for start bit (SD goes LOW)
                  if (sd_sync(1) = '0') then
                     -- Start bit detected: set counter to half-period for center sampling
                     multi_cycles   <= to_unsigned(multi_speed / 2, 12);
                     multi_bitcount <= 1;
                     multi_startbit <= '1';
                  end if;
               elsif (multi_cycles >= multi_speed) then
                  multi_cycles <= multi_cycles - multi_speed;

                  -- Shift in received bit
                  multi_rx_reg <= multi_rx_reg(16 downto 0) & sd_sync(1);

                  if (multi_bitcount = 17) then
                     -- 17 samples collected (16 data + stop bit)
                     -- Data is in multi_rx_reg(16 downto 1), stop in multi_rx_reg(0)
                     -- But we read OLD multi_rx_reg (before this shift takes effect)
                     -- After 16 shifts: multi_rx_reg(15:0) = data(15:0) MSB-first
                     multi_bitcount <= 0;
                     multi_startbit <= '0';

                     if (link_is_parent = '1') then
                        -- Parent done after receiving child's data
                        -- SIODATA32 = {child_data, parent_data}
                        REG_SIODATA32_READBACK <= multi_rx_reg(15 downto 0) & REG_SIODATA8;
                        if (REG_SIOCNT(14) = '1') then
                           IRP_Serial <= '1';
                        end if;
                        multi_active <= '0';
                     else
                        -- Child received parent's data, now must send own data
                        -- SIODATA32 = {child_data, parent_data}
                        REG_SIODATA32_READBACK <= REG_SIODATA8 & multi_rx_reg(15 downto 0);
                        multi_sending  <= '1';
                        multi_tx_reg   <= '0' & REG_SIODATA8 & '1';
                        multi_bitcount <= 0;
                        multi_cycles   <= (others => '0');
                     end if;
                  else
                     multi_bitcount <= multi_bitcount + 1;
                  end if;
               end if;
            end if;

            -- Default SD idle when not sending
            if (multi_sending = '0') then
               multi_sd_out_r <= '1';
            end if;

            -- Normal mode signals idle
            serial_data_out <= '1';
            serial_clk_out  <= '1';

         else
            -- ============================================================
            -- NORMAL MODE (SIOCNT[13]=0)
            -- SPI-style clocked serial, 8/32-bit, 2 devices
            -- ============================================================

            -- Multi-player outputs idle
            serial_sc_out  <= '1';
            serial_sc_dir  <= '0';
            serial_sd_dir  <= '0';
            multi_sd_out_r <= '1';
            multi_active   <= '0';

            if (SIO_start = '1') then

               if (REG_SIOCNT(0) = '1') then
                  -- ========== Internal clock (master) ==========
                  -- SIOCNT[1]: 0 = 256 KHz (32 cycles/half-period), 1 = 2 MHz (4 cycles/half-period)
                  if (new_cycles_valid = '1') then
                     cycles <= cycles + new_cycles;
                  else
                     if ((REG_SIOCNT(1) = '0' and cycles >= 32) or (REG_SIOCNT(1) = '1' and cycles >= 4)) then
                        if (REG_SIOCNT(1) = '1') then
                           cycles <= cycles - 4;
                        else
                           cycles <= cycles - 32;
                        end if;

                        if (int_clk_phase = '0') then
                           serial_clk_out  <= '0';
                           serial_data_out <= shift_reg(transfer_bits);
                           int_clk_phase   <= '1';
                        else
                           serial_clk_out <= '1';
                           shift_reg      <= shift_reg(30 downto 0) & serial_data_in;
                           int_clk_phase  <= '0';

                           if (bitcount = transfer_bits) then
                              if (REG_SIOCNT(14) = '1') then
                                 IRP_Serial <= '1';
                              end if;
                              SIO_start    <= '0';
                              received_data <= shift_reg(30 downto 0) & serial_data_in;
                              serial_clk_out <= '1';
                           else
                              bitcount <= bitcount + 1;
                           end if;
                        end if;
                     end if;
                  end if;

               else
                  -- ========== External clock (slave) ==========
                  if (sck_fall = '1') then
                     serial_data_out <= shift_reg(transfer_bits);
                  end if;

                  if (sck_rise = '1') then
                     shift_reg <= shift_reg(30 downto 0) & serial_data_in;

                     if (bitcount = transfer_bits) then
                        if (REG_SIOCNT(14) = '1') then
                           IRP_Serial <= '1';
                        end if;
                        SIO_start     <= '0';
                        received_data <= shift_reg(30 downto 0) & serial_data_in;
                     else
                        bitcount <= bitcount + 1;
                     end if;
                  end if;
               end if;

            else
               -- Not transferring
               serial_data_out <= REG_SIOCNT(3);
               serial_clk_out  <= '1';
            end if;

         end if;  -- multi_mode / normal mode

         -- ============================================================
         -- Handle SIOCNT write: transfer start (applies to both modes)
         -- ============================================================
         if (SIOCNT_written = '1') then
            if (REG_SIOCNT(7) = '1') then
               if (multi_mode = '1') then
                  -- Multi-player transfer start
                  multi_active   <= '1';
                  multi_bitcount <= 0;
                  multi_cycles   <= (others => '0');
                  multi_startbit <= '0';
                  multi_tx_reg   <= '0' & REG_SIODATA8 & '1';  -- start + data + stop

                  -- Parent sends first, child waits to receive
                  multi_sending <= link_is_parent;

                  -- Reset SIODATA32 readback to all 1s (per spec)
                  REG_SIODATA32_READBACK <= (others => '1');

               elsif (REG_RCNT(15) = '0' and REG_SIOCNT(13) = '0') then
                  -- Normal mode transfer start
                  SIO_start     <= '1';
                  bitcount      <= 0;
                  cycles        <= (others => '0');
                  int_clk_phase <= '0';

                  if (REG_SIOCNT(12) = '1') then
                     transfer_bits <= 31;
                     shift_reg     <= REG_SIODATA32;
                  else
                     transfer_bits <= 7;
                     shift_reg     <= x"000000" & REG_SIODATA8(7 downto 0);
                  end if;

                  if (REG_SIOCNT(12) = '1') then
                     serial_data_out <= REG_SIODATA32(31);
                  else
                     serial_data_out <= REG_SIODATA8(7);
                  end if;
               end if;
            end if;
         end if;

         -- Handle direct writes to SIODATA32 and SIODATA8 registers
         if (SIODATA32_written = '1') then
            REG_SIODATA32_READBACK <= REG_SIODATA32;
         end if;

         if (SIODATA8_written = '1') then
            REG_SIODATA8_READBACK <= REG_SIODATA8;
         end if;

         -- Normal mode SIODATA readback (when not in multi-player and not overridden by writes)
         if (multi_mode = '0' and SIODATA32_written = '0' and SIODATA8_written = '0' and SIOCNT_written = '0') then
            if (SIO_start = '1') then
               REG_SIODATA32_READBACK <= shift_reg;
               REG_SIODATA8_READBACK  <= shift_reg(15 downto 0);
            else
               REG_SIODATA32_READBACK <= received_data;
               REG_SIODATA8_READBACK  <= received_data(15 downto 0);
            end if;
         end if;

      end if;
   end process;

end architecture;
