// ============================================================================
// lmd_rx_top.sv - A/B feed merge + LMD decoder for one channel
//
// Connect a_* and b_* to the RX AXI4-Stream of two 10G MACs (through small
// cut-through FIFOs, see lmd_ab_mux.sv). For several channels, instantiate
// one decoder per channel behind the same mux.
//
// Synthesis target: AMD/Xilinx VCU118 (Virtex UltraScale+ xcvu9p-flga2104-2L-e),
// see vivado/build.tcl.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module lmd_rx_top #(
    parameter logic [15:0] CHANNEL_ID = 16'h0001
)(
    input  logic        clk,
    input  logic        rst,

    input  logic [63:0] a_tdata,
    input  logic [7:0]  a_tkeep,
    input  logic        a_tvalid,
    output logic        a_tready,
    input  logic        a_tlast,
    input  logic        a_tuser,

    input  logic [63:0] b_tdata,
    input  logic [7:0]  b_tkeep,
    input  logic        b_tvalid,
    output logic        b_tready,
    input  logic        b_tlast,
    input  logic        b_tuser,

    output logic        msg_valid,
    output logic [63:0] msg_seq,
    output logic [7:0]  msg_type,
    output logic [7:0]  msg_side,
    output logic [15:0] msg_instrument,
    output logic [31:0] msg_flags,
    output logic [63:0] msg_order_id,
    output logic [63:0] msg_price,
    output logic [31:0] msg_qty,
    output logic [31:0] msg_ts_delta,
    output logic [47:0] msg_frame_ts,

    output logic        frame_done,
    output logic        frame_ok,

    output logic        gap_valid,
    output logic [63:0] gap_start,
    output logic [63:0] gap_count,

    output logic [63:0] expected_seq,
    output logic        synced,
    output logic [31:0] stat_frames,
    output logic [31:0] stat_dup_frames,
    output logic [31:0] stat_gaps,
    output logic [31:0] stat_bad_frames
);

    logic [63:0] m_tdata;
    logic [7:0]  m_tkeep;
    logic        m_tvalid, m_tready, m_tlast, m_tuser;

    lmd_ab_mux u_mux (
        .clk, .rst,
        .a_tdata, .a_tkeep, .a_tvalid, .a_tready, .a_tlast, .a_tuser,
        .b_tdata, .b_tkeep, .b_tvalid, .b_tready, .b_tlast, .b_tuser,
        .m_tdata, .m_tkeep, .m_tvalid, .m_tready, .m_tlast, .m_tuser
    );

    lmd_decoder #(.CHANNEL_ID(CHANNEL_ID)) u_dec (
        .clk, .rst,
        .s_axis_tdata (m_tdata),
        .s_axis_tkeep (m_tkeep),
        .s_axis_tvalid(m_tvalid),
        .s_axis_tready(m_tready),
        .s_axis_tlast (m_tlast),
        .s_axis_tuser (m_tuser),
        .msg_valid, .msg_seq, .msg_type, .msg_side, .msg_instrument, .msg_flags,
        .msg_order_id, .msg_price, .msg_qty, .msg_ts_delta, .msg_frame_ts,
        .frame_done, .frame_ok,
        .gap_valid, .gap_start, .gap_count,
        .expected_seq, .synced,
        .stat_frames, .stat_dup_frames, .stat_gaps, .stat_bad_frames
    );

endmodule

`default_nettype wire
