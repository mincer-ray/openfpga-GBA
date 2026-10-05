library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Normal 8/32-bit synchronous serial engine.
--
-- The CPU-facing register block owns mode selection, SIOCNT/SIODATA storage,
-- and IRQ generation.  This engine snapshots a requested transfer, generates
-- or follows SC, shifts SO/SI, and reports a single completion event.  All
-- internally generated wire timing advances from new_exact_cycle so CPU
-- stalls, DMA, and fast-forward do not change the physical bit rate.
entity gba_serial_normal is
   port
   (
      clk100          : in  std_logic;
      reset           : in  std_logic;
      mode_enable     : in  std_logic;
      new_exact_cycle : in  std_logic;

      start           : in  std_logic;
      cancel          : in  std_logic;
      transfer_32     : in  std_logic;
      internal_clock  : in  std_logic;
      fast_clock      : in  std_logic;
      idle_so         : in  std_logic;
      tx_data         : in  std_logic_vector(31 downto 0);

      si_in           : in  std_logic;
      sc_in           : in  std_logic;

      busy            : out std_logic := '0';
      rx_data         : out std_logic_vector(31 downto 0) := (others => '0');
      complete        : out std_logic := '0';

      so_out          : out std_logic := '1';
      so_oe           : out std_logic := '0';
      sc_out          : out std_logic := '1';
      sc_oe           : out std_logic := '0'
   );
end entity;

architecture arch of gba_serial_normal is

   type normal_state_type is
   (
      NORMAL_IDLE,
      NORMAL_MASTER,
      NORMAL_MASTER_SAMPLE,
      NORMAL_MASTER_HOLD,
      NORMAL_SLAVE
   );

   signal state             : normal_state_type := NORMAL_IDLE;
   signal busy_r            : std_logic := '0';
   signal complete_r        : std_logic := '0';
   signal rx_data_r         : std_logic_vector(31 downto 0) := (others => '0');
   signal rx_shift_r        : std_logic_vector(31 downto 0) := (others => '0');
   signal tx_shift_r        : std_logic_vector(31 downto 0) := (others => '0');
   signal bits_remaining_r  : integer range 0 to 32 := 0;
   signal half_count_r      : integer range 0 to 31 := 0;
   signal half_limit_r      : integer range 3 to 31 := 31;
   signal internal_clock_r  : std_logic := '0';
   signal so_r              : std_logic := '1';
   signal sc_r              : std_logic := '1';
   signal sc_prev_r         : std_logic := '1';

begin

   busy     <= busy_r;
   rx_data  <= rx_data_r;
   complete <= complete_r;

   -- SO is always an output in Normal mode. SC is driven only by the
   -- internal-clock side; the live setting is used while idle and the
   -- start-time snapshot is used for the active transfer.
   so_oe  <= mode_enable;
   sc_oe  <= '0' when mode_enable = '0' else
             internal_clock_r when state /= NORMAL_IDLE else
             internal_clock;
   so_out <= so_r when state /= NORMAL_IDLE else idle_so;
   sc_out <= sc_r when state /= NORMAL_IDLE and internal_clock_r = '1' else '1';

   process (clk100)
      variable next_rx : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk100) then
         complete_r <= '0';
         sc_prev_r  <= sc_in;

         if reset = '1' then
            state            <= NORMAL_IDLE;
            busy_r           <= '0';
            rx_data_r        <= (others => '0');
            rx_shift_r       <= (others => '0');
            tx_shift_r       <= (others => '0');
            bits_remaining_r <= 0;
            half_count_r     <= 0;
            half_limit_r     <= 31;
            internal_clock_r <= '0';
            so_r             <= '1';
            sc_r             <= '1';
            sc_prev_r        <= '1';

         elsif mode_enable = '0' then
            -- A mode exit is an abort, not a successful completion.
            state            <= NORMAL_IDLE;
            busy_r           <= '0';
            bits_remaining_r <= 0;
            half_count_r     <= 0;
            internal_clock_r <= '0';
            so_r             <= '1';
            sc_r             <= '1';

         elsif cancel = '1' then
            state            <= NORMAL_IDLE;
            busy_r           <= '0';
            bits_remaining_r <= 0;
            half_count_r     <= 0;
            so_r             <= idle_so;
            sc_r             <= '1';

         elsif start = '1' and busy_r = '0' then
            busy_r           <= '1';
            rx_shift_r       <= (others => '0');
            half_count_r     <= 0;
            internal_clock_r <= internal_clock;
            so_r             <= idle_so;
            sc_r             <= '1';

            if transfer_32 = '1' then
               bits_remaining_r <= 32;
            else
               bits_remaining_r <= 8;
            end if;

            if fast_clock = '1' then
               -- 16.777216 MHz / 8: four native ticks per half-period.
               half_limit_r <= 3;
            else
               -- 16.777216 MHz / 64: 32 native ticks per half-period.
               half_limit_r <= 31;
            end if;

            if transfer_32 = '1' then
               tx_shift_r <= tx_data;
            else
               -- Align the eight-bit payload to the common MSB-first shifter.
               tx_shift_r <= tx_data(7 downto 0) & x"000000";
            end if;

            if internal_clock = '1' then
               state <= NORMAL_MASTER;
            else
               state <= NORMAL_SLAVE;
            end if;

         elsif start = '1' and busy_r = '1' and
               state = NORMAL_SLAVE and internal_clock = '1' then
            -- Nintendo's RFU library first arms its ID-check word with
            -- external clock (SIOCNT=5080), then changes bit 0 while Start
            -- remains set (SIOCNT=5081). Real hardware takes ownership of SC
            -- and continues the already-armed word. Preserve all shift state
            -- and only begin the internal half-period cadence here.
            state            <= NORMAL_MASTER;
            internal_clock_r <= '1';
            half_count_r     <= 0;
            sc_r             <= '1';

         else
            case state is
               when NORMAL_IDLE =>
                  busy_r <= '0';
                  so_r   <= idle_so;
                  sc_r   <= '1';

               when NORMAL_MASTER =>
                  if new_exact_cycle = '1' then
                     if half_count_r = half_limit_r then
                        half_count_r <= 0;

                        if sc_r = '1' then
                           -- Falling SC edge: present the next outgoing bit.
                           sc_r       <= '0';
                           so_r       <= tx_shift_r(31);
                           tx_shift_r <= tx_shift_r(30 downto 0) & '0';
                        else
                           sc_r <= '1';

                           if half_limit_r = 3 then
                              -- At 2 MHz the connector input can still be
                              -- settling when the generated rising edge is
                              -- observed through the SI synchronizer. Defer the
                              -- logical sample by one 16.78 MHz native tick.
                              -- The divider continues in the sample state, so
                              -- this does not move either physical SC edge.
                              state <= NORMAL_MASTER_SAMPLE;
                           else
                              -- Rising SC edge: sample SI immediately at the
                              -- slow rate, matching the established path.
                              next_rx := rx_shift_r(30 downto 0) & si_in;
                              rx_shift_r <= next_rx;

                              if bits_remaining_r = 1 then
                                 -- Retain the final outgoing bit for one full
                                 -- high half-period before publishing completion.
                                 bits_remaining_r <= 0;
                                 state            <= NORMAL_MASTER_HOLD;
                              else
                                 bits_remaining_r <= bits_remaining_r - 1;
                              end if;
                           end if;
                        end if;
                     else
                        half_count_r <= half_count_r + 1;
                     end if;
                  end if;

               when NORMAL_MASTER_SAMPLE =>
                  -- One native tick after a fast generated rising edge, the
                  -- synchronized SI value has had another ~59.6 ns to settle.
                  -- Count this tick as part of the existing high half-period.
                  if new_exact_cycle = '1' then
                     next_rx := rx_shift_r(30 downto 0) & si_in;
                     rx_shift_r   <= next_rx;
                     half_count_r <= half_count_r + 1;

                     if bits_remaining_r = 1 then
                        bits_remaining_r <= 0;
                        state            <= NORMAL_MASTER_HOLD;
                     else
                        bits_remaining_r <= bits_remaining_r - 1;
                        state            <= NORMAL_MASTER;
                     end if;
                  end if;

               when NORMAL_MASTER_HOLD =>
                  -- Keep SC high and the final SO bit stable for the selected
                  -- rate's last half-period. Only then clear busy, publish the
                  -- received word, and pulse completion. This gives the peer
                  -- its sampling hold while ensuring software cannot begin the
                  -- RFU ready handshake before idle SO is physically visible.
                  if new_exact_cycle = '1' then
                     if half_count_r = half_limit_r then
                        state        <= NORMAL_IDLE;
                        busy_r       <= '0';
                        complete_r   <= '1';
                        rx_data_r    <= rx_shift_r;
                        half_count_r <= 0;
                        so_r         <= idle_so;
                        sc_r         <= '1';
                     else
                        half_count_r <= half_count_r + 1;
                     end if;
                  end if;

               when NORMAL_SLAVE =>
                  if sc_prev_r = '1' and sc_in = '0' then
                     -- Falling external SC edge: present the next outgoing bit.
                     so_r       <= tx_shift_r(31);
                     tx_shift_r <= tx_shift_r(30 downto 0) & '0';
                  elsif sc_prev_r = '0' and sc_in = '1' then
                     -- Rising external SC edge: sample SI.
                     next_rx := rx_shift_r(30 downto 0) & si_in;
                     rx_shift_r <= next_rx;

                     if bits_remaining_r = 1 then
                        state            <= NORMAL_IDLE;
                        busy_r           <= '0';
                        complete_r       <= '1';
                        bits_remaining_r <= 0;
                        rx_data_r        <= next_rx;
                        so_r             <= idle_so;
                     else
                        bits_remaining_r <= bits_remaining_r - 1;
                     end if;
                  end if;
            end case;
         end if;
      end if;
   end process;

end architecture;
