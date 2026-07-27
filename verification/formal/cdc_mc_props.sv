// cdc_mc_props.sv -- SymbiYosys MULTICLOCK proof for the real pipe7_cdc_elastic_buf via the
// yosys-slang frontend (closure-plan item 32). Unlike fifo_cdc (single-clock abstraction
// wr_clk==rd_clk), this drives wr_clk and rd_clk as INDEPENDENT clocks under sby `multiclock on`,
// so the Gray-pointer + 2-flop synchronizer crossing is exercised with arbitrary clock
// interleavings -- the true dual-clock safety argument.
//
// Physical occupancy = wr_ptr - rd_ptr. Writes are gated by wr_full, which the RTL computes from
// the *synchronized* (lagging) read pointer, so it is conservative -- the true occupancy can only
// be <= what wr_full sees. Proved (sampled every global step):
//   P1  0 <= (wr_ptr - rd_ptr) <= BUFFER_DEPTH   (no overflow / no underflow across the CDC)
//   P2  wr_ready == !wr_full                      (no write accepted while full)

`default_nettype none

module cdc_mc_props #(
    parameter int INPUT_DATA_WIDTH  = 8,
    parameter int OUTPUT_DATA_WIDTH = 8,
    parameter int BUFFER_DEPTH      = 4
) (
    input logic wr_clk,
    input logic rd_clk
);
    localparam int PTR_W = $clog2(BUFFER_DEPTH) + 1;

    // Reset: free, but constrained to be asserted (low) for an initial global-time window then
    // released, so both domains start from a defined state. gclk-sampled init counter.
    (* gclk *) reg gclk;
    reg [2:0] init_cnt = 3'd0;
    always @(posedge gclk) if (init_cnt != 3'd7) init_cnt <= init_cnt + 3'd1;
    wire rst_n  = (init_cnt >= 3'd3);
    wire f_past = (init_cnt >= 3'd4);

    // Free DUT inputs.
    logic                          wr_valid, wr_error, rd_ready;
    logic [INPUT_DATA_WIDTH-1:0]   wr_data;
    // DUT outputs.
    logic                          wr_ready, wr_full, rd_valid, rd_error;
    logic [OUTPUT_DATA_WIDTH-1:0]  rd_data;

    pipe7_cdc_elastic_buf #(
        .INPUT_DATA_WIDTH(INPUT_DATA_WIDTH), .OUTPUT_DATA_WIDTH(OUTPUT_DATA_WIDTH),
        .BUFFER_DEPTH(BUFFER_DEPTH)
    ) dut (
        .wr_clk(wr_clk), .rd_clk(rd_clk), .rst_n(rst_n),
        .wr_valid(wr_valid), .wr_ready(wr_ready), .wr_data(wr_data), .wr_error(wr_error),
        .wr_full(wr_full),
        .rd_valid(rd_valid), .rd_ready(rd_ready), .rd_data(rd_data), .rd_error(rd_error)
    );

    // Physical occupancy across the crossing (both pointers are PTR_W-bit wrapping counters).
    wire [PTR_W-1:0] occ = dut.wr_ptr - dut.rd_ptr;

    // Sampled every global step (multiclock).
    always @(posedge gclk) if (f_past && rst_n) begin
        assert (occ <= PTR_W'(BUFFER_DEPTH));   // P1 no overflow (and, being unsigned, no underflow)
        assert (wr_ready == !wr_full);          // P2
    end
endmodule

`default_nettype wire
