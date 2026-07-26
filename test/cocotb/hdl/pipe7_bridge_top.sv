
`timescale 1ns/1ps

/**
 * pipe7_bridge_top -- thin cocotb DUT wrapper for the INTEGRATED bridge cross-check
 * (Tier 1b PyUVM, closure-plan item 23). Instantiates the real ucie_rdi_to_pipe7_mac_bridge
 * with a PHY loopback (TxData -> RxData), a PHY-responder stub (PhyStatus) and a message-bus
 * responder stub (P2M), and flattens the credit-based flit RDI, control, and message-bus ports
 * so the PyUVM env can drive/observe them. The RTL is untouched; this wrapper only gives cocotb
 * a stable top-level port list (dual-clock: pclk + rdi_clk).
 */
module pipe7_bridge_top
    import pipe7_pkg::*;
#(
    parameter int PIPE_WIDTH = 80,
    parameter int RDI_WIDTH  = 64,
    parameter int CREDITS    = 8
) (
    input  logic                     pclk,
    input  logic                     rdi_clk,
    input  logic                     reset_n,

    // ---- UCIe RDI TX flit in (credit-gated) ----
    input  logic                     rdi_tx_valid,
    input  logic [RDI_WIDTH-1:0]     rdi_tx_data,
    input  logic                     rdi_tx_sob,
    input  logic                     rdi_tx_is_os,
    output logic [1:0]               rdi_tx_crd,

    // ---- UCIe RDI RX flit out ----
    output logic                     rdi_rx_valid,
    output logic [RDI_WIDTH-1:0]     rdi_rx_data,
    output logic                     rdi_rx_sob,
    output logic                     rdi_rx_is_os,
    input  logic [1:0]               rdi_rx_crd,

    // ---- Control request ----
    input  logic                     req_valid,
    input  logic [1:0]               req_kind,
    input  logic [3:0]               req_power_down,
    input  logic [3:0]               req_rate,
    input  logic [2:0]               req_width,
    input  logic [2:0]               req_rxwidth,
    output logic                     busy,
    output logic                     done,
    output logic                     req_error,

    // ---- Message-bus request ----
    input  logic                     mb_req_valid,
    input  logic                     mb_req_write,
    input  logic                     mb_req_committed,
    input  logic [MB_ADDR_WIDTH-1:0] mb_req_addr,
    input  logic [MB_DATA_WIDTH-1:0] mb_req_wdata,
    output logic                     mb_req_ready,
    output logic                     mb_busy,
    output logic                     mb_rsp_valid,
    output logic                     mb_rsp_is_read,
    output logic [MB_DATA_WIDTH-1:0] mb_rsp_rdata,
    output logic                     mb_rsp_error,

    // ---- Observable PIPE Tx stream + status ----
    output logic [PIPE_WIDTH-1:0]    tx_data,
    output logic                     tx_data_valid,
    output logic [3:0]               rate,
    output logic                     block_locked,
    output logic                     sync_error,
    output logic                     in_data_phase
);

    // PIPE MAC command / status nets.
    logic [3:0] tx_elec_idle, power_down;
    logic [2:0] width, rx_width;
    logic       rx_standby, pclk_change_ack, phy_status, pclk_change_ok;
    logic [MB_BUS_WIDTH-1:0] m2p, p2m;
    logic [PIPE_WIDTH-1:0]   rx_data;

    ucie_rdi_to_pipe7_mac_bridge #(
        .PIPE_WIDTH(PIPE_WIDTH), .RDI_WIDTH(RDI_WIDTH), .CREDITS(CREDITS)
    ) bridge (
        .rst_n(reset_n), .rdi_clk, .pclk,
        .rdi_tx_valid, .rdi_tx_data, .rdi_tx_sob, .rdi_tx_is_os, .rdi_tx_crd,
        .rdi_rx_valid, .rdi_rx_data, .rdi_rx_sob, .rdi_rx_is_os, .rdi_rx_crd,
        .req_valid, .req_kind, .req_power_down, .req_rate, .req_width, .req_rxwidth,
        .busy, .done, .req_error,
        .mb_req_valid, .mb_req_write, .mb_req_committed, .mb_req_addr, .mb_req_wdata,
        .mb_req_ready, .mb_busy, .mb_rsp_valid, .mb_rsp_is_read, .mb_rsp_rdata, .mb_rsp_error,
        .tx_data, .tx_data_valid, .tx_elec_idle, .power_down, .rate, .width, .rx_width,
        .rx_standby, .pclk_change_ack, .m2p_message_bus(m2p),
        .rx_data, .rx_valid(tx_data_valid), .phy_status, .pclk_change_ok, .p2m_message_bus(p2m),
        .block_locked, .sync_error, .in_data_phase
    );

    // PHY loopback + responders.
    assign rx_data = tx_data;
    pipe7_phy_responder_stub #(.LATENCY(4)) phy (
        .pclk, .reset_n, .power_down, .rate, .width, .rx_width,
        .pclk_change_ack, .phy_status, .pclk_change_ok
    );
    pipe7_msgbus_responder_stub #(.RC_LATENCY(3), .MEM_BITS(4)) mbresp (
        .pclk, .reset_n, .m2p, .p2m
    );

endmodule
