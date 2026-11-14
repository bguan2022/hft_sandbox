#!/usr/bin/env python3
"""Test vectors for tb_lmd_trader.sv: SPY option quotes in, call orders out.

Scenario (strategy watches SPY 2026-11-20 600 C = instrument 101):
  * ask above the limit                       -> no order
  * a put and another underlying's call       -> no order
  * ask below the limit                       -> buy 10 @ ask
  * two qualifying quotes in one frame        -> act on the latest (size-limited to 4)
  * qualifying quote in a bad-FCS frame       -> no order (non-speculative mode)
  * the B copy of that frame                  -> buy 10
  * B copy of an earlier frame (duplicate)    -> ignored by the decoder
  * one more qualifying quote                 -> rejected: position limit

Expected order frames come from an event-level model of strategy + risk gate,
built on the reference Sequencer in sw/lmd.py.
"""

import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "sw"))
sys.path.insert(0, str(HERE))

import lmd  # noqa: E402
from gen_vectors import DST, SRC, CHANNEL, to_beats  # noqa: E402

USD = 1_000_000_000          # price units are 1e-9
SPY_600C = 101
SPY_600P = 102
QQQ_500C = 201

CFG = dict(
    enable=1,
    instrument=SPY_600C,
    max_price=int(2.20 * USD),     # buy when ask <= $2.20
    order_qty=10,
    kill=0,
    max_order_qty=50,
    price_collar=5 * USD,
    max_position=25,
    min_gap_cycles=0,
)
SESSION = 1
GATEWAY_MAC = bytes.fromhex("020000000010")
LOCAL_MAC = bytes.fromhex("020000000001")


def q(instr, pc, bid, ask, bid_sz, ask_sz):
    return lmd.option_quote(instr, pc, int(bid * USD), int(ask * USD), bid_sz, ask_sz)


def scenario():
    t = 34_200_000_000_000
    C, P = lmd.CALL, lmd.PUT
    frames = []
    seq = 1

    def add(desc, msgs, fcs_ok=True, reuse_seq=None):
        nonlocal seq
        s = seq if reuse_seq is None else reuse_seq
        frames.append((desc, lmd.build_frame(DST, SRC, CHANNEL, s, t + 1000 * len(frames), msgs), fcs_ok))
        if reuse_seq is None and fcs_ok:
            seq += len(msgs)
        return s

    add("ask above limit", [q(SPY_600C, C, 2.30, 2.35, 40, 50)])
    add("put + other underlying", [q(SPY_600P, P, 1.05, 1.10, 20, 20), q(QQQ_500C, C, 0.45, 0.50, 30, 30)])
    s_buy1 = add("ask 2.15 -> buy 10", [q(SPY_600C, C, 2.10, 2.15, 25, 30)])
    add("two hits, latest wins (size 4)", [q(SPY_600C, C, 2.05, 2.12, 10, 50), q(SPY_600C, C, 2.10, 2.18, 10, 4)])
    s_bad = add("ask 2.00 in bad-FCS frame", [q(SPY_600C, C, 1.95, 2.00, 50, 100)], fcs_ok=False)
    add("B copy of bad frame -> buy 10", [q(SPY_600C, C, 1.95, 2.00, 50, 100)], reuse_seq=s_bad)
    seq += 1
    add("duplicate of earlier frame", [q(SPY_600C, C, 2.10, 2.15, 25, 30)], reuse_seq=s_buy1)
    add("ask 2.05 -> rejected by position limit", [q(SPY_600C, C, 2.00, 2.05, 20, 20)])
    return frames


def model(frames):
    """Strategy (non-speculative) + risk gate, one decision per good frame."""
    seqr = lmd.Sequencer(CHANNEL)
    position, order_seq = 0, 0
    orders, rejects = [], []
    for _, fb, fcs_ok in frames:
        res = seqr.on_frame(fb, fcs_ok)
        if not res.accepted or not res.ok:
            continue
        cand = None
        for _, m in res.msgs:
            ask, ask_size = m.price, m.qty & 0xFFFF
            if (CFG["enable"] and CFG["order_qty"] and m.type == lmd.MSG_OPTION_QUOTE and m.side == lmd.CALL
                    and m.instrument == CFG["instrument"] and ask_size and 0 < ask <= CFG["max_price"]):
                cand = (m.instrument, ask, min(ask_size, CFG["order_qty"]))
        if cand is None:
            continue
        instr, price, qty = cand
        if CFG["kill"]:
            rejects.append(1)
        elif qty == 0 or qty > CFG["max_order_qty"]:
            rejects.append(2)
        elif price <= 0 or price > CFG["price_collar"]:
            rejects.append(3)
        elif position + qty > CFG["max_position"]:
            rejects.append(4)
        else:
            position += qty
            order_seq += 1
            orders.append(lmd.build_order_frame(GATEWAY_MAC, LOCAL_MAC, SESSION, order_seq, 0,
                                                lmd.new_order(instr, lmd.SIDE_BUY, price, qty, order_seq)))
    return orders, rejects, position


def main():
    rng = random.Random(7)
    frames = scenario()
    beats = []
    for _, fb, fcs_ok in frames:
        beats += to_beats(fb, fcs_ok, rng)
        beats += [(0, 0, 0, 0)] * 16          # leave room for the order to go out
    orders, rejects, position = model(frames)

    (HERE / "trader_stream.hex").write_text(
        "".join(f"{(v << 66) | (u << 65) | (l << 64) | d:017x}\n" for v, u, l, d in beats))
    # one 512-bit line per order frame, beat k in bits [64k+63:64k]
    lines = []
    for fr in orders:
        assert len(fr) == 64
        lines.append(f"{int.from_bytes(fr, 'little'):0128x}\n")
    (HERE / "trader_exp_orders.hex").write_text("".join(lines))
    signed64 = lambda v: f"64'sd{v}" if v >= 0 else f"-64'sd{-v}"  # noqa: E731
    (HERE / "trader_params.vh").write_text("".join([
        f"`define T_N_BEATS          {len(beats)}\n",
        f"`define T_N_ORDERS         {len(orders)}\n",
        f"`define T_N_REJECTS        {len(rejects)}\n",
        f"`define T_LAST_REJECT      {rejects[-1] if rejects else 0}\n",
        f"`define T_POSITION         {position}\n",
        f"`define CFG_ENABLE         1'b{CFG['enable']}\n",
        f"`define CFG_INSTRUMENT     16'd{CFG['instrument']}\n",
        f"`define CFG_MAX_PRICE      {signed64(CFG['max_price'])}\n",
        f"`define CFG_ORDER_QTY      16'd{CFG['order_qty']}\n",
        f"`define CFG_KILL           1'b{CFG['kill']}\n",
        f"`define CFG_MAX_ORDER_QTY  16'd{CFG['max_order_qty']}\n",
        f"`define CFG_PRICE_COLLAR   {signed64(CFG['price_collar'])}\n",
        f"`define CFG_MAX_POSITION   32'd{CFG['max_position']}\n",
        f"`define CFG_MIN_GAP_CYCLES 32'd{CFG['min_gap_cycles']}\n",
    ]))

    for desc, _, ok in frames:
        print(f"  {desc}{'' if ok else '  [bad FCS]'}")
    print(f"{len(beats)} beats -> {len(orders)} orders, {len(rejects)} rejected (reasons {rejects}), "
          f"final position {position}")
    for fr in orders:
        o = lmd.parse_frame(fr, lmd.ETHERTYPE_OE)
        m = o.msgs[0]
        print(f"  order seq={o.seq} instr={m.instrument} BUY {m.qty} @ {m.price / USD:.2f} IOC")


if __name__ == "__main__":
    main()
