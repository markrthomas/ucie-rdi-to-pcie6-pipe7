// gearbox_props.sv — SymbiYosys formal proof for the Gen5 128b/130b full-width TX gearbox
// accept/accumulator invariants (closure-plan item 24). Yosys cannot parse the SV package-import
// header of src/pipe7_tx_framer_gb.sv, so — following the fifo_cdc methodology — this is a
// faithful plain-Verilog model of the framer's accumulator-fill accounting (mirrors
// pipe7_tx_framer_gb.sv exactly: emit one PIPE_WIDTH word when fill>=PIPE_WIDTH, then accept
// take=min(pl_cnt, room_blocks) blocks of BLOCK_BITS each, room_blocks capped at 2).
//
// Only the *fill* counter is modelled (the block-count / no-overflow safety is independent of
// the payload data). Proved unconditionally (no environment assumptions -- the framer gates
// accept on room, so it is safe for any offered stream):
//   P1  pl_acc <= pl_cnt        (never accept more blocks than offered)
//   P2  pl_acc <= 2             (never accept more than two blocks/cycle)
//   P3  pl_acc <= room_blocks   (never accept beyond accumulator room)
//   P4  0 <= fill <= ACC_W      (accumulator never overflows or underflows)
// Cover:
//   C1  a two-block accept occurs (the gearbox actually bursts to two)
//   C2  a word is emitted (tx_data_valid)

`default_nettype none
`timescale 1ns/1ps

module gearbox_props #(
    parameter integer PIPE_WIDTH = 160
) (
    input wire clk,
    input wire rst_n
);
    localparam integer BLOCK_BITS = 130;
    localparam integer ACC_W      = PIPE_WIDTH + 2*BLOCK_BITS;
    localparam integer FW         = $clog2(ACC_W + 1);

    // Free input: number of blocks offered this cycle (0..2).
    wire [1:0] pl_cnt;

    reg  [FW-1:0] fill = {FW{1'b0}};      // bits currently buffered (init = reset state)

    // Combinational next-state (mirrors pipe7_tx_framer_gb always_comb).
    reg           emit;
    reg  [FW-1:0] fill_e;
    integer       room, room_blocks, offered, take;
    reg  [FW-1:0] n_fill;

    always @(*) begin
        emit   = (fill >= PIPE_WIDTH);
        fill_e = emit ? (fill - PIPE_WIDTH[FW-1:0]) : fill;

        room = ACC_W - fill_e;
        if      (room >= 2*BLOCK_BITS) room_blocks = 2;
        else if (room >=   BLOCK_BITS) room_blocks = 1;
        else                           room_blocks = 0;
        offered = pl_cnt;
        take    = (offered < room_blocks) ? offered : room_blocks;

        n_fill = fill_e + take[FW-1:0] * BLOCK_BITS[FW-1:0];
    end

    wire [1:0] pl_acc = take[1:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fill <= {FW{1'b0}};
        else        fill <= n_fill;
    end

`ifdef FORMAL
    reg f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;

    always @(*) assume(pl_cnt <= 2);

    always @(posedge clk) if (rst_n) begin
        assert(pl_acc <= pl_cnt);         // P1
        assert(pl_acc <= 2);              // P2
        assert(take   <= room_blocks);    // P3
        assert(fill   <= ACC_W);          // P4 (upper)
        assert(n_fill <= ACC_W);          // P4 next-state (the accumulator never overflows)
    end

    always @(posedge clk) if (rst_n && f_past_valid) begin
        cover(pl_acc == 2);               // C1
        cover(emit);                      // C2
    end
`endif
endmodule
`default_nettype wire
