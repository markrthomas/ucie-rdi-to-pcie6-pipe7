
`timescale 1ns/1ps

/**
 * tb_pipe7_deframer_gb_ovf -- directed garbage/recovery test for the full-width gearbox RX
 * deframer (closure-plan item 41). Self-clocking; `verilator --binary --timing`.
 *
 * The clean-loopback framing_gb smoke never exercises the deframer_gb's misalignment paths (the
 * bit-slip re-hunt and the item-27 flush guard). This drives pipe7_rx_deframer_gb with sustained
 * garbage (rx_valid=1, all-ones words -> sync 0b11, never a legal header) so the slip + flush
 * branches run, checks the accumulator stays bounded (rfill <= RACC_W) and no spurious block is
 * emitted, then feeds an aligned stream to prove it re-locks and recovers. Prints
 * [DEFRAMER GB OVF] PASS / FAIL.
 */
module tb_pipe7_deframer_gb_ovf;
    import pipe7_pkg::*;

    localparam int PIPE_WIDTH = 160;
    localparam int RACC_W     = PIPE_WIDTH + 3*BLOCK_BITS;   // deframer_gb accumulator width

    logic clk, reset_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    logic [PIPE_WIDTH-1:0]    rx_data;
    logic                     rx_valid;
    logic [1:0]               pl_cnt;
    logic [BLOCK_PAYLOAD-1:0] pl_data0, pl_data1;
    logic                     pl_is_os0, pl_is_os1, block_locked, sync_error;

    pipe7_rx_deframer_gb #(.PIPE_WIDTH(PIPE_WIDTH)) deframer (
        .clk, .reset_n,
        .rx_data, .rx_valid,
        .pl_cnt, .pl_data0, .pl_is_os0, .pl_data1, .pl_is_os1,
        .block_locked, .sync_error
    );

    // LSB-first word k of a periodic aligned data stream (each 130b block = sync 0b10, payload 0).
    function automatic logic [PIPE_WIDTH-1:0] legal_word(input int k);
        logic [PIPE_WIDTH-1:0] w;
        w = '0;
        for (int j = 0; j < PIPE_WIDTH; j++)
            if (((k*PIPE_WIDTH + j) % BLOCK_BITS) == 1) w[j] = 1'b1;
        return w;
    endfunction

    int  ovf_viol, spurious, recovered;
    bit  in_garbage;

    always @(negedge clk) if (reset_n) begin
        if (deframer.rfill > RACC_W)        ovf_viol  <= ovf_viol + 1;
        if (in_garbage && pl_cnt != 2'd0)   spurious  <= spurious + 1;
    end

    initial begin
        ovf_viol = 0; spurious = 0; recovered = 0; in_garbage = 1'b0;
        rx_data = '0; rx_valid = 1'b0;
        reset_n = 1'b0;
        repeat (4) @(negedge clk);
        reset_n = 1'b1;
        repeat (2) @(negedge clk);

        // ---- Phase G: sustained garbage (never a legal header) -> slip + flush guard ----
        in_garbage = 1'b1;
        rx_valid = 1'b1;
        rx_data  = {PIPE_WIDTH{1'b1}};       // sync candidate 0b11 -> always illegal
        repeat (120) @(negedge clk);
        in_garbage = 1'b0;

        // ---- Phase R: aligned stream -> re-hunt, re-lock, recover (up to two blocks/cycle) ----
        for (int k = 0; k < 400; k++) begin
            rx_data = legal_word(k);
            @(negedge clk);
            if (pl_cnt != 2'd0) recovered = recovered + int'(pl_cnt);
            if (recovered >= 3 && block_locked) break;
        end
        rx_valid = 1'b0;
        repeat (4) @(negedge clk);

        if (ovf_viol != 0)
            $fatal(1, "[DEFRAMER GB OVF] FAIL  (rfill exceeded RACC_W in %0d cycles)", ovf_viol);
        if (spurious != 0)
            $fatal(1, "[DEFRAMER GB OVF] FAIL  (%0d spurious blocks during garbage)", spurious);
        if (recovered < 3 || !block_locked)
            $fatal(1, "[DEFRAMER GB OVF] FAIL  (no re-lock/recovery: recov=%0d locked=%0b)",
                   recovered, block_locked);

        $display("[DEFRAMER GB OVF] PASS  (rfill<=RACC_W under garbage, re-locked, recovered=%0d)",
                 recovered);
        $finish;
    end

    initial begin #500000; $fatal(1, "[DEFRAMER GB OVF] FAIL  (global timeout)"); end

endmodule
