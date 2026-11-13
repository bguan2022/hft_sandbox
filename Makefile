RTL = rtl/lmd_decoder.sv rtl/lmd_ab_mux.sv rtl/lmd_rx_top.sv

.PHONY: all vectors sim xsim lint synth impl clean

all: sim

vectors:
	python3 sim/gen_vectors.py

# Icarus Verilog (iverilog >= 11)
sim: vectors
	cd sim && iverilog -g2012 -Wall -o tb.vvp ../rtl/lmd_decoder.sv tb_lmd_decoder.sv && vvp tb.vvp

# Vivado simulator
xsim:
	./sim/run_xsim.sh

lint:
	verilator --lint-only -Wall -Wno-UNUSEDSIGNAL --top-module lmd_rx_top $(RTL)

# VCU118 (xcvu9p-flga2104-2L-e), out-of-context
synth:
	mkdir -p vivado/out && vivado -mode batch -nojournal -log vivado/out/synth.log -source vivado/build.tcl -tclargs synth

impl:
	mkdir -p vivado/out && vivado -mode batch -nojournal -log vivado/out/impl.log -source vivado/build.tcl -tclargs impl

clean:
	rm -rf sim/*.hex sim/params.vh sim/tb.vvp sim/*.vcd sim/xsim.dir sim/*.jou sim/*.log sim/*.pb sim/*.wdb vivado/out .Xil
