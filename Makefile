RTL = rtl/lmd_decoder.v rtl/lmd_ab_mux.v rtl/lmd_rx_top.v

.PHONY: all vectors sim lint clean

all: sim

vectors:
	python3 sim/gen_vectors.py

sim: vectors
	cd sim && iverilog -g2005 -Wall -o tb.vvp ../rtl/lmd_decoder.v tb_lmd_decoder.v && vvp tb.vvp

lint:
	verilator --lint-only -Wall -Wno-UNUSEDSIGNAL --top-module lmd_rx_top $(RTL)

clean:
	rm -f sim/*.hex sim/params.vh sim/tb.vvp sim/*.vcd
