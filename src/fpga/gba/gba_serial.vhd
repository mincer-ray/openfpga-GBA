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
      serial_sc_dir     : out std_logic := '0'    -- 0=input, 1=output
   );
end entity;

architecture arch of gba_serial is

   constant MULTI_ROLE_STABLE_LIMIT : integer := 16383;

   subtype word16_t is std_logic_vector(15 downto 0);
   subtype word32_t is std_logic_vector(31 downto 0);

   type multi_phase_type is (
      MULTI_PHASE_IDLE,
      MULTI_PHASE_PARENT_TX,
      MULTI_PHASE_PARENT_WAIT_CHILD_START,
      MULTI_PHASE_PARENT_RX,
      MULTI_PHASE_PARENT_COMPLETE_WAIT,
      MULTI_PHASE_CHILD_WAIT_PARENT_START,
      MULTI_PHASE_CHILD_RX,
      MULTI_PHASE_CHILD_REPLY_DELAY,
      MULTI_PHASE_CHILD_TX,
      MULTI_PHASE_CHILD_WAIT_PARENT_END
   );

   function pack_multi_slots(
      parent_word : word16_t;
      child_word  : word16_t)
      return word32_t is
   begin
      return child_word & parent_word;
   end function;

   signal REG_SIODATA32   : std_logic_vector(SIODATA32  .upper downto SIODATA32  .lower) := (others => '0');
   signal REG_SIOMULTI0   : std_logic_vector(SIOMULTI0  .upper downto SIOMULTI0  .lower) := (others => '0');
   signal REG_SIOMULTI1   : std_logic_vector(SIOMULTI1  .upper downto SIOMULTI1  .lower) := (others => '0');
   signal REG_SIOCNT      : std_logic_vector(SIOCNT     .upper downto SIOCNT     .lower) := (others => '0');
   signal REG_SIOMLT_SEND : std_logic_vector(SIOMLT_SEND.upper downto SIOMLT_SEND.lower) := (others => '0');
   signal REG_SIODATA8    : std_logic_vector(SIODATA8   .upper downto SIODATA8   .lower) := (others => '0');
   signal REG_SIOMLT_SEND_BUS : std_logic_vector(SIOMLT_SEND.upper downto SIOMLT_SEND.lower) := (others => '0');
   signal REG_SIODATA8_BUS    : std_logic_vector(SIODATA8   .upper downto SIODATA8   .lower) := (others => '0');
   signal REG_RCNT        : std_logic_vector(RCNT       .upper downto RCNT       .lower) := (others => '0');
   signal REG_IR          : std_logic_vector(IR         .upper downto IR         .lower) := (others => '0');
   signal REG_JOYCNT      : std_logic_vector(JOYCNT     .upper downto JOYCNT     .lower) := (others => '0');
   signal REG_JOY_RECV    : std_logic_vector(JOY_RECV   .upper downto JOY_RECV   .lower) := (others => '0');
   signal REG_JOY_TRANS   : std_logic_vector(JOY_TRANS  .upper downto JOY_TRANS  .lower) := (others => '0');
   signal REG_JOYSTAT     : std_logic_vector(JOYSTAT    .upper downto JOYSTAT    .lower) := (others => '0');

   signal SIOCNT_READBACK : std_logic_vector(SIOCNT     .upper downto SIOCNT     .lower) := (others => '0');
   signal SIOCNT_written  : std_logic;
   signal REG_SIOCNT_SEND : std_logic_vector(SIOCNT_SEND.upper downto SIOCNT_SEND.lower) := (others => '0');
   signal REG_SIOCNT_SEND_READBACK : std_logic_vector(31 downto 0) := (others => '0');
   signal SIOCNT_SEND_written : std_logic;
   signal SIOCNT_SEND_bEna : std_logic_vector(3 downto 0);

   signal RCNT_READBACK   : std_logic_vector(RCNT       .upper downto RCNT       .lower) := (others => '0');

   -- SIODATA32 readback — serves reads for SIODATA32 (0x120, 32-bit),
   -- SIOMULTI0 (0x120, lower 16-bit), and SIOMULTI1 (0x122, upper 16-bit)
   signal REG_SIODATA32_READBACK : std_logic_vector(31 downto 0) := (others => '1');
   signal SIODATA32_READBACK_BUS : std_logic_vector(31 downto 0) := (others => '1');
   constant REG_SIOMULTI23_READBACK : std_logic_vector(31 downto 0) := x"FFFFFFFF";
   signal SIODATA32_written      : std_logic;
   signal SIOMULTI0_written      : std_logic;
   signal SIOMULTI1_written      : std_logic;

   -- Shared readback for the 0x12A alias (SIOMLT_SEND in multi-player,
   -- SIODATA8 in normal/UART modes).
   signal REG_SIO12A_READBACK : std_logic_vector(15 downto 0) := (others => '0');
   -- SIODATA8 / SIOMLT_SEND readback (0x12A, 16-bit)
   signal REG_SIODATA8_READBACK : std_logic_vector(15 downto 0) := (others => '0');
   signal SIODATA8_written      : std_logic;
   signal SIOMLT_SEND_written   : std_logic;
   signal SIO12A_word_written   : std_logic;
   signal multi_local_send_word : std_logic_vector(15 downto 0);

   -- Normal mode transfer state
   signal SIO_start       : std_logic := '0';
   signal cycles          : unsigned(11 downto 0) := (others => '0');
   signal bitcount        : integer range 0 to 31 := 0;
   signal shift_reg       : std_logic_vector(31 downto 0) := (others => '0');
   signal transfer_bits   : integer range 0 to 31 := 7;
   signal received_data   : std_logic_vector(31 downto 0) := (others => '0');
   signal si_sync         : std_logic_vector(2 downto 0) := (others => '1');

   -- Normal mode external clock edge detection
   signal sck_sync        : std_logic_vector(2 downto 0) := (others => '0');
   signal sck_rise        : std_logic;
   signal sck_fall        : std_logic;
   signal int_clk_phase   : std_logic := '0';

   -- Multi-player mode state
   signal multi_mode      : std_logic;
   signal multi_phase     : multi_phase_type := MULTI_PHASE_IDLE;
   signal multi_active    : std_logic := '0';
   signal multi_busy_state : std_logic := '0';
   signal multi_sending   : std_logic := '0';
   signal multi_bitcount  : integer range 0 to 18 := 0;
   signal multi_cycles    : unsigned(11 downto 0) := (others => '0');
   signal multi_speed     : integer range 145 to 1747 := 145;
   signal multi_tx_reg    : std_logic_vector(17 downto 0) := (others => '1');
   signal multi_rx_reg    : std_logic_vector(17 downto 0) := (others => '1');
   signal multi_sd_out_r  : std_logic := '1';
   signal multi_error     : std_logic := '0';
   signal multi_sc_state  : std_logic;
   signal multi_sd_state  : std_logic;
   signal multi_ready_state : std_logic;
   signal multi_role_bit  : std_logic;
   signal multi_id_state  : std_logic_vector(1 downto 0);
   signal multi_si_state  : std_logic;
   signal multi_so_state  : std_logic;
   signal multi_parent_observed : std_logic;
   signal multi_is_parent : std_logic := '0';
   signal multi_role_valid : std_logic := '0';
   signal multi_rx_first  : std_logic := '0';
   signal multi_send_pending : std_logic := '0';
   signal multi_endcount  : integer range 0 to 40000 := 0;
   signal multi_endlimit  : integer range 0 to 40000 := 2610;
   signal multi_role_sample_parent : std_logic := '0';
   signal multi_role_stable : integer range 0 to MULTI_ROLE_STABLE_LIMIT := 0;
   signal multi_id_valid : std_logic := '0';
   signal multi_si_seen_low : std_logic := '0';
   signal multi_child_finish_ok : std_logic;
   signal normal_disconnected_idle : std_logic;
   signal multi_disconnected_idle  : std_logic;

   -- SC input synchronizer for child to detect parent's SC going LOW
   signal sc_sync         : std_logic_vector(2 downto 0) := (others => '1');
   signal sc_rise         : std_logic;
   signal sc_fall         : std_logic;

   -- SD input synchronizer
   signal sd_sync         : std_logic_vector(2 downto 0) := (others => '1');
   signal multi_mode_prev : std_logic := '0';
   signal multi_sd_drive_state : std_logic := '0';

begin

   -- SIODATA32 at 0x120 (32-bit) — also serves SIOMULTI0 (lower 16) and SIOMULTI1 (upper 16)
   iSIODATA32   : entity work.eProcReg_gba generic map (SIODATA32  ) port map  (clk100, gb_bus, SIODATA32_READBACK_BUS, REG_SIODATA32, SIODATA32_written);
   -- The register helper only matches exact addresses, so multiplayer reads
   -- still need distinct endpoints at 0x120 and 0x122.
   iSIOMULTI0   : entity work.eProcReg_gba generic map (SIOMULTI0  ) port map  (clk100, gb_bus, SIODATA32_READBACK_BUS(15 downto 0), REG_SIOMULTI0, SIOMULTI0_written);
   iSIOMULTI1   : entity work.eProcReg_gba generic map (SIOMULTI1  ) port map  (clk100, gb_bus, SIODATA32_READBACK_BUS(31 downto 16), REG_SIOMULTI1, SIOMULTI1_written);
   -- Emerald reads REG_SIOMLT_RECV as a 64-bit block. In 2-player mode slots
   -- 2 and 3 should therefore read back as 0xFFFF via a full 32-bit access at
   -- 0x124, not only through the separate 16-bit aliases.
   iSIOMULTI23  : entity work.eProcReg_gba
      generic map (SIOMULTI23)
      port map (
         clk      => clk100,
         proc_bus => gb_bus,
         Din      => REG_SIOMULTI23_READBACK,
         Dout     => open,
         written  => open,
         bEna     => open
      );
   iSIOMULTI3   : entity work.eProcReg_gba generic map (SIOMULTI3  ) port map  (clk100, gb_bus, x"FFFF"               , open           );
   iSIOCNT      : entity work.eProcReg_gba generic map (SIOCNT     ) port map  (clk100, gb_bus, SIOCNT_READBACK       , REG_SIOCNT     , SIOCNT_written);
   iSIOCNT_SEND : entity work.eProcReg_gba generic map (SIOCNT_SEND) port map  (clk100, gb_bus, REG_SIOCNT_SEND_READBACK, REG_SIOCNT_SEND, SIOCNT_SEND_written, SIOCNT_SEND_bEna);
   iSIOMLT_SEND : entity work.eProcReg_gba generic map (SIOMLT_SEND) port map  (clk100, gb_bus, REG_SIO12A_READBACK   , REG_SIOMLT_SEND_BUS, SIOMLT_SEND_written);
   iSIODATA8    : entity work.eProcReg_gba generic map (SIODATA8   ) port map  (clk100, gb_bus, REG_SIO12A_READBACK   , REG_SIODATA8_BUS   , SIODATA8_written);
   iRCNT        : entity work.eProcReg_gba generic map (RCNT       ) port map  (clk100, gb_bus, RCNT_READBACK         , REG_RCNT       );
   iIR          : entity work.eProcReg_gba generic map (IR         ) port map  (clk100, gb_bus, REG_IR         , REG_IR         );
   iJOYCNT      : entity work.eProcReg_gba generic map (JOYCNT     ) port map  (clk100, gb_bus, REG_JOYCNT     , REG_JOYCNT     );
   iJOY_RECV    : entity work.eProcReg_gba generic map (JOY_RECV   ) port map  (clk100, gb_bus, REG_JOY_RECV   , REG_JOY_RECV   );
   iJOY_TRANS   : entity work.eProcReg_gba generic map (JOY_TRANS  ) port map  (clk100, gb_bus, REG_JOY_TRANS  , REG_JOY_TRANS  );
   iJOYSTAT     : entity work.eProcReg_gba generic map (JOYSTAT    ) port map  (clk100, gb_bus, REG_JOYSTAT    , REG_JOYSTAT    );

   -- Mode detection
   multi_mode <= '1' when REG_SIOCNT(13 downto 12) = "10" and REG_RCNT(15) = '0' else '0';

   multi_active <= '0' when multi_phase = MULTI_PHASE_IDLE else '1';
   multi_busy_state <= multi_active;
   multi_sending <= '1' when (multi_phase = MULTI_PHASE_PARENT_TX or multi_phase = MULTI_PHASE_CHILD_TX) else '0';
   multi_send_pending <= '1' when multi_phase = MULTI_PHASE_CHILD_REPLY_DELAY else '0';
   multi_role_bit <= '1' when multi_role_valid = '0' else (not multi_is_parent);
   multi_id_state <= "00" when multi_id_valid = '0' else
                     "00" when multi_is_parent = '1' else
                     "01";
   -- Only treat the idle bus as "parent-candidate" when all three external
   -- lines have settled into the expected master-side signature for a sustained
   -- period. A brief SI glitch on the slave side should not be enough to flip
   -- the whole session into the parent path.
   multi_parent_observed <= '1' when si_sync = "000" and sc_sync = "111" and sd_sync = "111" else '0';
   -- Preserve the old stubbed "no cable" behavior while the link port is idle
   -- and we still have no evidence of a peer. That prevents games from
   -- mistaking an unplugged port for a ready-but-idle link session.
   normal_disconnected_idle <= '1' when multi_mode = '0' and SIO_start = '0' and si_sync(1) = '1' else '0';
   multi_disconnected_idle  <= '1' when multi_mode = '1' and
                                        multi_phase = MULTI_PHASE_IDLE and
                                        multi_role_valid = '0' and
                                        multi_parent_observed = '0' and
                                        sc_sync(1) = '1' else
                               '0';
   SIODATA32_READBACK_BUS   <= (others => '1') when normal_disconnected_idle = '1' or
                                                multi_disconnected_idle = '1' else
                               REG_SIODATA32_READBACK;

   -- SIOCNT readback: different layout for Normal vs Multi-Player mode
   SIOCNT_READBACK <=
      -- Idle/disconnected: match the previous no-link stub until a peer is
      -- actually observed on the bus.
      REG_SIOCNT(15 downto 8) & '0' & '1' & REG_SIOCNT(5 downto 0)
      when multi_mode = '1' and multi_disconnected_idle = '1' else
      -- Multi-player: [15:14]=reg, [13]=1, [12]=0, [11:8]=reg, [7]=busy, [6]=error,
      --               [5:4]=ID, [3]=all-ready, [2]=SI(0=parent,1=child), [1:0]=baud
      REG_SIOCNT(15 downto 8) & multi_busy_state & multi_error & multi_id_state & multi_ready_state & multi_role_bit & REG_SIOCNT(1 downto 0)
      when multi_mode = '1' else
      REG_SIOCNT(15 downto 8) & '0' & '1' & REG_SIOCNT(5 downto 0)
      when normal_disconnected_idle = '1' else
      -- Normal: [15:8]=reg, [7]=start, [6]=error(1=no cable), [5:3]=reg, [2]=SI pin, [1:0]=reg
      REG_SIOCNT(15 downto 8) & SIO_start & REG_SIOCNT(6 downto 3) & serial_data_in & REG_SIOCNT(1 downto 0);

   -- RCNT readback: lower bits reflect pin states in multi-player mode
   RCNT_READBACK <=
      REG_RCNT
      when multi_disconnected_idle = '1' else
      REG_RCNT(15 downto 4) & multi_so_state & multi_si_state & multi_sd_state & multi_sc_state
      when multi_mode = '1' else
      REG_RCNT;

   REG_SIO12A_READBACK <= REG_SIOMLT_SEND when multi_mode = '1' else REG_SIODATA8_READBACK;
   REG_SIOCNT_SEND_READBACK <= REG_SIO12A_READBACK & SIOCNT_READBACK;
   SIO12A_word_written <= '1' when SIOCNT_SEND_written = '1' and
                                   (SIOCNT_SEND_bEna(2) = '1' or SIOCNT_SEND_bEna(3) = '1') else
                          '0';
   multi_local_send_word <= REG_SIOCNT_SEND(31 downto 16) when SIO12A_word_written = '1' else REG_SIOMLT_SEND;

   multi_sc_state <= '0' when multi_role_valid = '1' and multi_is_parent = '1' and multi_active = '1' else
                     '1' when multi_role_valid = '1' and multi_is_parent = '1' else
                     sc_sync(1);
   multi_sd_state <= multi_sd_out_r when multi_sending = '1' else sd_sync(1);
   -- SIOCNT[3] should reflect the shared SD ready line while the bus is idle,
   -- but after a failed transfer with no confirmed role we should stop
   -- advertising the bus as ready until new link evidence appears.
   multi_ready_state <= '1' when multi_phase = MULTI_PHASE_IDLE and
                                 sd_sync(1) = '1' and
                                 not (multi_error = '1' and multi_role_valid = '0') else
                        '0';
   -- Report the master-visible grounded SI level once the role is latched so
   -- software reads the expected parent/child state even while a transfer is in
   -- progress and the raw SI line is being used for the chain.
   multi_si_state <= '0' when multi_role_valid = '1' and multi_is_parent = '1' else si_sync(1);
   -- In multi-player mode the SO line is the slot handoff token. Keep it HIGH
   -- through the parent's own slot, then pull it LOW once the parent has
   -- finished so the first child sees a real downstream "go" transition before
   -- starting its reply. Child units still pull SO LOW while forwarding to the
   -- next device in the chain.
   multi_so_state <= '0' when ((multi_role_valid = '1' and multi_is_parent = '1' and
                                (multi_phase = MULTI_PHASE_PARENT_WAIT_CHILD_START or
                                 multi_phase = MULTI_PHASE_PARENT_RX or
                                 multi_phase = MULTI_PHASE_PARENT_COMPLETE_WAIT)) or
                               (multi_role_valid = '1' and multi_is_parent = '0' and
                                (multi_sending = '1' or multi_send_pending = '1')))
                     else '1';
   multi_endlimit <= multi_speed * 18;
   multi_sd_drive_state <= '1' when multi_mode = '1' and
                                    (multi_sending = '1' or
                                     multi_phase = MULTI_PHASE_IDLE) else
                           '0';
   -- Once the child has begun transmitting its reply, trust the parent's SC
   -- release as the authoritative end-of-transfer signal. Real hardware can
   -- release SC before our local stop-bit phase bookkeeping reaches a
   -- synthesized "half stop bit elapsed" threshold.
   multi_child_finish_ok <= '1' when multi_phase = MULTI_PHASE_CHILD_WAIT_PARENT_END else
                            '1' when multi_phase = MULTI_PHASE_CHILD_TX else
                            '0';
   -- Normal mode: expose internal clock select for SCK direction
   serial_int_clock <= REG_SIOCNT(0) when multi_mode = '0' else '0';

   -- Normal mode external clock edge detect
   sck_rise <= '1' when sck_sync(2) = '0' and sck_sync(1) = '1' else '0';
   sck_fall <= '1' when sck_sync(2) = '1' and sck_sync(1) = '0' else '0';
   sc_rise  <= '1' when sc_sync(2) = '0' and sc_sync(1) = '1' else '0';
   sc_fall  <= '1' when sc_sync(2) = '1' and sc_sync(1) = '0' else '0';

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
         si_sync  <= si_sync(1 downto 0) & serial_data_in;

         if (multi_mode = '0') then
            multi_is_parent         <= '0';
            multi_role_valid        <= '0';
            multi_role_sample_parent <= '0';
            multi_role_stable       <= 0;
            multi_id_valid          <= '0';
            multi_si_seen_low       <= '0';
         elsif (multi_mode_prev = '0') then
            multi_is_parent         <= '0';
            multi_role_valid        <= '0';
            multi_role_sample_parent <= '0';
            multi_role_stable       <= 0;
            multi_id_valid          <= '0';
            multi_si_seen_low       <= '0';
         elsif (multi_phase = MULTI_PHASE_IDLE) then
            if (multi_role_valid = '0') then
               if (multi_parent_observed /= multi_role_sample_parent) then
                  multi_role_sample_parent <= multi_parent_observed;
                  multi_role_stable        <= 0;
               elsif (new_exact_cycle = '1') then
                  if (multi_role_stable < MULTI_ROLE_STABLE_LIMIT) then
                     multi_role_stable <= multi_role_stable + 1;
                  elsif (multi_parent_observed = '1') then
                     multi_id_valid    <= '0';
                     multi_is_parent   <= multi_parent_observed;
                     multi_role_valid  <= '1';
                  end if;
               end if;
            elsif (multi_is_parent = '1') then
               -- Once the cable has shown a credible master-side idle signature,
               -- keep that role latched for the session. On Pocket hardware the
               -- idle SI level can wobble enough to revoke parent just before our
               -- own SC edge, which then makes us mis-capture our own transfer as
               -- a child attempt.
               multi_role_stable <= 0;
            else
               multi_role_stable <= 0;
            end if;
            multi_si_seen_low <= '0';
         else
            multi_role_stable <= 0;
         end if;

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
            -- MULTI-PLAYER MODE (SIOCNT[13:12]=10, RCNT[15]=0)
            -- UART on SD pin, SC as handshake, 2-player only
            -- ============================================================

            -- SC output: LOW when transfer active, HIGH when idle
            if (multi_active = '1') then
               serial_sc_out <= '0';
            else
               serial_sc_out <= '1';
            end if;

            -- SC direction: parent drives, child reads
            serial_sc_dir <= multi_is_parent and multi_role_valid;

            -- In multiplayer mode SD is HIGH during inactivity when the link is
            -- ready, then released except while this unit is actively sending
            -- its own UART slot. Driving HIGH while idle is what lets a real
            -- parent detect "all GBAs ready" and begin the transfer.
            serial_sd_dir <= multi_sd_drive_state;

            -- On real hardware the slave's busy state is driven by the
            -- incoming SC line, not by a local start-bit write.
            if ((multi_role_valid = '0' or multi_is_parent = '0') and
                multi_parent_observed = '0' and
                sc_fall = '1' and multi_phase = MULTI_PHASE_IDLE) then
               multi_is_parent          <= '0';
               multi_role_valid         <= '1';
               multi_role_sample_parent <= '0';
               multi_role_stable        <= 0;
               multi_phase              <= MULTI_PHASE_CHILD_WAIT_PARENT_START;
               multi_bitcount           <= 0;
               multi_cycles             <= (others => '0');
               multi_tx_reg             <= "11" & multi_local_send_word;
               multi_error              <= '0';
               multi_rx_reg             <= (others => '1');
               multi_rx_first           <= '0';
               multi_sd_out_r           <= '1';
               multi_endcount           <= 0;
               if (si_sync(1) = '0') then
                  multi_si_seen_low <= '1';
               else
                  multi_si_seen_low <= '0';
               end if;
               REG_SIODATA32_READBACK   <= (others => '1');
            elsif (multi_is_parent = '0' and sc_rise = '1' and multi_phase /= MULTI_PHASE_IDLE) then
               if (multi_child_finish_ok = '0' or multi_si_seen_low = '0') then
                  multi_error <= '1';
                  multi_id_valid           <= '0';
                  multi_is_parent          <= '0';
                  multi_role_valid         <= '0';
                  multi_role_sample_parent <= '0';
                  multi_role_stable        <= 0;
               else
                  multi_id_valid <= '1';
               end if;
               multi_phase    <= MULTI_PHASE_IDLE;
               multi_bitcount <= 0;
               multi_cycles   <= (others => '0');
               multi_rx_first <= '0';
               multi_endcount <= 0;
               multi_sd_out_r <= '1';
               multi_si_seen_low <= '0';
               if (REG_SIOCNT(14) = '1' and
                   multi_child_finish_ok = '1' and
                   multi_si_seen_low = '1') then
                  IRP_Serial <= '1';
               end if;
            else
               case multi_phase is
                  when MULTI_PHASE_IDLE =>
                     null;

                  when MULTI_PHASE_PARENT_TX | MULTI_PHASE_CHILD_TX =>
                     if (new_exact_cycle = '1') then
                        if (multi_cycles >= multi_speed) then
                           multi_cycles <= multi_cycles - multi_speed;
                           if (multi_bitcount < 16) then
                              multi_sd_out_r <= multi_tx_reg(multi_bitcount);
                              multi_bitcount <= multi_bitcount + 1;
                           elsif (multi_bitcount = 16) then
                              multi_sd_out_r <= '1';
                              multi_bitcount <= 17;
                           else
                              multi_bitcount <= 0;
                              multi_cycles   <= (others => '0');
                              multi_sd_out_r <= '1';
                              if (multi_phase = MULTI_PHASE_PARENT_TX) then
                                 REG_SIODATA32_READBACK <= pack_multi_slots(REG_SIOMLT_SEND, x"FFFF");
                                 multi_phase <= MULTI_PHASE_PARENT_WAIT_CHILD_START;
                                 multi_endcount <= 0;
                              else
                                 multi_phase <= MULTI_PHASE_CHILD_WAIT_PARENT_END;
                              end if;
                           end if;
                        else
                           multi_cycles <= multi_cycles + 1;
                        end if;
                     end if;

                  when MULTI_PHASE_PARENT_WAIT_CHILD_START =>
                     if (sd_sync(1) = '0') then
                        multi_phase    <= MULTI_PHASE_PARENT_RX;
                        multi_bitcount <= 0;
                        multi_cycles   <= (others => '0');
                        multi_rx_reg   <= (others => '1');
                        multi_rx_first <= '1';
                     elsif (new_exact_cycle = '1') then
                        if (multi_endcount >= multi_endlimit) then
                           multi_phase    <= MULTI_PHASE_IDLE;
                           multi_error    <= '1';
                           multi_id_valid           <= '0';
                           multi_is_parent          <= '0';
                           multi_role_valid         <= '0';
                           multi_role_sample_parent <= '0';
                           multi_role_stable        <= 0;
                           multi_cycles   <= (others => '0');
                           multi_rx_first <= '0';
                           multi_endcount <= 0;
                           multi_sd_out_r <= '1';
                        else
                           multi_endcount <= multi_endcount + 1;
                        end if;
                     end if;

                  when MULTI_PHASE_CHILD_WAIT_PARENT_START =>
                     if (si_sync(1) = '0') then
                        multi_si_seen_low <= '1';
                     end if;
                     if (sc_sync(1) = '0' and sd_sync(1) = '0') then
                        multi_phase    <= MULTI_PHASE_CHILD_RX;
                        multi_bitcount <= 0;
                        multi_cycles   <= (others => '0');
                        multi_rx_reg   <= (others => '1');
                        multi_rx_first <= '1';
                     end if;

                  when MULTI_PHASE_PARENT_RX | MULTI_PHASE_CHILD_RX =>
                     if (multi_phase = MULTI_PHASE_CHILD_RX and si_sync(1) = '0') then
                        multi_si_seen_low <= '1';
                     end if;
                     if (new_exact_cycle = '1') then
                        if ((multi_rx_first = '1' and multi_cycles >= (multi_speed + (multi_speed / 2))) or
                            (multi_rx_first = '0' and multi_cycles >= multi_speed)) then
                           if (multi_rx_first = '1') then
                              multi_cycles   <= multi_cycles - (multi_speed + (multi_speed / 2));
                              multi_rx_first <= '0';
                           else
                              multi_cycles <= multi_cycles - multi_speed;
                           end if;

                           if (multi_bitcount < 16) then
                              multi_rx_reg(multi_bitcount) <= sd_sync(1);
                              multi_bitcount <= multi_bitcount + 1;
                           else
                              multi_bitcount <= 0;
                              multi_rx_first <= '0';
                              if (sd_sync(1) = '0') then
                                 multi_error <= '1';
                              end if;

                              if (multi_phase = MULTI_PHASE_PARENT_RX) then
                                 REG_SIODATA32_READBACK <= pack_multi_slots(REG_SIOMLT_SEND, multi_rx_reg(15 downto 0));
                                 multi_phase <= MULTI_PHASE_PARENT_COMPLETE_WAIT;
                                 multi_endcount <= 0;
                                 multi_cycles   <= (others => '0');
                              else
                                 REG_SIODATA32_READBACK <= pack_multi_slots(multi_rx_reg(15 downto 0), REG_SIOMLT_SEND);
                                 multi_phase <= MULTI_PHASE_CHILD_REPLY_DELAY;
                                 multi_cycles       <= (others => '0');
                                 multi_sd_out_r     <= '1';
                              end if;
                           end if;
                        else
                           multi_cycles <= multi_cycles + 1;
                        end if;
                     end if;

                  when MULTI_PHASE_CHILD_REPLY_DELAY =>
                     -- The stop bit is sampled in the middle of its bit cell, so
                     -- only the remaining half-bit is left before the next slot can
                     -- legally begin. A real slave should also see the previous
                     -- node's SO drive its SI terminal LOW before taking its turn.
                     if (new_exact_cycle = '1') then
                        if (si_sync(1) = '0') then
                           multi_si_seen_low <= '1';
                        end if;
                        if (sc_sync(1) = '0' and multi_cycles >= (multi_speed / 2) and
                            (multi_si_seen_low = '1' or si_sync(1) = '0')) then
                           multi_phase    <= MULTI_PHASE_CHILD_TX;
                           multi_bitcount <= 0;
                           multi_cycles   <= (others => '0');
                           multi_sd_out_r <= '0';
                        else
                           multi_cycles <= multi_cycles + 1;
                        end if;
                     end if;

                  when MULTI_PHASE_PARENT_COMPLETE_WAIT =>
                     if (new_exact_cycle = '1') then
                        if (multi_endcount >= multi_endlimit) then
                           multi_phase    <= MULTI_PHASE_IDLE;
                           multi_cycles   <= (others => '0');
                           multi_endcount <= 0;
                           multi_sd_out_r <= '1';
                           if (multi_error = '0') then
                              multi_id_valid <= '1';
                           else
                              multi_id_valid           <= '0';
                              multi_is_parent          <= '0';
                              multi_role_valid         <= '0';
                              multi_role_sample_parent <= '0';
                              multi_role_stable        <= 0;
                           end if;
                           if (REG_SIOCNT(14) = '1' and multi_error = '0') then
                              IRP_Serial <= '1';
                           end if;
                        else
                           multi_endcount <= multi_endcount + 1;
                        end if;
                     end if;

                  when MULTI_PHASE_CHILD_WAIT_PARENT_END =>
                     null;
               end case;
            end if;

            -- In multi-player mode SO is used as the terminal-chain signal.
            serial_data_out <= multi_so_state;
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
            multi_phase    <= MULTI_PHASE_IDLE;
            multi_rx_first <= '0';
            multi_error    <= '0';
            multi_endcount <= 0;
            multi_cycles   <= (others => '0');
            multi_bitcount <= 0;

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
                              -- Normal-mode serial IRQs stay masked because
                              -- Pocket software probes this path during normal
                              -- gameplay often enough to cause audible
                              -- regressions, whereas multiplayer IRQs are
                              -- still required for real link-cable support.
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
                  multi_bitcount <= 0;
                  multi_cycles   <= (others => '0');
                  multi_rx_first <= '0';
                  multi_error    <= '0';
                  multi_tx_reg   <= "11" & multi_local_send_word;
                  multi_rx_reg   <= (others => '1');
                  multi_endcount <= 0;

                  -- Parent sends first; unresolved or child-side units stay idle
                  -- until the real master pulls SC LOW.
                  if (multi_role_valid = '1' and multi_is_parent = '1' and multi_parent_observed = '1') then
                     multi_phase    <= MULTI_PHASE_PARENT_TX;
                     multi_sd_out_r <= '0';
                  else
                     if (multi_role_valid = '1' and multi_is_parent = '1') then
                        multi_is_parent          <= '0';
                        multi_role_valid         <= '0';
                        multi_id_valid           <= '0';
                        multi_role_sample_parent <= '0';
                        multi_role_stable        <= 0;
                     end if;
                     multi_phase    <= MULTI_PHASE_IDLE;
                     multi_sd_out_r <= '1';
                  end if;

                  -- Reset SIODATA32 readback to all 1s (per spec)
                  REG_SIODATA32_READBACK <= (others => '1');

               elsif (REG_RCNT(15) = '0' and REG_SIOCNT(13) = '0') then
                  -- Normal mode transfer start. In master mode, don't launch a
                  -- transfer unless SI already shows a ready peer. With no
                  -- cable attached the line is HIGH/idle, and treating that as
                  -- an immediate transfer completion creates spurious link IRQs.
                  if (REG_SIOCNT(0) = '0' or si_sync(1) = '0') then
                     SIO_start     <= '1';
                     bitcount      <= 0;
                     cycles        <= (others => '0');
                     int_clk_phase <= '0';

                     if (REG_SIOCNT(12) = '1') then
                        transfer_bits <= 31;
                        shift_reg     <= REG_SIODATA32_READBACK;
                     else
                        transfer_bits <= 7;
                        shift_reg     <= x"000000" & REG_SIODATA8(7 downto 0);
                     end if;

                     if (REG_SIOCNT(12) = '1') then
                        serial_data_out <= REG_SIODATA32_READBACK(31);
                     else
                        serial_data_out <= REG_SIODATA8(7);
                     end if;
                  else
                     SIO_start      <= '0';
                     bitcount       <= 0;
                     cycles         <= (others => '0');
                     int_clk_phase  <= '0';
                     received_data  <= (others => '1');
                     serial_clk_out <= '1';
                     serial_data_out <= REG_SIOCNT(3);
                  end if;
               end if;
            end if;
         end if;

         -- Handle direct writes to SIODATA32 and SIODATA8 registers
         -- In multi-player mode the CPU-visible receive slots are read-only in
         -- practice; writes to the 0x120/0x122 aliases should not overwrite the
         -- last transfer result.
         if (SIODATA32_written = '1' and multi_mode = '0') then
            REG_SIODATA32_READBACK <= REG_SIODATA32;
         end if;

         if (SIOMULTI0_written = '1' and multi_mode = '0') then
            REG_SIODATA32_READBACK(15 downto 0) <= REG_SIOMULTI0;
         end if;

         if (SIOMULTI1_written = '1' and multi_mode = '0') then
            REG_SIODATA32_READBACK(31 downto 16) <= REG_SIOMULTI1;
         end if;

         if (SIOMLT_SEND_written = '1' and multi_mode = '1') then
            REG_SIOMLT_SEND <= REG_SIOMLT_SEND_BUS;
         end if;

         if (SIODATA8_written = '1' and multi_mode = '0') then
            REG_SIODATA8         <= REG_SIODATA8_BUS;
            REG_SIODATA8_READBACK <= REG_SIODATA8_BUS;
         end if;

         -- A 32-bit CPU access at 0x128 can legally update both SIOCNT and the
         -- 0x12A data half in one transfer. The generic register helper matches
         -- exact addresses only, so mirror the upper half here.
         if (SIO12A_word_written = '1') then
            if (multi_mode = '1') then
               REG_SIOMLT_SEND <= REG_SIOCNT_SEND(31 downto 16);
            else
               REG_SIODATA8          <= REG_SIOCNT_SEND(31 downto 16);
               REG_SIODATA8_READBACK <= REG_SIOCNT_SEND(31 downto 16);
            end if;
         end if;

         -- Normal mode SIODATA readback (when not in multi-player and not overridden by writes)
         if (multi_mode = '0' and SIODATA32_written = '0' and SIODATA8_written = '0' and
             SIOCNT_written = '0' and SIO12A_word_written = '0') then
            if (SIO_start = '1') then
               REG_SIODATA32_READBACK <= shift_reg;
               REG_SIODATA8_READBACK  <= shift_reg(15 downto 0);
            else
               REG_SIODATA32_READBACK <= received_data;
               REG_SIODATA8_READBACK  <= received_data(15 downto 0);
            end if;
         end if;

         multi_mode_prev <= multi_mode;
      end if;
   end process;

end architecture;
