RTL = rtl/lmd_decoder.sv rtl/lmd_ab_mux.sv rtl/lmd_rx_top.sv \
      rtl/lmd_opt_strategy.sv rtl/lmd_risk_gate.sv rtl/lmd_order_tx.sv rtl/lmd_trader_top.sv
TOP ?= lmd_trader_top

.PHONY: all sim sim-decoder sim-trader xsim xsim-trader lint synth impl clean

all: sim

sim: sim-decoder sim-trader

# Icarus Verilog (iverilog >= 11)
sim-decoder:
	python3 sim/gen_vectors.py
	cd sim && iverilog -g2012 -Wall -o tb.vvp ../rtl/lmd_decoder.sv tb_lmd_decoder.sv && vvp tb.vvp

sim-trader:
	python3 sim/gen_trader_vectors.py
	cd sim && iverilog -g2012 -Wall -o tb_trader.vvp $(addprefix ../,$(RTL)) tb_lmd_trader.sv && vvp tb_trader.vvp

# Vivado simulator
xsim:
	./sim/run_xsim.sh decoder

xsim-trader:
	./sim/run_xsim.sh trader

lint:
	verilator --lint-only -Wall -Wno-UNUSEDSIGNAL --top-module $(TOP) $(RTL)

# VCU118 (xcvu9p-flga2104-2L-e), out-of-context. TOP=lmd_rx_top for the receiver only.
synth:
	mkdir -p vivado/out && vivado -mode batch -nojournal -log vivado/out/synth.log -source vivado/build.tcl -tclargs synth $(TOP)

impl:
	mkdir -p vivado/out && vivado -mode batch -nojournal -log vivado/out/impl.log -source vivado/build.tcl -tclargs impl $(TOP)

clean:
	rm -rf sim/*.hex sim/*params.vh sim/*.vvp sim/*.vcd sim/xsim.dir sim/*.jou sim/*.log sim/*.pb sim/*.wdb vivado/out .Xil
