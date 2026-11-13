// ============================================================================
// lmd_ab_mux.sv - frame-granular A/B feed merge
//
// Exchanges and internal distributors send every frame twice, on two
// independent networks (A and B). This mux forwards whole frames from either
// feed in arrival order with zero added latency for the frame that arrives
// first; the decoder then drops the duplicate by sequence number.
//
// While one feed's frame is passing through, the other feed is held with
// tready=0. MAC RX paths cannot be back-pressured, so put a small cut-through
// AXIS FIFO (>= 1 max-size frame, e.g. 2 KB) between each MAC and this mux.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module lmd_ab_mux (
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

    output logic [63:0] m_tdata,
    output logic [7:0]  m_tkeep,
    output logic        m_tvalid,
    input  logic        m_tready,
    output logic        m_tlast,
    output logic        m_tuser
);

    logic busy;   // inside a frame
    logic sel;    // 0 = A, 1 = B (valid while busy)
    logic cur;

    // Between frames, take whichever feed has data; A wins a tie.
    always_comb begin
        cur      = busy ? sel : ~a_tvalid;
        m_tdata  = cur ? b_tdata  : a_tdata;
        m_tkeep  = cur ? b_tkeep  : a_tkeep;
        m_tvalid = cur ? b_tvalid : a_tvalid;
        m_tlast  = cur ? b_tlast  : a_tlast;
        m_tuser  = cur ? b_tuser  : a_tuser;
        a_tready = m_tready & ~cur;
        b_tready = m_tready &  cur;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            sel  <= 1'b0;
        end else if (m_tvalid && m_tready) begin
            busy <= ~m_tlast;
            sel  <= cur;
        end
    end

endmodule

`default_nettype wire
