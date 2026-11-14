// ============================================================================
// tb_lmd_trader.sv - self-checking testbench for lmd_trader_top
//
// SPY option quotes go in on feed A; every NEW_ORDER frame on the MAC TX port
// is compared byte-for-byte with gen_trader_vectors.py's expected orders
// (except the send timestamp). Run from this directory:
//   python3 gen_trader_vectors.py
//   iverilog -g2012 -o tb_trader.vvp ../rtl/*.sv tb_lmd_trader.sv && vvp tb_trader.vvp
// ============================================================================
`timescale 1ns/1ps
`default_nettype none
`include "trader_params.vh"

module tb_lmd_trader;

    logic clk = 1'b0;
    always #3.2 clk = ~clk;
    logic rst = 1'b1;

    logic [67:0]  stim    [0:`T_N_BEATS-1];
    logic [511:0] exp_ord [0:`T_N_ORDERS-1];

    logic [63:0] a_tdata = '0;
    logic        a_tvalid = 1'b0, a_tlast = 1'b0, a_tuser = 1'b0;
    logic        a_tready, b_tready;

    logic [63:0] tx_tdata;
    logic [7:0]  tx_tkeep;
    logic        tx_tvalid, tx_tlast, tx_tuser;

    logic [47:0] ts_ns = 48'd34_200_000_000_000;
    always @(posedge clk) ts_ns <= ts_ns + 48'd6;

    logic        gap_valid, synced;
    logic [63:0] gap_start, gap_count, expected_seq, last_order_seq;
    logic [31:0] position, stat_signals, stat_dropped, stat_sent, stat_rejected;
    logic [3:0]  last_reject;

    lmd_trader_top #(.SPECULATIVE(1'b0)) dut (
        .clk, .rst,
        .a_tdata, .a_tkeep(8'hFF), .a_tvalid, .a_tready, .a_tlast, .a_tuser,
        .b_tdata(64'd0), .b_tkeep(8'h00), .b_tvalid(1'b0), .b_tready, .b_tlast(1'b0), .b_tuser(1'b0),
        .tx_tdata, .tx_tkeep, .tx_tvalid, .tx_tready(1'b1), .tx_tlast, .tx_tuser,
        .ts_ns,
        .cfg_enable(`CFG_ENABLE), .cfg_instrument(`CFG_INSTRUMENT),
        .cfg_max_price(`CFG_MAX_PRICE), .cfg_order_qty(`CFG_ORDER_QTY),
        .cfg_kill(`CFG_KILL), .cfg_max_order_qty(`CFG_MAX_ORDER_QTY),
        .cfg_price_collar(`CFG_PRICE_COLLAR), .cfg_max_position(`CFG_MAX_POSITION),
        .cfg_min_gap_cycles(`CFG_MIN_GAP_CYCLES),
        .gap_valid, .gap_start, .gap_count, .synced, .expected_seq,
        .position, .stat_signals, .stat_dropped, .stat_sent, .stat_rejected,
        .last_reject, .last_order_seq
    );

    // send_ts (frame bytes 26..31) depends on simulation time: not compared
    localparam logic [511:0] TS_MASK = ~(512'hFFFF_FFFF_FFFF << 208);

    int n_ord = 0, errors = 0, beat_i = 0;
    int cycle = 0;
    logic [511:0] got;

    always @(posedge clk) cycle <= cycle + 1;

    initial begin
        $readmemh("trader_stream.hex",     stim);
        $readmemh("trader_exp_orders.hex", exp_ord);
        repeat (4) @(posedge clk);
        @(negedge clk) rst = 1'b0;
        for (int i = 0; i < `T_N_BEATS; i++) begin
            @(negedge clk);
            {a_tvalid, a_tuser, a_tlast, a_tdata} = stim[i][66:0];
        end
        @(negedge clk);
        a_tvalid = 1'b0; a_tlast = 1'b0; a_tuser = 1'b0;
        repeat (40) @(posedge clk);

        if (n_ord != `T_N_ORDERS)           begin errors++; $display("ERROR: %0d orders sent, expected %0d", n_ord, `T_N_ORDERS); end
        if (stat_rejected != `T_N_REJECTS) begin errors++; $display("ERROR: %0d rejects, expected %0d", stat_rejected, `T_N_REJECTS); end
        if (last_reject != `T_LAST_REJECT) begin errors++; $display("ERROR: last reject %0d, expected %0d", last_reject, `T_LAST_REJECT); end
        if (position != `T_POSITION)       begin errors++; $display("ERROR: position %0d, expected %0d", position, `T_POSITION); end
        if (stat_dropped != 0)             begin errors++; $display("ERROR: %0d signals dropped", stat_dropped); end
        if (tx_tuser !== 1'b0)             begin errors++; $display("ERROR: tx_tuser set"); end

        $display("signals=%0d sent=%0d rejected=%0d (last reason %0d) position=%0d",
                 stat_signals, stat_sent, stat_rejected, last_reject, position);
        if (errors == 0) $display("PASS: %0d orders checked", n_ord);
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    // Collect TX beats into a 64-byte frame and compare
    always @(posedge clk) if (!rst && tx_tvalid) begin
        got[64*beat_i +: 64] = tx_tdata;
        if (tx_tkeep !== 8'hFF) begin errors++; $display("ERROR: tkeep %h", tx_tkeep); end
        if (tx_tlast) begin
            if (beat_i != 7) begin
                errors++; $display("ERROR: order frame has %0d beats", beat_i + 1);
            end else if (n_ord >= `T_N_ORDERS || (got & TS_MASK) !== (exp_ord[n_ord] & TS_MASK)) begin
                errors++;
                $display("ERROR order %0d:\n  got %h\n  exp %h", n_ord, got, exp_ord[n_ord]);
            end else begin
                $display("order %0d ok, frame end at cycle %0d", n_ord, cycle);
            end
            n_ord++;
            beat_i = 0;
        end else begin
            beat_i++;
        end
    end

endmodule

`default_nettype wire
