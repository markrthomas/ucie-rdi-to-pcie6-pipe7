
`timescale 1ns/1ps

/**
 * tb_pipe7_rx_burst_fifo -- unit test for the RX burst-absorption skid FIFO (closure-plan
 * item 29). Self-clocking; `verilator --binary --timing`.
 *
 * Drives 0/1/2-per-cycle pushes against a 1-per-cycle drain to prove the FIFO:
 *   - preserves order and data (popped values are strictly increasing -- push order, no dup),
 *   - absorbs a balanced 1-in/1-out stream with no overflow,
 *   - overflows (dropping the excess) when a sustained 2-in/1-out burst exceeds DEPTH,
 *   - drains cleanly to empty afterwards.
 * Prints [BURST FIFO] PASS / FAIL.
 */
module tb_pipe7_rx_burst_fifo;
    localparam int WIDTH = 129;
    localparam int DEPTH = 4;

    logic clk, reset_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    logic [1:0]       push_cnt;
    logic [WIDTH-1:0] din0, din1;
    logic             pop_valid, pop_ready, overflow;
    logic [WIDTH-1:0] pop_data;

    pipe7_rx_burst_fifo #(.WIDTH(WIDTH), .DEPTH(DEPTH)) dut (
        .clk, .reset_n, .push_cnt, .din0, .din1,
        .pop_valid, .pop_data, .pop_ready, .overflow
    );

    int  next_val;      // monotonically increasing pushed value
    int  last_pop;      // last popped value (for strict-increase check)
    int  pops, ovf_ph1, ovf_ph2, errors;

    // Present the next push values combinationally from next_val.
    assign din0 = WIDTH'(next_val);
    assign din1 = WIDTH'(next_val + 1);

    // Pop checker: FIFO order => strictly increasing popped values.
    always @(negedge clk) if (reset_n && pop_valid && pop_ready) begin
        if (int'(pop_data) <= last_pop && pops > 0) begin
            errors <= errors + 1;
            $display("[BURST FIFO] FAIL: out-of-order/dup pop %0d after %0d", int'(pop_data), last_pop);
        end
        last_pop <= int'(pop_data);
        pops     <= pops + 1;
    end

    // Advance the pushed-value counter by however many were accepted this cycle.
    wire [1:0] accepted = dut.accept;
    always @(posedge clk) if (reset_n) next_val <= next_val + int'(accepted);

    task automatic step(input logic [1:0] pc, input logic pr);
        push_cnt = pc; pop_ready = pr;
        @(negedge clk);
    endtask

    int phase;
    initial begin
        next_val = 0; last_pop = -1; pops = 0; ovf_ph1 = 0; ovf_ph2 = 0; errors = 0; phase = 0;
        push_cnt = 0; pop_ready = 0;   // din0/din1 are continuously assigned from next_val
        reset_n = 0; repeat (3) @(negedge clk); reset_n = 1; @(negedge clk);

        // Phase 1: balanced 1-in / 1-out -> never overflows.
        phase = 1;
        repeat (20) begin step(2'd1, 1'b1); if (overflow) ovf_ph1++; end

        // Phase 2: sustained 2-in / 1-out -> net +1/cycle, fills then overflows.
        phase = 2;
        repeat (12) begin step(2'd2, 1'b1); if (overflow) ovf_ph2++; end

        // Phase 3: drain to empty.
        phase = 3;
        push_cnt = 0;
        while (pop_valid) step(2'd0, 1'b1);
        repeat (2) @(negedge clk);

        if (ovf_ph1 != 0) begin errors++; $display("[BURST FIFO] FAIL: overflow in balanced phase"); end
        if (ovf_ph2 == 0) begin errors++; $display("[BURST FIFO] FAIL: no overflow under 2-in/1-out burst"); end
        if (pops < 20)    begin errors++; $display("[BURST FIFO] FAIL: too few pops (%0d)", pops); end

        if (errors == 0)
            $display("[BURST FIFO] PASS  (pops=%0d, burst-overflows=%0d, order preserved)", pops, ovf_ph2);
        else
            $fatal(1, "[BURST FIFO] FAIL  (errors=%0d)", errors);
        $finish;
    end

    initial begin #200000; $fatal(1, "[BURST FIFO] FAIL  (timeout)"); end

endmodule
