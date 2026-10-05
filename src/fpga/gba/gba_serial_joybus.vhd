library IEEE;
use IEEE.std_logic_1164.all;

package p_gba_serial_joybus is
   -- command_kind values accompanying command_complete.
   constant JOYBUS_COMMAND_RESET  : std_logic_vector(1 downto 0) := "00";
   constant JOYBUS_COMMAND_STATUS : std_logic_vector(1 downto 0) := "01";
   constant JOYBUS_COMMAND_WRITE  : std_logic_vector(1 downto 0) := "10";
   constant JOYBUS_COMMAND_READ   : std_logic_vector(1 downto 0) := "11";
end package;

library IEEE;
use IEEE.std_logic_1164.all;

use work.p_gba_serial_joybus.all;

entity gba_serial_joybus is
   port
   (
      clk100            : in  std_logic;
      reset             : in  std_logic;
      enable            : in  std_logic;
      new_exact_cycle   : in  std_logic;

      -- SI must already have been synchronized into the clk100 domain.
      si_in             : in  std_logic;

      -- CPU-owned state is sampled atomically when a valid command is
      -- accepted, before the response starts.
      joystat_in        : in  std_logic_vector(7 downto 0);
      joy_trans_in      : in  std_logic_vector(31 downto 0);

      -- JoyBus mode initially uses the GBA's actively-driven-high idle
      -- policy.  OE is nevertheless explicit so the central pin mux can
      -- release SO on reset, mode exit, or for a later idle-policy A/B test.
      so_out            : out std_logic := '1';
      so_oe             : out std_logic := '0';

      -- A Data Write word is accepted only after the command, all four
      -- payload bytes, and the host stop have been validated.  Bytes arrive
      -- least-significant first and are reordered into the CPU word here.
      recv_accept       : out std_logic := '0';
      recv_data         : out std_logic_vector(31 downto 0) := (others => '0');

      -- Pulses in the cycle where a Data Read atomically snapshots
      -- joy_trans_in.  The register owner uses this boundary to distinguish a
      -- newly queued CPU word from the word already being returned.
      read_accept       : out std_logic := '0';

      -- One pulse follows the final transmitted stop cell.  STATUS is also
      -- reported; the register owner decides which kinds set flags or IRQs.
      command_complete  : out std_logic := '0';
      command_kind      : out std_logic_vector(1 downto 0) := JOYBUS_COMMAND_STATUS
   );
end entity;

architecture arch of gba_serial_joybus is

   -- clk100 receive windows.  The nominal clock is 100.663296 MHz, so the
   -- supported 4 us and 5 us host cells are approximately 403 and 503 clocks.
   -- The wide total-cell window admits both sources and useful edge jitter;
   -- the pulse minimum prevents narrow cable/translator glitches becoming
   -- protocol bits.  Bit value is deliberately ratio-decoded below.
   constant RX_MIN_CELL_CLK100       : integer := 240;
   constant RX_MAX_CELL_CLK100       : integer := 704;
   constant RX_MIN_PULSE_CLK100      : integer := 40;
   constant RX_MAX_STOP_LOW_CLK100   : integer := 704;

   -- Response timing is expressed in native 16.777216 MHz ticks.  This is
   -- the profile proven by Game Bub on a real GameCube: one 64-tick cell,
   -- four 16-tick quarters, one cell of turnaround, and one low stop cell.
   constant TX_CELL_NATIVE_TICKS     : integer := 64;
   constant TX_QUARTER_NATIVE_TICKS  : integer := 16;
   constant TX_TURN_NATIVE_TICKS     : integer := 64;
   constant TX_STOP_NATIVE_TICKS     : integer := 64;

   -- A malformed/unknown frame must see this much uninterrupted idle before
   -- reception is armed again.  The same interval bounds missing cable
   -- feedback while transmitting (about 61 us).
   constant RECOVERY_IDLE_NATIVE_TICKS : integer := 1024;
   constant FEEDBACK_NATIVE_TICKS      : integer := 1024;

   constant JOYBUS_OPCODE_RESET      : std_logic_vector(7 downto 0) := x"FF";
   constant JOYBUS_OPCODE_STATUS     : std_logic_vector(7 downto 0) := x"00";
   constant JOYBUS_OPCODE_WRITE      : std_logic_vector(7 downto 0) := x"15";
   constant JOYBUS_OPCODE_READ       : std_logic_vector(7 downto 0) := x"14";

   type joybus_state_type is
   (
      STATE_IDLE,
      STATE_RX_LOW,
      STATE_RX_HIGH,
      STATE_RX_STOP_LOW,
      STATE_TX_TURNAROUND,
      STATE_TX_BITS,
      STATE_TX_STOP,
      STATE_RECOVER
   );

   signal state                 : joybus_state_type := STATE_IDLE;
   signal si_previous           : std_logic := '1';

   signal rx_low_count          : integer range 0 to RX_MAX_CELL_CLK100 + 1 := 0;
   signal rx_high_count         : integer range 0 to RX_MAX_CELL_CLK100 + 1 := 0;
   signal rx_bit_count          : integer range 0 to 39 := 0;
   signal rx_shift              : std_logic_vector(39 downto 0) := (others => '0');
   signal command_latched       : std_logic_vector(7 downto 0) := (others => '0');

   signal native_count          : integer range 0 to RECOVERY_IDLE_NATIVE_TICKS - 1 := 0;
   signal feedback_count        : integer range 0 to FEEDBACK_NATIVE_TICKS - 1 := 0;

   signal tx_shift              : std_logic_vector(39 downto 0) := (others => '1');
   signal tx_bits_left          : integer range 0 to 40 := 0;
   signal tx_cell_count         : integer range 0 to TX_CELL_NATIVE_TICKS - 1 := 0;

begin

   -- JoyBus defines SO as an output.  Keep the initial active-high idle
   -- policy isolated here so integration can later choose to gate this OE.
   so_oe <= enable and not reset;

   -- Each transmit bit is 16 ticks low, 32 ticks equal to the data bit, then
   -- 16 ticks high.  The response stop is a separate 64-tick low cell.
   so_out <=
      '0' when state = STATE_TX_STOP else
      '0' when state = STATE_TX_BITS and
                   tx_cell_count < TX_QUARTER_NATIVE_TICKS else
      tx_shift(39) when state = STATE_TX_BITS and
                        tx_cell_count < (3 * TX_QUARTER_NATIVE_TICKS) else
      '1';

   read_accept <= '1' when enable = '1' and reset = '0' and
                           state = STATE_TX_TURNAROUND and
                           command_latched = JOYBUS_OPCODE_READ and
                           si_in = '1' and new_exact_cycle = '1' and
                           native_count = TX_TURN_NATIVE_TICKS - 1 else
                  '0';

   process (clk100)
      variable decoded_bit    : std_logic;
      variable shifted_rx     : std_logic_vector(39 downto 0);
      variable completed_byte : std_logic_vector(7 downto 0);
      variable status_snapshot: std_logic_vector(7 downto 0);
   begin
      if rising_edge(clk100) then
         -- Event outputs are pulses.  Their payload/kind registers retain the
         -- last value so the consuming register block has the whole cycle to
         -- sample them.
         recv_accept      <= '0';
         command_complete <= '0';
         si_previous      <= si_in;

         if (reset = '1' or enable = '0') then
            state           <= STATE_IDLE;
            rx_low_count    <= 0;
            rx_high_count   <= 0;
            rx_bit_count    <= 0;
            rx_shift        <= (others => '0');
            command_latched <= (others => '0');
            native_count    <= 0;
            feedback_count  <= 0;
            tx_shift        <= (others => '1');
            tx_bits_left    <= 0;
            tx_cell_count   <= 0;
            recv_data       <= (others => '0');
            command_kind    <= JOYBUS_COMMAND_STATUS;

         else
            case state is
               when STATE_IDLE =>
                  rx_low_count   <= 0;
                  rx_high_count  <= 0;
                  rx_bit_count   <= 0;
                  native_count   <= 0;
                  feedback_count <= 0;

                  -- A falling edge begins the first command bit.
                  if (si_previous = '1' and si_in = '0') then
                     rx_shift       <= (others => '0');
                     rx_low_count   <= 1;
                     state          <= STATE_RX_LOW;
                  end if;

               when STATE_RX_LOW =>
                  if (si_in = '0') then
                     if (rx_low_count >= RX_MAX_CELL_CLK100) then
                        native_count <= 0;
                        state        <= STATE_RECOVER;
                     else
                        rx_low_count <= rx_low_count + 1;
                     end if;
                  else
                     -- This is the low-to-high edge of a command/payload bit.
                     if (rx_low_count < RX_MIN_PULSE_CLK100) then
                        native_count <= 0;
                        state        <= STATE_RECOVER;
                     else
                        rx_high_count <= 1;
                        state         <= STATE_RX_HIGH;
                     end if;
                  end if;

               when STATE_RX_HIGH =>
                  if (si_in = '1') then
                     if ((rx_low_count + rx_high_count) >= RX_MAX_CELL_CLK100) then
                        native_count <= 0;
                        state        <= STATE_RECOVER;
                     else
                        rx_high_count <= rx_high_count + 1;
                     end if;
                  else
                     -- This falling edge closes the previous cell and also
                     -- begins the next data bit (or the host stop bit).
                     if (rx_high_count < RX_MIN_PULSE_CLK100 or
                         (rx_low_count + rx_high_count) < RX_MIN_CELL_CLK100 or
                         (rx_low_count + rx_high_count) > RX_MAX_CELL_CLK100) then
                        native_count <= 0;
                        state        <= STATE_RECOVER;
                     else
                        if (rx_high_count > rx_low_count) then
                           decoded_bit := '1';
                        else
                           decoded_bit := '0';
                        end if;

                        shifted_rx := rx_shift(38 downto 0) & decoded_bit;
                        rx_shift   <= shifted_rx;
                        rx_low_count  <= 1;
                        rx_high_count <= 0;

                        if (rx_bit_count = 7) then
                           completed_byte := shifted_rx(7 downto 0);
                           command_latched <= completed_byte;
                           rx_bit_count <= 8;

                           case completed_byte is
                              when JOYBUS_OPCODE_WRITE =>
                                 -- The current falling edge is payload bit 0.
                                 state <= STATE_RX_LOW;

                              when JOYBUS_OPCODE_RESET |
                                   JOYBUS_OPCODE_STATUS |
                                   JOYBUS_OPCODE_READ =>
                                 -- The current falling edge starts the stop.
                                 state <= STATE_RX_STOP_LOW;

                              when others =>
                                 native_count <= 0;
                                 state        <= STATE_RECOVER;
                           end case;

                        elsif (rx_bit_count = 39) then
                           -- Only Data Write reaches 40 received bits.  The
                           -- current falling edge starts its stop bit.
                           state <= STATE_RX_STOP_LOW;
                        else
                           rx_bit_count <= rx_bit_count + 1;
                           state        <= STATE_RX_LOW;
                        end if;
                     end if;
                  end if;

               when STATE_RX_STOP_LOW =>
                  if (si_in = '0') then
                     if (rx_low_count >= RX_MAX_STOP_LOW_CLK100) then
                        native_count <= 0;
                        state        <= STATE_RECOVER;
                     else
                        rx_low_count <= rx_low_count + 1;
                     end if;
                  else
                     -- The stop must contain a credible low pulse.  Its high
                     -- idle portion is validated throughout turnaround.
                     if (rx_low_count < RX_MIN_PULSE_CLK100) then
                        native_count <= 0;
                        state        <= STATE_RECOVER;
                     else
                        native_count <= 0;
                        state        <= STATE_TX_TURNAROUND;
                     end if;
                  end if;

               when STATE_TX_TURNAROUND =>
                  -- A new low before the complete setup interval invalidates
                  -- the stop/idle period; do not expose any command event.
                  if (si_in = '0') then
                     native_count <= 0;
                     state        <= STATE_RECOVER;
                  elsif (new_exact_cycle = '1') then
                     if (native_count = TX_TURN_NATIVE_TICKS - 1) then
                        native_count   <= 0;
                        tx_cell_count  <= 0;
                        feedback_count <= 0;
                        status_snapshot := joystat_in;

                        -- Place the first wire byte at tx_shift(39 downto 32).
                        -- Shifting left after each cell therefore sends every
                        -- byte MSB-first while preserving byte sequence.
                        case command_latched is
                           when JOYBUS_OPCODE_RESET =>
                              tx_shift     <= x"0004" & status_snapshot & x"0000";
                              tx_bits_left <= 24;
                              command_kind <= JOYBUS_COMMAND_RESET;
                              state        <= STATE_TX_BITS;

                           when JOYBUS_OPCODE_STATUS =>
                              tx_shift     <= x"0004" & status_snapshot & x"0000";
                              tx_bits_left <= 24;
                              command_kind <= JOYBUS_COMMAND_STATUS;
                              state        <= STATE_TX_BITS;

                           when JOYBUS_OPCODE_WRITE =>
                              -- Hardware receive-pending is visible in the
                              -- returned status even though the register owner
                              -- consumes recv_accept on this same edge.
                              status_snapshot(1) := '1';
                              tx_shift     <= status_snapshot & x"00000000";
                              tx_bits_left <= 8;
                              recv_data    <= rx_shift(7 downto 0) &
                                              rx_shift(15 downto 8) &
                                              rx_shift(23 downto 16) &
                                              rx_shift(31 downto 24);
                              recv_accept  <= '1';
                              command_kind <= JOYBUS_COMMAND_WRITE;
                              state        <= STATE_TX_BITS;

                           when JOYBUS_OPCODE_READ =>
                              tx_shift     <= joy_trans_in(7 downto 0) &
                                              joy_trans_in(15 downto 8) &
                                              joy_trans_in(23 downto 16) &
                                              joy_trans_in(31 downto 24) &
                                              status_snapshot;
                              tx_bits_left <= 40;
                              command_kind <= JOYBUS_COMMAND_READ;
                              state        <= STATE_TX_BITS;

                           when others =>
                              -- Defensive: unknown opcodes normally enter
                              -- recovery as soon as the command byte closes.
                              state <= STATE_RECOVER;
                        end case;
                     else
                        native_count <= native_count + 1;
                     end if;
                  end if;

               when STATE_TX_BITS =>
                  if (si_in = '0') then
                     feedback_count <= 0;
                  end if;

                  if (new_exact_cycle = '1') then
                     if (si_in = '1' and
                         feedback_count = FEEDBACK_NATIVE_TICKS - 1) then
                        -- The full recovery-idle interval has already elapsed
                        -- while feedback stayed high, so abandon immediately.
                        native_count   <= 0;
                        feedback_count <= 0;
                        tx_bits_left   <= 0;
                        tx_cell_count  <= 0;
                        state          <= STATE_IDLE;
                     else
                        if (si_in = '1') then
                           feedback_count <= feedback_count + 1;
                        end if;

                        if (tx_cell_count = TX_CELL_NATIVE_TICKS - 1) then
                           tx_cell_count <= 0;
                           if (tx_bits_left = 1) then
                              tx_bits_left <= 0;
                              state        <= STATE_TX_STOP;
                           else
                              tx_shift     <= tx_shift(38 downto 0) & '1';
                              tx_bits_left <= tx_bits_left - 1;
                           end if;
                        else
                           tx_cell_count <= tx_cell_count + 1;
                        end if;
                     end if;
                  end if;

               when STATE_TX_STOP =>
                  if (si_in = '0') then
                     feedback_count <= 0;
                  end if;

                  if (new_exact_cycle = '1') then
                     if (si_in = '1' and
                         feedback_count = FEEDBACK_NATIVE_TICKS - 1) then
                        native_count   <= 0;
                        feedback_count <= 0;
                        tx_bits_left   <= 0;
                        tx_cell_count  <= 0;
                        state          <= STATE_IDLE;
                     else
                        if (si_in = '1') then
                           feedback_count <= feedback_count + 1;
                        end if;

                        if (tx_cell_count = TX_STOP_NATIVE_TICKS - 1) then
                           tx_cell_count    <= 0;
                           tx_bits_left     <= 0;
                           command_complete <= '1';
                           state            <= STATE_IDLE;
                        else
                           tx_cell_count <= tx_cell_count + 1;
                        end if;
                     end if;
                  end if;

               when STATE_RECOVER =>
                  rx_low_count   <= 0;
                  rx_high_count  <= 0;
                  rx_bit_count   <= 0;
                  feedback_count <= 0;
                  tx_bits_left   <= 0;
                  tx_cell_count  <= 0;

                  -- Ignore the remainder of a malformed/unknown frame and
                  -- re-arm only after a deterministic uninterrupted idle.
                  if (new_exact_cycle = '1') then
                     if (si_in = '0') then
                        native_count <= 0;
                     elsif (native_count = RECOVERY_IDLE_NATIVE_TICKS - 1) then
                        native_count <= 0;
                        state        <= STATE_IDLE;
                     else
                        native_count <= native_count + 1;
                     end if;
                  end if;
            end case;
         end if;
      end if;
   end process;

end architecture;
