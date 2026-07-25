
`timescale 1ns/1ps

/**
 * tb_pipe7_framing_gb -- Gen5 128b/130b full-width gearbox round-trip (closure-plan item 16).
 * Self-clocking; built with `verilator --binary --timing`.
 *
 * framing_gb_check instantiates pipe7_tx_framer_gb -> pipe7_rx_deframer_gb in loopback at a
 * parameterized width, drives up to two block payloads per cycle (respecting pl_acc backpressure)
 * and collects up to two recovered blocks per cycle, checking the round-trip in order. The top
 * instantiates it at WIDTH=160 (the two-blocks-per-PCLK case) and WIDTH=80 (boundary), proving
 * the gearbox covers the full SerDes width set. Prints [FRAMING GB] PASS / FAIL.
 */

module framing_gb_check
    import pipe7_pkg::*;
#(
    parameter int WIDTH = 160,
    parameter int N     = 40,     // real blocks to check
    parameter int FLUSH = 6       // trailing filler blocks to flush the last real block out
) (
    input  logic clk,
    input  logic reset_n,
    output logic done,
    output int   errs
);
    localparam int TOTAL = N + FLUSH;
    logic [1:0]               pl_cnt;
    logic [BLOCK_PAYLOAD-1:0] pl_data0, pl_data1;
    logic                     pl_is_os0, pl_is_os1;
    logic [1:0]               pl_acc;
    logic [WIDTH-1:0]         stream;
    logic                     stream_valid;

    logic [1:0]               r_cnt;
    logic [BLOCK_PAYLOAD-1:0] r_data0, r_data1;
    logic                     r_os0, r_os1;
    logic                     blk_locked, sync_err;

    pipe7_tx_framer_gb #(.PIPE_WIDTH(WIDTH)) framer (
        .clk, .reset_n,
        .pl_cnt, .pl_data0, .pl_is_os0, .pl_data1, .pl_is_os1, .pl_acc,
        .tx_data(stream), .tx_data_valid(stream_valid)
    );
    pipe7_rx_deframer_gb #(.PIPE_WIDTH(WIDTH)) deframer (
        .clk, .reset_n,
        .rx_data(stream), .rx_valid(stream_valid),
        .pl_cnt(r_cnt), .pl_data0(r_data0), .pl_is_os0(r_os0),
        .pl_data1(r_data1), .pl_is_os1(r_os1),
        .block_locked(blk_locked), .sync_error(sync_err)
    );

    logic [BLOCK_PAYLOAD-1:0] src_data [TOTAL];
    logic                     src_os   [TOTAL];

    // Producer: offer up to two blocks per cycle; advance by pl_acc. Sends N real blocks plus
    // FLUSH trailing filler blocks so the last real block is fully emitted (as a continuous
    // link's idle/SKP blocks would flush it).
    int sent;
    initial begin
        pl_cnt = 2'd0; pl_data0 = '0; pl_is_os0 = 1'b0; pl_data1 = '0; pl_is_os1 = 1'b0;
        sent = 0;
        @(posedge reset_n);
        repeat (2) @(negedge clk);
        for (int i = 0; i < TOTAL; i++) begin
            src_data[i] = {$random, $random, $random, $random};
            src_os[i]   = ($random & 1);
        end
        while (sent < TOTAL) begin
            int n_offer;
            @(negedge clk);
            n_offer  = (TOTAL - sent >= 2) ? 2 : 1;
            pl_data0 = src_data[sent]; pl_is_os0 = src_os[sent];
            if (n_offer == 2) begin pl_data1 = src_data[sent+1]; pl_is_os1 = src_os[sent+1]; end
            pl_cnt = n_offer[1:0];
            #1;
            sent = sent + int'(pl_acc);
        end
        @(negedge clk);
        pl_cnt = 2'd0;
    end

    // Consumer: collect up to two recovered blocks per cycle; check in order.
    int recv;
    initial begin
        done = 1'b0; errs = 0; recv = 0;
        @(posedge reset_n);
        while (recv < N) begin
            @(negedge clk);
            if (r_cnt >= 2'd1) begin
                if (r_data0 !== src_data[recv] || r_os0 !== src_os[recv]) begin
                    errs = errs + 1;
                    $display("[FRAMING GB] W%0d FAIL block %0d (port0)", WIDTH, recv);
                end
                recv = recv + 1;
            end
            if (r_cnt >= 2'd2 && recv < N) begin
                if (r_data1 !== src_data[recv] || r_os1 !== src_os[recv]) begin
                    errs = errs + 1;
                    $display("[FRAMING GB] W%0d FAIL block %0d (port1)", WIDTH, recv);
                end
                recv = recv + 1;
            end
        end
        if (!blk_locked) begin errs = errs + 1; $display("[FRAMING GB] W%0d FAIL: not locked", WIDTH); end
        done = 1'b1;
    end

    // sync_error must never fire on a clean loopback.
    always @(negedge clk)
        if (reset_n && sync_err) begin errs = errs + 1; $display("[FRAMING GB] W%0d FAIL: sync_error", WIDTH); end

endmodule


module tb_pipe7_framing_gb;
    logic clk;
    logic reset_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    logic done160, done80;
    int   errs160, errs80;

    framing_gb_check #(.WIDTH(160), .N(40)) chk160 (.clk, .reset_n, .done(done160), .errs(errs160));
    framing_gb_check #(.WIDTH(80),  .N(40)) chk80  (.clk, .reset_n, .done(done80),  .errs(errs80));

    initial begin
        reset_n = 1'b0;
        repeat (4) @(negedge clk);
        reset_n = 1'b1;

        wait (done160 && done80);
        repeat (4) @(negedge clk);

        if (errs160 == 0 && errs80 == 0) begin
            $display("[FRAMING GB] PASS  (W160 + W80, 40 blocks each, up to 2/cycle)");
            $finish;
        end else begin
            $fatal(1, "[FRAMING GB] FAIL  (errs160=%0d errs80=%0d)", errs160, errs80);
        end
    end

    initial begin
        #500000;
        $fatal(1, "[FRAMING GB] FAIL  (global timeout)");
    end

endmodule
