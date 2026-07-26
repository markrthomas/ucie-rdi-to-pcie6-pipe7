
`timescale 1ns/1ps

/**
 * tb_pipe7_cdc -- RDI<->PCLK CDC of the block-payload stream (closure-plan item 19).
 * Self-clocking; built with `verilator --binary --timing`.
 *
 * Carries the block payload {is_os, data[127:0]} + error across pipe7_cdc_elastic_buf between
 * two independent clocks (write ~71 MHz, read 100 MHz), with read-side backpressure that makes
 * the buffer fill and deassert wr_ready. A FIFO scoreboard checks that every accepted write
 * beat is read back in order with matching data/is_os/error. Prints [CDC] PASS / FAIL.
 */
module tb_pipe7_cdc;
    import pipe7_pkg::*;

    localparam int DW    = BLOCK_PAYLOAD + 1;   // {is_os, data128}
    localparam int DEPTH = 16;
    localparam int N     = 48;

    logic wr_clk, rd_clk, rst_n;
    initial wr_clk = 1'b0;
    initial rd_clk = 1'b0;
    always #7 wr_clk = ~wr_clk;   // ~71 MHz
    always #5 rd_clk = ~rd_clk;   // 100 MHz

    // Golden stream.
    logic [BLOCK_PAYLOAD-1:0] src_data [N];
    logic                     src_os   [N];
    logic                     src_err  [N];
    initial begin
        for (int i = 0; i < N; i++) begin
            src_data[i] = {$random, $random, $random, $random};
            src_os[i]   = ($random & 1);
            src_err[i]  = ($random & 1);
        end
    end

    // Write side.
    logic          wr_valid, wr_ready, wr_error, wr_full;
    logic [DW-1:0] wr_data;
    int            sent;
    wire           wr_fire = wr_valid && wr_ready;
    assign wr_valid = (sent < N) && rst_n;
    assign wr_data  = {src_os[sent], src_data[sent]};
    assign wr_error = src_err[sent];
    always_ff @(posedge wr_clk or negedge rst_n)
        if (!rst_n) sent <= 0;
        else if (wr_fire) sent <= sent + 1;

    // Read side with periodic backpressure (stall 1 in 3).
    logic          rd_valid, rd_ready, rd_error;
    logic [DW-1:0] rd_data;
    int            rd_beat, recv, errors;
    assign rd_ready = (rd_beat % 3 != 0);
    always_ff @(posedge rd_clk or negedge rst_n) begin
        if (!rst_n) begin rd_beat <= 0; recv <= 0; errors <= 0; end
        else begin
            rd_beat <= rd_beat + 1;
            if (rd_valid && rd_ready) begin
                if (rd_data !== {src_os[recv], src_data[recv]} || rd_error !== src_err[recv]) begin
                    errors <= errors + 1;
                    $display("[CDC] FAIL beat %0d: data/is_os/error mismatch", recv);
                end
                recv <= recv + 1;
            end
        end
    end

    pipe7_cdc_elastic_buf #(
        .INPUT_DATA_WIDTH(DW), .OUTPUT_DATA_WIDTH(DW), .BUFFER_DEPTH(DEPTH)
    ) dut (
        .wr_clk, .rd_clk, .rst_n,
        .wr_valid, .wr_ready, .wr_data, .wr_error, .wr_full,
        .rd_valid, .rd_ready, .rd_data, .rd_error
    );

    initial begin
        rst_n = 1'b0;
        repeat (4) @(negedge rd_clk);
        rst_n = 1'b1;

        wait (recv == N);
        repeat (4) @(negedge rd_clk);

        if (errors == 0) begin
            $display("[CDC] PASS  (%0d block payloads crossed RDI<->PCLK with backpressure)", N);
            $finish;
        end else begin
            $fatal(1, "[CDC] FAIL  (errors=%0d)", errors);
        end
    end

    initial begin
        #500000;
        $fatal(1, "[CDC] FAIL  (global timeout sent=%0d recv=%0d)", sent, recv);
    end

endmodule
