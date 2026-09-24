library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

use work.pProc_bus_gba.all;

-- Exercise the public register/pin interface, with the cable's shared SC/SD
-- buses and chained SO -> SI connections. No internal DUT signals are used.
entity tb_gba_serial_multiplayer is
end entity;

architecture test of tb_gba_serial_multiplayer is
   constant CLOCK_PERIOD : time := 10 ns;
   constant NATIVE_PERIOD : time := 6 * CLOCK_PERIOD;
   type time_array is array (0 to 3) of time;
   constant BIT_PERIOD : time_array := (
      1748 * NATIVE_PERIOD, 437 * NATIVE_PERIOD,
       292 * NATIVE_PERIOD, 146 * NATIVE_PERIOD);
   type bus_array is array (0 to 3) of proc_bus_gb_type;
   type integer_array is array (0 to 3) of natural;
   type word_array is array (0 to 3) of std_logic_vector(15 downto 0);
   signal buses : bus_array := (others => (
      Din => (others => '0'), Dout => (others => 'Z'), Adr => (others => '0'),
      rnw => '1', ena => '0', done => 'Z', acc => ACCESS_16BIT,
      bEna => "0011", rst => '1'));
   signal clk : std_logic := '0';
   signal native_tick : std_logic := '0';
   signal connected_count : natural range 1 to 4 := 2;
   signal baud : natural range 0 to 3 := 0;
   signal sc, sd : std_logic := 'H';
   signal so_out, so_oe, si_out, si_oe, sd_out, sd_oe, sc_out, sc_oe : std_logic_vector(0 to 3);
   signal so_in, si_in, sd_in, sc_in, irq, active : std_logic_vector(0 to 3);
   signal abort_wire : std_logic_vector(0 to 3) := (others => '0');
   signal monitor_reset : std_logic := '1';
   signal checking : std_logic := '0';
   signal irq_count, tx_count : integer_array := (others => 0);
   signal wire_words : word_array := (others => x"FFFF");
   signal words : word_array := (x"A55A", x"0FF0", x"81C3", x"369C");

begin
   clk <= not clk after CLOCK_PERIOD / 2;
   process(clk)
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

   sc <= 'H';
   sd <= 'H';
   nodes : for i in 0 to 3 generate
      sc <= sc_out(i) when i < connected_count and sc_oe(i) = '1' else 'Z';
      sd <= sd_out(i) when i < connected_count and sd_oe(i) = '1' else 'Z';
      sc_in(i) <= to_x01(sc) when i < connected_count else '1';
      sd_in(i) <= to_x01(sd) when i < connected_count else '1';
      so_in(i) <= so_out(i) when so_oe(i) = '1' else '1';
      parent : if i = 0 generate
         si_in(i) <= '0';
      end generate;
      child : if i > 0 generate
         si_in(i) <= so_out(i-1) when i < connected_count and so_oe(i-1) = '1' else '1';
      end generate;

      dut : entity work.gba_serial
         port map (
            clk100 => clk, gb_bus => buses(i), new_cycles => to_unsigned(1, 8),
            new_cycles_valid => native_tick, new_exact_cycle => native_tick,
            serial_abort => abort_wire(i), IRP_Serial => irq(i), serial_link_active => active(i),
            serial_so_out => so_out(i), serial_so_oe => so_oe(i), serial_so_in => so_in(i),
            serial_si_out => si_out(i), serial_si_oe => si_oe(i), serial_si_in => si_in(i),
            serial_sd_out => sd_out(i), serial_sd_oe => sd_oe(i), serial_sd_in => sd_in(i),
            serial_sc_out => sc_out(i), serial_sc_oe => sc_oe(i), serial_sc_in => sc_in(i));

      -- A separate UART observer decodes each transmitted frame from the
      -- resolved cable, checking framing and the send-register snapshot.
      decode_wire : process
         variable observed : std_logic_vector(15 downto 0);
         variable expected : std_logic_vector(15 downto 0);
         variable period : time;
      begin
         wait until sd_oe(i) = '1';
         if checking = '1' and i < connected_count then
            expected := words(i);
            period := BIT_PERIOD(baud);
            wait for period / 2;
            assert to_x01(sd) = '0' report "UART start bit missing" severity failure;
            for bit_index in 0 to 15 loop
               wait for period;
               observed(bit_index) := to_x01(sd);
            end loop;
            wait for period;
            assert to_x01(sd) = '1' report "UART stop bit missing" severity failure;
            assert observed = expected report "Wire word does not match latched send word for node " & integer'image(i) severity failure;
            wire_words(i) <= observed;
         end if;
      end process;
   end generate;

   monitor : process(clk)
      variable old_oe, old_so : std_logic_vector(0 to 3) := (others => '0');
      variable finished : std_logic_vector(0 to 3) := (others => '0');
      variable next_sender, drivers : natural := 0;
   begin
      if rising_edge(clk) then
         -- Count every IRQ, including during abort/error scenarios where the
         -- successful-transfer wire assertions are deliberately disabled.
         for i in 0 to 3 loop
            if irq(i) = '1' then
               irq_count(i) <= irq_count(i) + 1;
            end if;
         end loop;
         if monitor_reset = '1' then
            irq_count <= (others => 0);
            tx_count <= (others => 0);
            old_oe := (others => '0');
            old_so := (others => '1');
            finished := (others => '0');
            next_sender := 0;
         elsif checking = '1' then
            drivers := 0;
            assert to_x01(sc) /= 'X' and to_x01(sd) /= 'X' report "Contention on shared cable" severity failure;
            for i in 0 to connected_count-1 loop
               if irq(i) = '1' then
                  assert to_x01(sc) = '1' report "IRQ before parent ended the transfer" severity failure;
               end if;
               assert si_oe(i) = '0' report "Multiplayer must not drive SI" severity failure;
               if i > 0 then
                  assert sc_oe(i) = '0' report "Child drove shared SC" severity failure;
               end if;
               if sd_oe(i) = '1' then
                  drivers := drivers + 1;
                  assert so_out(i) = '1' report "SO handed off before local word finished" severity failure;
                  if old_oe(i) = '0' then
                     assert i = next_sender report "Cable slot transmitted out of order" severity failure;
                     assert tx_count(i) = 0 report "Node transmitted more than once in one exchange" severity failure;
                     tx_count(i) <= tx_count(i) + 1;
                     next_sender := next_sender + 1;
                  end if;
               elsif old_oe(i) = '1' then
                  finished(i) := '1';
               end if;
               if old_so(i) = '1' and so_out(i) = '0' then
                  assert finished(i) = '1' report "SO handoff preceded own transmission" severity failure;
               end if;
               if finished(i) = '1' and to_x01(sc) = '0' then
                  assert so_out(i) = '0' report "Completed node did not retain downstream handoff" severity failure;
               end if;
               old_oe(i) := sd_oe(i);
               old_so(i) := so_out(i);
            end loop;
            assert drivers <= 1 report "Multiple consoles drive SD simultaneously" severity failure;
         end if;
      end if;
   end process;

   stimulus : process
      procedure clocks(count : positive) is
      begin
         for i in 1 to count loop
            wait until rising_edge(clk);
         end loop;
         wait for 1 ns;
      end procedure;

      procedure write_reg(signal ports : inout bus_array; node, address, value : natural;
                          bytes : std_logic_vector(3 downto 0) := "0011") is
      begin
         wait until falling_edge(clk);
         ports(node).Adr <= std_logic_vector(to_unsigned(address, proc_busadr));
         ports(node).Din <= std_logic_vector(to_unsigned(value, 32));
         ports(node).rnw <= '0';
         ports(node).bEna <= bytes;
         ports(node).ena <= '1';
         clocks(1);
         ports(node).ena <= '0';
         ports(node).rnw <= '1';
         clocks(3);
      end procedure;

      procedure read_reg(signal ports : inout bus_array; node, address : natural;
                         variable value : out std_logic_vector(31 downto 0)) is
      begin
         wait until falling_edge(clk);
         ports(node).Adr <= std_logic_vector(to_unsigned(address, proc_busadr));
         ports(node).rnw <= '1';
         ports(node).ena <= '1';
         ports(node).acc <= ACCESS_32BIT;
         clocks(1);
         value := ports(node).Dout;
         ports(node).ena <= '0';
         clocks(1);
      end procedure;

      procedure setup(count, speed : natural) is
      begin
         checking <= '0';
         monitor_reset <= '1';
         connected_count <= count;
         baud <= speed;
         for i in 0 to 3 loop
            buses(i).rst <= '1';
         end loop;
         clocks(8);
         for i in 0 to 3 loop
            buses(i).rst <= '0';
         end loop;
         for i in 0 to count-1 loop
            write_reg(buses, i, 16#128#, 16#6000# + speed);
         end loop;
         -- The existing parent-role qualification is 16384 native ticks.
         wait for 17000 * NATIVE_PERIOD;
         clocks(8);
      end procedure;

      variable readback, expected_low, expected_high : std_logic_vector(31 downto 0);
      variable expected_words : word_array;
   begin
      for speed in 0 to 3 loop
         for count in 2 to 4 loop
            setup(count, speed);
            for exchange in 0 to 1 loop
               report "Cable test: " & integer'image(count) & " players, baud index " & integer'image(speed) & ", exchange " & integer'image(exchange);
               for i in 0 to 3 loop
                  expected_words(i) := std_logic_vector(to_unsigned((16#A55A# + i * 16#1729# + exchange * 16#3187#) mod 65536, 16));
               end loop;
               words <= expected_words;
               for i in 0 to count-1 loop
                  write_reg(buses, i, 16#12A#, to_integer(unsigned(expected_words(i))));
               end loop;
               monitor_reset <= '1';
               clocks(4);
               monitor_reset <= '0';
               checking <= '1';
               write_reg(buses, 0, 16#128#, 16#6080# + speed);
               wait for NATIVE_PERIOD * 8;
               for i in 0 to count-1 loop
                  read_reg(buses, i, 16#128#, readback);
                  assert readback(7) = '1' report "Connected console never became busy" severity failure;
                  read_reg(buses, i, 16#120#, readback);
                  assert readback = x"FFFFFFFF" report "Start did not clear slots 0/1" severity failure;
                  read_reg(buses, i, 16#124#, readback);
                  assert readback = x"FFFFFFFF" report "Start did not clear slots 2/3" severity failure;
               end loop;

               -- Start writes on busy nodes must not restart or cancel their
               -- in-flight state. Changing the send register after SC
               -- falls must affect the next exchange, not this one.
               write_reg(buses, 0, 16#128#, 16#6080# + speed);
               write_reg(buses, 0, 16#12A#, 16#FEED#);
               write_reg(buses, count-1, 16#128#, 16#6080# + speed);
               write_reg(buses, count-1, 16#12A#, 16#1234#);
               wait until to_x01(sc) = '1' for BIT_PERIOD(speed) * 120;
               assert to_x01(sc) = '1' report "Transfer did not complete within bounded wire time" severity failure;
               clocks(40);

               expected_low := expected_words(1) & expected_words(0);
               expected_high := x"FFFFFFFF";
               if count >= 3 then expected_high(15 downto 0) := expected_words(2); end if;
               if count = 4 then expected_high(31 downto 16) := expected_words(3); end if;
               for i in 0 to count-1 loop
                  read_reg(buses, i, 16#128#, readback);
                  assert readback(7) = '0' report "Busy remained set after completion" severity failure;
                  assert readback(6) = '0' report "Unexpected multiplayer error" severity failure;
                  assert unsigned(readback(5 downto 4)) = i report "Incorrect cable-position ID" severity failure;
                  assert readback(2) = '0' or i > 0 report "Parent role bit incorrect" severity failure;
                  assert readback(2) = '1' or i = 0 report "Child role bit incorrect" severity failure;
                  assert irq_count(i) = 1 report "Expected exactly one completion IRQ per console" severity failure;
                  assert tx_count(i) = 1 report "Expected exactly one local word per console" severity failure;
                  assert wire_words(i) = expected_words(i) report "Wire observer missed local word" severity failure;
                  read_reg(buses, i, 16#120#, readback);
                  assert readback = expected_low report "SIOMULTI0/1 readback mismatch for node " & integer'image(i) severity failure;
                  read_reg(buses, i, 16#124#, readback);
                  assert readback = expected_high report "SIOMULTI2/3 readback mismatch for node " & integer'image(i) severity failure;
                  for slot in 0 to 3 loop
                     read_reg(buses, i, 16#120# + 2 * slot, readback);
                     if slot < count then
                        assert readback(15 downto 0) = expected_words(slot) report "Halfword receive alias mismatch" severity failure;
                     else
                        assert readback(15 downto 0) = x"FFFF" report "Absent player slot was not FFFF" severity failure;
                     end if;
                  end loop;
               end loop;
               checking <= '0';
               wait for BIT_PERIOD(speed) * 2;
            end loop;
         end loop;
      end loop;

      -- Abort the whole cable during a live word: no completed transfer/IRQ,
      -- release every pin, clear receive state, then allow a clean restart.
      setup(4, 3);
      for i in 0 to 3 loop
         write_reg(buses, i, 16#12A#, 16#A55A#);
      end loop;
      monitor_reset <= '0';
      write_reg(buses, 0, 16#128#, 16#6083#);
      wait for BIT_PERIOD(3) * 4;
      assert to_x01(sc) = '0' report "Abort scenario did not start" severity failure;
      abort_wire <= (others => '1');
      clocks(8);
      assert sd_oe = "0000" and sc_oe = "0000" and so_oe = "0000" report "Abort did not release link pins" severity failure;
      assert irq = "0000" report "Abort raised an IRQ" severity failure;
      abort_wire <= (others => '0');
      clocks(16);
      for i in 0 to 3 loop
         read_reg(buses, i, 16#128#, readback);
         assert readback(7) = '0' report "Abort retained busy" severity failure;
         read_reg(buses, i, 16#120#, readback);
         assert readback = x"FFFFFFFF" report "Abort retained slots 0/1" severity failure;
         read_reg(buses, i, 16#124#, readback);
         assert readback = x"FFFFFFFF" report "Abort retained slots 2/3" severity failure;
         assert irq_count(i) = 0 report "Abort emitted a completion IRQ" severity failure;
      end loop;

      -- A savestate abort leaves mode configuration in place. Requalify the
      -- parent and exchange new data without resetting any console.
      expected_words := (x"0123", x"4567", x"89AB", x"CDEF");
      words <= expected_words;
      for i in 0 to 3 loop
         write_reg(buses, i, 16#12A#, to_integer(unsigned(expected_words(i))));
      end loop;
      wait for 17000 * NATIVE_PERIOD;
      monitor_reset <= '1';
      clocks(4);
      monitor_reset <= '0';
      checking <= '1';
      write_reg(buses, 0, 16#128#, 16#6083#);
      assert to_x01(sc) = '0' report "Transfer after abort did not start" severity failure;
      wait until to_x01(sc) = '1' for BIT_PERIOD(3) * 120;
      assert to_x01(sc) = '1' report "Transfer after abort did not finish" severity failure;
      clocks(40);
      for i in 0 to 3 loop
         read_reg(buses, i, 16#128#, readback);
         assert readback(7 downto 6) = "00" and unsigned(readback(5 downto 4)) = i
            report "Transfer after abort did not recover status/ID" severity failure;
         assert irq_count(i) = 1 and tx_count(i) = 1 report "Transfer after abort did not complete once" severity failure;
         read_reg(buses, i, 16#120#, readback);
         assert readback = x"45670123" report "Transfer after abort slots 0/1 mismatch" severity failure;
         read_reg(buses, i, 16#124#, readback);
         assert readback = x"CDEF89AB" report "Transfer after abort slots 2/3 mismatch" severity failure;
      end loop;
      checking <= '0';

      -- Preserve the existing no-peer timeout: the absent first child is an
      -- error and does not produce a successful-transfer interrupt.
      setup(1, 3);
      monitor_reset <= '0';
      write_reg(buses, 0, 16#12A#, 16#BEEF#);
      write_reg(buses, 0, 16#128#, 16#6083#);
      wait for BIT_PERIOD(3) * 50;
      read_reg(buses, 0, 16#128#, readback);
      assert readback(7) = '0' and readback(6) = '1' report "No-peer timeout behavior changed" severity failure;
      assert irq_count(0) = 0 report "No-peer timeout raised an IRQ" severity failure;

      report "PASS: multiplayer cable, framing, slots, IDs, IRQ, restart, and abort tests";
      stop;
      wait;
   end process;

   watchdog : process
   begin
      wait for 150 ms;
      assert false report "Multiplayer testbench watchdog expired" severity failure;
      wait;
   end process;
end architecture;
