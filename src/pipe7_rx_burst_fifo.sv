
`timescale 1ns/1ps

/**
 * pipe7_rx_burst_fifo -- RX burst-absorption skid FIFO (closure-plan item 29).
 *
 * The full-width Gen5 deframer (pipe7_rx_deframer_gb) can recover UP TO TWO 130b blocks in a
 * single PCLK (a 160-bit RxData word straddling two blocks), but the downstream RDI<->PCLK
 * elastic buffer accepts one block/PCLK. This FIFO absorbs the 0/1/2-blocks-per-cycle burst and
 * drains it one block/PCLK into the CDC. It is the piece that lets the rate-aware datapath fold
 * into the integrated bridge without dropping recovered blocks (as long as the average recovered
 * rate stays <= 1 block/PCLK -- guaranteed when the RDI source rate keeps the datapath below the
 * CDC drain, the same envelope the RX-overflow flag guards).
 *
 * push_cnt (0/1/2) writes din0 then din1 this cycle; pop drains one entry when pop_ready. If a
 * push would exceed DEPTH the excess is dropped and `overflow` pulses (surfaced by the bridge as
 * part of rx_overflow). DEPTH must be >= 3 so a 2-burst on an almost-full FIFO is detectable.
 */
module pipe7_rx_burst_fifo #(
    parameter int WIDTH = 129,   // {is_os, data128}
    parameter int DEPTH = 4
) (
    input  logic             clk,
    input  logic             reset_n,

    // Burst write (up to two entries per cycle).
    input  logic [1:0]       push_cnt,
    input  logic [WIDTH-1:0] din0,
    input  logic [WIDTH-1:0] din1,

    // Single read.
    output logic             pop_valid,
    output logic [WIDTH-1:0] pop_data,
    input  logic             pop_ready,

    output logic             overflow    // 1-cycle pulse: a burst did not fit (block dropped)
);
    localparam int AW = $clog2(DEPTH);

    logic [WIDTH-1:0] mem [DEPTH];
    logic [AW:0]      count;
    logic [AW-1:0]    wr_ptr, rd_ptr;

    wire        do_pop = pop_valid && pop_ready;
    // Slots free this cycle = current free entries + the one this cycle's pop releases.
    wire [AW:0] avail  = (DEPTH[AW:0] - count) + (do_pop ? (AW+1)'(1) : (AW+1)'(0));
    // Accept min(push_cnt, avail); push_cnt is 0..2 so avail[1:0] is exact when avail < push_cnt.
    wire [1:0]  accept = (avail >= (AW+1)'(push_cnt)) ? push_cnt : avail[1:0];

    assign pop_valid = (count != 0);
    assign pop_data  = mem[rd_ptr];
    assign overflow  = (accept != push_cnt);

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            count  <= '0;
            wr_ptr <= '0;
            rd_ptr <= '0;
        end else begin
            if (accept >= 1) mem[wr_ptr]                 <= din0;
            if (accept >= 2) mem[wr_ptr + 1'b1]          <= din1;
            wr_ptr <= wr_ptr + accept[AW-1:0];
            if (do_pop) rd_ptr <= rd_ptr + 1'b1;
            count  <= count + {{(AW-1){1'b0}}, accept} - (do_pop ? {{AW{1'b0}}, 1'b1} : '0);
        end
    end

endmodule
