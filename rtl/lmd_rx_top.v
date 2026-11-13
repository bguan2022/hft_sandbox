// ============================================================================
// lmd_rx_top.v - A/B feed merge + LMD decoder for one channel
//
// Connect a_* and b_* to the RX AXI4-Stream of two 10G MACs (through small
// cut-through FIFOs, see lmd_ab_mux.v). For several channels, instantiate one
// decoder per channel behind the same mux.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module lmd_rx_top #(
    parameter [15:0] CHANNEL_ID = 16'h0001
)(
    input  wire        clk,
    input  wire        rst,

    input  wire [63:0] a_tdata,
    input  wire [7:0]  a_tkeep,
    input  wire        a_tvalid,
    output wire        a_tready,
    input  wire        a_tlast,
    input  wire        a_tuser,

    input  wire [63:0] b_tdata,
    input  wire [7:0]  b_tkeep,
    input  wire        b_tvalid,
    output wire        b_tready,
    input  wire        b_tlast,
    input  wire        b_tuser,

    output wire        msg_valid,
    output wire [63:0] msg_seq,
    output wire [7:0]  msg_type,
    output wire [7:0]  msg_side,
    output wire [15:0] msg_instrument,
    output wire [31:0] msg_flags,
    output wire [63:0] msg_order_id,
    output wire [63:0] msg_price,
    output wire [31:0] msg_qty,
    output wire [31:0] msg_ts_delta,
    output wire [47:0] msg_frame_ts,

    output wire        frame_done,
    output wire        frame_ok,

    output wire        gap_valid,
    output wire [63:0] gap_start,
    output wire [63:0] gap_count,

    output wire [63:0] expected_seq,
    output wire        synced,
    output wire [31:0] stat_frames,
    output wire [31:0] stat_dup_frames,
    output wire [31:0] stat_gaps,
    output wire [31:0] stat_bad_frames
);

    wire [63:0] m_tdata;
    wire [7:0]  m_tkeep;
    wire        m_tvalid, m_tready, m_tlast, m_tuser;

    lmd_ab_mux u_mux (
        .clk(clk), .rst(rst),
        .a_tdata(a_tdata), .a_tkeep(a_tkeep), .a_tvalid(a_tvalid), .a_tready(a_tready),
        .a_tlast(a_tlast), .a_tuser(a_tuser),
        .b_tdata(b_tdata), .b_tkeep(b_tkeep), .b_tvalid(b_tvalid), .b_tready(b_tready),
        .b_tlast(b_tlast), .b_tuser(b_tuser),
        .m_tdata(m_tdata), .m_tkeep(m_tkeep), .m_tvalid(m_tvalid), .m_tready(m_tready),
        .m_tlast(m_tlast), .m_tuser(m_tuser)
    );

    lmd_decoder #(.CHANNEL_ID(CHANNEL_ID)) u_dec (
        .clk(clk), .rst(rst),
        .s_axis_tdata(m_tdata), .s_axis_tkeep(m_tkeep), .s_axis_tvalid(m_tvalid),
        .s_axis_tready(m_tready), .s_axis_tlast(m_tlast), .s_axis_tuser(m_tuser),
        .msg_valid(msg_valid), .msg_seq(msg_seq), .msg_type(msg_type), .msg_side(msg_side),
        .msg_instrument(msg_instrument), .msg_flags(msg_flags), .msg_order_id(msg_order_id),
        .msg_price(msg_price), .msg_qty(msg_qty), .msg_ts_delta(msg_ts_delta),
        .msg_frame_ts(msg_frame_ts),
        .frame_done(frame_done), .frame_ok(frame_ok),
        .gap_valid(gap_valid), .gap_start(gap_start), .gap_count(gap_count),
        .expected_seq(expected_seq), .synced(synced),
        .stat_frames(stat_frames), .stat_dup_frames(stat_dup_frames),
        .stat_gaps(stat_gaps), .stat_bad_frames(stat_bad_frames)
    );

endmodule

`default_nettype wire
