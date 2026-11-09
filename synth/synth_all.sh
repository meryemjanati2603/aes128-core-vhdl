#!/bin/sh
# Resource estimates with free tools: GHDL converts the VHDL to a Verilog netlist (ghdl --synth), then Yosys maps it
# to three FPGA families. These are synthesis estimates only: no place-and-route, no timing, no board.
# The official numbers for a given device come from its vendor tool (for example Quartus for Altera/Intel).
# Usage: sh synth_all.sh   (writes report.txt)
set -e
cd "$(dirname "$0")"
mkdir -p build
ghdl --synth --std=08 --out=verilog --workdir=build ../rtl/aes_pkg.vhd ../rtl/aes128_core.vhd -e aes128_core \
    > build/aes128_core_synth.v 2> build/ghdl_synth.log
{
  echo "AES-128 core: synthesis estimates (GHDL + Yosys). Synthesis only, not place-and-route, nothing run on a board."
  echo "Yosys: $(yosys -V)"
  echo
  echo "== Lattice iCE40 (synth_ice40), the UP5K has 5280 logic cells =="
  yosys -q -l build/ice40.log -p "read_verilog build/aes128_core_synth.v; synth_ice40 -top aes128_core; stat"
  grep -E "^ +(SB_LUT4|SB_DFF[A-Z]*|SB_CARRY) " build/ice40.log | sort -u
  echo
  echo "== Intel Cyclone V (synth_intel_alm), adaptive LUTs =="
  yosys -q -l build/alm.log -p "read_verilog build/aes128_core_synth.v; synth_intel_alm -family cyclonev -top aes128_core; stat"
  grep -E "^ +MISTRAL_(ALUT[0-9_A-Z]*|FF) " build/alm.log | sort -u
  echo
  echo "== Xilinx 7 series (synth_xilinx) =="
  yosys -q -l build/xc7.log -p "read_verilog build/aes128_core_synth.v; synth_xilinx -family xc7 -top aes128_core; stat"
  grep -E "^ +(LUT[0-9]|FDRE|MUXF[0-9]) " build/xc7.log | sort -u
} | tee report.txt
