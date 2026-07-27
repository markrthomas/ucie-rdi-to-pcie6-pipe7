// deframer_props.sv — SymbiYosys formal proof for the Gen5 128b/130b RX deframer accumulator
// overflow guard (closure-plan item 27). Yosys cannot parse the SV package-import header of
// src/pipe7_rx_deframer.sv, so — following the fifo_cdc methodology — this is a faithful
// plain-Verilog model of the deframer's fill accounting (mirrors pipe7_rx_deframer.sv: append
// PIPE_WIDTH bits/cycle when rx_valid; a legal header extracts a full BLOCK_BITS block; an
// illegal header slips one bit; the item-27 flush guard re-hunts from empty when appending
// would overflow the accumulator).
//
// Only the *fill* counter is modelled (the overflow safety is independent of the payload data;
// header legality is a free input, i.e. adversarial). The whole point of item 27 is that the
// guard makes the bound hold *unconditionally* — no alignment assumption:
//   P1  0 <= rfill <= RACC_W          (accumulator never overflows or underflows)
//   P2  the appended word always fits  (rfill + PIPE_WIDTH <= RACC_W whenever we append)
// Cover:
//   C1  the flush guard actually fires (a persistently-misaligned stream is recovered)
//   C2  a normal block extraction occurs

`default_nettype none
`timescale 1ns/1ps

module deframer_props #(
    parameter integer PIPE_WIDTH = 80
) (
    input wire clk,
    input wire rst_n
);
    localparam integer BLOCK_BITS = 130;
    localparam integer RACC_W     = PIPE_WIDTH + 2*BLOCK_BITS;
    localparam integer FW         = $clog2(RACC_W + PIPE_WIDTH + 1);

    // Free inputs: RX word presence and whether the current header is legal (data-dependent).
    wire rx_valid;
    wire hdr_legal;

    reg [FW-1:0] rfill = {FW{1'b0}};

    // Combinational next-state (mirrors pipe7_rx_deframer with the item-27 flush guard).
    reg           flush;
    reg [FW-1:0]  base_fill, n_rfill;
    reg           extract, slip;

    always @(*) begin
        flush     = (rfill + PIPE_WIDTH) > RACC_W;
        base_fill = flush ? {FW{1'b0}} : (rx_valid ? (rfill + PIPE_WIDTH[FW-1:0]) : rfill);

        extract = (!flush) && (base_fill >= BLOCK_BITS) &&  hdr_legal;
        slip    = (!flush) && (base_fill >= BLOCK_BITS) && !hdr_legal;

        if      (extract) n_rfill = base_fill - BLOCK_BITS[FW-1:0];
        else if (slip)    n_rfill = base_fill - 1'b1;
        else              n_rfill = base_fill;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rfill <= {FW{1'b0}};
        else        rfill <= n_rfill;
    end

`ifdef FORMAL
    reg f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;

    always @(posedge clk) if (rst_n) begin
        assert(rfill  <= RACC_W);              // P1 (upper): unconditional bound
        assert(n_rfill <= RACC_W);             // next-state bound (accumulator never overflows)
        if (!flush && rx_valid)
            assert(rfill + PIPE_WIDTH <= RACC_W); // P2: the appended word always fits
    end

    always @(posedge clk) if (rst_n && f_past_valid) begin
        cover(flush);                          // C1: the guard fires and recovers
        cover(extract);                        // C2: a normal extraction
    end
`endif
endmodule
`default_nettype wire
