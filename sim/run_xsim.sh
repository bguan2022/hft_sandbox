#!/usr/bin/env bash
# Run a self-checking testbench with Vivado's simulator (xsim).
#   ./run_xsim.sh            # decoder testbench
#   ./run_xsim.sh trader     # tick-to-trade testbench
# Needs Vivado's settings64.sh sourced so xvlog/xelab/xsim are on PATH.
set -euo pipefail
cd "$(dirname "$0")"
case "${1:-decoder}" in
    decoder)
        python3 gen_vectors.py
        xvlog -sv -i . ../rtl/lmd_decoder.sv tb_lmd_decoder.sv
        tb=tb_lmd_decoder ;;
    trader)
        python3 gen_trader_vectors.py
        xvlog -sv -i . ../rtl/*.sv tb_lmd_trader.sv
        tb=tb_lmd_trader ;;
    *) echo "usage: $0 [decoder|trader]" >&2; exit 2 ;;
esac
xelab -debug typical "$tb" -s "$tb"
xsim "$tb" -R
