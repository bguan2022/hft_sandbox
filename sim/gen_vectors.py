#!/usr/bin/env python3
"""Generate test vectors for tb_lmd_decoder.v and self-check the design.

1. Builds a scenario of frames as they would leave the A/B mux (duplicates,
   overlap, gap, heartbeat, bad FCS, foreign EtherType, other channel,
   truncated frame) using the reference encoder in sw/lmd.py.
2. Runs the frame-level reference Sequencer to get expected results.
3. Runs a cycle-by-cycle model that mirrors rtl/lmd_decoder.v register by
   register, and asserts both agree.
4. Writes stream.hex, exp_msgs.hex, exp_frames.hex, exp_gaps.hex, params.vh.
"""

import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "sw"))

import lmd  # noqa: E402
from lmd import Msg, Sequencer, build_frame  # noqa: E402

CHANNEL = 1
DST = bytes.fromhex("01005e000101")
SRC = bytes.fromhex("020000000001")
MASK64 = (1 << 64) - 1


def mk_msgs(seq0, n, instrument=7):
    out = []
    for i in range(n):
        s = seq0 + i
        out.append(Msg(type=lmd.MSG_ADD_ORDER + (s % 5),
                       side=lmd.SIDE_BUY if s % 2 else lmd.SIDE_SELL,
                       instrument=instrument,
                       flags=lmd.FLAG_END_OF_EVENT if i == n - 1 else 0,
                       order_id=0x1000_0000_0000 + s,
                       price=(-1 if s % 3 == 0 else 1) * (101_250_000_000 + s * 10_000_000),
                       qty=100 * s,
                       ts_delta=250 + s))
    return out


def frame(seq, n, ts, **kw):
    return build_frame(DST, SRC, kw.pop("channel", CHANNEL), seq, ts, mk_msgs(seq, n), **kw)


def scenario():
    """List of (description, frame_bytes, fcs_ok) in arrival order after the mux."""
    t = 34_200_000_000_000  # 09:30:00 in ns since midnight
    f = []
    f.append(("seq 1-3 (A) syncs", frame(1, 3, t), True))
    f.append(("seq 1-3 (B) duplicate", frame(1, 3, t), True))
    f.append(("seq 4-5 in order", frame(4, 2, t + 1000), True))
    f.append(("seq 5-7 overlap, skip 1", frame(5, 3, t + 2000), True))
    f.append(("seq 10-11 after gap 8-9", frame(10, 2, t + 3000), True))
    f.append(("heartbeat seq 12", frame(12, 0, t + 4000), True))
    f.append(("seq 12-13 bad FCS", frame(12, 2, t + 5000), False))
    f.append(("seq 12-13 (B copy) good", frame(12, 2, t + 5000), True))
    f.append(("foreign EtherType", frame(14, 2, t + 6000, ethertype=0x0800), True))
    f.append(("channel 2", frame(14, 2, t + 6000, channel=2), True))
    trunc = build_frame(DST, SRC, CHANNEL, 14, t + 7000, mk_msgs(14, 2), count_override=3)
    f.append(("seq 14 count=3 truncated after 2", trunc, True))
    f.append(("seq 14 good", frame(14, 1, t + 8000), True))
    f.append(("seq 15-60 full 46-msg frame", frame(15, lmd.MAX_MSGS_STD_MTU, t + 9000), True))
    return f


def to_beats(frame_bytes, fcs_ok, rng):
    """Split into 64-bit beats (byte 0 -> bits [7:0]); random idle bubbles."""
    beats = []
    chunks = [frame_bytes[i:i + 8] for i in range(0, len(frame_bytes), 8)]
    for i, c in enumerate(chunks):
        if rng.random() < 0.15:
            beats.append((0, 0, 0, 0))
        last = i == len(chunks) - 1
        data = int.from_bytes(c.ljust(8, b"\0"), "little")
        beats.append((1, int(last and not fcs_ok), int(last), data))
    return beats


def rtl_model(beats, channel_id=CHANNEL):
    """Register-level mirror of rtl/lmd_decoder.v (nonblocking semantics)."""
    r = dict(beat=0, hdr_match=0, count=0, channel=0, seq_hi=0, frame_ts=0, accept=0, skip=0,
             frame_seq=0, frame_end=0, mbeat=0, midx=0, synced=0, expected=0,
             r_type=0, r_side=0, r_instr=0, r_flags=0, r_oid=0, r_price=0)
    msgs, frames, gaps = [], [], []
    for valid, tuser, tlast, data in beats:
        if not valid:
            continue
        b = [(data >> (8 * i)) & 0xFF for i in range(8)]
        be = lambda lo, hi: int.from_bytes(bytes(b[lo:hi]), "big")  # noqa: E731
        o = dict(r)          # old (register) values
        n = {}               # next values

        n["beat"] = 0 if tlast else min(o["beat"] + 1, 0x7FF)
        beat = o["beat"]
        if beat == 1:
            n["hdr_match"] = int(be(4, 6) == lmd.ETHERTYPE and b[6] == lmd.VERSION)
            n["count"] = b[7]
        elif beat == 2:
            n["channel"] = be(0, 2)
            n["seq_hi"] = be(2, 8)
        elif beat == 3:
            seq_w = (o["seq_hi"] << 16) | be(0, 2)
            end_w = (seq_w + o["count"]) & MASK64
            hdr_ok = o["hdr_match"] and o["channel"] == channel_id
            is_gap = o["synced"] and seq_w > o["expected"]
            is_dup = o["synced"] and end_w <= o["expected"] and o["count"] != 0
            n.update(frame_ts=be(2, 8), frame_seq=seq_w, frame_end=end_w, mbeat=0, midx=0, skip=0)
            if not hdr_ok or tlast:
                n["accept"] = 0
            elif not o["synced"] or is_gap:
                n["accept"] = 1
                if is_gap:
                    gaps.append((o["expected"], (seq_w - o["expected"]) & MASK64))
            elif is_dup:
                n["accept"] = 0
            else:
                n["accept"] = 1
                n["skip"] = (o["expected"] - seq_w) & 0xFF
        elif o["accept"]:
            n["mbeat"] = (o["mbeat"] + 1) & 3
            mb = o["mbeat"]
            if mb == 0:
                n.update(r_type=b[0], r_side=b[1], r_instr=be(2, 4), r_flags=be(4, 8))
            elif mb == 1:
                n["r_oid"] = be(0, 8)
            elif mb == 2:
                n["r_price"] = be(0, 8)
            else:
                if o["midx"] < o["count"] and o["midx"] >= o["skip"]:
                    msgs.append(((o["frame_seq"] + o["midx"]) & MASK64, o["r_type"], o["r_side"],
                                 o["r_instr"], o["r_flags"], o["r_oid"], o["r_price"],
                                 be(0, 4), be(4, 8), o["frame_ts"]))
                if o["midx"] != 0xFF:
                    n["midx"] = o["midx"] + 1

        if tlast:
            if o["accept"]:
                last_needed = 3 + 4 * o["count"]
                ok = int(not tuser and beat >= last_needed)
                frames.append(ok)
                if ok:
                    n["synced"] = 1
                    if not o["synced"] or o["frame_end"] > o["expected"]:
                        n["expected"] = o["frame_end"]
            n["accept"] = 0
        r.update(n)
    return msgs, frames, gaps


def reference(scn):
    seqr = Sequencer(CHANNEL)
    msgs, frames, gaps = [], [], []
    for _, fb, fcs_ok in scn:
        res = seqr.on_frame(fb, fcs_ok)
        if not res.accepted:
            continue
        if res.gap:
            gaps.append(res.gap)
        ts = int.from_bytes(fb[26:32], "big")
        for seq, m in res.msgs:
            msgs.append((seq, m.type, m.side, m.instrument, m.flags, m.order_id,
                         m.price & MASK64, m.qty, m.ts_delta, ts))
        frames.append(int(res.ok))
    return msgs, frames, gaps


def main():
    rng = random.Random(2026)
    scn = scenario()
    beats = []
    for _, fb, fcs_ok in scn:
        beats += to_beats(fb, fcs_ok, rng)
        beats += [(0, 0, 0, 0)] * rng.randint(0, 3)   # inter-frame gap

    ref = reference(scn)
    mdl = rtl_model(beats)
    for name, a, b in zip(("messages", "frames", "gaps"), ref, mdl):
        assert a == b, f"RTL model and reference disagree on {name}:\n{a}\n{b}"

    msgs, frames, gaps = mdl
    (HERE / "stream.hex").write_text(
        "".join(f"{(v << 66) | (u << 65) | (l << 64) | d:017x}\n" for v, u, l, d in beats))
    widths = (64, 8, 8, 16, 32, 64, 64, 32, 32, 48)
    lines = []
    for m in msgs:
        word = 0
        for val, w in zip(m, widths):
            word = (word << w) | (val & ((1 << w) - 1))
        lines.append(f"{word:092x}\n")
    (HERE / "exp_msgs.hex").write_text("".join(lines))
    (HERE / "exp_frames.hex").write_text("".join(f"{ok:x}\n" for ok in frames))
    (HERE / "exp_gaps.hex").write_text("".join(f"{s:016x}{c:016x}\n" for s, c in gaps))
    (HERE / "params.vh").write_text(
        f"`define N_BEATS  {len(beats)}\n`define N_MSGS   {len(msgs)}\n"
        f"`define N_FRAMES {len(frames)}\n`define N_GAPS   {len(gaps)}\n")

    print(f"{len(scn)} frames -> {len(beats)} beats; expect {len(msgs)} messages, "
          f"{len(frames)} accepted frames ({frames.count(0)} aborted), {len(gaps)} gap(s)")
    print("messages by seq:", [m[0] for m in msgs][:16], "...")
    print("gaps:", gaps)
    print("RTL model matches reference sequencer.")


if __name__ == "__main__":
    main()
