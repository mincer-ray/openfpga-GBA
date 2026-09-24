library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

use work.pProc_bus_gba.all;

-- One physical child against a scripted cable, independent of the DUT UART.
-- Peers can have different clocks and send directly adjacent UART words.
entity tb_gba_serial_multiplayer_peer is
end entity;

architecture test of tb_gba_serial_multiplayer_peer is
   constant CLOCK_PERIOD : time := 10 ns;
   constant NATIVE_PERIOD : time := 6 * CLOCK_PERIOD;
   type time_array is array (0 to 3) of time;
   constant DUT_BIT_PERIOD : time_array := (
      1748 * NATIVE_PERIOD, 437 * NATIVE_PERIOD,
       292 * NATIVE_PERIOD, 146 * NATIVE_PERIOD);
   constant IDEAL_BIT_PERIOD : time_array := (
      (NATIVE_PERIOD * 16777216) / 9600,
      (NATIVE_PERIOD * 16777216) / 38400,
      (NATIVE_PERIOD * 16777216) / 57600,
      (NATIVE_PERIOD * 16777216) / 115200);
   type word_array is array (0 to 3) of std_logic_vector(15 downto 0);
   constant WORDS : word_array := (x"25A5", x"563C", x"3196", x"4B69");
   signal ports : proc_bus_gb_type := (
      Din => (others => '0'), Dout => (others => 'Z'), Adr => (others => '0'),
      rnw => '1', ena => '0', done => 'Z', acc => ACCESS_16BIT,
      bEna => "0011", rst => '1');
   signal clk : std_logic := '0';
   signal native_tick : std_logic := '0';
   signal cable_sc : std_logic := '1';
   signal cable_si : std_logic := '1';
   signal peer_sd : std_logic := 'Z';
   signal cable_sd : std_logic := 'H';
   signal so_out, so_oe, si_out, si_oe, sd_out, sd_oe, sc_out, sc_oe : std_logic;
   signal irq, active : std_logic;
   signal monitor_reset : std_logic := '1';
   signal irq_count, tx_count : natural := 0;
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

   cable_sd <= 'H';
   cable_sd <= peer_sd;
   cable_sd <= sd_out when sd_oe = '1' else 'Z';
   dut : entity work.gba_serial
      port map (
         clk100 => clk, gb_bus => ports, new_cycles => to_unsigned(1, 8),
         new_cycles_valid => native_tick, new_exact_cycle => native_tick,
         serial_abort => '0', IRP_Serial => irq, serial_link_active => active,
         serial_so_out => so_out, serial_so_oe => so_oe, serial_so_in => so_out,
         serial_si_out => si_out, serial_si_oe => si_oe, serial_si_in => cable_si,
         serial_sd_out => sd_out, serial_sd_oe => sd_oe, serial_sd_in => to_x01(cable_sd),
         serial_sc_out => sc_out, serial_sc_oe => sc_oe, serial_sc_in => cable_sc);

   monitor : process(clk)
      variable old_oe : std_logic := '0';
   begin
      if rising_edge(clk) then
         if monitor_reset = '1' then
            irq_count <= 0;
            tx_count <= 0;
            old_oe := '0';
         else
            assert sc_oe = '0' and si_oe = '0'
               report "Scripted child drove SC or SI" severity failure;
            assert to_x01(cable_sd) /= 'X'
               report "Scripted peer/DUT contention on SD" severity failure;
            if sd_oe = '1' then
               assert so_out = '1'
                  report "Child granted downstream turn before finishing TX" severity failure;
               assert peer_sd = 'Z'
                  report "Child overlapped a scripted peer's word" severity failure;
               if old_oe = '0' then
                  tx_count <= tx_count + 1;
               end if;
            end if;
            if irq = '1' then
               irq_count <= irq_count + 1;
               assert cable_sc = '1'
                  report "Child IRQ before physical SC completion" severity failure;
            end if;
            old_oe := sd_oe;
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

      procedure write_reg(address, value : natural) is
      begin
         wait until falling_edge(clk);
         ports.Adr <= std_logic_vector(to_unsigned(address, proc_busadr));
         ports.Din <= std_logic_vector(to_unsigned(value, 32));
         ports.rnw <= '0';
         ports.bEna <= "0011";
         ports.ena <= '1';
         clocks(1);
         ports.ena <= '0';
         ports.rnw <= '1';
         clocks(3);
      end procedure;

      procedure read_reg(address : natural; variable value : out std_logic_vector(31 downto 0)) is
      begin
         wait until falling_edge(clk);
         ports.Adr <= std_logic_vector(to_unsigned(address, proc_busadr));
         ports.rnw <= '1';
         ports.ena <= '1';
         ports.acc <= ACCESS_32BIT;
         clocks(1);
         value := ports.Dout;
         ports.ena <= '0';
         clocks(1);
      end procedure;

      procedure setup(speed, local_id : natural) is
      begin
         monitor_reset <= '1';
         cable_sc <= '1';
         cable_si <= '1';
         peer_sd <= 'Z';
         ports.rst <= '1';
         clocks(8);
         ports.rst <= '0';
         clocks(4);
         write_reg(16#128#, 16#6000# + speed);
         write_reg(16#12A#, to_integer(unsigned(WORDS(local_id))));
         clocks(12);
         monitor_reset <= '0';
         clocks(4);
      end procedure;

      procedure send_word(slot : natural; period : time; bad_stop : boolean := false) is
      begin
         peer_sd <= '0';
         wait for period;
         for bit_index in 0 to 15 loop
            peer_sd <= WORDS(slot)(bit_index);
            wait for period;
         end loop;
         if bad_stop then
            peer_sd <= '0';
         else
            peer_sd <= '1';
         end if;
         wait for period;
      end procedure;

      procedure receive_local(slot, speed : natural; early_sc : boolean) is
         variable observed : std_logic_vector(15 downto 0);
         constant period : time := DUT_BIT_PERIOD(speed);
      begin
         peer_sd <= 'Z';
         cable_si <= '0';
         wait until sd_oe = '1' for 3 * period;
         assert sd_oe = '1' report "Child did not take its granted slot" severity failure;
         wait for period / 2;
         assert to_x01(cable_sd) = '0' report "Missing local start bit" severity failure;
         for bit_index in 0 to 15 loop
            wait for period;
            observed(bit_index) := to_x01(cable_sd);
         end loop;
         wait for period;
         assert to_x01(cable_sd) = '1' report "Missing local stop bit" severity failure;
         assert observed = WORDS(slot)
            report "Local transmitted word mismatch" severity failure;
         if early_sc then
            -- SC can finish in the final child's stop cell before it retires TX.
            cable_sc <= '1';
         end if;
         wait until sd_oe = '0' for 2 * period;
         assert sd_oe = '0' report "Child failed to release SD" severity failure;
         wait for 1 ns;
         if not early_sc then
            assert so_out = '0'
               report "Child failed to grant downstream turn after TX" severity failure;
         end if;
      end procedure;

      procedure check_completion(local_id : natural; expect_error : boolean;
                                 check_words : boolean := true; expect_tx : natural := 1) is
         variable value : std_logic_vector(31 downto 0);
      begin
         peer_sd <= 'Z';
         cable_sc <= '1';
         clocks(20);
         read_reg(16#128#, value);
         assert value(7) = '0' report "Child remained busy after SC rose" severity failure;
         if expect_error then
            assert value(6) = '1' report "Missing multiplayer error flag" severity failure;
         else
            assert value(6) = '0' report "Unexpected multiplayer error flag" severity failure;
            assert unsigned(value(5 downto 4)) = local_id
               report "Scripted cable position/ID mismatch" severity failure;
         end if;
         assert irq_count = 1 report "Child must produce one completion IRQ" severity failure;
         assert tx_count = expect_tx report "Unexpected number of local UART transmissions" severity failure;
         assert so_out = '1' and sd_oe = '0' report "Child did not return pins to idle" severity failure;
         if check_words then
            read_reg(16#120#, value);
            assert value = WORDS(1) & WORDS(0)
               report "Scripted slots 0/1 mismatch: got " & to_hstring(value) severity failure;
            read_reg(16#124#, value);
            assert value = WORDS(3) & WORDS(2)
               report "Scripted slots 2/3 mismatch: got " & to_hstring(value) severity failure;
         end if;
      end procedure;

      procedure exchange(local_id, speed : natural; period : time;
                         early_sc : boolean := false; bad_slot : integer := -1) is
      begin
         setup(speed, local_id);
         cable_sc <= '0';
         for slot in 0 to local_id-1 loop
            send_word(slot, period, slot = bad_slot);
         end loop;
         receive_local(local_id, speed, early_sc);
         for slot in local_id+1 to 3 loop
            send_word(slot, period, slot = bad_slot);
         end loop;
         check_completion(local_id, bad_slot >= 0);
      end procedure;

      variable period : time;
   begin
      for skew in 0 to 2 loop
         for speed in 0 to 3 loop
            period := IDEAL_BIT_PERIOD(speed);
            if skew = 1 then
               period := period * 99 / 100;
            elsif skew = 2 then
               period := period * 101 / 100;
            end if;
            for local_id in 1 to 3 loop
               report "Scripted peer: child " & integer'image(local_id) &
                  ", baud index " & integer'image(speed) & ", skew case " & integer'image(skew);
               exchange(local_id, speed, period);
            end loop;
         end loop;
      end loop;

      report "Scripted final-child early SC during TX stop cell";
      exchange(3, 3, IDEAL_BIT_PERIOD(3), true);

      report "Scripted bad stop bit before local slot";
      exchange(2, 3, IDEAL_BIT_PERIOD(3), false, 1);
      report "Scripted bad stop bit after local slot";
      exchange(1, 3, IDEAL_BIT_PERIOD(3), false, 2);

      report "Scripted missing SI handoff";
      setup(3, 3);
      cable_sc <= '0';
      for slot in 0 to 3 loop
         send_word(slot, IDEAL_BIT_PERIOD(3));
      end loop;
      check_completion(3, true, false, 0);

      report "PASS: independent multiplayer peer, all child positions/baud rates, clock skew, stop and token errors";
      stop;
      wait;
   end process;

   watchdog : process
   begin
      wait for 250 ms;
      assert false report "Independent peer test timed out" severity failure;
   end process;
end architecture;
