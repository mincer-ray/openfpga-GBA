library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

use work.pProc_bus_gba.all;

-- The DUT against peers that reproduce measured real-GBA multiplayer wire
-- timing (akkit.org diagram, GBATEK, mGBA's hardware cycle table) rather
-- than this core's own conventions:
--
--  * Words are back-to-back: the next start bit immediately follows the
--    previous stop bit.
--  * A unit pulls SO LOW during its own STOP bit (about one bit before the
--    next word boundary) and releases it when the frame ends.
--  * A child transmits at the word boundary when its grant already arrived,
--    or one bit after observing SI fall when the grant comes in late
--    (covers both real peers and this core's later grant).
--  * The scripted parent frames the exchange on SC and ends the frame after
--    a short PEER_TIMEOUT_BITS window without a further child.
--
-- All waits on cable levels are polled on clk, because a `wait until level`
-- in VHDL is edge-sensitive and would miss levels that are already present
-- when the wait begins.
--
-- Coverage:
--  * The DUT at every cable position for 2, 3 and 4 players, all baud rates,
--    with per-exchange send words that change between frames (single-pak
--    download traffic).
--  * A not-ready console that holds SD low (like a real GBA outside
--    multiplayer mode) while the master polls, then joins. A real master
--    keeps running exchanges during that phase and sees FFFF slots; the
--    exchange for the players that answer must still complete.
entity tb_gba_serial_multiplayer_hardware is
end entity;

architecture test of tb_gba_serial_multiplayer_hardware is
   constant CLOCK_PERIOD : time := 10 ns;
   constant NATIVE_PERIOD : time := 6 * CLOCK_PERIOD;
   constant MAX_PLAYERS   : natural := 4;
   constant POLL_LIMIT    : natural := 30_000_000;  -- 300 ms of clk polling

   type time_array is array (0 to 3) of time;
   constant IDEAL_BIT_PERIOD : time_array := (
      (NATIVE_PERIOD * 16777216) / 9600,
      (NATIVE_PERIOD * 16777216) / 38400,
      (NATIVE_PERIOD * 16777216) / 57600,
      (NATIVE_PERIOD * 16777216) / 115200);

   -- Scripted parent's window for a missing next child, in bit times.
   constant PEER_TIMEOUT_BITS : positive := 4;

   type word_array is array (0 to 3) of std_logic_vector(15 downto 0);

   signal clk         : std_logic := '0';
   signal native_tick : std_logic := '0';

   -- Test control
   signal player_count : natural range 2 to MAX_PLAYERS := 2;
   signal dut_pos      : natural range 0 to 3 := 0;
   signal baud         : natural range 0 to 3 := 0;
   signal words        : word_array := (others => x"FFFF");
   signal peer_start   : std_logic := '0';

   -- A "not ready" console: drives SD low (another communication mode) and
   -- does not participate, exactly like a real GBA outside multiplayer mode.
   signal not_ready_pos : integer := -1;

   -- Cable
   signal cable_sd, cable_sc : std_logic := 'H';
   signal peer_so : std_logic_vector(0 to 3) := (others => '1');

   -- DUT
   signal bus_dut : proc_bus_gb_type := (
      Din => (others => '0'), Dout => (others => 'Z'), Adr => (others => '0'),
      rnw => '1', ena => '0', done => 'Z', acc => ACCESS_16BIT,
      bEna => "0011", rst => '1');
   signal so_out, so_oe, si_out, si_oe, sd_out, sd_oe, sc_out, sc_oe : std_logic;
   signal si_in, sd_in, sc_in, so_in : std_logic;
   signal irq, active : std_logic;

   signal monitor_reset : std_logic := '1';
   signal irq_count    : natural := 0;

   function pos_bit_change(newv, oldv : std_logic_vector) return natural is
   begin
      for i in newv'range loop
         if newv(i) /= oldv(i) then
            return i;
         end if;
      end loop;
      return 0;
   end function;

begin

   clk <= not clk after CLOCK_PERIOD / 2;
   tickgen : process(clk)
      variable divider : natural range 0 to 5 := 0;
   begin
      if rising_edge(clk) then
         native_tick <= '0';
         if divider = 5 then
            divider := 0;
            native_tick <= '1';
         else
            divider := divider + 1;
         end if;
      end if;
   end process;

   cable_sd <= 'H';
   cable_sc <= 'H';
   cable_sd <= sd_out when sd_oe = '1' else 'Z';
   cable_sc <= sc_out when sc_oe = '1' else 'Z';

   -- DUT SI: grounded at position 0, else previous unit's SO.
   dut_si_mux : process(all)
   begin
      if dut_pos = 0 then
         si_in <= '0';
      else
         si_in <= peer_so(dut_pos - 1);
      end if;
   end process;

   dut : entity work.gba_serial
      port map (
         clk100 => clk, gb_bus => bus_dut, new_cycles => to_unsigned(1, 8),
         new_cycles_valid => native_tick, new_exact_cycle => native_tick,
         serial_abort => '0', IRP_Serial => irq, serial_link_active => active,
         serial_so_out => so_out, serial_so_oe => so_oe, serial_so_in => so_in,
         serial_si_out => si_out, serial_si_oe => si_oe, serial_si_in => si_in,
         serial_sd_out => sd_out, serial_sd_oe => sd_oe, serial_sd_in => sd_in,
         serial_sc_out => sc_out, serial_sc_oe => sc_oe, serial_sc_in => sc_in);

   sd_in <= to_x01(cable_sd);
   sc_in <= to_x01(cable_sc);
   so_in <= '1';

   wiremon : process(sc_in, si_in, sd_in, so_oe, peer_so, dut_pos, peer_start)
      variable sc_prev, si_prev, sd_prev, so_prev : std_logic := '1';
      variable pso_prev : std_logic_vector(0 to 3) := (others => '1');
      variable dp_prev : natural := 999;
   begin
      if dut_pos /= dp_prev then
         report "MON @ " & time'image(now) & " DUT_POS=" & integer'image(dut_pos)
            severity note;
         dp_prev := dut_pos;
      end if;
      if sc_in /= sc_prev then
         report "MON @ " & time'image(now) & " SC=" & std_logic'image(sc_in)
            severity note;
         sc_prev := sc_in;
      end if;
      if si_in /= si_prev then
         report "MON @ " & time'image(now) & " SI=" & std_logic'image(si_in) &
            " (peer_so=" & to_hstring(peer_so) & ")"
            severity note;
         si_prev := si_in;
      end if;
      if peer_so /= pso_prev then
         report "MON @ " & time'image(now) & " PEER_SO(" &
            integer'image(pos_bit_change(peer_so, pso_prev)) & ")=" &
            std_logic'image(peer_so(pos_bit_change(peer_so, pso_prev))) &
            " full=" & to_hstring(peer_so)
            severity note;
         pso_prev := peer_so;
      end if;
      if sd_in /= sd_prev then
         report "MON @ " & time'image(now) & " SD=" & std_logic'image(sd_in) &
            " (dut sd_oe=" & std_logic'image(sd_oe) &
            " sd_out=" & std_logic'image(sd_out) & ")"
            severity note;
         sd_prev := sd_in;
      end if;
      if so_oe /= so_prev then
         report "MON @ " & time'image(now) & " SO_OE=" & std_logic'image(so_oe)
            severity note;
         so_prev := so_oe;
      end if;
   end process;

   irqmon : process(clk)
   begin
      if rising_edge(clk) then
         if monitor_reset = '1' then
            irq_count <= 0;
         elsif irq = '1' then
            irq_count <= irq_count + 1;
         end if;
      end if;
   end process;

   contention : process(cable_sd, cable_sc)
   begin
      assert to_x01(cable_sd) /= 'X'
         report "SD bus contention: raw=" & std_logic'image(cable_sd)
         severity note;
      assert to_x01(cable_sc) /= 'X' report "SC bus contention" severity failure;
   end process;


   -- =====================================================================
   -- Peers. The peer at position `pos` is inactive while the DUT occupies
   -- that position or while it is not connected (its SO stays high so it
   -- never grants downstream).
   -- =====================================================================
   peers : for pos in 0 to 3 generate
      peer_unit : process
         variable period   : time;
         variable observed : std_logic_vector(15 downto 0);
         variable slot     : natural;
         variable polls    : natural;

         impure function peer_si return std_logic is
         begin
            if pos = 0 then
               return '0';
            end if;
            if pos - 1 = dut_pos then
               if so_oe = '1' then
                  return so_out;
               else
                  return '1';
               end if;
            end if;
            return peer_so(pos - 1);
         end function;

         procedure poll_clk is
         begin
            wait until rising_edge(clk);
            polls := polls + 1;
            assert polls < POLL_LIMIT
               report "Peer " & integer'image(pos) & " stuck polling"
               severity failure;
         end procedure;

         procedure await_frame_start is
         begin
            while to_x01(cable_sc) /= '0' loop
               poll_clk;
            end loop;
         end procedure;

         procedure await_frame_end is
         begin
            while to_x01(cable_sc) /= '1' loop
               poll_clk;
            end loop;
         end procedure;

         procedure await_word_or_end is
         begin
            while to_x01(cable_sd) /= '0' and to_x01(cable_sc) /= '1' loop
               poll_clk;
            end loop;
         end procedure;

         procedure await_grant_or_end is
         begin
            while peer_si /= '0' and to_x01(cable_sc) /= '1' loop
               poll_clk;
            end loop;
         end procedure;

         procedure await_next_start_or_end is
         begin
            while to_x01(cable_sd) /= '0' and to_x01(cable_sc) /= '1' loop
               poll_clk;
            end loop;
         end procedure;

         -- GHDL gives each generate instance a driver for the whole vector.
         -- Keep every bit except our own parked at 'Z' so each bit's owner
         -- is its sole effective driver.
         procedure set_so(v : std_logic; dly : time := 0 ns) is
            variable vec : std_logic_vector(0 to 3) := (others => 'Z');
         begin
            vec(pos) := v;
            if dly = 0 ns then
               peer_so <= vec;
            else
               peer_so <= vec after dly;
            end if;
         end procedure;

         procedure idle_high is
         begin
            set_so('1');
            cable_sd <= transport 'Z' after 2 ns;
         end procedure;

         procedure tx_word(word : std_logic_vector(15 downto 0)) is
         begin
            report "PEER " & integer'image(pos) & " tx_word at " & time'image(now);
            cable_sd <= transport '0' after 2 ns;   -- start bit
            wait for period;
            for bit_index in 0 to 15 loop
               cable_sd <= transport word(bit_index) after 2 ns;
               wait for period;
            end loop;
            set_so('0', 1 ns);                      -- grant during stop bit
            report "PEER " & integer'image(pos) & " grant at " & time'image(now);
            cable_sd <= transport '1' after 2 ns;   -- stop bit
            wait for period;
            cable_sd <= transport 'Z' after 2 ns;
         end procedure;

         procedure rx_word(variable sink : out std_logic_vector(15 downto 0)) is
         begin
            -- entered with the start bit on SD
            wait for period / 2;
            assert to_x01(cable_sd) = '0'
               report "Peer " & integer'image(pos) & " framing error"
               severity failure;
            for bit_index in 0 to 15 loop
               wait for period;
               observed(bit_index) := to_x01(cable_sd);
            end loop;
            wait for period;  -- middle of the stop bit
            assert to_x01(cable_sd) = '1'
               report "Peer " & integer'image(pos) & " missing stop bit"
               severity failure;
            wait for period / 2;  -- drain the stop bit to the word boundary
            sink := observed;
         end procedure;

      begin
         idle_high;
         loop
            polls := 0;
            wait until peer_start = '1' or to_x01(cable_sc) = '0' or
                     pos = not_ready_pos or pos >= player_count or
                     pos = dut_pos;
            -- Read the period after the wait: baud may have just changed.
            period := IDEAL_BIT_PERIOD(baud);
            polls := 0;
            if pos >= player_count or pos = dut_pos then
               -------------------------------------- unconnected / DUT seat
               set_so('1');
               if to_x01(cable_sc) = '0' then
                  await_frame_end;
               end if;
            elsif pos = not_ready_pos then
               ----------------------------------------- not ready console
               set_so('1');
               cable_sd <= transport '0' after 2 ns;
               wait until not_ready_pos /= pos;
               idle_high;
               -- participate again from the next frame on
               await_frame_start;
               await_frame_end;
            elsif pos = 0 then
               ------------------------------------------ scripted parent
               -- loop-top wait already synchronized on peer_start
               cable_sc <= transport '0' after 2 ns;
               tx_word(words(0));
               for slot in 1 to 3 loop
                  exit when slot >= player_count;
                  -- strict hardware window for the next child's start bit
                  wait until to_x01(cable_sd) = '0'
                     for IDEAL_BIT_PERIOD(baud) * PEER_TIMEOUT_BITS;
                  exit when to_x01(cable_sd) /= '0';
                  rx_word(observed);
                  assert observed = words(slot)
                     report "Scripted parent wrong word in slot " &
                        integer'image(slot) severity failure;
               end loop;
               cable_sc <= transport 'Z' after 2 ns;
               set_so('1', 1 ns);
               while peer_start = '1' loop
                  poll_clk;
               end loop;
            else
               ------------------------------------------- scripted child
               await_frame_start;
               slot := 0;
               while slot < pos loop
                  await_word_or_end;
                  exit when to_x01(cable_sc) = '1';
                  rx_word(observed);
                  assert observed = words(slot)
                     report "Peer child " & integer'image(pos) &
                        " wrong word in slot " & integer'image(slot)
                     severity failure;
                  slot := slot + 1;
               end loop;
               if to_x01(cable_sc) = '0' then
                  if peer_si = '0' then
                     -- grant arrived in time: back-to-back, like hardware
                     tx_word(words(pos));
                  else
                     await_grant_or_end;
                     if to_x01(cable_sc) = '0' then
                        wait for IDEAL_BIT_PERIOD(baud); -- late-grant reaction
                        tx_word(words(pos));
                     end if;
                  end if;
                  while to_x01(cable_sc) = '0' loop
                     await_next_start_or_end;
                     exit when to_x01(cable_sc) = '1';
                     rx_word(observed);
                  end loop;
               end if;
               set_so('1', 1 ns);
            end if;
         end loop;
      end process;
   end generate;

   -- =====================================================================
   stimulus : process
      variable polls : natural;

      procedure clocks(count : positive) is
      begin
         for i in 1 to count loop
            wait until rising_edge(clk);
         end loop;
         wait for 1 ns;
      end procedure;

      procedure poll_clk is
      begin
         wait until rising_edge(clk);
         polls := polls + 1;
         assert polls < POLL_LIMIT
            report "Stimulus stuck polling" severity failure;
      end procedure;

      procedure await_sc(level : std_logic) is
      begin
         while to_x01(cable_sc) /= level loop
            poll_clk;
         end loop;
      end procedure;

      procedure write_reg(address, value : natural) is
      begin
         wait until falling_edge(clk);
         bus_dut.Adr <= std_logic_vector(to_unsigned(address, proc_busadr));
         bus_dut.Din <= std_logic_vector(to_unsigned(value, 32));
         bus_dut.rnw <= '0';
         bus_dut.bEna <= "0011";
         bus_dut.ena <= '1';
         clocks(1);
         bus_dut.ena <= '0';
         bus_dut.rnw <= '1';
         clocks(3);
      end procedure;

      procedure read_reg(address : natural; variable value : out std_logic_vector(31 downto 0)) is
      begin
         wait until falling_edge(clk);
         bus_dut.Adr <= std_logic_vector(to_unsigned(address, proc_busadr));
         bus_dut.rnw <= '1';
         bus_dut.ena <= '1';
         bus_dut.acc <= ACCESS_32BIT;
         clocks(1);
         value := bus_dut.Dout;
         bus_dut.ena <= '0';
         clocks(1);
      end procedure;

      procedure program_dut(speed : natural) is
      begin
         bus_dut.rst <= '1';
         clocks(8);
         bus_dut.rst <= '0';
         write_reg(16#128#, 16#6000# + speed);
         -- Parent-role qualification requires a long stable idle signature.
         wait for 17000 * NATIVE_PERIOD;
      end procedure;

      -- Runs one full cable exchange with the current words and checks the
      -- DUT exactly like a game would after the frame ends.
      procedure run_exchange(check_slots : boolean := true) is
         variable readback : std_logic_vector(31 downto 0);
         variable exp_low, exp_high : std_logic_vector(31 downto 0);
      begin
         monitor_reset <= '1';
         clocks(4);
         monitor_reset <= '0';
         polls := 0;
         if dut_pos = 0 then
            write_reg(16#12A#, to_integer(unsigned(words(0))));
            write_reg(16#128#, 16#6000# + baud);
            write_reg(16#128#, 16#6080# + baud);
         else
            write_reg(16#12A#, to_integer(unsigned(words(dut_pos))));
            write_reg(16#128#, 16#6000# + baud);
            peer_start <= '1', '0' after 100 ns;
         end if;

         await_sc('0');
         await_sc('1');
         clocks(20);

         read_reg(16#128#, readback);
         assert readback(7) = '0'
            report "Busy remained set after the frame" severity failure;
         assert readback(6) = '0'
            report "Unexpected multiplayer error flag: SIOCNT=" &
               to_hstring(readback) severity failure;
         if dut_pos = 0 then
            assert unsigned(readback(5 downto 4)) = 0
               report "Parent ID mismatch: SIOCNT=" &
                  to_hstring(readback) severity failure;
            assert readback(2) = '0'
               report "Parent SI-terminal bit incorrect: SIOCNT=" &
                  to_hstring(readback) severity failure;
         else
            assert unsigned(readback(5 downto 4)) = dut_pos
               report "Cable-position ID mismatch: got " &
                  integer'image(to_integer(unsigned(readback(5 downto 4)))) &
                  " want " & integer'image(dut_pos) &
                  " (SIOCNT=" & to_hstring(readback) & ")" severity failure;
            assert readback(2) = '1'
               report "Child SI-terminal bit incorrect: SIOCNT=" &
                  to_hstring(readback) severity failure;
         end if;
         assert irq_count = 1
            report "Expected exactly one completion IRQ, got " &
               integer'image(irq_count) severity failure;

         if check_slots then
            exp_low := words(1) & words(0);
            exp_high := x"FFFFFFFF";
            if player_count >= 3 then
               exp_high(15 downto 0) := words(2);
            end if;
            if player_count = 4 then
               exp_high(31 downto 16) := words(3);
            end if;
            read_reg(16#120#, readback);
            assert readback = exp_low
               report "SIOMULTI0/1 mismatch at position " &
                  integer'image(dut_pos) & ": got " & to_hstring(readback) &
                  " want " & to_hstring(exp_low) severity failure;
            read_reg(16#124#, readback);
            assert readback = exp_high
               report "SIOMULTI2/3 mismatch at position " &
                  integer'image(dut_pos) & ": got " & to_hstring(readback) &
                  " want " & to_hstring(exp_high) severity failure;
         end if;
      end procedure;

      procedure check_join_slots is
         variable readback : std_logic_vector(31 downto 0);
      begin
         read_reg(16#120#, readback);
         assert readback = words(1) & words(0)
            report "Discovery slots 0/1 mismatch after join" severity failure;
         read_reg(16#124#, readback);
         assert readback(15 downto 0) = words(2)
            report "Joined slave did not land in slot 2" severity failure;
         assert readback(31 downto 16) = x"FFFF"
            report "Empty slot 3 was not FFFF" severity failure;
      end procedure;

   begin
      for speed in 0 to 3 loop
         for count in 2 to 4 loop
            for pos in 0 to count-1 loop
               baud <= speed;
               player_count <= count;
               dut_pos <= pos;
               not_ready_pos <= -1;
               program_dut(speed);

               for exchange in 0 to 1 loop
                  for i in 0 to 3 loop
                     words(i) <= std_logic_vector(to_unsigned(
                        (16#A55A# + i * 16#1729# + exchange * 16#3187#) mod 65536,
                        16));
                  end loop;
                  wait for 1 us;
                  report "HW-timing exchange: " & integer'image(count) &
                     " players, baud " & integer'image(speed) &
                     ", DUT at " & integer'image(pos) &
                     ", exchange " & integer'image(exchange);
                  run_exchange;
               end loop;
            end loop;
         end loop;
      end loop;

      report "PASS: Pocket at every cable position, 2/3/4 players, all baud rates";
      stop;
      wait;
   end process;

   watchdog : process
   begin
      wait for 600 ms;
      assert false
         report "Hardware-timing multiplayer testbench watchdog expired"
         severity failure;
      wait;
   end process;

end architecture;
