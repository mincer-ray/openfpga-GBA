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

      IRP_Serial        : out std_logic := '0';

      -- Link cable I/O (directly mapped to Pocket port_tran pins)
      serial_data_out   : out std_logic := '1';  -- SO pin
      serial_data_in    : in  std_logic;          -- SI pin
      serial_clk_out    : out std_logic := '1';   -- SCK output (when master)
      serial_clk_in     : in  std_logic;          -- SCK input (when slave)
      serial_int_clock  : out std_logic := '0'    -- 1 = internal clock (SCK is output)
   );
end entity;

architecture arch of gba_serial is

   signal REG_SIODATA32   : std_logic_vector(SIODATA32  .upper downto SIODATA32  .lower) := (others => '0');
   signal REG_SIOMULTI0   : std_logic_vector(SIOMULTI0  .upper downto SIOMULTI0  .lower) := (others => '0');
   signal REG_SIOMULTI1   : std_logic_vector(SIOMULTI1  .upper downto SIOMULTI1  .lower) := (others => '0');
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

   -- Readback for SIODATA32/SIODATA8 — reflects shift register during transfer, received data after
   signal SIODATA32_READBACK : std_logic_vector(31 downto 0) := (others => '0');
   signal SIODATA8_READBACK  : std_logic_vector(SIODATA8.upper downto SIODATA8.lower) := (others => '0');
   signal received_data      : std_logic_vector(31 downto 0) := (others => '0');

   -- Transfer state
   signal SIO_start       : std_logic := '0';
   signal cycles          : unsigned(11 downto 0) := (others => '0');
   signal bitcount        : integer range 0 to 31 := 0;

   -- Shift register for actual data transfer
   signal shift_reg       : std_logic_vector(31 downto 0) := (others => '0');
   signal transfer_bits   : integer range 0 to 31 := 7;  -- 7 for 8-bit, 31 for 32-bit

   -- External clock edge detection (2-stage synchronizer + edge detect)
   signal sck_sync        : std_logic_vector(2 downto 0) := (others => '0');
   signal sck_rise        : std_logic;
   signal sck_fall        : std_logic;

   -- Internal clock toggle tracking
   signal int_clk_phase   : std_logic := '0';  -- 0 = will fall next, 1 = will rise next

begin

   iSIODATA32   : entity work.eProcReg_gba generic map (SIODATA32  ) port map  (clk100, gb_bus, SIODATA32_READBACK, REG_SIODATA32  );
   iSIOMULTI0   : entity work.eProcReg_gba generic map (SIOMULTI0  ) port map  (clk100, gb_bus, REG_SIOMULTI0  , REG_SIOMULTI0  );
   iSIOMULTI1   : entity work.eProcReg_gba generic map (SIOMULTI1  ) port map  (clk100, gb_bus, REG_SIOMULTI1  , REG_SIOMULTI1  );
   iSIOMULTI2   : entity work.eProcReg_gba generic map (SIOMULTI2  ) port map  (clk100, gb_bus, REG_SIOMULTI2  , REG_SIOMULTI2  );
   iSIOMULTI3   : entity work.eProcReg_gba generic map (SIOMULTI3  ) port map  (clk100, gb_bus, REG_SIOMULTI3  , REG_SIOMULTI3  );
   iSIOCNT      : entity work.eProcReg_gba generic map (SIOCNT     ) port map  (clk100, gb_bus, SIOCNT_READBACK, REG_SIOCNT     , SIOCNT_written);
   iSIOMLT_SEND : entity work.eProcReg_gba generic map (SIOMLT_SEND) port map  (clk100, gb_bus, REG_SIOMLT_SEND, REG_SIOMLT_SEND);
   iSIODATA8    : entity work.eProcReg_gba generic map (SIODATA8   ) port map  (clk100, gb_bus, SIODATA8_READBACK, REG_SIODATA8   );
   iRCNT        : entity work.eProcReg_gba generic map (RCNT       ) port map  (clk100, gb_bus, REG_RCNT       , REG_RCNT       );
   iIR          : entity work.eProcReg_gba generic map (IR         ) port map  (clk100, gb_bus, REG_IR         , REG_IR         );
   iJOYCNT      : entity work.eProcReg_gba generic map (JOYCNT     ) port map  (clk100, gb_bus, REG_JOYCNT     , REG_JOYCNT     );
   iJOY_RECV    : entity work.eProcReg_gba generic map (JOY_RECV   ) port map  (clk100, gb_bus, REG_JOY_RECV   , REG_JOY_RECV   );
   iJOY_TRANS   : entity work.eProcReg_gba generic map (JOY_TRANS  ) port map  (clk100, gb_bus, REG_JOY_TRANS  , REG_JOY_TRANS  );
   iJOYSTAT     : entity work.eProcReg_gba generic map (JOYSTAT    ) port map  (clk100, gb_bus, REG_JOYSTAT    , REG_JOYSTAT    );

   -- SIOCNT readback: bit 7 reflects SIO_start, bit 2 reflects SI pin state
   SIOCNT_READBACK <= REG_SIOCNT(15 downto 8) & SIO_start & REG_SIOCNT(6 downto 3) & serial_data_in & REG_SIOCNT(1 downto 0);

   -- SIODATA32 readback reflects shift register during transfer, received data after
   SIODATA32_READBACK <= shift_reg when SIO_start = '1' else received_data;

   -- SIODATA8 readback: low 16 bits of shift register during transfer, received data after
   SIODATA8_READBACK <= shift_reg(15 downto 0) when SIO_start = '1' else received_data(15 downto 0);

   -- Expose internal clock select to top level for SCK direction control
   -- SIOCNT bit 0: 0=external clock (slave), 1=internal clock (master)
   serial_int_clock <= REG_SIOCNT(0);

   -- External clock synchronizer and edge detect
   sck_rise <= '1' when sck_sync(2) = '0' and sck_sync(1) = '1' else '0';
   sck_fall <= '1' when sck_sync(2) = '1' and sck_sync(1) = '0' else '0';

   process (clk100)
   begin
      if rising_edge(clk100) then

         IRP_Serial <= '0';

         -- Synchronize external SCK input
         sck_sync <= sck_sync(1 downto 0) & serial_clk_in;

         if (SIO_start = '1') then

            if (REG_SIOCNT(0) = '1') then
               -- ========== Internal clock (master) ==========
               -- Count GBA CPU cycles to generate SCK timing
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
                        -- Falling edge: output MSB of shift register on SO
                        serial_clk_out <= '0';
                        serial_data_out <= shift_reg(transfer_bits);
                        int_clk_phase <= '1';
                     else
                        -- Rising edge: sample SI into LSB, shift register shifts left
                        serial_clk_out <= '1';
                        shift_reg <= shift_reg(30 downto 0) & serial_data_in;
                        int_clk_phase <= '0';

                        -- Check if transfer complete
                        if (bitcount = transfer_bits) then
                           if (REG_SIOCNT(14) = '1') then
                              IRP_Serial <= '1';
                           end if;
                           SIO_start <= '0';
                           received_data <= shift_reg(30 downto 0) & serial_data_in;
                           serial_clk_out <= '1';  -- idle high
                        else
                           bitcount <= bitcount + 1;
                        end if;
                     end if;
                  end if;
               end if;

            else
               -- ========== External clock (slave) ==========
               -- React to edges on SCK from master device
               if (sck_fall = '1') then
                  -- Falling edge: output MSB on SO
                  serial_data_out <= shift_reg(transfer_bits);
               end if;

               if (sck_rise = '1') then
                  -- Rising edge: sample SI, shift left
                  shift_reg <= shift_reg(30 downto 0) & serial_data_in;

                  if (bitcount = transfer_bits) then
                     if (REG_SIOCNT(14) = '1') then
                        IRP_Serial <= '1';
                     end if;
                     SIO_start <= '0';
                     received_data <= shift_reg(30 downto 0) & serial_data_in;
                  else
                     bitcount <= bitcount + 1;
                  end if;
               end if;
            end if;

         else
            -- Not transferring: SO reflects SIOCNT bit 3 (idle SO level)
            serial_data_out <= REG_SIOCNT(3);
            serial_clk_out <= '1';  -- SCK idles high
         end if;

         -- Handle SIOCNT write: check for transfer start
         -- Only start in Normal mode: RCNT[15]=0 (not GP/JOY Bus) and SIOCNT[13]=0 (not Multi-Player)
         if (SIOCNT_written = '1') then
            if (REG_SIOCNT(7) = '1' and REG_RCNT(15) = '0' and REG_SIOCNT(13) = '0') then
               SIO_start      <= '1';
               bitcount       <= 0;
               cycles         <= (others => '0');
               int_clk_phase  <= '0';
               -- SIOCNT[12]: 0 = 8-bit transfer, 1 = 32-bit transfer
               if (REG_SIOCNT(12) = '1') then
                  transfer_bits <= 31;
                  shift_reg     <= REG_SIODATA32;
               else
                  transfer_bits <= 7;
                  shift_reg     <= x"000000" & REG_SIODATA8(7 downto 0);
               end if;
               -- Initial SO: output MSB immediately
               if (REG_SIOCNT(12) = '1') then
                  serial_data_out <= REG_SIODATA32(31);
               else
                  serial_data_out <= REG_SIODATA8(7);
               end if;
            end if;
         end if;

      end if;
   end process;

end architecture;
