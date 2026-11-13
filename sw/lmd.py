"""LMD v1 - Low-latency Market Data over raw Ethernet.

Reference encoder, parser and sequencer (A/B arbitration + gap detection).
The sequencer mirrors the behaviour of rtl/lmd_decoder.v and is used to
generate expected results for the hardware testbench.

Frame layout (all multi-byte fields big-endian):

    off  len  field
    ---  ---  ------------------------------------------------------------
      0    6  dst MAC (multicast group, e.g. 01:00:5e:..)
      6    6  src MAC
     12    2  EtherType = 0x88B5 (IEEE 802 local experimental)
     14    1  version   = 1
     15    1  msg_count (0 = heartbeat)
     16    2  channel_id
     18    8  seq       (sequence number of the first message in the frame)
     26    6  send_ts   (ns since midnight, 48-bit)
     32  32n  messages  (fixed 32 bytes each, 8-byte aligned)

Message (32 bytes):

      0    1  type
      1    1  side ('B' / 'S', 0 when not applicable)
      2    2  instrument_id
      4    4  flags (bit0 = END_OF_EVENT)
      8    8  order_id
     16    8  price (signed, 1e-9 units)
     24    4  quantity
     28    4  ts_delta (ns; event_time = send_ts - ts_delta)
"""

from __future__ import annotations

import socket
import struct
from dataclasses import dataclass, field
from typing import List, Optional, Tuple

ETHERTYPE = 0x88B5
VERSION = 1

ETH_HDR_LEN = 14
LMD_HDR_LEN = 18
HDR_LEN = ETH_HDR_LEN + LMD_HDR_LEN  # 32 bytes = 4 beats on a 64-bit bus
MSG_LEN = 32                         # 4 beats on a 64-bit bus
MIN_FRAME_NO_FCS = 60
MAX_MSGS_STD_MTU = (1500 - LMD_HDR_LEN) // MSG_LEN  # 46
MAX_MSGS = 255

# Message types
MSG_ADD_ORDER = 0x01
MSG_MODIFY_ORDER = 0x02
MSG_DELETE_ORDER = 0x03
MSG_EXECUTE = 0x04
MSG_TRADE = 0x05
MSG_INSTRUMENT_STATUS = 0x06

SIDE_BUY = ord("B")
SIDE_SELL = ord("S")

FLAG_END_OF_EVENT = 0x0000_0001

MASK64 = (1 << 64) - 1

_LMD_HDR = struct.Struct(">BBHQ")        # version, count, channel, seq (12 bytes) + 6-byte ts
_MSG = struct.Struct(">BBHIQqII")        # 32 bytes
assert _MSG.size == MSG_LEN


@dataclass(frozen=True)
class Msg:
    type: int
    side: int = 0
    instrument: int = 0
    flags: int = 0
    order_id: int = 0
    price: int = 0
    qty: int = 0
    ts_delta: int = 0

    def pack(self) -> bytes:
        return _MSG.pack(self.type, self.side, self.instrument, self.flags,
                         self.order_id, self.price, self.qty, self.ts_delta)

    @classmethod
    def unpack(cls, b: bytes) -> "Msg":
        return cls(*_MSG.unpack(b))


@dataclass(frozen=True)
class Frame:
    channel: int
    seq: int
    send_ts: int
    msg_count: int
    msgs: Tuple[Msg, ...]      # complete messages actually present


def build_frame(dst_mac: bytes, src_mac: bytes, channel: int, seq: int,
                send_ts: int, msgs: List[Msg], *, ethertype: int = ETHERTYPE,
                version: int = VERSION, count_override: Optional[int] = None,
                pad: bool = True) -> bytes:
    """Build an Ethernet frame (without FCS; the MAC appends it)."""
    if len(msgs) > MAX_MSGS:
        raise ValueError("too many messages for one frame")
    count = len(msgs) if count_override is None else count_override
    eth = dst_mac + src_mac + struct.pack(">H", ethertype)
    hdr = _LMD_HDR.pack(version, count, channel, seq & MASK64) + (send_ts & ((1 << 48) - 1)).to_bytes(6, "big")
    frame = eth + hdr + b"".join(m.pack() for m in msgs)
    if pad and len(frame) < MIN_FRAME_NO_FCS:
        frame += bytes(MIN_FRAME_NO_FCS - len(frame))
    return frame


def parse_frame(frame: bytes) -> Optional[Frame]:
    """Parse a frame. Returns None if it is not an LMD v1 frame.

    Truncated frames are returned with only the complete messages present;
    callers decide validity by comparing len(msgs) with msg_count.
    """
    if len(frame) < HDR_LEN:
        return None
    if struct.unpack_from(">H", frame, 12)[0] != ETHERTYPE:
        return None
    version, count, channel, seq = _LMD_HDR.unpack_from(frame, ETH_HDR_LEN)
    if version != VERSION:
        return None
    send_ts = int.from_bytes(frame[26:32], "big")
    avail = (len(frame) - HDR_LEN) // MSG_LEN
    n = min(count, avail)
    msgs = tuple(Msg.unpack(frame[HDR_LEN + i * MSG_LEN: HDR_LEN + (i + 1) * MSG_LEN]) for i in range(n))
    return Frame(channel, seq, send_ts, count, msgs)


@dataclass
class FrameResult:
    accepted: bool
    ok: bool = False
    msgs: List[Tuple[int, Msg]] = field(default_factory=list)   # (seq, msg), emitted speculatively
    gap: Optional[Tuple[int, int]] = None                       # (first missing seq, count)
    duplicate: bool = False


class Sequencer:
    """A/B arbitration + gap detection for one channel.

    Feed frames from both feeds in arrival order. Rules (identical to the RTL):
      * first good-header frame syncs the sequencer
      * seq > expected                 -> gap reported, frame accepted
      * seq + count <= expected, n > 0 -> duplicate, frame dropped
      * seq <= expected < seq + count  -> partial overlap, leading messages skipped
      * messages are emitted as they arrive; `ok` arrives at end of frame and,
        if False, every message of that frame must be discarded
      * expected advances only on a frame that ends good
    """

    def __init__(self, channel: int):
        self.channel = channel
        self.expected = 0
        self.synced = False

    def on_frame(self, frame: bytes, fcs_ok: bool = True) -> FrameResult:
        f = parse_frame(frame)
        if f is None or f.channel != self.channel:
            return FrameResult(accepted=False)
        seq, count = f.seq, f.msg_count
        end = (seq + count) & MASK64
        skip = 0
        gap = None
        if not self.synced:
            pass
        elif seq > self.expected:
            gap = (self.expected, seq - self.expected)
        elif end <= self.expected and count != 0:
            return FrameResult(accepted=False, duplicate=True)
        else:
            skip = (self.expected - seq) & 0xFF
        res = FrameResult(accepted=True, gap=gap)
        for i, m in enumerate(f.msgs):
            if i >= skip:
                res.msgs.append(((seq + i) & MASK64, m))
        complete = len(frame) >= HDR_LEN + MSG_LEN * count
        res.ok = fcs_ok and complete
        if res.ok:
            if end > self.expected or not self.synced:
                self.expected = end
            self.synced = True
        return res


def send_raw(ifname: str, frame: bytes) -> None:
    """Send one frame on a Linux interface via AF_PACKET (needs CAP_NET_RAW).

    Fine for testing a decoder. A production publisher would use a kernel-bypass
    API (ef_vi, DPDK, AF_XDP) or transmit from the FPGA itself.
    """
    with socket.socket(socket.AF_PACKET, socket.SOCK_RAW) as s:
        s.bind((ifname, 0))
        s.send(frame)
