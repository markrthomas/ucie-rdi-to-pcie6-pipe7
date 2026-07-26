
`timescale 1ns/1ps

/**
 * pipe7_mac_dut -- UVM DUT wrapper for the PIPE 7.1 MAC bridge env (closure-plan item 22).
 *
 * Retargeted at the INTEGRATED bridge: this now wraps the real
 * `ucie_rdi_to_pipe7_mac_bridge` (item 20) rather than re-composing the cores. The env drives
 * the credit-based, flit-level UCIe RDI front end (RDI_WIDTH-bit flits with a start-of-block
 * marker) across the RDI clock domain, while the PIPE MAC command/status/message-bus signals
 * live in the pclk domain -- so the wrapper carries both clocks and the bridge owns the
 * RDI<->PCLK CDC internally.
 *
 * The bridge's datapath owns TxElecIdle (asserted except while transmitting; a data phase
 * starts only in P0), so TxDataValid is never high while TxElecIdle is asserted.
 *
 * The Gen6-wide RX cross-check (item 22) is a separate aux datapath (`pipe7_mac_datapath_ra`)
 * instantiated in the UVM top, since the integrated bridge's data plane is the single-block
 * Gen5 path (rate-matched to the block-payload CDC, item 20).
 */
module pipe7_mac_dut
    import pipe7_pkg::*;
#(
    parameter int PIPE_WIDTH = 80,
    parameter int RDI_WIDTH  = 64,
    parameter int CREDITS    = 8
) (
    input  logic                     pclk,
    input  logic                     rdi_clk,
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

    // ---- PIPE MAC command outputs (bridge -> PHY) ----
    output logic [3:0]               power_down,
    output logic [3:0]               rate,
    output logic [2:0]               width,
    output logic [2:0]               rx_width,
    output logic [3:0]               tx_elec_idle,
    output logic                     rx_standby,
    output logic                     pclk_change_ack,

    // ---- PIPE MAC status inputs (PHY -> bridge) ----
    input  logic                     phy_status,
    input  logic                     pclk_change_ok,

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

    // ---- PIPE MAC Tx datapath (to PHY) ----
    output logic [PIPE_WIDTH-1:0]    tx_data,
    output logic                     tx_data_valid,

    // ---- PIPE MAC Rx datapath (from PHY) ----
    input  logic [PIPE_WIDTH-1:0]    rx_data,
    input  logic                     rx_valid,

    // ---- Datapath status ----
    output logic                     block_locked,
    output logic                     sync_error,
    output logic                     in_data_phase,
    output logic                     rx_overflow,

    // ---- Message-bus request (controller -> master) ----
    input  logic                      mb_req_valid,
    input  logic                      mb_req_write,
    input  logic                      mb_req_committed,
    input  logic [MB_ADDR_WIDTH-1:0]  mb_req_addr,
    input  logic [MB_DATA_WIDTH-1:0]  mb_req_wdata,
    output logic                      mb_req_ready,
    output logic                      mb_busy,
    output logic                      mb_rsp_valid,
    output logic                      mb_rsp_is_read,
    output logic [MB_DATA_WIDTH-1:0]  mb_rsp_rdata,
    output logic                      mb_rsp_error,

    // ---- Message bus (MAC <-> PHY) ----
    output logic [MB_BUS_WIDTH-1:0]   m2p_message_bus,
    input  logic [MB_BUS_WIDTH-1:0]   p2m_message_bus
);

    ucie_rdi_to_pipe7_mac_bridge #(
        .PIPE_WIDTH(PIPE_WIDTH), .RDI_WIDTH(RDI_WIDTH), .CREDITS(CREDITS)
    ) bridge (
        .rst_n(reset_n), .rdi_clk, .pclk,
        // UCIe RDI TX / RX (credit-based flits)
        .rdi_tx_valid, .rdi_tx_data, .rdi_tx_sob, .rdi_tx_is_os, .rdi_tx_crd,
        .rdi_rx_valid, .rdi_rx_data, .rdi_rx_sob, .rdi_rx_is_os, .rdi_rx_crd,
        // Control request
        .req_valid, .req_kind, .req_power_down, .req_rate, .req_width, .req_rxwidth,
        .busy, .done, .req_error,
        // Message-bus request
        .mb_req_valid, .mb_req_write, .mb_req_committed, .mb_req_addr, .mb_req_wdata,
        .mb_req_ready, .mb_busy, .mb_rsp_valid, .mb_rsp_is_read, .mb_rsp_rdata, .mb_rsp_error,
        // PIPE MAC command / data out
        .tx_data, .tx_data_valid, .tx_elec_idle, .power_down, .rate, .width, .rx_width,
        .rx_standby, .pclk_change_ack, .m2p_message_bus,
        // PIPE MAC status / data in
        .rx_data, .rx_valid, .phy_status, .pclk_change_ok, .p2m_message_bus,
        // Status
        .block_locked, .sync_error, .in_data_phase, .rx_overflow
    );

endmodule
