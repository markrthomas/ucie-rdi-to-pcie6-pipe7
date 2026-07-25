
`timescale 1ns/1ps

/**
 * pipe7_mac_dut -- datapath + control-plane DUT for the PIPE 7.1 MAC UVM env
 * (closure-plan items 8-9).
 *
 * Composes the MAC-owned cores into a single bridge block:
 *   - control plane: pipe7_mac_ctrl_fsm sequences PowerDown/Rate/Width toward the PHY, gated
 *     on PhyStatus (item 9). Its request interface is exposed as DUT ports for the UVM control
 *     agent; its command outputs drive the PIPE MAC command signals.
 *   - datapath: pipe7_tx_framer -> pipe7_rx_deframer (Gen5 128b/130b, item 8). RDI payload in
 *     -> framed TxData; RxData -> recovered RDI payload out.
 *
 * The UVM top loops TxData back to RxData through a PHY BFM and drives PhyStatus from the
 * PHY-responder agent, so both the datapath round-trip and the control-plane handshake close.
 * TX_DATA_WIDTH is a Gen5 SerDes width <= 130 (single-block-per-cycle framer), default 80.
 */
module pipe7_mac_dut
    import pipe7_pkg::*;
#(
    parameter int PIPE_WIDTH = 80
) (
    input  logic                     clk,
    input  logic                     reset_n,

    // ---- Control request (controller -> FSM) ----
    input  logic                     req_valid,
    input  logic [1:0]               req_kind,
    input  logic [3:0]               req_power_down,
    input  logic [3:0]               req_rate,
    input  logic [2:0]               req_width,
    input  logic [2:0]               req_rxwidth,
    output logic                     busy,
    output logic                     done,
    output logic                     req_error,

    // ---- PIPE MAC command outputs (FSM -> PHY) ----
    output logic [3:0]               power_down,
    output logic [3:0]               rate,
    output logic [2:0]               width,
    output logic [2:0]               rx_width,
    output logic [3:0]               tx_elec_idle,
    output logic                     rx_standby,
    output logic                     pclk_change_ack,

    // ---- PIPE MAC status inputs (PHY -> FSM) ----
    input  logic                     phy_status,
    input  logic                     pclk_change_ok,

    // ---- RDI payload in (TX source) ----
    input  logic                     rdi_tx_valid,
    input  logic [BLOCK_PAYLOAD-1:0] rdi_tx_data,
    input  logic                     rdi_tx_is_os,
    output logic                     rdi_tx_ready,

    // ---- RDI payload out (RX sink) ----
    output logic                     rdi_rx_valid,
    output logic [BLOCK_PAYLOAD-1:0] rdi_rx_data,
    output logic                     rdi_rx_is_os,

    // ---- PIPE MAC Tx datapath (to PHY) ----
    output logic [PIPE_WIDTH-1:0]    tx_data,
    output logic                     tx_data_valid,

    // ---- PIPE MAC Rx datapath (from PHY) ----
    input  logic [PIPE_WIDTH-1:0]    rx_data,
    input  logic                     rx_valid,

    // ---- Datapath status ----
    output logic                     block_locked,
    output logic                     sync_error
);

    // Control plane: PowerDown/Rate/Width sequencer gated on PhyStatus.
    pipe7_mac_ctrl_fsm #(.PCLK_IS_PHY_INPUT(1'b0)) fsm (
        .pclk(clk), .reset_n,
        .req_valid, .req_kind(ctrl_req_e'(req_kind)),
        .req_power_down, .req_rate, .req_width, .req_rxwidth,
        .busy, .done, .req_error,
        .power_down, .rate, .width, .rx_width, .tx_elec_idle, .rx_standby, .pclk_change_ack,
        .phy_status, .pclk_change_ok
    );

    // Datapath: Gen5 128b/130b framer -> deframer.
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
