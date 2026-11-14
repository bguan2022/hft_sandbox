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
| 0x07 | OPTION_QUOTE | Top-of-book quote for one option series (fields reused, below) |

**OPTION_QUOTE field reuse.** `instrument_id` names one option series (for example SPY 2026-11-20 600 C), with the id-to-series mapping coming from reference data. `side` = `'C'` or `'P'`, `order_id` = bid price, `price` = ask price (both 1e-9 units), `quantity` = `{bid_size[15:0], ask_size[15:0]}` in contracts. The decoder needs no change, since every message has the same 32-byte layout.

## Order entry

Orders use the same header and 32-byte message layout on EtherType `0x88B6`, one order per 64-byte frame. `channel_id` is the session id, and `seq` is the session's order sequence number.

| Offset in message | Size | Field | NEW_ORDER (type 0x10) |
|---|---|---|---|
| 0 | 1 | type | `0x10` |
| 1 | 1 | side | `'B'` / `'S'` |
| 2 | 2 | instrument_id | Option series |
| 4 | 4 | flags | bit 1 `IOC` (immediate-or-cancel) |
| 8 | 8 | client order id | Equals `seq` in the FPGA encoder |
| 16 | 8 | limit price | 1e-9 units |
| 24 | 4 | quantity | Contracts |
| 28 | 4 | reserved | 0 |

The frames go to an order gateway, which forwards them to a broker or exchange. Acknowledgements, fills and cancels are not defined yet.

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
| `rtl/lmd_opt_strategy.sv` | Buys a configured call when its ask is at or below a limit |
| `rtl/lmd_risk_gate.sv` | Pre-trade risk checks: kill switch, quantity, price collar, position, rate |
| `rtl/lmd_order_tx.sv` | Encodes approved orders as 64-byte NEW_ORDER frames to the MAC TX |
| `rtl/lmd_trader_top.sv` | Tick-to-trade top: receiver + strategy + risk + order encoder |
| `constraints/lmd_ooc.xdc` | 156.25 MHz clock and port timing for out-of-context builds |
| `vivado/build.tcl` | Synthesis and place & route for the VCU118 |
| `sw/lmd.py` | Reference encoder, parser, sequencer and a raw-socket sender for testing |
| `sim/gen_vectors.py` | Decoder test scenarios and a register-level model of the decoder |
| `sim/gen_trader_vectors.py` | SPY option quote scenarios and a model of strategy + risk |
| `sim/tb_lmd_decoder.sv`, `sim/tb_lmd_trader.sv` | Self-checking testbenches |
| `sim/run_xsim.sh` | Runs either testbench in Vivado's simulator |

**Interface.** 64-bit AXI4-Stream at 156.25 MHz (10GbE), frame byte 0 in `tdata[7:0]`, `tuser = 1` on the last beat for a bad FCS. This matches common MAC cores (e.g. AMD/Xilinx 10G/25G Ethernet subsystem, Alex Forencich's open-source `verilog-ethernet`). The decoder never back-pressures (`tready = 1`).

**Latency.** The first message of a frame occupies beats 4–7 and appears on `msg_valid` one clock (6.4 ns) after its last byte arrives, about 58 ns after the first byte of the frame reaches the decoder. Every later message also adds just one clock beyond its own wire time. MAC/PCS/PHY latency is extra and usually dominates; low-latency MAC IP and bypassing the RX FIFO matter more than the decoder from here.

**Cut-through trade-off.** Messages are emitted before the FCS is checked, which saves a full frame of latency. The consumer must be able to undo a frame when `frame_ok = 0`, for example by staging updates until `frame_done` or by keeping a shadow book. Bad FCS on a short, clean link is very rare, and the other feed's copy fills it in.

**Resources.** Roughly 1,000–1,500 flip-flops and a few 64-bit adders/comparators per channel, with no block RAM. That is well under 1% of the VCU118's XCVU9P, and it should close timing comfortably at 156.25 MHz. These are estimates until `make impl` has been run.

## Tick-to-trade: buying SPY calls

```
 feeds A/B ─► lmd_rx_top ─► lmd_opt_strategy ─► lmd_risk_gate ─► lmd_order_tx ─► MAC TX ─► order gateway
              (decode)      (series = cfg,       (kill, qty, collar,  (NEW_ORDER,
                             call, ask <= limit)  position, rate)      IOC, 8 beats)
```

**Strategy.** When an OPTION_QUOTE arrives for `cfg_instrument`, is a call, and has an ask at or below `cfg_max_price`, the strategy requests an immediate-or-cancel buy at the ask for `min(cfg_order_qty, ask_size)` contracts. If several quotes in one frame qualify, the latest wins.

**Risk gate.** Every request is checked in one clock before it can reach the wire. Rejections are counted, and `last_reject` holds the reason: 1 kill switch, 2 quantity, 3 price collar, 4 position, 5 rate. Position assumes every order fills, because fills are not fed back yet; that over-counts, which errs on the safe side.

**Latency.** From a decoded quote, the first byte of the order reaches the MAC TX three clocks later (19.2 ns at 156.25 MHz): strategy, risk gate, then encoder.
- With `SPECULATIVE = 1` the strategy acts on the quote immediately.
- With `SPECULATIVE = 0` (default) it waits for the frame's good FCS. For a frame carrying a single quote that costs nothing, since the quote ends on the frame's last beat. Each further message in the frame adds 4 beats (25.6 ns).

**Configuration.** `cfg_*` are plain ports. A board design would drive them from a host-writable register block (PCIe or AXI-Lite) so software can map SPY series to instrument ids, set limits and hit the kill switch. `ts_ns` should come from a PTP-disciplined clock.

**Production reality.** Real SPY option quotes come from OPRA, the consolidated options feed. That needs a data agreement, a colocated 10G/25G line and either an OPRA decoder in RTL or a feed handler that republishes LMD. Sending orders straight from an FPGA needs exchange connectivity, usually a broker's sponsored or direct market access. Under SEC Rule 15c3-5 the broker must apply its own pre-trade risk controls on top of yours. Retail broker APIs such as Schwab's are HTTPS/OAuth and can't be driven from this pipeline.

## Building for the VCU118

The RTL is SystemVerilog and targets the AMD/Xilinx VCU118 board, whose FPGA is a Virtex UltraScale+ XCVU9P (Vivado part `xcvu9p-flga2104-2L-e`).

```
make synth                  # synthesis only, lmd_trader_top
make impl                   # synthesis + place & route, lmd_trader_top
make impl TOP=lmd_rx_top    # receiver only
```

Both run Vivado in batch mode, out-of-context: the design is built on its own with a 156.25 MHz clock and no pin assignments. That is the standard way to size and time a block before integrating it. Checkpoints and utilization/timing reports go to `vivado/out/`, and the log prints the worst setup slack (negative means timing failed). For a 25G MAC with a 64-bit datapath, change the clock in `constraints/lmd_ooc.xdc` to `-period 2.560` (390.625 MHz).

**Board integration (next step).** On the VCU118 the feeds arrive on the two QSFP28 cages, which connect to GTY transceivers. A full design adds, per feed:

- an Ethernet MAC + PCS/PMA in 10GBASE-R mode with a 64-bit AXI4-Stream interface. Options are the AMD 10G/25G Ethernet Subsystem IP (`xxv_ethernet`), or Alex Forencich's open-source `verilog-ethernet`, which includes VCU118 example designs;
- a small cut-through AXIS FIFO between the MAC and `lmd_ab_mux` (see the note in that file);
- a board-level XDC with the QSFP transceiver locations and reference clocks from the VCU118 board files or user guide (UG1224).

Feed A goes on QSFP1 and feed B on QSFP2, and the design runs on the MAC's RX clock. Order frames leave through the TX side of a MAC toward the order gateway; if that MAC's TX clock differs from the RX clock, add an asynchronous AXIS FIFO.

## Running the testbenches

With Icarus Verilog 11 or newer (`apt install iverilog`):

```
make sim            # both testbenches, prints PASS/FAIL for each
make sim-decoder    # decoder only
make sim-trader     # tick-to-trade only
```

With Vivado's simulator (after sourcing Vivado's `settings64.sh`): `make xsim` and `make xsim-trader`. `make lint` runs Verilator lint, if installed.

**Decoder scenario:** sync, an A/B duplicate, in-order frames, a partial overlap, a gap, a heartbeat, a bad-FCS frame followed by its good B copy, a foreign EtherType, another channel, a truncated frame and a full 46-message frame, with random idle cycles in the stream.

**Trader scenario** (SPY 600 C, buy at or below $2.20, 10 contracts, position limit 25): an ask above the limit, a put and another underlying's call (ignored), a buy at $2.15, two qualifying quotes in one frame (the latest, size-limited to 4, is bought), a qualifying quote in a bad-FCS frame (no order) and its good B copy (buy 10), a duplicate frame (ignored), and a final quote rejected by the position limit. Each order frame is compared byte for byte with the Python model, except the timestamp.

## Routed networks

If feeds must cross a router, carry the same 18-byte header and messages in UDP. The header region becomes 14 + 20 + 8 + 18 = 60 bytes, so add 4 bytes of padding after `send_ts` to keep messages 8-byte aligned (beat 8). The decoder change is limited to the header beat indices.

## Next steps

- **Multi-channel:** keep `expected_seq` per channel in distributed RAM indexed by `channel_id`, instead of one decoder per channel.
- **Earlier hand-off:** emit the instrument ID on a message's first beat so the order book lookup starts three cycles sooner.
- **Gap recovery:** a retransmission request/response protocol over TCP or UDP, plus periodic snapshots.
- **Publisher:** an FPGA or kernel-bypass (ef_vi, DPDK, AF_XDP) encoder. `sw/lmd.py` is for testing only.
- **25G:** the same layout works on a 64-bit bus at 390.625 MHz or a 128-bit bus at 195 MHz (2 beats per message).
- **Order lifecycle:** acks, fills and cancels from the gateway, fed back into the risk gate's position.
- **Host control:** an AXI-Lite or PCIe register block for the `cfg_*` ports, the kill switch and the status counters.
- **Strategy:** compare against fair value from the underlying instead of a fixed price limit; watch several series.
