# ============================================================================
# lmd_ooc.xdc - out-of-context timing constraints for lmd_trader_top / lmd_rx_top on VCU118
#               (Virtex UltraScale+ xcvu9p-flga2104-2L-e)
#
# 156.25 MHz = the 64-bit AXI4-Stream clock of a 10GBASE-R MAC.
# For a 25G MAC with a 64-bit datapath use 390.625 MHz (-period 2.560).
#
# Pins are not assigned here: in the full design the decoder sits behind the
# Ethernet MAC/PHY on the QSFP28 cages, and its ports connect to fabric logic.
# ============================================================================

create_clock -name clk -period 6.400 [get_ports clk]

# Inputs (reset, MAC RX streams) and outputs (decoded messages) connect to
# registered fabric logic in the full design; budget about a third of the
# period for the routing on the other side of each port.
set_input_delay  -clock clk 2.000 [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_output_delay -clock clk 2.000 [get_ports -filter {DIRECTION == OUT}]
