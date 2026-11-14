// ============================================================================
// lmd_risk_gate.sv - pre-trade risk checks in hardware
//
// Every order request is checked in one cycle before it can reach the wire:
//   1 KILL      kill switch asserted
//   2 QTY       quantity is 0 or above cfg_max_order_qty
//   3 PRICE     limit price <= 0 or above cfg_max_price (price collar)
//   4 POSITION  position + quantity would exceed cfg_max_position
//   5 RATE      fewer than cfg_min_gap_cycles since the previous order
//
// Position assumes every order fills completely (no fill feedback yet), which
// over-counts and so errs on the safe side. Feed real fills/cancels back from
// the order gateway before relying on it for anything else.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module lmd_risk_gate (
    input  logic               clk,
    input  logic               rst,

    // Request from the strategy
    input  logic               ord_valid,
    output logic               ord_ready,
    input  logic [15:0]        ord_instrument,
    input  logic signed [63:0] ord_price,
    input  logic [15:0]        ord_qty,

    // Approved order to the encoder (one-cycle pulse)
    output logic               tx_valid,
    input  logic               tx_ready,
    output logic [15:0]        tx_instrument,
    output logic signed [63:0] tx_price,
    output logic [15:0]        tx_qty,

    // Limits (from host registers)
    input  logic               cfg_kill,
    input  logic [15:0]        cfg_max_order_qty,
    input  logic signed [63:0] cfg_max_price,
    input  logic [31:0]        cfg_max_position,
    input  logic [31:0]        cfg_min_gap_cycles,

    output logic [31:0]        position,
    output logic [31:0]        stat_sent,
    output logic [31:0]        stat_rejected,
    output logic [3:0]         last_reject
);

    localparam logic [3:0] REJ_NONE     = 4'd0;
    localparam logic [3:0] REJ_KILL     = 4'd1;
    localparam logic [3:0] REJ_QTY      = 4'd2;
    localparam logic [3:0] REJ_PRICE    = 4'd3;
    localparam logic [3:0] REJ_POSITION = 4'd4;
    localparam logic [3:0] REJ_RATE     = 4'd5;

    logic [31:0] since_last;   // cycles since the last approved order (saturating)
    logic [32:0] pos_after;
    logic [3:0]  reject;

    always_comb begin
        // tx_valid is registered, so hold the next request for one cycle after
        // an approval while the encoder latches it.
        ord_ready = tx_ready && !tx_valid;
        pos_after = {1'b0, position} + {17'd0, ord_qty};

        if (cfg_kill)                                                  reject = REJ_KILL;
        else if ((ord_qty == 16'd0) || (ord_qty > cfg_max_order_qty))  reject = REJ_QTY;
        else if ((ord_price <= 0) || (ord_price > cfg_max_price))      reject = REJ_PRICE;
        else if (pos_after > {1'b0, cfg_max_position})                 reject = REJ_POSITION;
        else if (since_last < cfg_min_gap_cycles)                      reject = REJ_RATE;
        else                                                           reject = REJ_NONE;
    end

    always_ff @(posedge clk) begin
        tx_valid <= 1'b0;

        if (rst) begin
            since_last    <= '1;
            position      <= '0;
            stat_sent     <= '0;
            stat_rejected <= '0;
            last_reject   <= REJ_NONE;
        end else begin
            if (since_last != 32'hFFFF_FFFF)
                since_last <= since_last + 32'd1;

            if (ord_valid && ord_ready) begin
                if (reject != REJ_NONE) begin
                    stat_rejected <= stat_rejected + 32'd1;
                    last_reject   <= reject;
                end else begin
                    tx_valid      <= 1'b1;
                    tx_instrument <= ord_instrument;
                    tx_price      <= ord_price;
                    tx_qty        <= ord_qty;
                    position      <= pos_after[31:0];
                    stat_sent     <= stat_sent + 32'd1;
                    since_last    <= '0;
                end
            end
        end
    end

endmodule

`default_nettype wire
