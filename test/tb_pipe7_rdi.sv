
`timescale 1ns/1ps

/**
 * tb_pipe7_rdi -- UCIe RDI ingress/egress + credit flow-control round-trip (closure-plan
 * item 18). Self-clocking; built with `verilator --binary --timing`.
 *
 * RDI flit words -> pipe7_rdi_ingress (credit return) -> 128-bit block payloads ->
 * pipe7_rdi_egress -> RDI flit words. A credit-tracking source drives the ingress (never
 * exceeding CREDITS outstanding) and a credit-returning sink drains the egress. The output flit
 * stream must equal the input flit stream (data + sob + is_os) in order. Prints [RDI] PASS/FAIL.
 */
module tb_pipe7_rdi;
    import pipe7_pkg::*;

    localparam int RDI_WIDTH = 64;
    localparam int CREDITS   = 8;
    localparam int N         = 16;             // blocks
    localparam int FLITS     = N * (BLOCK_PAYLOAD / RDI_WIDTH);   // 2 flits/block

    logic clk, reset_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Golden input flit stream (both words of a block share is_os; sob on word 0).
    logic [RDI_WIDTH-1:0] in_data [FLITS];
    logic                 in_sob  [FLITS];
    logic                 in_os   [FLITS];
    initial begin
        for (int k = 0; k < N; k++) begin
            logic o;
            o = ($random & 1);
            in_data[2*k]   = $random;             in_sob[2*k]   = 1'b1; in_os[2*k]   = o;
            in_data[2*k+1] = $random;             in_sob[2*k+1] = 1'b0; in_os[2*k+1] = o;
        end
    end

    // ---- Credit-tracking RDI source -> ingress ----
    int  avail, sent;
    wire can_send = (avail > 0) && (sent < FLITS) && reset_n;
    logic                 i_valid;
    logic [RDI_WIDTH-1:0] i_data;
    logic                 i_sob, i_os;
    logic [1:0]           i_crd;
    assign i_valid = can_send;
    assign i_data  = in_data[sent];
    assign i_sob   = in_sob[sent];
    assign i_os    = in_os[sent];

    // ---- ingress -> block -> egress ----
    logic                     blk_valid, blk_is_os, blk_ready;
    logic [BLOCK_PAYLOAD-1:0] blk_data;

    pipe7_rdi_ingress #(.RDI_WIDTH(RDI_WIDTH), .CREDITS(CREDITS)) ingress (
        .clk, .reset_n,
        .rdi_valid(i_valid), .rdi_data(i_data), .rdi_sob(i_sob), .rdi_is_os(i_os), .rdi_crd(i_crd),
        .blk_valid, .blk_data, .blk_is_os, .blk_ready
    );

    logic                 o_valid, o_sob, o_os;
    logic [RDI_WIDTH-1:0] o_data;
    logic [1:0]           o_crd;

    pipe7_rdi_egress #(.RDI_WIDTH(RDI_WIDTH), .CREDITS(CREDITS)) egress (
        .clk, .reset_n,
        .blk_valid, .blk_data, .blk_is_os, .blk_ready,
        .rdi_valid(o_valid), .rdi_data(o_data), .rdi_sob(o_sob), .rdi_is_os(o_os), .rdi_crd(o_crd)
    );

    // ---- Sink: return one credit per emitted flit (1-cycle delayed) ----
    always_ff @(posedge clk or negedge reset_n)
        if (!reset_n) o_crd <= 2'd0;
        else          o_crd <= {1'b0, o_valid};

    // ---- Source credit accounting ----
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin avail <= CREDITS; sent <= 0; end
        else begin
            if (can_send) sent <= sent + 1;
            avail <= avail - (can_send ? 1 : 0) + int'(i_crd);
        end
    end

    // ---- Consumer: check the output flit stream vs the input ----
    int recv, errors;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin recv <= 0; errors <= 0; end
        else if (o_valid) begin
            if (o_data !== in_data[recv] || o_sob !== in_sob[recv] || o_os !== in_os[recv]) begin
                errors <= errors + 1;
                $display("[RDI] FAIL flit %0d: data/sob/os mismatch", recv);
            end
            recv <= recv + 1;
        end
    end

    initial begin
        reset_n = 1'b0;
        repeat (4) @(negedge clk);
        reset_n = 1'b1;

        wait (recv == FLITS);
        repeat (4) @(negedge clk);

        if (errors == 0) begin
            $display("[RDI] PASS  (%0d blocks / %0d flits round-tripped with credit FC)", N, FLITS);
            $finish;
        end else begin
            $fatal(1, "[RDI] FAIL  (errors=%0d)", errors);
        end
    end

    initial begin
        #500000;
        $fatal(1, "[RDI] FAIL  (global timeout recv=%0d)", recv);
    end

endmodule
