
`timescale 1ns/1ps

/**
 * pipe7_rx_deframer -- Gen5 128b/130b RX block deframer, MAC-owned. Closure-plan item 5.
 *
 * In the SerDes architecture block alignment and 128b/130b decode are the MAC's job (the PHY
 * gives only a parallel RxData stream on the recovered clock; there is no RxSyncHeader /
 * RxStartBlock pin -- crosscheck H3/F3/F4). This block accumulates RxData[PIPE_WIDTH-1:0]
 * (qualified by rx_valid), recovers the 130-bit block boundary by sync-header hunting with
 * single-bit slip, checks the sync header (data 0b10 / ordered-set 0b01), and emits the
 * recovered 128-bit payload.
 *
 * Alignment: from the accumulator low bits it inspects the 2-bit sync candidate. A legal
 * header consumes a full 130-bit block and emits its payload (asserting block_locked); an
 * illegal header slips the stream by one bit and drops lock (pulsing sync_error while it was
 * locked). This is the classic 128b/130b block-lock hunt. Multi-block lock *confirmation*
 * and slip-under-noise hardening are exercised in the UVM/PyUVM tiers (items 10/14).
 *
 * Width: single-block-per-cycle, so PIPE_WIDTH <= BLOCK_BITS (Gen5 SerDes 10/20/40/80). The
 * two-blocks-per-PCLK 160-bit gearbox is item 6. Inverse of pipe7_tx_framer's bit order.
 */
module pipe7_rx_deframer
    import pipe7_pkg::*;
#(
    parameter int PIPE_WIDTH = 80
) (
    input  logic                       clk,
    input  logic                       reset_n,

    // ---- PIPE MAC Rx data (block-coded; recovered-clock domain modelled in pclk here) ----
    input  logic [PIPE_WIDTH-1:0]      rx_data,
    input  logic                       rx_valid,

    // ---- Recovered payload output ----
    output logic                       pl_valid,     // 1-cycle: a payload block recovered
    output logic [BLOCK_PAYLOAD-1:0]   pl_data,
    output logic                       pl_is_os,
    output logic                       block_locked, // level: currently block-aligned
    output logic                       sync_error    // 1-cycle: illegal header while locked
);

    // Two blocks of headroom so an appended word plus a straddling block never overflows.
    localparam int RACC_W = PIPE_WIDTH + 2*BLOCK_BITS;

    logic [RACC_W-1:0] racc;   // valid bits [rfill-1:0], higher bits 0
    int                rfill;

    wire [RACC_W-1:0] rx_ext = {{(RACC_W-PIPE_WIDTH){1'b0}}, rx_data};

    logic [RACC_W-1:0] base_acc, n_racc;
    int                base_fill, n_rfill;
    logic [1:0]        sync_cand;
    logic              legal;

    always_comb begin
        // Append this cycle's word (if valid) at the top of the accumulator.
        if (rx_valid) begin
            base_acc  = racc | (rx_ext << rfill);
            base_fill = rfill + PIPE_WIDTH;
        end else begin
            base_acc  = racc;
            base_fill = rfill;
        end

        sync_cand = base_acc[1:0];
        legal     = (sync_cand == SYNC_HDR_DATA) || (sync_cand == SYNC_HDR_OS);

        pl_valid   = 1'b0;
        pl_data    = base_acc[BLOCK_BITS-1:2];
        pl_is_os   = (sync_cand == SYNC_HDR_OS);
        sync_error = 1'b0;
        n_racc     = base_acc;
        n_rfill    = base_fill;

        if (base_fill >= BLOCK_BITS) begin
            if (legal) begin
                // Aligned block: emit payload and consume the whole 130-bit block.
                pl_valid = 1'b1;
                n_racc   = base_acc >> BLOCK_BITS;
                n_rfill  = base_fill - BLOCK_BITS;
            end else begin
                // Not aligned: slip one bit and re-hunt.
                sync_error = block_locked;   // only flag a lost lock, not the initial hunt
                n_racc     = base_acc >> 1;
                n_rfill    = base_fill - 1;
            end
        end
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            racc         <= '0;
            rfill        <= 0;
            block_locked <= 1'b0;
        end else begin
            racc  <= n_racc;
            rfill <= n_rfill;
            if (base_fill >= BLOCK_BITS)
                block_locked <= legal;   // set on a good header, cleared on a slip
        end
    end

endmodule
