# LMD v1 — Low-latency Market Data over raw Ethernet

A market data protocol for internal, colocated links (exchange feed handler → strategy boxes, or an internal redistribution tier), designed so an FPGA can decode it at line rate with one clock of added latency per message.

## Design choices

| Choice | Why |
|---|---|
| Raw Ethernet (EtherType `0x88B5`), no IP/UDP | Saves 28 bytes and a parse stage. Works on one L2 segment; see "Routed networks" for the UDP variant. |
| 32-byte header region (14 Ethernet + 18 LMD) | Messages start exactly at beat 4 of a 64-bit bus. |
| Fixed 32-byte messages | Every message is exactly 4 beats and 8-byte aligned. No length fields, no byte shifting, no `tkeep` handling. |
| Big-endian fields | Network convention; on the FPGA it is just wiring. |
| Sequence number per channel, MoldUDP64-style | Lets the receiver merge redundant A/B feeds, drop duplicates and detect gaps in hardware. |
| Heartbeats (`msg_count = 0`) | Gaps are detected even when the market is quiet. |

## Frame layout

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 6 | dst MAC | Multicast group, e.g. `01:00:5e:00:01:01` |
| 6 | 6 | src MAC | |
| 12 | 2 | EtherType | `0x88B5` |
| 14 | 1 | version | `1` |
| 15 | 1 | msg_count | 0–255; ≤ 46 fits a 1500-byte MTU; 0 = heartbeat |
| 16 | 2 | channel_id | Independent sequence space (e.g. a symbol range) |
| 18 | 8 | seq | Sequence number of the first message; message *i* has `seq + i` |
| 26 | 6 | send_ts | Nanoseconds since midnight (48-bit) |
| 32 | 32 × n | messages | |

The MAC appends the FCS. Heartbeats are padded to the 60-byte Ethernet minimum; receivers ignore bytes past the last message.

## Message layout (32 bytes)

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 1 | type | See below |
| 1 | 1 | side | `'B'` (0x42), `'S'` (0x53), or 0 |
| 2 | 2 | instrument_id | |
| 4 | 4 | flags | bit 0 `END_OF_EVENT`: book is consistent after this message |
| 8 | 8 | order_id | |
| 16 | 8 | price | Signed, units of 1e-9 |
| 24 | 4 | quantity | |
| 28 | 4 | ts_delta | ns; event time = `send_ts − ts_delta` |

| type | Name | Meaning |
|---|---|---|
| 0x01 | ADD_ORDER | New resting order |
| 0x02 | MODIFY_ORDER | Price and/or quantity change |
| 0x03 | DELETE_ORDER | Order removed |
| 0x04 | EXECUTE | Resting order (partially) filled; `quantity` = executed size |
| 0x05 | TRADE | Trade not tied to a displayed order |
| 0x06 | INSTRUMENT_STATUS | Halt / open / close; status code in `flags[15:8]` |

## Sequencing and A/B arbitration

Every frame is published twice, on feed A and feed B (separate switches and NICs). The receiver merges both feeds and keeps one `expected` sequence number per channel:

1. **First frame** with a valid header syncs the receiver.
2. **`seq > expected`** → gap of `seq − expected` messages is reported; the frame is accepted.
3. **`seq + count ≤ expected`** (and `count > 0`) → duplicate, dropped. This is normally the slower feed's copy.
4. **`seq ≤ expected < seq + count`** → partial overlap; the first `expected − seq` messages are skipped.
5. **Bad FCS or truncated frame** → `frame_ok = 0`. Messages already emitted from that frame must be discarded. `expected` does not advance, so the other feed's copy is delivered in full.
6. `expected` advances to `seq + count` only when a frame ends good.

Gap recovery (a TCP retransmission server or a snapshot channel) is out of scope for v1. `gap_valid / gap_start / gap_count` are the hook for it.

## FPGA receiver

```
 10G MAC A ─► cut-through FIFO ─┐
                                ├─► lmd_ab_mux ─► lmd_decoder ─► msg_* (to order book)
 10G MAC B ─► cut-through FIFO ─┘   (whole frames,  (sequencing,     frame_done/ok
                                     first wins)     A/B dedup)      gap_*  stats
```

| File | Purpose |
|---|---|
| `rtl/lmd_decoder.sv` | Header parse, sequencing, dedup, gap detection, message decode |
| `rtl/lmd_ab_mux.sv` | Merges A and B feeds at frame granularity, zero added latency for the first arrival |
| `rtl/lmd_rx_top.sv` | Mux + decoder for one channel |
| `constraints/lmd_ooc.xdc` | 156.25 MHz clock and port timing for out-of-context builds |
| `vivado/build.tcl` | Synthesis and place & route for the VCU118 |
| `sw/lmd.py` | Reference encoder, parser, sequencer and a raw-socket sender for testing |
| `sim/gen_vectors.py` | Builds test scenarios and a register-level model of the decoder |
| `sim/tb_lmd_decoder.sv` | Self-checking testbench |
| `sim/run_xsim.sh` | Runs the testbench in Vivado's simulator |

**Interface.** 64-bit AXI4-Stream at 156.25 MHz (10GbE), frame byte 0 in `tdata[7:0]`, `tuser = 1` on the last beat for a bad FCS. This matches common MAC cores (e.g. AMD/Xilinx 10G/25G Ethernet subsystem, Alex Forencich's open-source `verilog-ethernet`). The decoder never back-pressures (`tready = 1`).

**Latency.** The first message of a frame occupies beats 4–7 and appears on `msg_valid` one clock (6.4 ns) after its last byte arrives, about 58 ns after the first byte of the frame reaches the decoder. Every later message also adds just one clock beyond its own wire time. MAC/PCS/PHY latency is extra and usually dominates; low-latency MAC IP and bypassing the RX FIFO matter more than the decoder from here.

**Cut-through trade-off.** Messages are emitted before the FCS is checked, which saves a full frame of latency. The consumer must be able to undo a frame when `frame_ok = 0`, for example by staging updates until `frame_done` or by keeping a shadow book. Bad FCS on a short, clean link is very rare, and the other feed's copy fills it in.

**Resources.** Roughly 1,000–1,500 flip-flops and a few 64-bit adders/comparators per channel, with no block RAM. That is well under 1% of the VCU118's XCVU9P, and it should close timing comfortably at 156.25 MHz. These are estimates until `make impl` has been run.

## Building for the VCU118

The RTL is SystemVerilog and targets the AMD/Xilinx VCU118 board, whose FPGA is a Virtex UltraScale+ XCVU9P (Vivado part `xcvu9p-flga2104-2L-e`).

```
make synth      # synthesis only
make impl       # synthesis + place & route
```

Both run Vivado in batch mode, out-of-context: the decoder is built on its own with a 156.25 MHz clock and no pin assignments. That is the standard way to size and time a block before integrating it. Checkpoints and utilization/timing reports go to `vivado/out/`, and the log prints the worst setup slack (negative means timing failed). For a 25G MAC with a 64-bit datapath, change the clock in `constraints/lmd_ooc.xdc` to `-period 2.560` (390.625 MHz).

**Board integration (next step).** On the VCU118 the feeds arrive on the two QSFP28 cages, which connect to GTY transceivers. A full design adds, per feed:

- an Ethernet MAC + PCS/PMA in 10GBASE-R mode with a 64-bit AXI4-Stream interface. Options are the AMD 10G/25G Ethernet Subsystem IP (`xxv_ethernet`), or Alex Forencich's open-source `verilog-ethernet`, which includes VCU118 example designs;
- a small cut-through AXIS FIFO between the MAC and `lmd_ab_mux` (see the note in that file);
- a board-level XDC with the QSFP transceiver locations and reference clocks from the VCU118 board files or user guide (UG1224).

Feed A goes on QSFP1 and feed B on QSFP2, and `lmd_rx_top` runs on the MAC's RX clock.

## Running the testbench

With Icarus Verilog 11 or newer (`apt install iverilog`):

```
make sim        # generates vectors, runs the testbench, prints PASS/FAIL
```

With Vivado's simulator (after sourcing Vivado's `settings64.sh`):

```
make xsim
```

`make lint` runs Verilator lint, if installed.

The scenario covers sync, an A/B duplicate, in-order frames, a partial overlap, a gap, a heartbeat, a bad-FCS frame followed by its good B copy, a foreign EtherType, another channel, a truncated frame and a full 46-message frame, with random idle cycles in the stream.

## Routed networks

If feeds must cross a router, carry the same 18-byte header and messages in UDP. The header region becomes 14 + 20 + 8 + 18 = 60 bytes, so add 4 bytes of padding after `send_ts` to keep messages 8-byte aligned (beat 8). The decoder change is limited to the header beat indices.

## Next steps

- **Multi-channel:** keep `expected_seq` per channel in distributed RAM indexed by `channel_id`, instead of one decoder per channel.
- **Earlier hand-off:** emit the instrument ID on a message's first beat so the order book lookup starts three cycles sooner.
- **Gap recovery:** a retransmission request/response protocol over TCP or UDP, plus periodic snapshots.
- **Publisher:** an FPGA or kernel-bypass (ef_vi, DPDK, AF_XDP) encoder. `sw/lmd.py` is for testing only.
- **25G:** the same layout works on a 64-bit bus at 390.625 MHz or a 128-bit bus at 195 MHz (2 beats per message).
