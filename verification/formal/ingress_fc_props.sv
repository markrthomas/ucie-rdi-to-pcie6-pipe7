// ingress_fc_props.sv -- SymbiYosys formal proof for the RDI ingress credit flow control
// (closure-plan item 33). The egress side was proven in item 24 (credit_fc); this proves the
// SENDER side: the ingress FIFO never overflows under a credit-honest sender. Faithful
// plain-Verilog model of pipe7_rdi_ingress's occupancy accounting (count += push, count -= FPB
// on a block pop, one credit returned per freed flit = FPB on pop) plus a credit-honest sender
// (holds `avail` credits, pushes only while a credit is available, folds returned credits back).
//
// Proved:
//   P1  no FIFO overflow : count <= DEPTH (= CREDITS)
//   P2  sender budget     : 0 <= avail <= CREDITS
//   P3  closed loop       : count + avail == CREDITS (occupancy == credits in flight)
// Cover:
//   C1  FIFO fills to CREDITS (sender exhausts its credits) then drains back.

`default_nettype none
`timescale 1ns/1ps

module ingress_fc_props #(
    parameter integer RDI_WIDTH = 64,
    parameter integer CREDITS   = 8
) (
    input wire clk,
    input wire rst_n
);
    localparam integer FPB   = 128 / RDI_WIDTH;    // flits per block (= 2 at 64b)
    localparam integer DEPTH = CREDITS;
    localparam integer CWID  = $clog2(2*CREDITS + 1);

    // Free environment: the sender wants to push, and the downstream (CDC) can take a block.
    wire want_push;
    wire blk_ready;

    // Ingress occupancy (flits buffered) and the credit-honest sender's budget.
    reg [CWID-1:0] count = {CWID{1'b0}};
    reg [CWID-1:0] avail = CREDITS[CWID-1:0];

    wire        pop     = (count >= FPB[CWID-1:0]) && blk_ready;   // a full block assembled + taken
    wire [1:0]  rdi_crd = pop ? FPB[1:0] : 2'd0;                   // credits returned this cycle
    wire        push    = want_push && (avail != 0);               // sender holds a credit

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count <= {CWID{1'b0}};
            avail <= CREDITS[CWID-1:0];
        end else begin
            count <= count + (push ? 1'b1 : 1'b0) - (pop ? FPB[CWID-1:0] : {CWID{1'b0}});
            avail <= avail - (push ? 1'b1 : 1'b0) + rdi_crd;
        end
    end

`ifdef FORMAL
    reg f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;

    always @(posedge clk) if (f_past_valid && rst_n) begin
        assert (count <= DEPTH[CWID-1:0]);                 // P1 no overflow
        assert (avail <= CREDITS[CWID-1:0]);               // P2 budget upper
        assert (count + avail == CREDITS[CWID-1:0]);       // P3 closed loop
    end

    always @(posedge clk) if (rst_n) begin
        cover (f_past_valid && count == CREDITS[CWID-1:0]);   // C1: fills to CREDITS
        cover (f_past_valid && avail == '0);                  // sender exhausts credits
    end
`endif
endmodule
`default_nettype wire
