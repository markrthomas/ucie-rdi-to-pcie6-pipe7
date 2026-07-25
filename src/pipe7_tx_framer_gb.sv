
`timescale 1ns/1ps

/**
 * pipe7_tx_framer_gb -- Gen5 128b/130b TX framer, full-width gearbox variant (closure-plan
 * item 16). Unlike pipe7_tx_framer (single block per PCLK, PIPE_WIDTH <= 130), this accepts up
 * to TWO 130-bit blocks per PCLK and emits PIPE_WIDTH bits per PCLK, so the full SerDes width
 * set {10,20,40,80,160} is supported -- at 160 the datapath needs ~1.23 blocks/PCLK, bursting
 * to two.
 *
 * Interface: the controller offers pl_cnt (0/1/2) blocks each cycle on {pl_data0,pl_is_os0} and
 * {pl_data1,pl_is_os1}; pl_acc reports how many were accepted (limited by accumulator room).
 * Bit order matches pipe7_tx_framer: block = {payload, sync[1:0]}, LSB-first onto TxData.
 */
module pipe7_tx_framer_gb
    import pipe7_pkg::*;
#(
    parameter int PIPE_WIDTH = 160
) (
    input  logic                     clk,
    input  logic                     reset_n,

    // Up to two block payloads offered per cycle.
    input  logic [1:0]               pl_cnt,      // number offered: 0, 1, or 2
    input  logic [BLOCK_PAYLOAD-1:0] pl_data0,
    input  logic                     pl_is_os0,
    input  logic [BLOCK_PAYLOAD-1:0] pl_data1,
    input  logic                     pl_is_os1,
    output logic [1:0]               pl_acc,      // number accepted this cycle

    output logic [PIPE_WIDTH-1:0]    tx_data,
    output logic                     tx_data_valid
);

    localparam int ACC_W = PIPE_WIDTH + 2*BLOCK_BITS;

    logic [ACC_W-1:0] acc;
    int               fill;

    wire [1:0]            sync0 = pl_is_os0 ? SYNC_HDR_OS : SYNC_HDR_DATA;
    wire [1:0]            sync1 = pl_is_os1 ? SYNC_HDR_OS : SYNC_HDR_DATA;
    wire [ACC_W-1:0]     blk0  = {{(ACC_W-BLOCK_BITS){1'b0}}, pl_data0, sync0};
    wire [ACC_W-1:0]     blk1  = {{(ACC_W-BLOCK_BITS){1'b0}}, pl_data1, sync1};

    logic [ACC_W-1:0] acc_e, n_acc;
    int               fill_e, n_fill, room, room_blocks, take, offered;
    logic             emit;

    always_comb begin
        // Emit one word if we have >= PIPE_WIDTH bits.
        emit = (fill >= PIPE_WIDTH);
        if (emit) begin acc_e = acc >> PIPE_WIDTH; fill_e = fill - PIPE_WIDTH; end
        else      begin acc_e = acc;               fill_e = fill;             end

        // How many whole blocks fit (0/1/2), capped by what's offered.
        room = ACC_W - fill_e;
        if      (room >= 2*BLOCK_BITS) room_blocks = 2;
        else if (room >=   BLOCK_BITS) room_blocks = 1;
        else                           room_blocks = 0;
        offered = int'(pl_cnt);
        take    = (offered < room_blocks) ? offered : room_blocks;

        // Append accepted blocks at the top of the accumulator.
        n_acc  = acc_e;
        n_fill = fill_e;
        if (take >= 1) begin n_acc = n_acc | (blk0 << n_fill); n_fill = n_fill + BLOCK_BITS; end
        if (take >= 2) begin n_acc = n_acc | (blk1 << n_fill); n_fill = n_fill + BLOCK_BITS; end
        pl_acc = take[1:0];
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            acc           <= '0;
            fill          <= 0;
            tx_data       <= '0;
            tx_data_valid <= 1'b0;
        end else begin
            tx_data_valid <= emit;
            tx_data       <= acc[PIPE_WIDTH-1:0];
            acc           <= n_acc;
            fill          <= n_fill;
        end
    end

endmodule
