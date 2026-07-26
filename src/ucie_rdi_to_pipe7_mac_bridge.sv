
`timescale 1ns/1ps

/**
 * ucie_rdi_to_pipe7_mac_bridge -- UCIe 1.0 RDI <-> PCIe 6.x / PIPE 7.1 MAC-facing bridge
 * (integrated top, closure-plan item 20). Replaces the item-1 datapath-only pass-through with
 * the full composition of the closure-plan cores, presenting the real PIPE 7.1 MAC signal set.
 *
 *   RDI TX flits --> pipe7_rdi_ingress (credit FC) --> tx CDC (rdi_clk -> pclk)
 *                --> pipe7_mac_datapath (Gen5 128b/130b framer, TxElecIdle-gated) --> TxData
 *   RxData --> pipe7_mac_datapath (deframer) --> rx CDC (pclk -> rdi_clk)
 *          --> pipe7_rdi_egress (credit FC) --> RDI RX flits
 *   Control: pipe7_mac_ctrl_fsm sequences PowerDown/Rate/Width, gated on PhyStatus.
 *   Message bus: pipe7_msgbus_master + pipe7_regfile drive M2P / consume P2M.
 *
 * TxElecIdle is owned by the datapath (asserted except while transmitting; a data phase starts
 * only in P0), so TxDataValid is never high while TxElecIdle is asserted. The datapath uses the
 * single-block Gen5 path at PIPE_WIDTH=80 (1 block/PCLK, rate-matched to the block-payload CDC);
 * the Gen5 full-width gearbox and the Gen6 raw data plane (proven standalone, items 16-17) are a
 * documented follow-on for wiring the rate-mux + 160-bit gearbox through this top.
 */
module ucie_rdi_to_pipe7_mac_bridge
    import pipe7_pkg::*;
#(
    parameter int PIPE_WIDTH = 80,
    parameter int RDI_WIDTH  = 64,
    parameter int CREDITS    = 8,
    parameter int BUF_DEPTH  = BUFFER_DEPTH   // reuse the pkg default
) (
    input  logic                     rst_n,
    input  logic                     rdi_clk,
    input  logic                     pclk,

    // ---- RDI TX flit input (credit-gated) ----
    input  logic                     rdi_tx_valid,
    input  logic [RDI_WIDTH-1:0]     rdi_tx_data,
    input  logic                     rdi_tx_sob,
    input  logic                     rdi_tx_is_os,
    output logic [1:0]               rdi_tx_crd,

    // ---- RDI RX flit output ----
    output logic                     rdi_rx_valid,
    output logic [RDI_WIDTH-1:0]     rdi_rx_data,
    output logic                     rdi_rx_sob,
    output logic                     rdi_rx_is_os,
    input  logic [1:0]               rdi_rx_crd,

    // ---- Control request (controller side) ----
    input  logic                     req_valid,
    input  logic [1:0]               req_kind,
    input  logic [3:0]               req_power_down,
    input  logic [3:0]               req_rate,
    input  logic [2:0]               req_width,
    input  logic [2:0]               req_rxwidth,
    output logic                     busy,
    output logic                     done,
    output logic                     req_error,

    // ---- Message-bus request (controller side) ----
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

    // ---- PIPE MAC command / data outputs (MAC -> PHY) ----
    output logic [PIPE_WIDTH-1:0]    tx_data,
    output logic                     tx_data_valid,
    output logic [3:0]               tx_elec_idle,
    output logic [3:0]               power_down,
    output logic [3:0]               rate,
    output logic [2:0]               width,
    output logic [2:0]               rx_width,
    output logic                     rx_standby,
    output logic                     pclk_change_ack,
    output logic [MB_BUS_WIDTH-1:0]  m2p_message_bus,

    // ---- PIPE MAC status / data inputs (PHY -> MAC) ----
    input  logic [PIPE_WIDTH-1:0]    rx_data,
    input  logic                     rx_valid,
    input  logic                     phy_status,
    input  logic                     pclk_change_ok,
    input  logic [MB_BUS_WIDTH-1:0]  p2m_message_bus,

    // ---- Status / observability ----
    output logic                     block_locked,
    output logic                     sync_error,
    output logic                     in_data_phase
);

    localparam int PW = BLOCK_PAYLOAD + 1;   // CDC block-payload width {is_os, data128}

    // ================= Control plane =================
    /* verilator lint_off UNUSEDSIGNAL */
    logic [3:0] fsm_tx_elec_idle;            // FSM's EI output unused; the datapath owns EI
    /* verilator lint_on UNUSEDSIGNAL */
    pipe7_mac_ctrl_fsm #(.PCLK_IS_PHY_INPUT(1'b0)) ctrl (
        .pclk, .reset_n(rst_n),
        .req_valid, .req_kind(ctrl_req_e'(req_kind)),
        .req_power_down, .req_rate, .req_width, .req_rxwidth,
        .busy, .done, .req_error,
        .power_down, .rate, .width, .rx_width,
        .tx_elec_idle(fsm_tx_elec_idle), .rx_standby, .pclk_change_ack,
        .phy_status, .pclk_change_ok
    );

    // ================= Message bus =================
    pipe7_msgbus_master mbus (
        .pclk, .reset_n(rst_n),
        .req_valid(mb_req_valid), .req_write(mb_req_write), .req_committed(mb_req_committed),
        .req_addr(mb_req_addr), .req_wdata(mb_req_wdata),
        .req_ready(mb_req_ready), .busy(mb_busy),
        .rsp_valid(mb_rsp_valid), .rsp_is_read(mb_rsp_is_read), .rsp_rdata(mb_rsp_rdata),
        .rsp_error(mb_rsp_error),
        .m2p(m2p_message_bus), .p2m(p2m_message_bus)
    );
    /* verilator lint_off UNUSEDSIGNAL */
    logic [MB_DATA_WIDTH-1:0] rf_rdata_nc;
    logic                     rf_hit_nc;
    logic [8*MB_DATA_WIDTH-1:0] rf_snap_nc;
    /* verilator lint_on UNUSEDSIGNAL */
    pipe7_regfile #(.NUM_REGS(8), .BASE_ADDR(REG_PHY_TX_CTRL_BASE)) rf (
        .pclk, .reset_n(rst_n),
        .host_we(1'b0), .host_re(1'b0), .host_addr('0), .host_wdata('0),
        .host_rdata(rf_rdata_nc), .host_hit(rf_hit_nc), .regs_flat(rf_snap_nc)
    );

    // ================= TX: RDI ingress -> CDC -> datapath =================
    logic          ig_blk_valid, ig_blk_is_os, ig_blk_ready;
    logic [BLOCK_PAYLOAD-1:0] ig_blk_data;

    pipe7_rdi_ingress #(.RDI_WIDTH(RDI_WIDTH), .CREDITS(CREDITS)) ingress (
        .clk(rdi_clk), .reset_n(rst_n),
        .rdi_valid(rdi_tx_valid), .rdi_data(rdi_tx_data), .rdi_sob(rdi_tx_sob),
        .rdi_is_os(rdi_tx_is_os), .rdi_crd(rdi_tx_crd),
        .blk_valid(ig_blk_valid), .blk_data(ig_blk_data), .blk_is_os(ig_blk_is_os),
        .blk_ready(ig_blk_ready)
    );

    logic          txc_rd_valid, txc_rd_ready, txc_wr_full;
    logic [PW-1:0] txc_rd_data;
    /* verilator lint_off UNUSEDSIGNAL */
    logic          txc_rd_error, txc_wr_ready_nc;
    /* verilator lint_on UNUSEDSIGNAL */
    assign ig_blk_ready = !txc_wr_full;

    pipe7_cdc_elastic_buf #(.INPUT_DATA_WIDTH(PW), .OUTPUT_DATA_WIDTH(PW), .BUFFER_DEPTH(BUF_DEPTH)) tx_cdc (
        .wr_clk(rdi_clk), .rd_clk(pclk), .rst_n(rst_n),
        .wr_valid(ig_blk_valid && ig_blk_ready), .wr_ready(txc_wr_ready_nc),
        .wr_data({ig_blk_is_os, ig_blk_data}), .wr_error(1'b0), .wr_full(txc_wr_full),
        .rd_valid(txc_rd_valid), .rd_ready(txc_rd_ready), .rd_data(txc_rd_data), .rd_error(txc_rd_error)
    );

    logic          dp_pl_ready, dp_rx_valid, dp_rx_is_os;
    logic [BLOCK_PAYLOAD-1:0] dp_rx_data;
    wire           data_enable = txc_rd_valid;         // start a data phase when TX data is buffered
    assign txc_rd_ready = dp_pl_ready;

    pipe7_mac_datapath #(.PIPE_WIDTH(PIPE_WIDTH)) datapath (
        .clk(pclk), .reset_n(rst_n),
        .power_down, .data_enable,
        .pl_valid(txc_rd_valid), .pl_data(txc_rd_data[BLOCK_PAYLOAD-1:0]),
        .pl_is_os(txc_rd_data[BLOCK_PAYLOAD]), .pl_ready(dp_pl_ready),
        .rx_pl_valid(dp_rx_valid), .rx_pl_data(dp_rx_data), .rx_pl_is_os(dp_rx_is_os),
        .tx_data, .tx_data_valid, .tx_elec_idle,
        .rx_data, .rx_valid,
        .block_locked, .sync_error, .in_data_phase
    );

    // ================= RX: datapath -> CDC -> RDI egress =================
    logic          rxc_rd_valid, rxc_rd_ready;
    logic [PW-1:0] rxc_rd_data;
    /* verilator lint_off UNUSEDSIGNAL */
    logic          rxc_wr_full, rxc_wr_ready, rxc_rd_error;
    /* verilator lint_on UNUSEDSIGNAL */

    pipe7_cdc_elastic_buf #(.INPUT_DATA_WIDTH(PW), .OUTPUT_DATA_WIDTH(PW), .BUFFER_DEPTH(BUF_DEPTH)) rx_cdc (
        .wr_clk(pclk), .rd_clk(rdi_clk), .rst_n(rst_n),
        .wr_valid(dp_rx_valid), .wr_ready(rxc_wr_ready),
        .wr_data({dp_rx_is_os, dp_rx_data}), .wr_error(1'b0), .wr_full(rxc_wr_full),
        .rd_valid(rxc_rd_valid), .rd_ready(rxc_rd_ready), .rd_data(rxc_rd_data), .rd_error(rxc_rd_error)
    );

    pipe7_rdi_egress #(.RDI_WIDTH(RDI_WIDTH), .CREDITS(CREDITS)) egress (
        .clk(rdi_clk), .reset_n(rst_n),
        .blk_valid(rxc_rd_valid), .blk_data(rxc_rd_data[BLOCK_PAYLOAD-1:0]),
        .blk_is_os(rxc_rd_data[BLOCK_PAYLOAD]), .blk_ready(rxc_rd_ready),
        .rdi_valid(rdi_rx_valid), .rdi_data(rdi_rx_data), .rdi_sob(rdi_rx_sob),
        .rdi_is_os(rdi_rx_is_os), .rdi_crd(rdi_rx_crd)
    );

endmodule
