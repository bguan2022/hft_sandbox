// ============================================================================
// lmd_order_tx.sv - NEW_ORDER frame encoder to a 10G MAC TX (AXI4-Stream)
//
// Each approved order becomes one 64-byte frame (8 beats), EtherType 0x88B6:
//   bytes  0-31 : Ethernet + LMD header (version, count=1, session, seq, ts)
//   bytes 32-63 : NEW_ORDER  type 0x10, side 'B', instrument, flags (IOC),
//                 client order id (= seq), limit price, qty, reserved
// The frame is assembled from registers latched on the request, so beat 0
// goes out the cycle after the order is accepted.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module lmd_order_tx #(
    parameter logic [47:0] DST_MAC    = 48'h02_00_00_00_00_10,   // order gateway
    parameter logic [47:0] SRC_MAC    = 48'h02_00_00_00_00_01,
    parameter logic [15:0] SESSION_ID = 16'h0001,
    parameter logic [15:0] ETHERTYPE  = 16'h88B6,
    parameter logic [7:0]  VERSION    = 8'h01
)(
    input  logic               clk,
    input  logic               rst,

    input  logic               ord_valid,
    output logic               ord_ready,
    input  logic [15:0]        ord_instrument,
    input  logic signed [63:0] ord_price,
    input  logic [15:0]        ord_qty,

    input  logic [47:0]        ts_ns,          // time of day, ns since midnight

    output logic [63:0]        m_tdata,
    output logic [7:0]         m_tkeep,
    output logic               m_tvalid,
    input  logic               m_tready,
    output logic               m_tlast,
    output logic               m_tuser,

    output logic [63:0]        last_seq
);

    localparam logic [7:0]  MSG_NEW_ORDER = 8'h10;
    localparam logic [7:0]  SIDE_BUY      = 8'h42;   // 'B'
    localparam logic [31:0] FLAG_IOC      = 32'h0000_0002;

    logic        busy;
    logic [2:0]  beat;
    logic [63:0] seq;
    logic [15:0] r_instr, r_qty;
    logic [63:0] r_price;
    logic [47:0] r_ts;

    logic [7:0]  fb [0:63];   // frame bytes

    assign ord_ready = !busy;

    always_comb begin
        for (int i = 0; i < 6; i++) begin
            fb[i]      = DST_MAC[47 - 8*i -: 8];
            fb[6 + i]  = SRC_MAC[47 - 8*i -: 8];
            fb[26 + i] = r_ts[47 - 8*i -: 8];
        end
        fb[12] = ETHERTYPE[15:8];
        fb[13] = ETHERTYPE[7:0];
        fb[14] = VERSION;
        fb[15] = 8'd1;                                // msg_count
        fb[16] = SESSION_ID[15:8];
        fb[17] = SESSION_ID[7:0];
        for (int i = 0; i < 8; i++) begin
            fb[18 + i] = seq[63 - 8*i -: 8];          // frame seq
            fb[40 + i] = seq[63 - 8*i -: 8];          // client order id = seq
            fb[48 + i] = r_price[63 - 8*i -: 8];
        end
        fb[32] = MSG_NEW_ORDER;
        fb[33] = SIDE_BUY;
        fb[34] = r_instr[15:8];
        fb[35] = r_instr[7:0];
        for (int i = 0; i < 4; i++) begin
            fb[36 + i] = FLAG_IOC[31 - 8*i -: 8];
            fb[60 + i] = 8'd0;                        // reserved
        end
        fb[56] = 8'd0;
        fb[57] = 8'd0;
        fb[58] = r_qty[15:8];
        fb[59] = r_qty[7:0];

        for (int k = 0; k < 8; k++)
            m_tdata[8*k +: 8] = fb[8*beat + k];
    end

    assign m_tkeep  = 8'hFF;
    assign m_tvalid = busy;
    assign m_tlast  = busy && (beat == 3'd7);
    assign m_tuser  = 1'b0;
    assign last_seq = seq;

    always_ff @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            beat <= '0;
            seq  <= '0;
        end else if (!busy) begin
            if (ord_valid) begin
                busy    <= 1'b1;
                beat    <= '0;
                seq     <= seq + 64'd1;
                r_instr <= ord_instrument;
                r_price <= ord_price;
                r_qty   <= ord_qty;
                r_ts    <= ts_ns;
            end
        end else if (m_tready) begin
            beat <= beat + 3'd1;
            if (beat == 3'd7)
                busy <= 1'b0;
        end
    end

endmodule

`default_nettype wire
