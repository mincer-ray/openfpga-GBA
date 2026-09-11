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

      -- A physical peer continues running while a savestate is loaded. Abort
      -- rather than attempting to resume an incoherent half-transaction.
      serial_abort      : in  std_logic := '0';

      IRP_Serial        : out std_logic := '0';
      serial_link_active : out std_logic := '0';

      -- One value/output-enable/input contract for every physical link pin.
      -- The mode mux below is the only logic which drives these outputs.
      serial_so_out     : out std_logic := '0';
      serial_so_oe      : out std_logic := '0';
      serial_so_in      : in  std_logic;
      serial_si_out     : out std_logic := '0';
      serial_si_oe      : out std_logic := '0';
      serial_si_in      : in  std_logic;
      serial_sd_out     : out std_logic := '0';
      serial_sd_oe      : out std_logic := '0';
      serial_sd_in      : in  std_logic;
      serial_sc_out     : out std_logic := '0';
      serial_sc_oe      : out std_logic := '0';
      serial_sc_in      : in  std_logic
   );
end entity;

architecture arch of gba_serial is

   constant MULTI_ROLE_STABLE_LIMIT : integer := 16383;

   subtype word16_t is std_logic_vector(15 downto 0);
   subtype word32_t is std_logic_vector(31 downto 0);

   type serial_mode_type is (
      SERIAL_NORMAL_8,
      SERIAL_NORMAL_32,
      SERIAL_MULTI,
      SERIAL_UART,
      SERIAL_GPIO,
      SERIAL_JOYBUS
   );

   constant JOY_COMMAND_RESET  : std_logic_vector(1 downto 0) := "00";
   constant JOY_COMMAND_STATUS : std_logic_vector(1 downto 0) := "01";
   constant JOY_COMMAND_WRITE  : std_logic_vector(1 downto 0) := "10";
   constant JOY_COMMAND_READ   : std_logic_vector(1 downto 0) := "11";

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
   signal REG_JOYCNT_BUS  : std_logic_vector(JOYCNT     .upper downto JOYCNT     .lower) := (others => '0');
   signal REG_JOY_TRANS_BUS : std_logic_vector(JOY_TRANS.upper downto JOY_TRANS.lower) := (others => '0');
   signal REG_JOYSTAT_BUS : std_logic_vector(JOYSTAT    .upper downto JOYSTAT    .lower) := (others => '0');

   signal JOYCNT_READBACK   : std_logic_vector(15 downto 0) := (others => '0');
   signal JOY_RECV_READBACK : std_logic_vector(31 downto 0) := (others => '0');
   signal JOY_TRANS_READBACK : std_logic_vector(31 downto 0) := (others => '0');
   signal JOYSTAT_READBACK  : std_logic_vector(15 downto 0) := (others => '0');
   signal joy_irq_enable    : std_logic := '0';
   signal joy_flags         : std_logic_vector(2 downto 0) := (others => '0');
   signal joy_status_flags  : std_logic_vector(1 downto 0) := (others => '0');
   signal joy_tx_pending    : std_logic := '0';
   signal joy_rx_pending    : std_logic := '0';
   signal JOYCNT_written    : std_logic;
   signal JOYCNT_bEna       : std_logic_vector(3 downto 0);
   signal JOY_TRANS_written : std_logic;
   signal JOY_TRANS_bEna    : std_logic_vector(3 downto 0);
   signal JOYSTAT_written   : std_logic;
   signal JOYSTAT_bEna      : std_logic_vector(3 downto 0);

   signal SIOCNT_READBACK : std_logic_vector(SIOCNT     .upper downto SIOCNT     .lower) := (others => '0');
   signal SIOCNT_written  : std_logic;
   signal SIOCNT_bEna     : std_logic_vector(3 downto 0);
   signal REG_SIOCNT_SEND : std_logic_vector(SIOCNT_SEND.upper downto SIOCNT_SEND.lower) := (others => '0');
   signal REG_SIOCNT_SEND_READBACK : std_logic_vector(31 downto 0) := (others => '0');
   signal SIOCNT_SEND_written : std_logic;
   signal SIOCNT_SEND_bEna : std_logic_vector(3 downto 0);

   signal RCNT_READBACK   : std_logic_vector(RCNT       .upper downto RCNT       .lower) := (others => '0');
   signal RCNT_written    : std_logic;
   signal RCNT_bEna       : std_logic_vector(3 downto 0);

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

   -- Central mode decode and synchronized physical inputs.
   signal serial_mode      : serial_mode_type := SERIAL_NORMAL_8;
   signal serial_mode_prev : serial_mode_type := SERIAL_NORMAL_8;
   signal mode_changed     : std_logic;
   signal so_sync          : std_logic_vector(2 downto 0) := (others => '1');
   signal si_sync          : std_logic_vector(2 downto 0) := (others => '1');
   signal sd_sync          : std_logic_vector(2 downto 0) := (others => '1');
   signal sc_sync          : std_logic_vector(2 downto 0) := (others => '1');
   signal si_fall          : std_logic;

   -- Normal 8/32-bit serial engine.
   signal normal_mode_enable : std_logic;
   signal normal_start       : std_logic;
   signal normal_cancel      : std_logic;
   signal normal_tx_data     : std_logic_vector(31 downto 0);
   signal normal_busy        : std_logic;
   signal normal_rx_data     : std_logic_vector(31 downto 0);
   signal normal_complete    : std_logic;
   signal normal_so_out      : std_logic;
   signal normal_so_oe       : std_logic;
   signal normal_sc_out      : std_logic;
   signal normal_sc_oe       : std_logic;
   signal normal_sc_readback : std_logic;

   -- JoyBus command/physical engine.
   signal joy_so_out          : std_logic;
   signal joy_so_oe           : std_logic;
   signal joy_recv_accept     : std_logic;
   signal joy_recv_data       : std_logic_vector(31 downto 0);
   signal joy_read_accept     : std_logic;
   signal joy_read_rewritten  : std_logic := '0';
   signal joy_command_complete : std_logic;
   signal joy_command_kind    : std_logic_vector(1 downto 0);
   signal joy_mode_enable     : std_logic;

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
   signal multi_disconnected_idle  : std_logic;

   signal sc_rise         : std_logic;
   signal sc_fall         : std_logic;
   signal multi_mode_prev : std_logic := '0';
   signal multi_sd_drive_state : std_logic := '0';
   signal multi_sc_out_r  : std_logic;
   signal multi_sc_oe_r   : std_logic;

   signal gpio_pin_readback : std_logic_vector(3 downto 0);
   signal physical_reset : std_logic;
   -- 2^22 native ticks are 250 ms. A valid physical-mode action reloads this
   -- guard so host-controlled fast-forward cannot race an accessory timeout.
   signal link_guard_counter : unsigned(21 downto 0) := (others => '0');

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
   iSIOCNT      : entity work.eProcReg_gba generic map (SIOCNT     ) port map  (clk100, gb_bus, SIOCNT_READBACK       , REG_SIOCNT     , SIOCNT_written, SIOCNT_bEna);
   iSIOCNT_SEND : entity work.eProcReg_gba generic map (SIOCNT_SEND) port map  (clk100, gb_bus, REG_SIOCNT_SEND_READBACK, REG_SIOCNT_SEND, SIOCNT_SEND_written, SIOCNT_SEND_bEna);
   iSIOMLT_SEND : entity work.eProcReg_gba generic map (SIOMLT_SEND) port map  (clk100, gb_bus, REG_SIO12A_READBACK   , REG_SIOMLT_SEND_BUS, SIOMLT_SEND_written);
   iSIODATA8    : entity work.eProcReg_gba generic map (SIODATA8   ) port map  (clk100, gb_bus, REG_SIO12A_READBACK   , REG_SIODATA8_BUS   , SIODATA8_written);
   iRCNT        : entity work.eProcReg_gba generic map (RCNT       ) port map  (clk100, gb_bus, RCNT_READBACK         , REG_RCNT       , RCNT_written, RCNT_bEna);
   iIR          : entity work.eProcReg_gba generic map (IR         ) port map  (clk100, gb_bus, REG_IR         , REG_IR         );
   iJOYCNT      : entity work.eProcReg_gba generic map (JOYCNT     ) port map  (clk100, gb_bus, JOYCNT_READBACK, REG_JOYCNT_BUS, JOYCNT_written, JOYCNT_bEna);
   -- JOY_RECV is hardware-owned receive data. CPU writes are ignored; reads
   -- are decoded below because they clear the receive-pending status bit.
   iJOY_RECV    : entity work.eProcReg_gba generic map (JOY_RECV   ) port map  (clk100, gb_bus, JOY_RECV_READBACK, open, open, open);
   -- JOY_TRANS is CPU write-only even though its stored word remains available
   -- to the JoyBus engine for an atomic Data Read response.
   iJOY_TRANS   : entity work.eProcReg_gba generic map (JOY_TRANS  ) port map  (clk100, gb_bus, x"00000000", REG_JOY_TRANS_BUS, JOY_TRANS_written, JOY_TRANS_bEna);
   iJOYSTAT     : entity work.eProcReg_gba generic map (JOYSTAT    ) port map  (clk100, gb_bus, JOYSTAT_READBACK, REG_JOYSTAT_BUS, JOYSTAT_written, JOYSTAT_bEna);

   -- RCNT overrides SIOCNT when its top two bits select GPIO or JoyBus.
   serial_mode <= SERIAL_GPIO      when REG_RCNT(15 downto 14) = "10" else
                  SERIAL_JOYBUS    when REG_RCNT(15 downto 14) = "11" else
                  SERIAL_NORMAL_8  when REG_SIOCNT(13 downto 12) = "00" else
                  SERIAL_NORMAL_32 when REG_SIOCNT(13 downto 12) = "01" else
                  SERIAL_MULTI     when REG_SIOCNT(13 downto 12) = "10" else
                  SERIAL_UART;

   mode_changed <= '1' when serial_mode /= serial_mode_prev else '0';
   multi_mode <= '1' when serial_mode = SERIAL_MULTI else '0';
   normal_mode_enable <= '1' when serial_mode = SERIAL_NORMAL_8 or
                                      serial_mode = SERIAL_NORMAL_32 else '0';
   joy_mode_enable <= '1' when serial_mode = SERIAL_JOYBUS else '0';

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
   multi_disconnected_idle  <= '1' when multi_mode = '1' and
                                        multi_phase = MULTI_PHASE_IDLE and
                                        multi_role_valid = '0' and
                                        multi_parent_observed = '0' and
                                        sc_sync(1) = '1' else
                               '0';
   SIODATA32_READBACK_BUS   <= (others => '1') when multi_disconnected_idle = '1' else
                               REG_SIODATA32_READBACK;

   -- SIOCNT readback is mode-specific. Hardware owns busy/error/ID and the
   -- sampled SI bit; configuration fields remain software-owned.
   SIOCNT_READBACK <=
      -- Idle/disconnected: retain the previous no-link status behavior until
      -- a peer is observed, while hard-wiring unused bit 15 low.
      '0' & REG_SIOCNT(14 downto 8) & '0' & '1' & REG_SIOCNT(5 downto 0)
      when multi_mode = '1' and multi_disconnected_idle = '1' else
      -- Multi-player: [15]=0, [14:8]=configuration, [7]=busy, [6]=error,
      -- [5:4]=ID, [3]=all-ready, [2]=SI/role, and [1:0]=baud.
      '0' & REG_SIOCNT(14 downto 8) & multi_busy_state & multi_error &
      multi_id_state & multi_ready_state & multi_role_bit & REG_SIOCNT(1 downto 0)
      when serial_mode = SERIAL_MULTI else
      -- Normal mode exposes live busy/SI, retains the documented software
      -- fields, and hard-wires unused bits 15 and 6:4 low.
      '0' & REG_SIOCNT(14 downto 8) & normal_busy & "000" &
      REG_SIOCNT(3) & si_sync(1) & REG_SIOCNT(1 downto 0)
      when serial_mode = SERIAL_NORMAL_8 or serial_mode = SERIAL_NORMAL_32 else
      -- RCNT-selected GPIO/JoyBus leaves SIOCNT inactive, so bit 7 reads its
      -- stored value rather than the Normal-engine busy state.
      '0' & REG_SIOCNT(14 downto 8) & REG_SIOCNT(7) & "000" &
      REG_SIOCNT(3) & si_sync(1) & REG_SIOCNT(1 downto 0)
      when serial_mode = SERIAL_GPIO or serial_mode = SERIAL_JOYBUS else
      -- UART remains unsupported, but its register mask still follows the
      -- hardware-visible layout.
      '0' & REG_SIOCNT(14 downto 7) & '0' & REG_SIOCNT(5) & '0' & REG_SIOCNT(3 downto 0);

   gpio_pin_readback(3) <= REG_RCNT(3) when REG_RCNT(7) = '1' else so_sync(1);
   gpio_pin_readback(2) <= REG_RCNT(2) when REG_RCNT(6) = '1' else si_sync(1);
   gpio_pin_readback(1) <= REG_RCNT(1) when REG_RCNT(5) = '1' else sd_sync(1);
   gpio_pin_readback(0) <= REG_RCNT(0) when REG_RCNT(4) = '1' else sc_sync(1);
   normal_sc_readback <= normal_sc_out when normal_sc_oe = '1' else sc_sync(1);

   -- RCNT[13:9] are unused. The low nibble exposes the selected mode's live
   -- link-pin levels; GPIO outputs read back their programmed values.
   RCNT_READBACK <=
      REG_RCNT(15 downto 14) & "00000" & REG_RCNT(8 downto 4) &
      multi_so_state & multi_si_state & multi_sd_state & multi_sc_state
      when serial_mode = SERIAL_MULTI else
      REG_RCNT(15 downto 14) & "00000" & REG_RCNT(8 downto 4) &
      normal_so_out & si_sync(1) & '0' & normal_sc_readback
      when serial_mode = SERIAL_NORMAL_8 or serial_mode = SERIAL_NORMAL_32 else
      REG_RCNT(15 downto 14) & "00000" & REG_RCNT(8 downto 4) & gpio_pin_readback
      when serial_mode = SERIAL_GPIO else
      REG_RCNT(15 downto 14) & "00000" & REG_RCNT(8 downto 4) &
      joy_so_out & si_sync(1) & "00"
      when serial_mode = SERIAL_JOYBUS else
      REG_RCNT(15 downto 14) & "00000" & REG_RCNT(8 downto 4) &
      so_sync(1) & si_sync(1) & sd_sync(1) & sc_sync(1);

   JOYCNT_READBACK <= "000000000" & joy_irq_enable & "000" & joy_flags;
   JOYSTAT_READBACK <= "0000000000" & joy_status_flags & joy_tx_pending & '0' & joy_rx_pending & '0';

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
   -- SD is a shared line: release it while idle/receiving and let the
   -- board-level pull-up provide the ready HIGH level.
   multi_sd_drive_state <= '1' when multi_mode = '1' and multi_sending = '1' else
                           '0';
   -- Once the child has begun transmitting its reply, trust the parent's SC
   -- release as the authoritative end-of-transfer signal. Real hardware can
   -- release SC before our local stop-bit phase bookkeeping reaches a
   -- synthesized "half stop bit elapsed" threshold.
   multi_child_finish_ok <= '1' when multi_phase = MULTI_PHASE_CHILD_WAIT_PARENT_END else
                            '1' when multi_phase = MULTI_PHASE_CHILD_TX else
                            '0';
   multi_sc_out_r <= not multi_active;
   multi_sc_oe_r <= multi_is_parent and multi_role_valid;

   sc_rise  <= '1' when sc_sync(2) = '0' and sc_sync(1) = '1' else '0';
   sc_fall  <= '1' when sc_sync(2) = '1' and sc_sync(1) = '0' else '0';
   si_fall  <= '1' when si_sync(2) = '1' and si_sync(1) = '0' else '0';

   physical_reset <= '1' when gb_bus.rst = '1' or serial_abort = '1' else '0';
   serial_link_active <= '1' when normal_busy = '1' or link_guard_counter /= 0 else '0';

   normal_start <= '1' when SIOCNT_written = '1' and SIOCNT_bEna(0) = '1' and
                              REG_SIOCNT(7) = '1' and normal_mode_enable = '1' and
                              mode_changed = '0' else '0';
   normal_cancel <= '1' when mode_changed = '1' or
                               (SIOCNT_written = '1' and SIOCNT_bEna(0) = '1' and
                                REG_SIOCNT(7) = '0') else '0';
   normal_tx_data <= REG_SIODATA32_READBACK when serial_mode = SERIAL_NORMAL_32 else
                     x"000000" & REG_SIOCNT_SEND(23 downto 16) when SIO12A_word_written = '1' else
                     x"000000" & REG_SIODATA8_READBACK(7 downto 0);

   inormal : entity work.gba_serial_normal
   port map
   (
      clk100          => clk100,
      reset           => physical_reset,
      mode_enable     => normal_mode_enable,
      new_exact_cycle => new_exact_cycle,
      start           => normal_start,
      cancel          => normal_cancel,
      transfer_32     => REG_SIOCNT(12),
      internal_clock  => REG_SIOCNT(0),
      fast_clock      => REG_SIOCNT(1),
      idle_so         => REG_SIOCNT(3),
      tx_data         => normal_tx_data,
      si_in           => si_sync(1),
      sc_in           => sc_sync(1),
      busy            => normal_busy,
      rx_data         => normal_rx_data,
      complete        => normal_complete,
      so_out          => normal_so_out,
      so_oe           => normal_so_oe,
      sc_out          => normal_sc_out,
      sc_oe           => normal_sc_oe
   );

   ijoybus : entity work.gba_serial_joybus
   port map
   (
      clk100          => clk100,
      reset           => physical_reset,
      enable          => joy_mode_enable,
      new_exact_cycle => new_exact_cycle,
      si_in           => si_sync(1),
      joystat_in      => JOYSTAT_READBACK(7 downto 0),
      joy_trans_in    => JOY_TRANS_READBACK,
      so_out          => joy_so_out,
      so_oe           => joy_so_oe,
      recv_accept     => joy_recv_accept,
      recv_data       => joy_recv_data,
      read_accept     => joy_read_accept,
      command_complete => joy_command_complete,
      command_kind    => joy_command_kind
   );

   -- The sole physical-pin driver. Reset/load release every translator before
   -- any mode engine can become visible at the connector.
   process (serial_mode, physical_reset, normal_so_out, normal_so_oe,
            normal_sc_out, normal_sc_oe, multi_so_state, multi_sd_out_r,
            multi_sd_drive_state, multi_sc_out_r, multi_sc_oe_r, REG_RCNT,
            joy_so_out, joy_so_oe)
   begin
      serial_so_out <= '0';
      serial_so_oe  <= '0';
      serial_si_out <= '0';
      serial_si_oe  <= '0';
      serial_sd_out <= '0';
      serial_sd_oe  <= '0';
      serial_sc_out <= '0';
      serial_sc_oe  <= '0';

      if physical_reset = '0' then
         case serial_mode is
            when SERIAL_NORMAL_8 | SERIAL_NORMAL_32 =>
               serial_so_out <= normal_so_out;
               serial_so_oe  <= normal_so_oe;
               serial_sd_out <= '0';
               serial_sd_oe  <= '1';
               serial_sc_out <= normal_sc_out;
               serial_sc_oe  <= normal_sc_oe;

            when SERIAL_MULTI =>
               serial_so_out <= multi_so_state;
               serial_so_oe  <= '1';
               serial_sd_out <= multi_sd_out_r;
               serial_sd_oe  <= multi_sd_drive_state;
               serial_sc_out <= multi_sc_out_r;
               serial_sc_oe  <= multi_sc_oe_r;

            when SERIAL_GPIO =>
               serial_so_out <= REG_RCNT(3);
               serial_so_oe  <= REG_RCNT(7);
               serial_si_out <= REG_RCNT(2);
               serial_si_oe  <= REG_RCNT(6);
               serial_sd_out <= REG_RCNT(1);
               serial_sd_oe  <= REG_RCNT(5);
               serial_sc_out <= REG_RCNT(0);
               serial_sc_oe  <= REG_RCNT(4);

            when SERIAL_JOYBUS =>
               serial_so_out <= joy_so_out;
               serial_so_oe  <= joy_so_oe;
               serial_sd_out <= '0';
               serial_sd_oe  <= '1';
               serial_sc_out <= '0';
               serial_sc_oe  <= '1';

            when SERIAL_UART =>
               null;
         end case;
      end if;
   end process;

   process (clk100)
   begin
      if rising_edge(clk100) then

         IRP_Serial <= '0';

         -- Synchronize external inputs
         so_sync  <= so_sync(1 downto 0) & serial_so_in;
         sc_sync  <= sc_sync(1 downto 0) & serial_sc_in;
         sd_sync  <= sd_sync(1 downto 0) & serial_sd_in;
         si_sync  <= si_sync(1 downto 0) & serial_si_in;

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

            -- In multiplayer mode SD is released while idle/receiving and
            -- driven only while this unit is actively sending its UART slot.

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

         else
            -- Leaving multiplayer aborts its wire state without producing a
            -- completion event. Normal and JoyBus run in dedicated engines.
            multi_sd_out_r <= '1';
            multi_phase    <= MULTI_PHASE_IDLE;
            multi_rx_first <= '0';
            multi_error    <= '0';
            multi_endcount <= 0;
            multi_cycles   <= (others => '0');
            multi_bitcount <= 0;
         end if;

         -- ============================================================
         -- Handle the existing multiplayer start. Normal start/cancel pulses
         -- are decoded above and sampled directly by the dedicated engine.
         -- ============================================================
         if (SIOCNT_written = '1' and SIOCNT_bEna(0) = '1' and
             mode_changed = '0') then
            if (REG_SIOCNT(7) = '1') then
               if (serial_mode = SERIAL_MULTI) then
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

               end if;
            end if;
         end if;

         -- Normal completion publishes the whole transfer atomically, clears
         -- busy through the engine, and creates at most one IRQ event.
         if (normal_complete = '1' and normal_mode_enable = '1' and
             mode_changed = '0') then
            if (serial_mode = SERIAL_NORMAL_32) then
               REG_SIODATA32_READBACK <= normal_rx_data;
            elsif (serial_mode = SERIAL_NORMAL_8) then
               REG_SIODATA8_READBACK(7 downto 0) <= normal_rx_data(7 downto 0);
            end if;

            if (REG_SIOCNT(14) = '1') then
               IRP_Serial <= '1';
            end if;
         end if;

         -- JOYCNT flags are write-one-to-clear. Hardware events below are
         -- deliberately later in this process, so a new event wins over a
         -- simultaneous software clear.
         if (JOYCNT_written = '1' and JOYCNT_bEna(0) = '1') then
            joy_irq_enable <= REG_JOYCNT_BUS(6);
            for i in 0 to 2 loop
               if (REG_JOYCNT_BUS(i) = '1') then
                  joy_flags(i) <= '0';
               end if;
            end loop;
         end if;

         if (JOYSTAT_written = '1' and JOYSTAT_bEna(0) = '1') then
            joy_status_flags <= REG_JOYSTAT_BUS(5 downto 4);
         end if;

         -- The peripheral bus is word-aligned. Both halfword views of
         -- JOY_RECV therefore use address 0x150 and trigger this side effect.
         if (gb_bus.ena = '1' and gb_bus.rnw = '1' and
             gb_bus.Adr = std_logic_vector(to_unsigned(JOY_RECV.Adr, gb_bus.Adr'length)) and
             (gb_bus.acc = ACCESS_16BIT or gb_bus.acc = ACCESS_32BIT)) then
            joy_rx_pending <= '0';
         end if;

         -- A complete Data Write is committed before its status reply begins.
         if (joy_recv_accept = '1' and joy_mode_enable = '1' and
             mode_changed = '0') then
            JOY_RECV_READBACK <= joy_recv_data;
            joy_rx_pending    <= '1';
         end if;

         -- This is the exact boundary at which the engine snapshots the word
         -- for a Data Read response.  A qualifying CPU write from this cycle
         -- onward belongs to the next host read and must keep TX pending set.
         if (joy_read_accept = '1' and joy_mode_enable = '1' and
             mode_changed = '0') then
            joy_read_rewritten <= '0';
         end if;

         if (joy_command_complete = '1' and joy_mode_enable = '1' and
             mode_changed = '0') then
            case joy_command_kind is
               when JOY_COMMAND_RESET =>
                  joy_flags(0) <= '1';
               when JOY_COMMAND_STATUS =>
                  null;
               when JOY_COMMAND_WRITE =>
                  joy_flags(1) <= '1';
               when JOY_COMMAND_READ =>
                  joy_flags(2)  <= '1';
                  if (joy_read_rewritten = '0') then
                     joy_tx_pending <= '0';
                  end if;
                  joy_read_rewritten <= '0';
               when others =>
                  null;
            end case;

            if (joy_command_kind /= JOY_COMMAND_STATUS and joy_irq_enable = '1') then
               IRP_Serial <= '1';
            end if;
         end if;

         -- CPU transmit writes have final priority over a simultaneous host
         -- Data Read completion, preserving newly queued data.
         if (JOY_TRANS_written = '1') then
            for i in 0 to 3 loop
               if (JOY_TRANS_bEna(i) = '1') then
                  JOY_TRANS_READBACK(((i + 1) * 8) - 1 downto i * 8) <=
                     REG_JOY_TRANS_BUS(((i + 1) * 8) - 1 downto i * 8);
               end if;
            end loop;
            -- Nintendo documents a word side effect; mGBA/Game Bub also apply
            -- it to either halfword. Byte writes update storage only.
            if (JOY_TRANS_bEna(1 downto 0) = "11" or
                JOY_TRANS_bEna(3 downto 2) = "11") then
               joy_tx_pending <= '1';
               joy_read_rewritten <= '1';
            end if;
         end if;

         -- GPIO SI falling-edge IRQ. Requiring GPIO on both sides of the mode
         -- boundary prevents a stale synchronized edge from firing on entry.
         if (serial_mode = SERIAL_GPIO and serial_mode_prev = SERIAL_GPIO and
             REG_RCNT(8) = '1' and si_fall = '1') then
            IRP_Serial <= '1';
         end if;

         -- Low-byte Normal writes include both transfer starts and the
         -- software-driven SO transitions used by the AGB-015 ready
         -- handshake. Completion refreshes the guard again so a long external
         -- clock wait still receives the full post-transfer idle window.
         if ((normal_mode_enable = '1' and
              ((SIOCNT_written = '1' and SIOCNT_bEna(0) = '1') or
               normal_complete = '1')) or
             (serial_mode = SERIAL_GPIO and
              (RCNT_written = '1' or si_fall = '1')) or
             (serial_mode = SERIAL_JOYBUS and si_fall = '1')) then
            link_guard_counter <= (others => '1');
         elsif (new_exact_cycle = '1' and link_guard_counter /= 0) then
            link_guard_counter <= link_guard_counter - 1;
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

         multi_mode_prev <= multi_mode;
         serial_mode_prev <= serial_mode;

         -- Reset, mode-load abort, and savestate load never complete a wire
         -- transaction or raise an interrupt.
         if (physical_reset = '1') then
            IRP_Serial              <= '0';
            multi_phase            <= MULTI_PHASE_IDLE;
            multi_is_parent        <= '0';
            multi_role_valid       <= '0';
            multi_role_sample_parent <= '0';
            multi_role_stable      <= 0;
            multi_id_valid         <= '0';
            multi_si_seen_low      <= '0';
            multi_rx_first         <= '0';
            multi_error            <= '0';
            multi_endcount         <= 0;
            multi_cycles           <= (others => '0');
            multi_bitcount         <= 0;
            multi_sd_out_r         <= '1';
            REG_SIODATA32_READBACK <= (others => '1');
            REG_SIODATA8_READBACK  <= (others => '0');
            REG_SIOMLT_SEND        <= (others => '0');
            REG_SIODATA8           <= (others => '0');
            joy_irq_enable         <= '0';
            joy_flags              <= (others => '0');
            joy_status_flags       <= (others => '0');
            joy_tx_pending         <= '0';
            joy_rx_pending         <= '0';
            JOY_RECV_READBACK      <= (others => '0');
            JOY_TRANS_READBACK     <= (others => '0');
            joy_read_rewritten     <= '0';
            link_guard_counter     <= (others => '0');
         end if;
      end if;
   end process;

end architecture;
