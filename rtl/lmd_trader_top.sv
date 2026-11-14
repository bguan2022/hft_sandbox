// ============================================================================
// lmd_trader_top.sv - tick-to-trade: option quotes in, call orders out
//
//   feed A/B ─► lmd_rx_top ─► lmd_opt_strategy ─► lmd_risk_gate ─► lmd_order_tx ─► MAC TX
//              (merge, dedup,  (configured call,   (kill, qty, price,  (64-byte NEW_ORDER
//               decode)         ask <= limit)        position, rate)     frame, IOC)
//
// cfg_* inputs would come from a host-writable register block (PCIe or
// AXI-Lite) in a board design. ts_ns should come from a PTP-disciplined
// time-of-day counter.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module lmd_trader_top #(
    parameter logic [15:0] CHANNEL_ID  = 16'h0001,
    parameter logic [15:0] SESSION_ID  = 16'h0001,
    parameter logic [47:0] GATEWAY_MAC = 48'h02_00_00_00_00_10,
    parameter logic [47:0] LOCAL_MAC   = 48'h02_00_00_00_00_01,
    parameter bit          SPECULATIVE = 1'b0
)(
    input  logic               clk,
    input  logic               rst,

    // Market data, feeds A and B (MAC RX)
    input  logic [63:0]        a_tdata,
    input  logic [7:0]         a_tkeep,
    input  logic               a_tvalid,
    output logic               a_tready,
    input  logic               a_tlast,
    input  logic               a_tuser,

    input  logic [63:0]        b_tdata,
    input  logic [7:0]         b_tkeep,
    input  logic               b_tvalid,
    output logic               b_tready,
    input  logic               b_tlast,
    input  logic               b_tuser,

    // Orders (MAC TX)
    output logic [63:0]        tx_tdata,
    output logic [7:0]         tx_tkeep,
    output logic               tx_tvalid,
    input  logic               tx_tready,
    output logic               tx_tlast,
    output logic               tx_tuser,

    input  logic [47:0]        ts_ns,

    // Strategy configuration
    input  logic               cfg_enable,
    input  logic [15:0]        cfg_instrument,
    input  logic signed [63:0] cfg_max_price,
    input  logic [15:0]        cfg_order_qty,

    // Risk limits
    input  logic               cfg_kill,
    input  logic [15:0]        cfg_max_order_qty,
    input  logic signed [63:0] cfg_price_collar,
    input  logic [31:0]        cfg_max_position,
    input  logic [31:0]        cfg_min_gap_cycles,

    // Status
    output logic               gap_valid,
    output logic [63:0]        gap_start,
    output logic [63:0]        gap_count,
    output logic               synced,
    output logic [63:0]        expected_seq,
    output logic [31:0]        position,
    output logic [31:0]        stat_signals,
    output logic [31:0]        stat_dropped,
    output logic [31:0]        stat_sent,
    output logic [31:0]        stat_rejected,
    output logic [3:0]         last_reject,
    output logic [63:0]        last_order_seq
);

    // ---- decoded market data
    logic        msg_valid, frame_done, frame_ok;
    logic [63:0] msg_seq, msg_order_id, msg_price;
    logic [7:0]  msg_type, msg_side;
    logic [15:0] msg_instrument;
    logic [31:0] msg_flags, msg_qty, msg_ts_delta;
    logic [47:0] msg_frame_ts;
    logic [31:0] stat_frames, stat_dup_frames, stat_gaps, stat_bad_frames;

    lmd_rx_top #(.CHANNEL_ID(CHANNEL_ID)) u_rx (
        .clk, .rst,
        .a_tdata, .a_tkeep, .a_tvalid, .a_tready, .a_tlast, .a_tuser,
        .b_tdata, .b_tkeep, .b_tvalid, .b_tready, .b_tlast, .b_tuser,
        .msg_valid, .msg_seq, .msg_type, .msg_side, .msg_instrument, .msg_flags,
        .msg_order_id, .msg_price, .msg_qty, .msg_ts_delta, .msg_frame_ts,
        .frame_done, .frame_ok,
        .gap_valid, .gap_start, .gap_count,
        .expected_seq, .synced,
        .stat_frames, .stat_dup_frames, .stat_gaps, .stat_bad_frames
    );

    // ---- strategy
    logic               sreq_valid, sreq_ready;
    logic [15:0]        sreq_instr, sreq_qty;
    logic signed [63:0] sreq_price;

    lmd_opt_strategy #(.SPECULATIVE(SPECULATIVE)) u_strategy (
        .clk, .rst,
        .msg_valid, .msg_type, .msg_side, .msg_instrument, .msg_price, .msg_qty,
        .frame_done, .frame_ok,
        .cfg_enable, .cfg_instrument, .cfg_max_price, .cfg_order_qty,
        .ord_valid(sreq_valid), .ord_ready(sreq_ready),
        .ord_instrument(sreq_instr), .ord_price(sreq_price), .ord_qty(sreq_qty),
        .stat_signals, .stat_dropped
    );

    // ---- risk
    logic               ok_valid, ok_ready;
    logic [15:0]        ok_instr, ok_qty;
    logic signed [63:0] ok_price;

    lmd_risk_gate u_risk (
        .clk, .rst,
        .ord_valid(sreq_valid), .ord_ready(sreq_ready),
        .ord_instrument(sreq_instr), .ord_price(sreq_price), .ord_qty(sreq_qty),
        .tx_valid(ok_valid), .tx_ready(ok_ready),
        .tx_instrument(ok_instr), .tx_price(ok_price), .tx_qty(ok_qty),
        .cfg_kill, .cfg_max_order_qty,
        .cfg_max_price(cfg_price_collar),
        .cfg_max_position, .cfg_min_gap_cycles,
        .position, .stat_sent, .stat_rejected, .last_reject
    );

    // ---- order encoder
    lmd_order_tx #(
        .DST_MAC(GATEWAY_MAC), .SRC_MAC(LOCAL_MAC), .SESSION_ID(SESSION_ID)
    ) u_tx (
        .clk, .rst,
        .ord_valid(ok_valid), .ord_ready(ok_ready),
        .ord_instrument(ok_instr), .ord_price(ok_price), .ord_qty(ok_qty),
        .ts_ns,
        .m_tdata(tx_tdata), .m_tkeep(tx_tkeep), .m_tvalid(tx_tvalid),
        .m_tready(tx_tready), .m_tlast(tx_tlast), .m_tuser(tx_tuser),
        .last_seq(last_order_seq)
    );

endmodule

`default_nettype wire
