
`timescale 1ns/1ps

/**
 * tb_pipe7_framing -- self-checking Gen5 128b/130b framing round-trip for pipe7_tx_framer +
 * pipe7_rx_deframer (closure-plan item 5). Self-clocking; built with `verilator --binary
 * --timing`.
 *
 * The framer output is looped straight back into the deframer (tx_data->rx_data,
 * tx_data_valid->rx_valid), modelling the MAC-owned block coding round-trip: a stream of
 * random 128-bit payloads (each randomly tagged data vs ordered-set) is framed into the
 * continuous 130-bit block stream and recovered. Because 130 is not a multiple of PIPE_WIDTH
 * the blocks straddle TxData word boundaries, exercising real block alignment on the RX side.
 *
 * Pass criterion: every payload is recovered in order with matching data and sync type, the
 * deframer reaches block lock, and no sync_error occurs on the clean aligned stream. Prints
 * [FRAMING] PASS / FAIL and $finish ($fatal on failure so CI catches regressions).
 */
module tb_pipe7_framing;
    import pipe7_pkg::*;

    localparam int PIPE_WIDTH = 80;
    localparam int N_BLOCKS   = 32;

    logic clk;
    logic reset_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    int  errors;
    int  recv;
    int  sync_err_count;
    bit  reset_done;

    // ---- Framer inputs / loopback wiring ----
    logic                     pl_valid_i, pl_is_os_i;
    logic [BLOCK_PAYLOAD-1:0] pl_data_i;
    logic                     pl_ready_i;
    logic [PIPE_WIDTH-1:0]    stream;
    logic                     stream_valid;

    // ---- Deframer outputs ----
    logic                     pl_valid_o, pl_is_os_o, blk_locked_o, sync_err_o;
    logic [BLOCK_PAYLOAD-1:0] pl_data_o;

    // Expected-payload queues (producer pushes, consumer pops in order).
    logic [BLOCK_PAYLOAD-1:0] exp_data [$];
    logic                     exp_os   [$];

    pipe7_tx_framer #(.PIPE_WIDTH(PIPE_WIDTH)) framer (
        .clk, .reset_n,
        .pl_valid(pl_valid_i), .pl_data(pl_data_i), .pl_is_os(pl_is_os_i), .pl_ready(pl_ready_i),
        .tx_data(stream), .tx_data_valid(stream_valid)
    );

    pipe7_rx_deframer #(.PIPE_WIDTH(PIPE_WIDTH)) deframer (
        .clk, .reset_n,
        .rx_data(stream), .rx_valid(stream_valid),
        .pl_valid(pl_valid_o), .pl_data(pl_data_o), .pl_is_os(pl_is_os_o),
        .block_locked(blk_locked_o), .sync_error(sync_err_o)
    );

    function automatic logic [BLOCK_PAYLOAD-1:0] rand128();
        logic [BLOCK_PAYLOAD-1:0] v;
        v = {$random, $random, $random, $random};
        return v;
    endfunction

    // Drive exactly one payload into the framer. Align to a negedge, assert valid, and hold it
    // until a negedge where pl_ready (combinational) is high -- the *following* posedge is then
    // the single accepting edge. Deassert at the next negedge so no second posedge sees valid
    // high (which would double-append the same block). The #1 lets pl_ready settle before it is
    // sampled (comb-read-after-drive).
    task automatic send_block(input logic [BLOCK_PAYLOAD-1:0] d, input logic o);
        @(negedge clk);
        pl_data_i  = d;
        pl_is_os_i = o;
        pl_valid_i = 1'b1;
        #1;
        while (!pl_ready_i) begin
            @(negedge clk);
            #1;
        end
        @(posedge clk);        // single accepting edge
        @(negedge clk);        // no posedge between accept and here
        pl_valid_i = 1'b0;
    endtask

    // ---- Producer ----
    initial begin
        errors = 0; recv = 0; sync_err_count = 0; reset_done = 1'b0;
        pl_valid_i = 1'b0; pl_is_os_i = 1'b0; pl_data_i = '0;
        reset_n = 1'b0;
        repeat (4) @(negedge clk);
        reset_n = 1'b1;
        repeat (2) @(negedge clk);
        reset_done = 1'b1;

        for (int i = 0; i < N_BLOCKS; i++) begin
            logic [BLOCK_PAYLOAD-1:0] d;
            logic                     o;
            d = rand128();
            o = ($random & 1);
            exp_data.push_back(d);
            exp_os.push_back(o);
            send_block(d, o);
        end
        // Idle a while so the framer drains its final buffered blocks.
        repeat (40) @(negedge clk);
    end

    // ---- sync_error monitor ----
    initial begin
        @(posedge reset_done);
        forever begin
            @(negedge clk);
            if (sync_err_o) sync_err_count = sync_err_count + 1;
        end
    end

    // ---- Consumer / scoreboard ----
    initial begin
        @(posedge reset_done);
        for (int r = 0; r < N_BLOCKS; r++) begin
            logic [BLOCK_PAYLOAD-1:0] ed;
            logic                     eo;
            @(negedge clk);
            while (!pl_valid_o) @(negedge clk);
            ed = exp_data.pop_front();
            eo = exp_os.pop_front();
            if (pl_data_o !== ed) begin
                errors = errors + 1;
                $display("[FRAMING] FAIL block %0d: data mismatch", r);
            end
            if (pl_is_os_o !== eo) begin
                errors = errors + 1;
                $display("[FRAMING] FAIL block %0d: is_os got %0b expected %0b", r, pl_is_os_o, eo);
            end
            recv = recv + 1;
        end

        // ---- Report ----
        if (recv != N_BLOCKS) begin
            errors = errors + 1;
            $display("[FRAMING] FAIL: recovered=%0d expected %0d", recv, N_BLOCKS);
        end
        if (!blk_locked_o) begin
            errors = errors + 1;
            $display("[FRAMING] FAIL: deframer not block-locked at end");
        end
        if (sync_err_count != 0) begin
            errors = errors + 1;
            $display("[FRAMING] FAIL: sync_error pulsed %0d times on a clean stream", sync_err_count);
        end

        if (errors == 0) begin
            $display("[FRAMING] PASS  (blocks=%0d, locked=%0b, sync_errors=%0d)",
                     recv, blk_locked_o, sync_err_count);
            $finish;
        end else begin
            $fatal(1, "[FRAMING] FAIL  (errors=%0d)", errors);
        end
    end

    // Global watchdog.
    initial begin
        #500000;
        $fatal(1, "[FRAMING] FAIL  (global timeout)");
    end

endmodule
