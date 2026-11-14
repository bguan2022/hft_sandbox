// ============================================================================
// lmd_opt_strategy.sv - buy a configured call option when its ask is cheap
//
// Watches decoded OPTION_QUOTE messages (type 0x07). When a quote is for the
// configured series (cfg_instrument, e.g. SPY 2026-11-20 600 C), it is a call,
// and its ask is at or below cfg_max_price, the module requests an
// immediate-or-cancel buy at the ask for min(cfg_order_qty, ask_size).
//
// OPTION_QUOTE field reuse from lmd_decoder:
//   msg_side  = 'C' / 'P'
//   msg_price = ask price (1e-9 units)       msg_order_id = bid price
//   msg_qty   = {bid_size[15:0], ask_size[15:0]}
//
// SPECULATIVE = 0 (default): act at frame_done of a good frame, on the
//   frame's latest qualifying quote. Never trades on a frame that later
//   fails its FCS check; costs the rest of the frame's wire time.
// SPECULATIVE = 1: act on the quote immediately (lowest latency). A quote
//   from a frame that later aborts may still trigger an order.
//
// Output is a valid/ready request held until the risk gate takes it. A new
// signal while a request is still waiting is dropped and counted.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module lmd_opt_strategy #(
    parameter bit SPECULATIVE = 1'b0
)(
    input  logic               clk,
    input  logic               rst,

    // From lmd_decoder
    input  logic               msg_valid,
    input  logic [7:0]         msg_type,
    input  logic [7:0]         msg_side,
    input  logic [15:0]        msg_instrument,
    input  logic [63:0]        msg_price,
    input  logic [31:0]        msg_qty,
    input  logic               frame_done,
    input  logic               frame_ok,

    // Configuration (from host registers)
    input  logic               cfg_enable,
    input  logic [15:0]        cfg_instrument,
    input  logic signed [63:0] cfg_max_price,
    input  logic [15:0]        cfg_order_qty,

    // Order request to the risk gate
    output logic               ord_valid,
    input  logic               ord_ready,
    output logic [15:0]        ord_instrument,
    output logic signed [63:0] ord_price,
    output logic [15:0]        ord_qty,

    output logic [31:0]        stat_signals,
    output logic [31:0]        stat_dropped
);

    localparam logic [7:0] MSG_OPTION_QUOTE = 8'h07;
    localparam logic [7:0] CALL             = 8'h43;   // 'C'

    logic               hit;
    logic [15:0]        ask_size, hit_qty;
    logic signed [63:0] ask;

    logic               cand_valid;
    logic [15:0]        cand_instr, cand_qty;
    logic signed [63:0] cand_price;

    logic               sig_valid;
    logic [15:0]        sig_instr, sig_qty;
    logic signed [63:0] sig_price;
    logic               slot_free;

    always_comb begin
        ask_size = msg_qty[15:0];
        ask      = $signed(msg_price);
        hit      = msg_valid && cfg_enable && (cfg_order_qty != 16'd0)
                && (msg_type == MSG_OPTION_QUOTE) && (msg_side == CALL)
                && (msg_instrument == cfg_instrument)
                && (ask_size != 16'd0) && (ask > 0) && (ask <= cfg_max_price);
        hit_qty  = (ask_size < cfg_order_qty) ? ask_size : cfg_order_qty;

        if (SPECULATIVE) begin
            sig_valid = hit;
            sig_instr = msg_instrument;
            sig_price = ask;
            sig_qty   = hit_qty;
        end else begin
            // The frame's last message and frame_done can arrive in the same cycle.
            sig_valid = frame_done && frame_ok && (hit || cand_valid);
            sig_instr = hit ? msg_instrument : cand_instr;
            sig_price = hit ? ask            : cand_price;
            sig_qty   = hit ? hit_qty        : cand_qty;
        end

        slot_free = !ord_valid || ord_ready;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            ord_valid    <= 1'b0;
            cand_valid   <= 1'b0;
            stat_signals <= '0;
            stat_dropped <= '0;
        end else begin
            if (ord_valid && ord_ready)
                ord_valid <= 1'b0;

            if (sig_valid) begin
                stat_signals <= stat_signals + 32'd1;
                if (slot_free) begin
                    ord_valid      <= 1'b1;
                    ord_instrument <= sig_instr;
                    ord_price      <= sig_price;
                    ord_qty        <= sig_qty;
                end else begin
                    stat_dropped <= stat_dropped + 32'd1;
                end
            end

            if (!SPECULATIVE) begin
                if (frame_done) begin
                    cand_valid <= 1'b0;
                end else if (hit) begin
                    cand_valid <= 1'b1;
                    cand_instr <= msg_instrument;
                    cand_price <= ask;
                    cand_qty   <= hit_qty;
                end
            end
        end
    end

endmodule

`default_nettype wire
