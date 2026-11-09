-- Self-checking testbench for aes128_core.
--
--  1. every vector of the file (generic VECTOR_FILE): the two FIPS 197 examples, single-bit sweeps and random
--     cases, whose expected ciphertexts come from OpenSSL (see scripts/gen_vectors.py);
--  2. the two examples of FIPS 197, written here again from the standard, as an independent second check;
--  3. protocol checks: latency of 11 cycles, busy high while working, done lasts one cycle, the key is latched,
--     a start pulse while busy is ignored, and a reset in the middle of an encryption returns the core to idle.
-- Prints "AES TEST PASSED" at the end, or stops with a failure.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use std.env.all;
use work.aes_pkg.all;

entity tb_aes128 is
    generic (VECTOR_FILE : string := "../vectors/aes128_vectors.txt");
end entity tb_aes128;

architecture sim of tb_aes128 is
    signal clk       : std_logic := '0';
    signal resetn    : std_logic := '0';
    signal start     : std_logic := '0';
    signal key       : block_t := (others => '0');
    signal block_in  : block_t := (others => '0');
    signal busy      : std_logic;
    signal done      : std_logic;
    signal block_out : block_t;

    constant LATENCY : integer := 11;
begin
    clk <= not clk after 5 ns;

    dut : entity work.aes128_core
        port map (clk => clk, resetn => resetn, start => start, key => key, block_in => block_in,
                  busy => busy, done => done, block_out => block_out);

    stim : process
        file     f       : text;
        variable l       : line;
        variable k, p, c : block_t;
        variable n_total : integer := 0;
        variable n_fail  : integer := 0;
        variable lat     : integer;

        procedure fail (msg : string) is
        begin
            report "FAIL: " & msg severity error;
            n_fail := n_fail + 1;
        end procedure;

        -- start one encryption; returns the latency in clock cycles (clock edge that samples start = 1)
        procedure begin_encrypt (kk, pp : in block_t) is
        begin
            wait until falling_edge(clk);
            key <= kk; block_in <= pp; start <= '1';
            wait until falling_edge(clk);                 -- the rising edge in between sampled start
            start <= '0';
        end procedure;

        procedure wait_done (result : out block_t; cycles : out integer) is
            variable n : integer := 1;                    -- one rising edge has passed (the one that sampled start)
        begin
            while done /= '1' loop
                if busy /= '1' then
                    fail("busy is low while the core is working");
                end if;
                wait until falling_edge(clk);
                n := n + 1;
                if n > 50 then
                    fail("timeout, done never went high");
                    exit;
                end if;
            end loop;
            result  := block_out;
            cycles := n;
        end procedure;

        procedure check (kk, pp, expected : in block_t; name : in string) is
            variable r : block_t;
            variable n : integer;
        begin
            begin_encrypt(kk, pp);
            wait_done(r, n);
            n_total := n_total + 1;
            if r /= expected then
                fail(name & ": wrong ciphertext, got " & to_hstring(r) & " expected " & to_hstring(expected));
            end if;
            if n /= LATENCY then
                fail(name & ": latency " & integer'image(n) & " instead of " & integer'image(LATENCY));
            end if;
            if busy /= '0' then
                fail(name & ": busy still high when done is high");
            end if;
            wait until falling_edge(clk);
            if done /= '0' then
                fail(name & ": done lasts more than one cycle");
            end if;
        end procedure;
    begin
        -- reset
        resetn <= '0';
        wait for 42 ns;
        wait until falling_edge(clk);
        resetn <= '1';
        wait until falling_edge(clk);
        if busy /= '0' or done /= '0' then
            fail("core not idle after reset");
        end if;

        -- 1. vectors from the file
        file_open(f, VECTOR_FILE, read_mode);
        while not endfile(f) loop
            readline(f, l);
            if l'length > 0 and l(l'left) /= '#' then
                hread(l, k);
                hread(l, p);
                hread(l, c);
                check(k, p, c, "file vector " & integer'image(n_total + 1));
            end if;
        end loop;
        file_close(f);
        report integer'image(n_total) & " vectors from the file checked";

        -- 2. the two examples of FIPS 197, typed here from the standard
        check(x"2b7e151628aed2a6abf7158809cf4f3c", x"3243f6a8885a308d313198a2e0370734",
              x"3925841d02dc09fbdc118597196a0b32", "FIPS 197 appendix B");
        check(x"000102030405060708090a0b0c0d0e0f", x"00112233445566778899aabbccddeeff",
              x"69c4e0d86a7b0430d8cdb78070b4c55a", "FIPS 197 appendix C.1");

        -- 3a. the key and the block are latched, and a start pulse while busy is ignored
        begin_encrypt(x"2b7e151628aed2a6abf7158809cf4f3c", x"3243f6a8885a308d313198a2e0370734");
        key      <= (others => '1');                      -- change the inputs while the core is working
        block_in <= (others => '1');
        wait until falling_edge(clk);
        wait until falling_edge(clk);
        start <= '1';                                     -- a start pulse while busy
        wait until falling_edge(clk);
        start <= '0';
        key      <= x"000102030405060708090a0b0c0d0e0f";
        block_in <= x"00112233445566778899aabbccddeeff";
        wait_done(c, lat);
        n_total := n_total + 1;
        if c /= x"3925841d02dc09fbdc118597196a0b32" then
            fail("latched key or ignored start while busy: wrong ciphertext " & to_hstring(c));
        end if;
        wait until falling_edge(clk);

        -- 3b. reset in the middle of an encryption: back to idle, no done pulse, and the next one works
        begin_encrypt(x"2b7e151628aed2a6abf7158809cf4f3c", x"3243f6a8885a308d313198a2e0370734");
        wait until falling_edge(clk);
        wait until falling_edge(clk);
        resetn <= '0';
        wait until falling_edge(clk);
        resetn <= '1';
        for i in 1 to 20 loop
            wait until falling_edge(clk);
            if done = '1' then
                fail("done pulse after a reset in the middle of an encryption");
            end if;
        end loop;
        if busy /= '0' then
            fail("busy still high after reset");
        end if;
        check(x"000102030405060708090a0b0c0d0e0f", x"00112233445566778899aabbccddeeff",
              x"69c4e0d86a7b0430d8cdb78070b4c55a", "after reset");

        report integer'image(n_total) & " encryptions checked, " & integer'image(n_fail) & " failure(s)";
        if n_fail = 0 then
            report "AES TEST PASSED";
        else
            report "AES TEST FAILED" severity failure;
        end if;
        finish;
    end process;

    -- watchdog: the whole test must finish
    watchdog : process
    begin
        wait for 20 ms;
        report "AES TEST FAILED: watchdog" severity failure;
        wait;
    end process;
end architecture sim;
