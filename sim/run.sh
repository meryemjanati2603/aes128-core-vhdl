#!/bin/sh
# Compile the core and its testbench with GHDL (free) and run the test.
# Usage: sh run.sh [path-to-vector-file]
set -e
cd "$(dirname "$0")"
mkdir -p build
VEC="${1:-../vectors/aes128_vectors.txt}"
ghdl -a --std=08 --workdir=build ../rtl/aes_pkg.vhd ../rtl/aes128_core.vhd ../tb/tb_aes128.vhd
ghdl -e --std=08 --workdir=build tb_aes128
ghdl -r --std=08 --workdir=build tb_aes128 -gVECTOR_FILE="$VEC" 2>&1
