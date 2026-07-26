
`timescale 1ns/1ps

/**
 * pipe7_rdi_ingress -- UCIe RDI ingress with credit-based flow control (closure-plan item 18).
 * Reassembles RDI flit words into 128-bit block payloads for the MAC datapath (framer / rate
 * datapath). Models a fuller RDI than a bare valid/ready: the receiver advertises CREDITS
 * buffer slots and returns a credit for every flit it frees, so the sender (which tracks
 * outstanding = sent - returned <= CREDITS) never overflows the ingress buffer.
 *
 * A block payload is BLOCK_PAYLOAD (128) bits = FLITS_PER_BLOCK (128/RDI_WIDTH) flit words; the
 * first word of a block carries rdi_sob=1 and the block type on rdi_is_os. Word order:
 * blk_data = {word[N-1], ..., word[0]} (word 0 is the sob word, in the low bits).
 */
module pipe7_rdi_ingress
    import pipe7_pkg::*;
#(
    parameter int RDI_WIDTH = 64,
    parameter int CREDITS   = 8
) (
    input  logic                     clk,
    input  logic                     reset_n,

    // ---- RDI flit input (credit-gated by the sender) ----
    input  logic                     rdi_valid,
    input  logic [RDI_WIDTH-1:0]     rdi_data,
    input  logic                     rdi_sob,     // start of block (first flit word)
    input  logic                     rdi_is_os,   // block type, valid with rdi_sob
    output logic [1:0]               rdi_crd,     // credits returned this cycle (0..2)

    // ---- Block payload output (to the CDC / MAC datapath) ----
    output logic                     blk_valid,
    output logic [BLOCK_PAYLOAD-1:0] blk_data,
    output logic                     blk_is_os,
    input  logic                     blk_ready
);

    localparam int FPB   = BLOCK_PAYLOAD / RDI_WIDTH;    // flits per block (=2 at 64b)
    localparam int DEPTH = CREDITS;
    localparam int AW    = $clog2(DEPTH);

    // Flit FIFO (data + is_os of the sob word).
    logic [RDI_WIDTH-1:0] fifo_data [DEPTH];
    logic                 fifo_os   [DEPTH];
    logic                 fifo_sob  [DEPTH];
    logic [AW:0]          count;
    logic [AW-1:0]        wr_ptr, rd_ptr;

    wire push = rdi_valid;                       // sender guarantees a free slot (credit-gated)
    wire pop  = blk_valid;                       // a full block is assembled this cycle

    // Assemble a block when >= FPB flits are buffered and the sink can take it.
    assign blk_valid = (count >= FPB[AW:0]) && blk_ready;
    always_comb begin
        blk_data  = '0;
        for (int i = 0; i < FPB; i++)
            blk_data[i*RDI_WIDTH +: RDI_WIDTH] = fifo_data[(rd_ptr + i[AW-1:0])];
        blk_is_os = fifo_os[rd_ptr];             // block type from the sob word
    end
    // Return one credit per flit freed this cycle.
    assign rdi_crd = pop ? FPB[1:0] : 2'd0;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            count  <= '0;
            wr_ptr <= '0;
            rd_ptr <= '0;
        end else begin
            if (push) begin
                fifo_data[wr_ptr] <= rdi_data;
                fifo_os[wr_ptr]   <= rdi_is_os;
                fifo_sob[wr_ptr]  <= rdi_sob;
                wr_ptr            <= wr_ptr + 1'b1;
            end
            if (pop)
                rd_ptr <= rd_ptr + FPB[AW-1:0];
            count <= count + (push ? {{AW{1'b0}}, 1'b1} : '0) - (pop ? FPB[AW:0] : '0);
        end
    end

    // fifo_sob is captured for debug/assertions (block boundary tracking); tie its read off.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_sob = fifo_sob[rd_ptr];
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
