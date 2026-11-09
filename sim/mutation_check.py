#!/usr/bin/env python3
"""Mutation testing: break the VHDL on purpose and check that the testbench notices.

Each mutant is one small change to rtl/aes_pkg.vhd or rtl/aes128_core.vhd. The testbench must report a failure
(or not finish) for every one of them. A mutant that still prints "AES TEST PASSED" is a hole in the tests.

Usage: python3 sim/mutation_check.py     (needs GHDL)
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# (name, file, old text, new text)
MUTANTS = [
    ("sbox_first_entry",       "aes_pkg.vhd",     'x"63", x"7c"', 'x"62", x"7c"'),
    ("sbox_last_entry",        "aes_pkg.vhd",     'x"b0", x"54", x"bb", x"16"', 'x"b0", x"54", x"bb", x"17"'),
    ("xtime_reduction",        "aes_pkg.vhd",     'r xor x"1b"', 'r xor x"1a"'),
    ("shift_rows_offset",      "aes_pkg.vhd",     '((c + row) mod 4)', '((c + row + 1) mod 4)'),
    ("shift_rows_none",        "aes_pkg.vhd",     '((c + row) mod 4)', '(c mod 4)'),
    ("mix_columns_coeff",      "aes_pkg.vhd",     'b0 := xtime(a0) xor (xtime(a1) xor a1) xor a2 xor a3;',
                                                  'b0 := xtime(a0) xor xtime(a1) xor a2 xor a3;'),
    ("mix_columns_row3",       "aes_pkg.vhd",     'b3 := (xtime(a0) xor a0) xor a1 xor a2 xor xtime(a3);',
                                                  'b3 := xtime(a0) xor a1 xor a2 xor xtime(a3);'),
    ("rcon_round9",            "aes_pkg.vhd",     'when 9      => return x"1b";', 'when 9      => return x"1a";'),
    ("rcon_round1",            "aes_pkg.vhd",     'when 1      => return x"01";', 'when 1      => return x"02";'),
    ("rcon_round10",           "aes_pkg.vhd",     'when others => return x"36";', 'when others => return x"35";'),
    ("rotword_missing",        "aes_pkg.vhd",     'rot  := w3(23 downto 0) & w3(31 downto 24);', 'rot  := w3;'),
    ("subword_one_byte",       "aes_pkg.vhd",     '& sbox(rot(7 downto 0));', '& rot(7 downto 0);'),
    ("key_not_chained",        "aes_pkg.vhd",     'n1 := w1 xor n0;', 'n1 := w1 xor w0;'),
    ("key_word3_chain",        "aes_pkg.vhd",     'n3 := w3 xor n2;', 'n3 := w3 xor w2;'),
    ("no_initial_addroundkey", "aes128_core.vhd", 'state <= block_in xor key;', 'state <= block_in;'),
    ("last_round_mixcolumns",  "aes128_core.vhd", 'if round < 10 then', 'if round < 11 then'),
    ("first_round_no_mix",     "aes128_core.vhd", 'if round < 10 then', 'if round < 10 and round > 1 then'),
    ("missing_last_round",     "aes128_core.vhd", 'if round = 10 then\n                    round  <= 0;', 'if round = 9 then\n                    round  <= 0;'),
    ("extra_round",            "aes128_core.vhd", 'if round = 10 then\n                    round  <= 0;', 'if round = 10 and false then\n                    round  <= 0;'),
    ("addroundkey_old_key",    "aes128_core.vhd", 'state <= st xor nk;', 'state <= st xor rkey;'),
    ("key_not_updated",        "aes128_core.vhd", '                rkey  <= nk;\n', ''),
    ("start_while_busy",       "aes128_core.vhd", 'elsif round = 0 then', "elsif round = 0 or start = '1' then"),
    ("key_not_latched",        "aes128_core.vhd", 'rkey  <= key;', 'rkey  <= rkey;'),
    ("done_never",             "aes128_core.vhd", "done_r <= '1';", "done_r <= '0';"),
    ("done_two_cycles",        "aes128_core.vhd", "            done_r <= '0';\n            if resetn", "            if resetn"),
    ("reset_ignored",          "aes128_core.vhd", "if resetn = '0' then\n                round <= 0;", "if false then\n                round <= 0;"),
    ("busy_always_low",        "aes128_core.vhd", "busy      <= '1' when round /= 0 else '0';", "busy      <= '0';"),
]


def run(workdir, vectors):
    cmds = [
        ["ghdl", "-a", "--std=08", "--workdir=" + str(workdir / "build"),
         str(workdir / "rtl" / "aes_pkg.vhd"), str(workdir / "rtl" / "aes128_core.vhd"),
         str(workdir / "tb" / "tb_aes128.vhd")],
        ["ghdl", "-e", "--std=08", "--workdir=" + str(workdir / "build"), "tb_aes128"],
    ]
    for c in cmds:
        r = subprocess.run(c, capture_output=True, text=True)
        if r.returncode != 0:
            return "compile error", r.stderr
    r = subprocess.run(["ghdl", "-r", "--std=08", "--workdir=" + str(workdir / "build"), "tb_aes128",
                        "-gVECTOR_FILE=" + str(vectors)], capture_output=True, text=True, timeout=300)
    out = r.stdout + r.stderr
    if "AES TEST PASSED" in out and r.returncode == 0:
        return "passed", out
    return "failed", out


def main():
    vectors = ROOT / "vectors" / "aes128_vectors.txt"
    missed = []
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        # reference run: the unmodified design must pass
        shutil.copytree(ROOT / "rtl", tmp / "rtl")
        shutil.copytree(ROOT / "tb", tmp / "tb")
        (tmp / "build").mkdir()
        status, out = run(tmp, vectors)
        if status != "passed":
            print("the unmodified design does not pass, abort\n" + out)
            sys.exit(2)
        for name, fname, old, new in MUTANTS:
            src = (ROOT / "rtl" / fname).read_text()
            if src.count(old) != 1:
                print("mutant %-24s cannot be applied (pattern found %d times)" % (name, src.count(old)))
                sys.exit(2)
            (tmp / "rtl" / fname).write_text(src.replace(old, new))
            shutil.rmtree(tmp / "build"); (tmp / "build").mkdir()
            status, out = run(tmp, vectors)
            (tmp / "rtl" / fname).write_text(src)
            if status == "passed":
                missed.append(name)
                print("NOT DETECTED : %s" % name)
            else:
                why = "compile error" if status == "compile error" else "test failed"
                print("detected     : %-24s (%s)" % (name, why))
    print("%d mutants, %d detected, %d not detected" % (len(MUTANTS), len(MUTANTS) - len(missed), len(missed)))
    sys.exit(1 if missed else 0)


if __name__ == "__main__":
    main()
