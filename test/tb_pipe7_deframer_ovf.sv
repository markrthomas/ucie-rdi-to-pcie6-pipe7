
`timescale 1ns/1ps

/**
 * tb_pipe7_deframer_ovf -- directed RTL test for the Gen5 RX deframer accumulator overflow guard
 * (closure-plan item 27). Self-clocking; `verilator --binary --timing`.
 *
 * Drives pipe7_rx_deframer directly (no framer) to exercise the flush-and-re-hunt guard that the
 * formal proof (verification/formal/deframer.sby) proves bounds the accumulator unconditionally:
 *   Phase G -- sustained garbage (rx_valid=1, all-ones words -> sync 0b11, never a legal header):
 *              without the guard rfill would grow ~+79 bits/cycle without bound. Check the RTL
 *              keeps rfill <= RACC_W and never emits a spurious payload.
 *   Phase R -- a hand-built aligned stream (every 130b block = data sync 0b10, zero payload):
 *              the deframer must re-hunt, reach block lock, and recover payloads -- proving the
 *              guard leaves the datapath able to recover after noise.
 * Prints [DEFRAMER OVF] PASS / FAIL.
 */
module tb_pipe7_deframer_ovf;
    import pipe7_pkg::*;

    localparam int PIPE_WIDTH = 80;
    localparam int RACC_W     = PIPE_WIDTH + 2*BLOCK_BITS;   // deframer accumulator width

    logic clk, reset_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    logic [PIPE_WIDTH-1:0]    rx_data;
    logic                     rx_valid;
    logic                     pl_valid, pl_is_os, block_locked, sync_error;
    logic [BLOCK_PAYLOAD-1:0] pl_data;

    pipe7_rx_deframer #(.PIPE_WIDTH(PIPE_WIDTH)) deframer (
        .clk, .reset_n,
        .rx_data, .rx_valid,
        .pl_valid, .pl_data, .pl_is_os, .block_locked, .sync_error
    );

    // LSB-first word k of a periodic aligned stream: each 130b block = {payload 0, sync 0b10}
    // (bit 1 of every block set, all others 0). This re-locks the deframer after noise; the
    // recovered payload value is the framing smoke's concern -- here we only require re-lock +
    // recovery (the item-27 guard must leave the datapath able to hunt again).
    function automatic logic [PIPE_WIDTH-1:0] legal_word(input int k);
        logic [PIPE_WIDTH-1:0] w;
        w = '0;
        for (int j = 0; j < PIPE_WIDTH; j++)
            if (((k*PIPE_WIDTH + j) % BLOCK_BITS) == 1) w[j] = 1'b1;
        return w;
    endfunction

    int  ovf_viol;      // cycles where rfill exceeded RACC_W (must stay 0)
    int  spurious;      // payloads emitted during the garbage phase (must stay 0)
    int  recovered;     // payloads recovered during the recovery phase
    bit  in_garbage;

    // Accumulator-bound + spurious-output monitor (hierarchical read of the guard's counter).
    always @(negedge clk) if (reset_n) begin
        if (deframer.rfill > RACC_W)     ovf_viol <= ovf_viol + 1;
        if (in_garbage && pl_valid)      spurious <= spurious + 1;
    end

    initial begin
        ovf_viol = 0; spurious = 0; recovered = 0; in_garbage = 1'b0;
        rx_data = '0; rx_valid = 1'b0;
        reset_n = 1'b0;
        repeat (4) @(negedge clk);
        reset_n = 1'b1;
        repeat (2) @(negedge clk);

        // ---- Phase G: sustained garbage (never a legal header) ----
        in_garbage = 1'b1;
        rx_valid = 1'b1;
        rx_data  = {PIPE_WIDTH{1'b1}};       // sync candidate 0b11 -> always illegal
        repeat (120) @(negedge clk);         // long enough that unguarded rfill would overflow
        in_garbage = 1'b0;

        // ---- Phase R: aligned stream -> re-hunt, re-lock, recover ----
        for (int k = 0; k < 400; k++) begin
            rx_data = legal_word(k);
            @(negedge clk);
            if (pl_valid) recovered = recovered + 1;
            if (recovered >= 3 && block_locked) break;
        end
        rx_valid = 1'b0;
        repeat (4) @(negedge clk);

        if (ovf_viol != 0)
            $fatal(1, "[DEFRAMER OVF] FAIL  (rfill exceeded RACC_W in %0d cycles)", ovf_viol);
        if (spurious != 0)
            $fatal(1, "[DEFRAMER OVF] FAIL  (%0d spurious payloads during garbage)", spurious);
        if (recovered < 3 || !block_locked)
            $fatal(1, "[DEFRAMER OVF] FAIL  (no re-lock/recovery after garbage: recov=%0d locked=%0b)",
                   recovered, block_locked);

        $display("[DEFRAMER OVF] PASS  (rfill<=RACC_W under garbage, re-locked, recovered=%0d)",
                 recovered);
        $finish;
    end

    initial begin #500000; $fatal(1, "[DEFRAMER OVF] FAIL  (global timeout)"); end

endmodule
