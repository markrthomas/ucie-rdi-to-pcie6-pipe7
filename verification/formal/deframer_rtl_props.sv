// deframer_rtl_props.sv -- SymbiYosys proof bound to the ACTUAL RX deframer RTL via the
// yosys-slang SystemVerilog frontend (closure-plan item 31). Unlike deframer_props.sv (a
// plain-Verilog re-model), this instantiates the real src/pipe7_rx_deframer.sv, so the item-27
// accumulator-overflow guard is proven on the shipped module.
//
// Unconditional (no environment assumption -- the flush guard bounds the accumulator for ANY
// rx_data / rx_valid): the deframer's internal fill counter stays in [0, RACC_W].

`default_nettype none

module deframer_rtl_props #(
    parameter int PIPE_WIDTH = 80
) (
    input logic clk
);
    localparam int BLOCK_BITS = 130;
    localparam int RACC_W     = PIPE_WIDTH + 2*BLOCK_BITS;

    // Internal reset: init-valued counter holds reset_n low for the first two cycles.
    logic [1:0] rc = 2'd0;
    always_ff @(posedge clk) if (rc != 2'd3) rc <= rc + 2'd1;
    wire reset_n = (rc >= 2'd2);
    wire f_past  = (rc == 2'd3);

    // Free stimulus into the real deframer.
    logic [PIPE_WIDTH-1:0] rx_data;
    logic                  rx_valid;
    logic                  pl_valid, pl_is_os, block_locked, sync_error;
    logic [127:0]          pl_data;

    pipe7_rx_deframer #(.PIPE_WIDTH(PIPE_WIDTH)) dut (
        .clk(clk), .reset_n(reset_n),
        .rx_data(rx_data), .rx_valid(rx_valid),
        .pl_valid(pl_valid), .pl_data(pl_data), .pl_is_os(pl_is_os),
        .block_locked(block_locked), .sync_error(sync_error)
    );

    // The item-27 guard bounds the real accumulator unconditionally.
    always_ff @(posedge clk) if (f_past && reset_n) begin
        assert (dut.rfill <= RACC_W);
        assert (dut.rfill >= 0);
    end
endmodule

`default_nettype wire
