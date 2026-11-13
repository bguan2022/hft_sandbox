// ============================================================================
// lmd_ab_mux.v - frame-granular A/B feed merge
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

    output wire [63:0] m_tdata,
    output wire [7:0]  m_tkeep,
    output wire        m_tvalid,
    input  wire        m_tready,
    output wire        m_tlast,
    output wire        m_tuser
);

    reg busy;   // inside a frame
    reg sel;    // 0 = A, 1 = B (valid while busy)

    // Between frames, take whichever feed has data; A wins a tie.
    wire cur = busy ? sel : ~a_tvalid;

    assign m_tdata  = cur ? b_tdata  : a_tdata;
    assign m_tkeep  = cur ? b_tkeep  : a_tkeep;
    assign m_tvalid = cur ? b_tvalid : a_tvalid;
    assign m_tlast  = cur ? b_tlast  : a_tlast;
    assign m_tuser  = cur ? b_tuser  : a_tuser;

    assign a_tready = m_tready & ~cur;
    assign b_tready = m_tready &  cur;

    always @(posedge clk) begin
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
