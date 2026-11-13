#!/usr/bin/env bash
# Run the self-checking testbench with Vivado's simulator (xsim).
# Needs Vivado's settings64.sh sourced so xvlog/xelab/xsim are on PATH.
set -euo pipefail
cd "$(dirname "$0")"
python3 gen_vectors.py
xvlog -sv -i . ../rtl/lmd_decoder.sv tb_lmd_decoder.sv
xelab -debug typical tb_lmd_decoder -s tb_lmd_decoder
xsim tb_lmd_decoder -R
