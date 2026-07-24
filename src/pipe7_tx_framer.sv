
`timescale 1ns/1ps

/**
 * pipe7_tx_framer -- Gen5 128b/130b TX block framer, MAC-owned. Closure-plan item 5.
 *
 * In the PIPE SerDes architecture the PHY is parallel<->serial only, so the MAC does the
 * 128b/130b block coding and embeds the 2-bit sync header directly in TxData -- there are
 * no discrete TxSyncHeader / TxStartBlock pins (crosscheck H1/H3). This block takes a stream
 * of 128-bit payloads (each tagged data vs ordered-set), forms 130-bit blocks
 * (block[1:0] = sync header, block[129:2] = payload), and serializes the continuous block
 * stream onto TxData[PIPE_WIDTH-1:0], asserting TxDataValid while it has a full word to emit.
 *
 * Bit order (internal, self-consistent with pipe7_rx_deframer): the sync header is the two
 * lowest bits of a block and is emitted first; TxData bit 0 is the oldest bit in the stream.
 * The exact mapping of PCIe-base payload bit-ordering into these 128 bits is an RDI-side
 * gearbox concern reconciled when the RDI datapath lands (item 6+); here framer/deframer are
 * exact inverses so the round-trip is faithful regardless of that outer convention.
 *
 * Width: this single-block-per-cycle engine requires PIPE_WIDTH <= BLOCK_BITS (valid Gen5
 * SerDes widths 10/20/40/80). The 160-bit (two-blocks-per-PCLK) gearbox is item 6 (Gen6
 * wide datapath), where wide-data handling is the focus.
 */
module pipe7_tx_framer
    import pipe7_pkg::*;
#(
    parameter int PIPE_WIDTH = 80
) (
    input  logic                       clk,
    input  logic                       reset_n,

    // ---- Payload input (one 128-bit block payload per accepted beat) ----
    input  logic                       pl_valid,
    input  logic [BLOCK_PAYLOAD-1:0]   pl_data,
    input  logic                       pl_is_os,      // 1 = ordered-set block, 0 = data block
    output logic                       pl_ready,      // combinational: room for a block this cycle

    // ---- PIPE MAC Tx data (block-coded; sync header embedded, no discrete pins) ----
    output logic [PIPE_WIDTH-1:0]      tx_data,
    output logic                       tx_data_valid
);

    localparam int ACC_W = PIPE_WIDTH + BLOCK_BITS;

    logic [ACC_W-1:0] acc;    // bit accumulator; valid bits are [fill-1:0], higher bits are 0
    int               fill;   // number of valid bits currently in acc

    // Block to append from the current payload: {payload, sync}, zero-extended to ACC_W.
    wire [1:0]           sync      = pl_is_os ? SYNC_HDR_OS : SYNC_HDR_DATA;
    wire [BLOCK_BITS-1:0] block    = {pl_data, sync};
    wire [ACC_W-1:0]     block_ext = {{(ACC_W-BLOCK_BITS){1'b0}}, block};

    // Combinational next-state: emit one word if we have >= PIPE_WIDTH bits, then append a
    // block if the payload is offered and there is room.
    logic [ACC_W-1:0] acc_e, n_acc;
    int               fill_e, n_fill;
    logic             emit, do_append;

    always_comb begin
        emit = (fill >= PIPE_WIDTH);
        if (emit) begin
            acc_e  = acc >> PIPE_WIDTH;
            fill_e = fill - PIPE_WIDTH;
        end else begin
            acc_e  = acc;
            fill_e = fill;
        end

        do_append = pl_valid && (fill_e <= ACC_W - BLOCK_BITS);
        if (do_append) begin
            n_acc  = acc_e | (block_ext << fill_e);
            n_fill = fill_e + BLOCK_BITS;
        end else begin
            n_acc  = acc_e;
            n_fill = fill_e;
        end

        pl_ready = do_append;
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            acc           <= '0;
            fill          <= 0;
            tx_data       <= '0;
            tx_data_valid <= 1'b0;
        end else begin
            tx_data_valid <= emit;
            tx_data       <= acc[PIPE_WIDTH-1:0];   // oldest word (valid only when emit)
            acc           <= n_acc;
            fill          <= n_fill;
        end
    end

endmodule
