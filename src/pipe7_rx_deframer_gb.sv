
`timescale 1ns/1ps

/**
 * pipe7_rx_deframer_gb -- Gen5 128b/130b RX deframer, full-width gearbox variant (closure-plan
 * item 16). Consumes RxData[PIPE_WIDTH-1:0] and recovers up to TWO 130-bit blocks per PCLK, so
 * a 160-bit word (which can span parts of two blocks) never lets the accumulator overflow.
 * Block alignment is the sync-header hunt with single-bit slip (as pipe7_rx_deframer); up to two
 * legal blocks are extracted per cycle. Inverse bit order of pipe7_tx_framer_gb.
 */
module pipe7_rx_deframer_gb
    import pipe7_pkg::*;
#(
    parameter int PIPE_WIDTH = 160
) (
    input  logic                     clk,
    input  logic                     reset_n,

    input  logic [PIPE_WIDTH-1:0]    rx_data,
    input  logic                     rx_valid,

    // Up to two block payloads recovered per cycle.
    output logic [1:0]               pl_cnt,
    output logic [BLOCK_PAYLOAD-1:0] pl_data0,
    output logic                     pl_is_os0,
    output logic [BLOCK_PAYLOAD-1:0] pl_data1,
    output logic                     pl_is_os1,

    output logic                     block_locked,
    output logic                     sync_error
);

    // Headroom for the appended word plus up to two straddling blocks.
    localparam int RACC_W = PIPE_WIDTH + 3*BLOCK_BITS;

    logic [RACC_W-1:0] racc;
    int                rfill;

    wire [RACC_W-1:0] rx_ext = {{(RACC_W-PIPE_WIDTH){1'b0}}, rx_data};

    function automatic logic legal(input logic [1:0] s);
        return (s == SYNC_HDR_DATA) || (s == SYNC_HDR_OS);
    endfunction

    logic [RACC_W-1:0] a_base, a_cur, n_racc;
    int                f_base, f_cur, n_rfill;
    logic [1:0]        s0, s1;
    logic              n_locked, flush;

    always_comb begin
        // Overflow guard: a persistently misaligned/noisy RX stream would otherwise grow the
        // accumulator without bound (append PIPE_WIDTH, slip only one bit). If appending this word
        // would exceed the accumulator, flush and re-hunt from empty and flag sync_error, rather
        // than silently truncating racc. Unreachable on an aligned stream (up to two blocks are
        // drained per cycle), so it never fires on legal data.
        flush = (rfill + PIPE_WIDTH) > RACC_W;

        // Append this cycle's word (if valid), unless flushing.
        if (flush)          begin a_base = '0;                        f_base = 0;                  end
        else if (rx_valid)  begin a_base = racc | (rx_ext << rfill);  f_base = rfill + PIPE_WIDTH; end
        else                begin a_base = racc;                      f_base = rfill;             end

        // Defaults for every comb-assigned signal (no inferred latches).
        pl_cnt     = 2'd0;
        pl_data0   = a_base[BLOCK_BITS-1:2];
        pl_is_os0  = 1'b0;
        pl_data1   = '0;
        pl_is_os1  = 1'b0;
        sync_error = flush ? block_locked : 1'b0;
        n_locked   = flush ? 1'b0 : block_locked;
        s0         = 2'b00;
        s1         = 2'b00;
        a_cur      = a_base;
        f_cur      = f_base;
        n_racc     = a_base;
        n_rfill    = f_base;

        // Extract block 0.
        if (f_cur >= BLOCK_BITS) begin
            s0 = a_cur[1:0];
            if (legal(s0)) begin
                pl_data0  = a_cur[BLOCK_BITS-1:2];
                pl_is_os0 = (s0 == SYNC_HDR_OS);
                pl_cnt    = 2'd1;
                n_locked  = 1'b1;
                a_cur     = a_cur >> BLOCK_BITS;
                f_cur     = f_cur - BLOCK_BITS;
                // Extract block 1 (only if immediately available and legal).
                if (f_cur >= BLOCK_BITS) begin
                    s1 = a_cur[1:0];
                    if (legal(s1)) begin
                        pl_data1  = a_cur[BLOCK_BITS-1:2];
                        pl_is_os1 = (s1 == SYNC_HDR_OS);
                        pl_cnt    = 2'd2;
                        a_cur     = a_cur >> BLOCK_BITS;
                        f_cur     = f_cur - BLOCK_BITS;
                    end
                    // If block 1's header is illegal, leave it: it becomes block 0 next cycle
                    // and is slipped there if still illegal.
                end
            end else begin
                // Not aligned: slip one bit and re-hunt.
                sync_error = block_locked;
                n_locked   = 1'b0;
                a_cur      = a_cur >> 1;
                f_cur      = f_cur - 1;
            end
        end

        n_racc  = a_cur;
        n_rfill = f_cur;
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            racc         <= '0;
            rfill        <= 0;
            block_locked <= 1'b0;
        end else begin
            racc         <= n_racc;
            rfill        <= n_rfill;
            block_locked <= n_locked;
        end
    end

endmodule
