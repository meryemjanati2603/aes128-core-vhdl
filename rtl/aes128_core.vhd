-- AES-128 encryption core (FIPS 197), iterative architecture: one round per clock cycle.
--
-- Protocol:
--   * While busy = '0', pulse start for one clock cycle with key and block_in valid. Both are latched at that
--     clock edge, so they may change afterwards.
--   * The core then runs 10 rounds (one per clock cycle). A start pulse received while busy = '1' is ignored.
--   * done is high for exactly one clock cycle when the result is ready; block_out holds the result from then
--     until the next start.
--   * Latency: 11 clock cycles from the clock edge that samples start to the cycle where done is high
--     (1 cycle for the initial AddRoundKey, 10 for the rounds). The round keys are computed on the fly, one per
--     round, so no key memory is needed.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.aes_pkg.all;

entity aes128_core is
    port (
        clk       : in  std_logic;
        resetn    : in  std_logic;                       -- synchronous, active low
        start     : in  std_logic;
        key       : in  std_logic_vector(127 downto 0);
        block_in  : in  std_logic_vector(127 downto 0);
        busy      : out std_logic;
        done      : out std_logic;
        block_out : out std_logic_vector(127 downto 0)
    );
end entity aes128_core;

architecture rtl of aes128_core is
    signal state  : block_t;                             -- current AES state
    signal rkey   : block_t;                             -- round key used by the previous round
    signal round  : natural range 0 to 10 := 0;          -- 0 = idle, 1 to 10 = round being computed next
    signal done_r : std_logic := '0';
begin
    busy      <= '1' when round /= 0 else '0';
    done      <= done_r;
    block_out <= state;

    process (clk)
        variable nk : block_t;
        variable st : block_t;
    begin
        if rising_edge(clk) then
            done_r <= '0';
            if resetn = '0' then
                round <= 0;
            elsif round = 0 then
                if start = '1' then
                    state <= block_in xor key;           -- initial AddRoundKey
                    rkey  <= key;
                    round <= 1;
                end if;
            else
                nk := next_round_key(rkey, round);
                st := shift_rows(sub_bytes(state));
                if round < 10 then
                    st := mix_columns(st);               -- the last round has no MixColumns
                end if;
                state <= st xor nk;                      -- AddRoundKey
                rkey  <= nk;
                if round = 10 then
                    round  <= 0;
                    done_r <= '1';
                else
                    round <= round + 1;
                end if;
            end if;
        end if;
    end process;
end architecture rtl;
