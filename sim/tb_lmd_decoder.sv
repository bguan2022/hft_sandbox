// ============================================================================
// tb_lmd_decoder.sv - self-checking testbench for lmd_decoder
//
// Vectors come from gen_vectors.py (run it first). Run from this directory:
//   iverilog -g2012 -o tb.vvp ../rtl/lmd_decoder.sv tb_lmd_decoder.sv && vvp tb.vvp
// or with Vivado xsim: ./run_xsim.sh
// ============================================================================
`timescale 1ns/1ps
`default_nettype none
`include "params.vh"

module tb_lmd_decoder;

    logic clk = 1'b0;
    always #3.2 clk = ~clk;               // 156.25 MHz, 10GbE 64-bit datapath
    logic rst = 1'b1;

    logic [67:0]  stim      [0:`N_BEATS-1];  // {pad, valid, tuser, tlast, tdata}
    logic [367:0] exp_msg   [0:`N_MSGS-1];
    logic [3:0]   exp_frame [0:`N_FRAMES-1];
    logic [127:0] exp_gap   [0:`N_GAPS-1];

    logic  [63:0] tdata  = 64'd0;
    logic         tvalid = 1'b0;
    logic         tlast  = 1'b0;
    logic         tuser  = 1'b0;
    logic        tready;

    logic        msg_valid, frame_done, frame_ok, gap_valid, synced;
    logic [63:0] msg_seq, msg_order_id, msg_price, gap_start, gap_count, expected_seq;
    logic [7:0]  msg_type, msg_side;
    logic [15:0] msg_instrument;
    logic [31:0] msg_flags, msg_qty, msg_ts_delta;
    logic [47:0] msg_frame_ts;
    logic [31:0] stat_frames, stat_dup_frames, stat_gaps, stat_bad_frames;

    lmd_decoder #(.CHANNEL_ID(16'h0001)) dut (
        .clk(clk), .rst(rst),
        .s_axis_tdata(tdata), .s_axis_tkeep(8'hFF), .s_axis_tvalid(tvalid),
        .s_axis_tready(tready), .s_axis_tlast(tlast), .s_axis_tuser(tuser),
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

    logic [367:0] got_msg;
    assign got_msg = {msg_seq, msg_type, msg_side, msg_instrument, msg_flags,
                            msg_order_id, msg_price, msg_qty, msg_ts_delta, msg_frame_ts};

    int i;
    int n_msg = 0, n_frame = 0, n_gap = 0, errors = 0;
    int cycle = 0, sof_cycle = -1, first_msg_latency = -1;

    always @(posedge clk) cycle <= cycle + 1;

    // ---- stimulus (driven on the falling edge)
    initial begin
        $readmemh("stream.hex",     stim);
        $readmemh("exp_msgs.hex",   exp_msg);
        $readmemh("exp_frames.hex", exp_frame);
        $readmemh("exp_gaps.hex",   exp_gap);
        repeat (4) @(posedge clk);
        @(negedge clk) rst = 1'b0;
        for (i = 0; i < `N_BEATS; i = i + 1) begin
            @(negedge clk);
            {tvalid, tuser, tlast, tdata} = stim[i][66:0];
        end
        @(negedge clk);
        tvalid = 1'b0; tlast = 1'b0; tuser = 1'b0;
        repeat (10) @(posedge clk);

        if (n_msg   != `N_MSGS)   begin errors = errors + 1; $display("ERROR: %0d messages, expected %0d", n_msg, `N_MSGS); end
        if (n_frame != `N_FRAMES) begin errors = errors + 1; $display("ERROR: %0d frames, expected %0d", n_frame, `N_FRAMES); end
        if (n_gap   != `N_GAPS)   begin errors = errors + 1; $display("ERROR: %0d gaps, expected %0d", n_gap, `N_GAPS); end
        if (tready !== 1'b1)      begin errors = errors + 1; $display("ERROR: decoder back-pressured"); end

        $display("frames ok=%0d dup=%0d bad=%0d gaps=%0d expected_seq=%0d",
                 stat_frames, stat_dup_frames, stat_bad_frames, stat_gaps, expected_seq);
        $display("first message out %0d cycles (%0d ns) after start of frame",
                 first_msg_latency, first_msg_latency * 64 / 10);
        if (errors == 0) $display("PASS: %0d messages, %0d frames, %0d gaps checked", n_msg, n_frame, n_gap);
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    // ---- checkers (outputs are registered, sampled one cycle later)
    always @(posedge clk) if (!rst) begin
        if (tvalid && sof_cycle < 0) sof_cycle = cycle;

        if (msg_valid) begin
            if (first_msg_latency < 0) first_msg_latency = cycle - sof_cycle;
            if (n_msg >= `N_MSGS || got_msg !== exp_msg[n_msg]) begin
                errors = errors + 1;
                $display("ERROR msg %0d: got seq=%0d type=%0d oid=%h, expected %h",
                         n_msg, msg_seq, msg_type, msg_order_id, exp_msg[n_msg]);
            end
            n_msg = n_msg + 1;
        end

        if (frame_done) begin
            if (n_frame >= `N_FRAMES || frame_ok !== exp_frame[n_frame][0]) begin
                errors = errors + 1;
                $display("ERROR frame %0d: frame_ok=%b", n_frame, frame_ok);
            end
            n_frame = n_frame + 1;
        end

        if (gap_valid) begin
            if (n_gap >= `N_GAPS || {gap_start, gap_count} !== exp_gap[n_gap]) begin
                errors = errors + 1;
                $display("ERROR gap %0d: start=%0d count=%0d", n_gap, gap_start, gap_count);
            end
            n_gap = n_gap + 1;
        end
    end

endmodule

`default_nettype wire
