
`timescale 1ns/1ps

/**
 * pipe7_mac_dut -- datapath DUT for the PIPE 7.1 MAC UVM base env (closure-plan item 8).
 *
 * Composes the MAC-owned Gen5 128b/130b datapath (pipe7_tx_framer -> pipe7_rx_deframer) into a
 * single bridge-datapath block: RDI payload in -> framed PIPE TxData; PIPE RxData -> recovered
 * RDI payload out. The UVM top loops TxData back to RxData through a PHY BFM so the round-trip
 * closes and the scoreboard can check RDI-payload in == RDI-payload out.
 *
 * Scope note: this is the DATAPATH env (item 8). The control-plane FSM + PHY-responder
 * handshake are wired in item 9, and the Gen6 raw path / message bus in item 10; the top drives
 * static Gen5 command values on pipe7_mac_if for now. TX_DATA_WIDTH is a Gen5 SerDes width
 * <= 130 (single-block-per-cycle framer), default 80.
 */
module pipe7_mac_dut
    import pipe7_pkg::*;
#(
    parameter int PIPE_WIDTH = 80
) (
    input  logic                     clk,
    input  logic                     reset_n,

    // RDI payload in (TX source)
    input  logic                     rdi_tx_valid,
    input  logic [BLOCK_PAYLOAD-1:0] rdi_tx_data,
    input  logic                     rdi_tx_is_os,
    output logic                     rdi_tx_ready,

    // RDI payload out (RX sink)
    output logic                     rdi_rx_valid,
    output logic [BLOCK_PAYLOAD-1:0] rdi_rx_data,
    output logic                     rdi_rx_is_os,

    // PIPE MAC Tx (to PHY)
    output logic [PIPE_WIDTH-1:0]    tx_data,
    output logic                     tx_data_valid,

    // PIPE MAC Rx (from PHY)
    input  logic [PIPE_WIDTH-1:0]    rx_data,
    input  logic                     rx_valid,

    // Datapath status (observed by the scoreboard/coverage)
    output logic                     block_locked,
    output logic                     sync_error
);

    pipe7_tx_framer #(.PIPE_WIDTH(PIPE_WIDTH)) framer (
        .clk, .reset_n,
        .pl_valid(rdi_tx_valid), .pl_data(rdi_tx_data), .pl_is_os(rdi_tx_is_os),
        .pl_ready(rdi_tx_ready),
        .tx_data(tx_data), .tx_data_valid(tx_data_valid)
    );

    pipe7_rx_deframer #(.PIPE_WIDTH(PIPE_WIDTH)) deframer (
        .clk, .reset_n,
        .rx_data(rx_data), .rx_valid(rx_valid),
        .pl_valid(rdi_rx_valid), .pl_data(rdi_rx_data), .pl_is_os(rdi_rx_is_os),
        .block_locked(block_locked), .sync_error(sync_error)
    );

endmodule
