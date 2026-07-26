
`timescale 1ns/1ps

/**
 * pipe7_rdi_egress -- UCIe RDI egress with credit-based flow control (closure-plan item 18).
 * Disassembles recovered 128-bit block payloads back into RDI flit words. The RDI sink returns
 * credits (rdi_crd); the egress holds CREDITS credits and emits a flit word only when a credit
 * is available, so it never overruns the sink. The first word of each block carries rdi_sob=1
 * and the block type on rdi_is_os. Inverse word order of pipe7_rdi_ingress.
 */
module pipe7_rdi_egress
    import pipe7_pkg::*;
#(
    parameter int RDI_WIDTH = 64,
    parameter int CREDITS   = 8
) (
    input  logic                     clk,
    input  logic                     reset_n,

    // ---- Block payload input (from the MAC datapath / CDC) ----
    input  logic                     blk_valid,
    input  logic [BLOCK_PAYLOAD-1:0] blk_data,
    input  logic                     blk_is_os,
    output logic                     blk_ready,

    // ---- RDI flit output + credit return from the sink ----
    output logic                     rdi_valid,
    output logic [RDI_WIDTH-1:0]     rdi_data,
    output logic                     rdi_sob,
    output logic                     rdi_is_os,
    input  logic [1:0]               rdi_crd
);

    localparam int FPB = BLOCK_PAYLOAD / RDI_WIDTH;   // flits per block (=2 at 64b)
    localparam int IW  = $clog2(FPB + 1);
    localparam int CW  = $clog2(2*CREDITS + 1);       // credit-counter width

    typedef enum logic {E_IDLE, E_EMIT} estate_e;
    estate_e                 state;
    logic [BLOCK_PAYLOAD-1:0] blk_q;
    logic                     os_q;
    logic [IW-1:0]            word_idx;
    logic [CW-1:0]            credits;   // available sink credits

    wire have_credit = (credits != 0);
    wire emit_word   = (state == E_EMIT) && have_credit;

    assign blk_ready = (state == E_IDLE);
    assign rdi_valid = emit_word;
    assign rdi_data  = blk_q[word_idx * RDI_WIDTH +: RDI_WIDTH];
    assign rdi_sob   = (word_idx == '0);
    assign rdi_is_os = os_q;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state    <= E_IDLE;
            blk_q    <= '0;
            os_q     <= 1'b0;
            word_idx <= '0;
            credits  <= CW'(CREDITS);
        end else begin
            // Credit accounting: consume one on a sent word, add returned credits.
            credits <= credits - (emit_word ? CW'(1) : CW'(0)) + CW'(rdi_crd);

            unique case (state)
                E_IDLE: begin
                    word_idx <= '0;
                    if (blk_valid) begin
                        blk_q <= blk_data;
                        os_q  <= blk_is_os;
                        state <= E_EMIT;
                    end
                end
                E_EMIT: if (emit_word) begin
                    if (word_idx == IW'(FPB - 1)) state <= E_IDLE;
                    else                          word_idx <= word_idx + 1'b1;
                end
                default: state <= E_IDLE;
            endcase
        end
    end

endmodule
