-- AES-128 helper functions (FIPS 197).
--
-- A 128-bit block is a std_logic_vector(127 downto 0). Byte i of the block (i = 0 is the first byte of the
-- message, in the usual hexadecimal notation) occupies bits (127 - 8*i) downto (120 - 8*i).
-- In the FIPS 197 state matrix, byte i sits at row (i mod 4), column (i / 4).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package aes_pkg is
    subtype byte_t  is std_logic_vector(7 downto 0);
    subtype block_t is std_logic_vector(127 downto 0);

    function sbox        (b : byte_t) return byte_t;
    function xtime       (b : byte_t) return byte_t;                 -- multiplication by 2 in GF(2^8)
    function sub_bytes   (s : block_t) return block_t;
    function shift_rows  (s : block_t) return block_t;
    function mix_columns (s : block_t) return block_t;
    function rcon        (round : natural) return byte_t;            -- round constant, rounds 1 to 10
    function next_round_key (k : block_t; round : natural) return block_t;
end package aes_pkg;

package body aes_pkg is

    type sbox_t is array (0 to 255) of byte_t;

    -- The table is computed from the definition (inverse in GF(2^8) followed by an affine map) by
    -- scripts/gen_sbox.py; "python3 scripts/gen_sbox.py --check" verifies that this table is the computed one.
    constant SBOX_TABLE : sbox_t := (
        x"63", x"7c", x"77", x"7b", x"f2", x"6b", x"6f", x"c5", x"30", x"01", x"67", x"2b", x"fe", x"d7", x"ab", x"76",
        x"ca", x"82", x"c9", x"7d", x"fa", x"59", x"47", x"f0", x"ad", x"d4", x"a2", x"af", x"9c", x"a4", x"72", x"c0",
        x"b7", x"fd", x"93", x"26", x"36", x"3f", x"f7", x"cc", x"34", x"a5", x"e5", x"f1", x"71", x"d8", x"31", x"15",
        x"04", x"c7", x"23", x"c3", x"18", x"96", x"05", x"9a", x"07", x"12", x"80", x"e2", x"eb", x"27", x"b2", x"75",
        x"09", x"83", x"2c", x"1a", x"1b", x"6e", x"5a", x"a0", x"52", x"3b", x"d6", x"b3", x"29", x"e3", x"2f", x"84",
        x"53", x"d1", x"00", x"ed", x"20", x"fc", x"b1", x"5b", x"6a", x"cb", x"be", x"39", x"4a", x"4c", x"58", x"cf",
        x"d0", x"ef", x"aa", x"fb", x"43", x"4d", x"33", x"85", x"45", x"f9", x"02", x"7f", x"50", x"3c", x"9f", x"a8",
        x"51", x"a3", x"40", x"8f", x"92", x"9d", x"38", x"f5", x"bc", x"b6", x"da", x"21", x"10", x"ff", x"f3", x"d2",
        x"cd", x"0c", x"13", x"ec", x"5f", x"97", x"44", x"17", x"c4", x"a7", x"7e", x"3d", x"64", x"5d", x"19", x"73",
        x"60", x"81", x"4f", x"dc", x"22", x"2a", x"90", x"88", x"46", x"ee", x"b8", x"14", x"de", x"5e", x"0b", x"db",
        x"e0", x"32", x"3a", x"0a", x"49", x"06", x"24", x"5c", x"c2", x"d3", x"ac", x"62", x"91", x"95", x"e4", x"79",
        x"e7", x"c8", x"37", x"6d", x"8d", x"d5", x"4e", x"a9", x"6c", x"56", x"f4", x"ea", x"65", x"7a", x"ae", x"08",
        x"ba", x"78", x"25", x"2e", x"1c", x"a6", x"b4", x"c6", x"e8", x"dd", x"74", x"1f", x"4b", x"bd", x"8b", x"8a",
        x"70", x"3e", x"b5", x"66", x"48", x"03", x"f6", x"0e", x"61", x"35", x"57", x"b9", x"86", x"c1", x"1d", x"9e",
        x"e1", x"f8", x"98", x"11", x"69", x"d9", x"8e", x"94", x"9b", x"1e", x"87", x"e9", x"ce", x"55", x"28", x"df",
        x"8c", x"a1", x"89", x"0d", x"bf", x"e6", x"42", x"68", x"41", x"99", x"2d", x"0f", x"b0", x"54", x"bb", x"16"
    );

    function sbox (b : byte_t) return byte_t is
    begin
        return SBOX_TABLE(to_integer(unsigned(b)));
    end function;

    function xtime (b : byte_t) return byte_t is
        variable r : byte_t;
    begin
        r := b(6 downto 0) & '0';
        if b(7) = '1' then
            r := r xor x"1b";        -- reduce modulo x^8 + x^4 + x^3 + x + 1
        end if;
        return r;
    end function;

    -- byte i of a block
    function get_byte (s : block_t; i : natural) return byte_t is
    begin
        return s(127 - 8 * i downto 120 - 8 * i);
    end function;

    function sub_bytes (s : block_t) return block_t is
        variable r : block_t;
    begin
        for i in 0 to 15 loop
            r(127 - 8 * i downto 120 - 8 * i) := sbox(get_byte(s, i));
        end loop;
        return r;
    end function;

    -- row r of the state is rotated left by r positions: new(r, c) = old(r, (c + r) mod 4)
    function shift_rows (s : block_t) return block_t is
        variable r : block_t;
        variable src : natural;
    begin
        for c in 0 to 3 loop
            for row in 0 to 3 loop
                src := row + 4 * ((c + row) mod 4);
                r(127 - 8 * (row + 4 * c) downto 120 - 8 * (row + 4 * c)) := get_byte(s, src);
            end loop;
        end loop;
        return r;
    end function;

    -- each column is multiplied by the fixed matrix [2 3 1 1; 1 2 3 1; 1 1 2 3; 3 1 1 2] over GF(2^8)
    function mix_columns (s : block_t) return block_t is
        variable r : block_t;
        variable a0, a1, a2, a3 : byte_t;
        variable b0, b1, b2, b3 : byte_t;
    begin
        for c in 0 to 3 loop
            a0 := get_byte(s, 4 * c);
            a1 := get_byte(s, 4 * c + 1);
            a2 := get_byte(s, 4 * c + 2);
            a3 := get_byte(s, 4 * c + 3);
            b0 := xtime(a0) xor (xtime(a1) xor a1) xor a2 xor a3;
            b1 := a0 xor xtime(a1) xor (xtime(a2) xor a2) xor a3;
            b2 := a0 xor a1 xor xtime(a2) xor (xtime(a3) xor a3);
            b3 := (xtime(a0) xor a0) xor a1 xor a2 xor xtime(a3);
            r(127 - 32 * c downto 120 - 32 * c) := b0;
            r(119 - 32 * c downto 112 - 32 * c) := b1;
            r(111 - 32 * c downto 104 - 32 * c) := b2;
            r(103 - 32 * c downto  96 - 32 * c) := b3;
        end loop;
        return r;
    end function;

    function rcon (round : natural) return byte_t is
    begin
        case round is
            when 1      => return x"01";
            when 2      => return x"02";
            when 3      => return x"04";
            when 4      => return x"08";
            when 5      => return x"10";
            when 6      => return x"20";
            when 7      => return x"40";
            when 8      => return x"80";
            when 9      => return x"1b";
            when others => return x"36";   -- round 10
        end case;
    end function;

    -- one step of the key schedule: from round key (round - 1) to round key (round)
    function next_round_key (k : block_t; round : natural) return block_t is
        variable w0, w1, w2, w3 : std_logic_vector(31 downto 0);
        variable rot, subw, t   : std_logic_vector(31 downto 0);
        variable n0, n1, n2, n3 : std_logic_vector(31 downto 0);
    begin
        w0 := k(127 downto 96);
        w1 := k( 95 downto 64);
        w2 := k( 63 downto 32);
        w3 := k( 31 downto  0);
        rot  := w3(23 downto 0) & w3(31 downto 24);                       -- RotWord
        subw := sbox(rot(31 downto 24)) & sbox(rot(23 downto 16))
              & sbox(rot(15 downto 8))  & sbox(rot(7 downto 0));          -- SubWord
        t  := subw xor (rcon(round) & x"000000");
        n0 := w0 xor t;
        n1 := w1 xor n0;
        n2 := w2 xor n1;
        n3 := w3 xor n2;
        return n0 & n1 & n2 & n3;
    end function;

end package body aes_pkg;
