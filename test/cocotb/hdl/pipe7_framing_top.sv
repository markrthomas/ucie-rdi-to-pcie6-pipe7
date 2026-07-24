
`timescale 1ns/1ps

/**
 * pipe7_framing_top -- thin cocotb DUT wrapper for the Gen5 128b/130b framing round-trip
 * (Tier 1b PyUVM cross-check, closure-plan item 13). Instantiates pipe7_tx_framer and
 * pipe7_rx_deframer in loopback (tx_data -> rx_data) and exposes only port-level signals so
 * the PyUVM env can drive payloads and observe recovered payloads + framing status. The RTL
 * itself is untouched; this wrapper exists purely to give cocotb a stable top-level port list.
 */
module pipe7_framing_top
    import pipe7_pkg::*;
#(
    parameter int PIPE_WIDTH = 80
) (
    input  logic                     clk,
    input  logic                     reset_n,

    // Payload in (driver side)
    input  logic                     pl_valid_i,
    input  logic [BLOCK_PAYLOAD-1:0] pl_data_i,
    input  logic                     pl_is_os_i,
    output logic                     pl_ready_i,

    // Payload out (monitor side)
    output logic                     pl_valid_o,
    output logic [BLOCK_PAYLOAD-1:0] pl_data_o,
    output logic                     pl_is_os_o,
    output logic                     block_locked,
    output logic                     sync_error,

    // Observable PIPE stream (for an independent Python deframe cross-check)
    output logic [PIPE_WIDTH-1:0]    tx_data,
    output logic                     tx_data_valid
);

    logic [PIPE_WIDTH-1:0] stream;
    logic                  stream_valid;

    assign tx_data       = stream;
    assign tx_data_valid = stream_valid;

    pipe7_tx_framer #(.PIPE_WIDTH(PIPE_WIDTH)) framer (
        .clk, .reset_n,
        .pl_valid(pl_valid_i), .pl_data(pl_data_i), .pl_is_os(pl_is_os_i), .pl_ready(pl_ready_i),
        .tx_data(stream), .tx_data_valid(stream_valid)
    );

    pipe7_rx_deframer #(.PIPE_WIDTH(PIPE_WIDTH)) deframer (
        .clk, .reset_n,
        .rx_data(stream), .rx_valid(stream_valid),
        .pl_valid(pl_valid_o), .pl_data(pl_data_o), .pl_is_os(pl_is_os_o),
        .block_locked(block_locked), .sync_error(sync_error)
    );

endmodule
