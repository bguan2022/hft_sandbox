// ============================================================================
// lmd_decoder.v - LMD v1 market data decoder (one channel)
//
// Input : 64-bit AXI4-Stream from a 10G MAC RX (FCS already stripped),
//         byte 0 of the frame in tdata[7:0]. tuser=1 on the tlast beat marks
//         a bad frame (FCS / PHY error), as most MAC cores report it.
// Output: one fully decoded 32-byte message per msg_valid pulse.
//
// Cut-through: a message is emitted the cycle after its 4th beat arrives,
// before the frame's FCS has been checked. frame_done/frame_ok follow on the
// frame's last beat; if frame_ok=0, every message of that frame must be
// discarded. The expected sequence number only advances on good frames, so
// the copy of the frame on the other feed (A/B) is then delivered normally.
//
// Latency at 156.25 MHz (6.4 ns/beat): the first message of a frame occupies
// beats 4..7 and appears on msg_valid one cycle after beat 7, i.e. one clock
// after the last byte of the message comes off the MAC.
//
// Frame beats (64-bit bus):
//   beat 0 : dst MAC[0:5], src MAC[0:1]
//   beat 1 : src MAC[2:5], EtherType, version, msg_count
//   beat 2 : channel_id, seq[63:16]
//   beat 3 : seq[15:0], send_ts[47:0]
//   beat 4+4k+0 : type, side, instrument_id, flags
//   beat 4+4k+1 : order_id
//   beat 4+4k+2 : price
//   beat 4+4k+3 : qty, ts_delta
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module lmd_decoder #(
    parameter [15:0] ETHERTYPE  = 16'h88B5,
    parameter [7:0]  VERSION    = 8'h01,
    parameter [15:0] CHANNEL_ID = 16'h0001
)(
    input  wire        clk,
    input  wire        rst,

    // AXI4-Stream from MAC RX
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,   // unused: LMD frames are 8-byte aligned
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,

    // Decoded messages
    output reg         msg_valid,
    output reg  [63:0] msg_seq,
    output reg  [7:0]  msg_type,
    output reg  [7:0]  msg_side,
    output reg  [15:0] msg_instrument,
    output reg  [31:0] msg_flags,
    output reg  [63:0] msg_order_id,
    output reg  [63:0] msg_price,
    output reg  [31:0] msg_qty,
    output reg  [31:0] msg_ts_delta,
    output reg  [47:0] msg_frame_ts,

    // End of an accepted frame (frame_ok=0: discard this frame's messages)
    output reg         frame_done,
    output reg         frame_ok,

    // Sequence gap detected (request recovery for [gap_start, gap_start+gap_count))
    output reg         gap_valid,
    output reg  [63:0] gap_start,
    output reg  [63:0] gap_count,

    // Status
    output reg  [63:0] expected_seq,
    output reg         synced,
    output reg  [31:0] stat_frames,
    output reg  [31:0] stat_dup_frames,
    output reg  [31:0] stat_gaps,
    output reg  [31:0] stat_bad_frames
);

    // Fully pipelined: never back-pressures the MAC.
    assign s_axis_tready = 1'b1;

    // Byte lanes of the current beat
    wire [7:0] b0 = s_axis_tdata[ 7: 0];
    wire [7:0] b1 = s_axis_tdata[15: 8];
    wire [7:0] b2 = s_axis_tdata[23:16];
    wire [7:0] b3 = s_axis_tdata[31:24];
    wire [7:0] b4 = s_axis_tdata[39:32];
    wire [7:0] b5 = s_axis_tdata[47:40];
    wire [7:0] b6 = s_axis_tdata[55:48];
    wire [7:0] b7 = s_axis_tdata[63:56];

    wire beat_en = s_axis_tvalid;

    // Frame state
    reg  [10:0] beat;          // index of the current beat within the frame
    reg         hdr_match;     // EtherType and version matched
    reg  [7:0]  count;         // msg_count
    reg  [15:0] channel;
    reg  [47:0] seq_hi;        // seq[63:16]
    reg  [47:0] frame_ts;
    reg         accept;        // frame passed sequencing, messages are decoded
    reg  [7:0]  skip;          // leading messages already delivered
    reg  [63:0] frame_seq;
    reg  [63:0] frame_end;     // frame_seq + count
    reg  [1:0]  mbeat;         // beat within the current message
    reg  [7:0]  midx;          // message index within the frame

    // Message fields collected over beats 0..2 of each message
    reg  [7:0]  r_type, r_side;
    reg  [15:0] r_instr;
    reg  [31:0] r_flags;
    reg  [63:0] r_oid, r_price;

    // Sequencing decision, evaluated on beat 3
    wire [63:0] seq_w       = {seq_hi, b0, b1};
    wire [63:0] end_w       = seq_w + {56'd0, count};
    wire        hdr_ok      = hdr_match && (channel == CHANNEL_ID);
    wire        is_gap      = synced && (seq_w > expected_seq);
    wire        is_dup      = synced && (end_w <= expected_seq) && (count != 8'd0);
    wire [63:0] overlap     = expected_seq - seq_w;     // used only when seq_w <= expected < end_w

    // A complete frame's last beat index is at least 3 + 4*count
    wire [10:0] last_needed = 11'd3 + {1'b0, count, 2'b00};

    always @(posedge clk) begin
        msg_valid  <= 1'b0;
        frame_done <= 1'b0;
        gap_valid  <= 1'b0;

        if (rst) begin
            beat            <= 11'd0;
            hdr_match       <= 1'b0;
            accept          <= 1'b0;
            mbeat           <= 2'd0;
            midx            <= 8'd0;
            skip            <= 8'd0;
            synced          <= 1'b0;
            expected_seq    <= 64'd0;
            frame_ok        <= 1'b0;
            stat_frames     <= 32'd0;
            stat_dup_frames <= 32'd0;
            stat_gaps       <= 32'd0;
            stat_bad_frames <= 32'd0;
        end else if (beat_en) begin
            // ---- beat counter (saturating; resets after tlast)
            if (s_axis_tlast)
                beat <= 11'd0;
            else if (beat != 11'h7FF)
                beat <= beat + 11'd1;

            case (beat)
                11'd0: ; // destination MAC: multicast filtering is done in the MAC

                11'd1: begin
                    hdr_match <= ({b4, b5} == ETHERTYPE) && (b6 == VERSION);
                    count     <= b7;
                end

                11'd2: begin
                    channel <= {b0, b1};
                    seq_hi  <= {b2, b3, b4, b5, b6, b7};
                end

                11'd3: begin
                    frame_ts  <= {b2, b3, b4, b5, b6, b7};
                    frame_seq <= seq_w;
                    frame_end <= end_w;
                    mbeat     <= 2'd0;
                    midx      <= 8'd0;
                    skip      <= 8'd0;
                    if (!hdr_ok || s_axis_tlast) begin
                        accept <= 1'b0;                       // not ours / runt
                    end else if (!synced || is_gap) begin
                        accept <= 1'b1;                       // first frame, or frame after a gap
                        if (is_gap) begin
                            gap_valid <= 1'b1;
                            gap_start <= expected_seq;
                            gap_count <= seq_w - expected_seq;
                            stat_gaps <= stat_gaps + 32'd1;
                        end
                    end else if (is_dup) begin
                        accept          <= 1'b0;              // already delivered by the other feed
                        stat_dup_frames <= stat_dup_frames + 32'd1;
                    end else begin
                        accept <= 1'b1;                       // in order, or partial overlap
                        skip   <= overlap[7:0];
                    end
                end

                default: if (accept) begin
                    mbeat <= mbeat + 2'd1;
                    case (mbeat)
                        2'd0: begin
                            r_type  <= b0;
                            r_side  <= b1;
                            r_instr <= {b2, b3};
                            r_flags <= {b4, b5, b6, b7};
                        end
                        2'd1: r_oid   <= {b0, b1, b2, b3, b4, b5, b6, b7};
                        2'd2: r_price <= {b0, b1, b2, b3, b4, b5, b6, b7};
                        2'd3: begin
                            if ((midx < count) && (midx >= skip)) begin
                                msg_valid      <= 1'b1;
                                msg_seq        <= frame_seq + {56'd0, midx};
                                msg_type       <= r_type;
                                msg_side       <= r_side;
                                msg_instrument <= r_instr;
                                msg_flags      <= r_flags;
                                msg_order_id   <= r_oid;
                                msg_price      <= r_price;
                                msg_qty        <= {b0, b1, b2, b3};
                                msg_ts_delta   <= {b4, b5, b6, b7};
                                msg_frame_ts   <= frame_ts;
                            end
                            if (midx != 8'hFF)
                                midx <= midx + 8'd1;
                        end
                    endcase
                end
            endcase

            // ---- end of frame: commit or abort
            if (s_axis_tlast) begin
                if (accept) begin
                    frame_done <= 1'b1;
                    if (!s_axis_tuser && (beat >= last_needed)) begin
                        frame_ok    <= 1'b1;
                        stat_frames <= stat_frames + 32'd1;
                        synced      <= 1'b1;
                        if (!synced || (frame_end > expected_seq))
                            expected_seq <= frame_end;
                    end else begin
                        frame_ok        <= 1'b0;              // bad FCS or truncated
                        stat_bad_frames <= stat_bad_frames + 32'd1;
                    end
                end
                accept <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
