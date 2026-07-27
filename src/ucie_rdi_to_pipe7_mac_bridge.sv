
`timescale 1ns/1ps

/**
 * ucie_rdi_to_pipe7_mac_bridge -- UCIe 1.0 RDI <-> PCIe 6.x / PIPE 7.1 MAC-facing bridge
 * (integrated top, closure-plan item 20). Replaces the item-1 datapath-only pass-through with
 * the full composition of the closure-plan cores, presenting the real PIPE 7.1 MAC signal set.
 *
*   RDI TX flits --> pipe7_rdi_ingress (credit FC) --> tx CDC (rdi_clk -> pclk) --> TX adapter
 *                --> pipe7_mac_datapath_ra (Gen5 128b/130b gearbox / Gen6 raw, TxElecIdle-gated) --> TxData
 *   RxData --> pipe7_mac_datapath_ra --> pipe7_rx_burst_fifo (absorbs 0/1/2 blocks/PCLK)
 *          --> rx CDC (pclk -> rdi_clk) --> pipe7_rdi_egress (credit FC) --> RDI RX flits
 *   Control: pipe7_mac_ctrl_fsm sequences PowerDown/Rate/Width, gated on PhyStatus (with watchdog).
 *   Message bus: pipe7_msgbus_master + pipe7_regfile drive M2P / consume P2M.
 *
 * TxElecIdle is owned by the datapath (asserted except while transmitting; a data phase starts
 * only in P0), so TxDataValid is never high while TxElecIdle is asserted. The rate-aware datapath
 * (item 17) muxes the Gen5 full-width gearbox and the Gen6 raw plane by Rate; the gearbox can
 * recover up to two blocks/PCLK at width 160, absorbed by the burst FIFO before the block-payload
 * CDC (item 29). The RDI source rate must keep the recovered rate within the CDC drain (else
 * rx_overflow fires). Gen6 raw words map to a padded/truncated block payload on the RX path.
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
    output logic                     in_data_phase,
    output logic                     rx_overflow       // recovered block dropped (RX CDC full)
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

    // ---- TX adapter: the 1-block/PCLK CDC drives the gearbox's burst-accept interface ----
    wire           data_enable = txc_rd_valid;          // start a data phase when TX data is buffered
    logic [1:0]    g5_pl_acc;
    wire [1:0]     g5_pl_cnt   = txc_rd_valid ? 2'd1 : 2'd0;   // offer one block when buffered
    assign txc_rd_ready = |g5_pl_acc;                   // consume the CDC word when the framer took it

    // ---- PAM4 config (item 30): the controller programs PAM4RestrictedLevels over the message
    // bus toward the PHY; the bridge write-throughs the same committed write into a MAC-side
    // register that drives the Gen6 datapath's PAM4 config (the MAC's only PAM4 knob). ----
    logic [MB_DATA_WIDTH-1:0] pam4_levels;
    wire mb_accept = mb_req_valid && mb_req_ready;
    always_ff @(posedge pclk or negedge rst_n) begin
        if (!rst_n)
            pam4_levels <= '0;
        else if (mb_accept && mb_req_write && (mb_req_addr == REG_PHY_PAM4_RESTRICTED_LEVELS))
            pam4_levels <= mb_req_wdata;
    end

    // ---- Rate-aware datapath (item 29): Gen5 128b/130b full-width gearbox + Gen6 raw, muxed by
    // Rate, TxElecIdle owned by its data-phase FSM. Gen6 TX is not driven from the top yet. ----
    logic [1:0]               g5_rx_cnt;
    logic [BLOCK_PAYLOAD-1:0] g5_rx_data0, g5_rx_data1;
    logic                     g5_rx_os0, g5_rx_os1;
    logic                     g6_rx_valid;
    logic [PIPE_WIDTH-1:0]    g6_rx_data;
    /* verilator lint_off UNUSEDSIGNAL */
    logic                     g6_pl_ready_nc;
    logic [MB_DATA_WIDTH-1:0] pam4_cfg_nc;
    /* verilator lint_on UNUSEDSIGNAL */

    pipe7_mac_datapath_ra #(.PIPE_WIDTH(PIPE_WIDTH)) datapath (
        .clk(pclk), .reset_n(rst_n),
        .rate, .power_down, .data_enable, .pam4_restricted_levels(pam4_levels),
        .g5_pl_cnt, .g5_pl_data0(txc_rd_data[BLOCK_PAYLOAD-1:0]), .g5_pl_is_os0(txc_rd_data[BLOCK_PAYLOAD]),
        .g5_pl_data1('0), .g5_pl_is_os1(1'b0), .g5_pl_acc,
        .g6_pl_valid(1'b0), .g6_pl_data('0), .g6_pl_ready(g6_pl_ready_nc),
        .tx_data, .tx_data_valid, .tx_elec_idle,
        .rx_data, .rx_valid,
        .g5_rx_cnt, .g5_rx_data0, .g5_rx_os0, .g5_rx_data1, .g5_rx_os1,
        .g6_rx_valid, .g6_rx_data,
        .block_locked, .sync_error, .in_data_phase, .pam4_cfg_out(pam4_cfg_nc)
    );

    // ================= RX: burst FIFO -> CDC -> RDI egress =================
    // The gearbox deframer can recover up to two blocks/PCLK (a 160-bit word straddling two
    // blocks); the burst FIFO absorbs the 0/1/2-per-cycle burst and drains one/PCLK into the CDC.
    // Gen6 raw words map to a block payload (padded/truncated) so the RX path is rate-uniform.
    wire                     rx_is_gen6 = (rate == RATE_GEN6);
    logic [BLOCK_PAYLOAD-1:0] g6_rx_blk;
    generate
        if (PIPE_WIDTH >= BLOCK_PAYLOAD) begin : g_g6_trunc
            assign g6_rx_blk = g6_rx_data[BLOCK_PAYLOAD-1:0];
        end else begin : g_g6_pad
            assign g6_rx_blk = {{(BLOCK_PAYLOAD-PIPE_WIDTH){1'b0}}, g6_rx_data};
        end
    endgenerate

    wire [1:0]     rx_push_cnt = rx_is_gen6 ? {1'b0, g6_rx_valid} : g5_rx_cnt;
    wire [PW-1:0]  rx_din0     = rx_is_gen6 ? {1'b0, g6_rx_blk} : {g5_rx_os0, g5_rx_data0};
    wire [PW-1:0]  rx_din1     = {g5_rx_os1, g5_rx_data1};

    logic          rxb_valid, rxb_overflow;
    logic [PW-1:0] rxb_data;
    logic          rxc_rd_valid, rxc_rd_ready, rxc_wr_full, rxc_wr_ready;
    logic [PW-1:0] rxc_rd_data;
    /* verilator lint_off UNUSEDSIGNAL */
    logic          rxc_rd_error;
    /* verilator lint_on UNUSEDSIGNAL */

    pipe7_rx_burst_fifo #(.WIDTH(PW), .DEPTH(4)) rx_burst (
        .clk(pclk), .reset_n(rst_n),
        .push_cnt(rx_push_cnt), .din0(rx_din0), .din1(rx_din1),
        .pop_valid(rxb_valid), .pop_data(rxb_data), .pop_ready(rxc_wr_ready),
        .overflow(rxb_overflow)
    );

    pipe7_cdc_elastic_buf #(.INPUT_DATA_WIDTH(PW), .OUTPUT_DATA_WIDTH(PW), .BUFFER_DEPTH(BUF_DEPTH)) rx_cdc (
        .wr_clk(pclk), .rd_clk(rdi_clk), .rst_n(rst_n),
        .wr_valid(rxb_valid), .wr_ready(rxc_wr_ready),
        .wr_data(rxb_data), .wr_error(1'b0), .wr_full(rxc_wr_full),
        .rd_valid(rxc_rd_valid), .rd_ready(rxc_rd_ready), .rd_data(rxc_rd_data), .rd_error(rxc_rd_error)
    );
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_rxc_wr_full = rxc_wr_full;
    /* verilator lint_on UNUSEDSIGNAL */

    pipe7_rdi_egress #(.RDI_WIDTH(RDI_WIDTH), .CREDITS(CREDITS)) egress (
        .clk(rdi_clk), .reset_n(rst_n),
        .blk_valid(rxc_rd_valid), .blk_data(rxc_rd_data[BLOCK_PAYLOAD-1:0]),
        .blk_is_os(rxc_rd_data[BLOCK_PAYLOAD]), .blk_ready(rxc_rd_ready),
        .rdi_valid(rdi_rx_valid), .rdi_data(rdi_rx_data), .rdi_sob(rdi_rx_sob),
        .rdi_is_os(rdi_rx_is_os), .rdi_crd(rdi_rx_crd)
    );

    // ================= RX overflow (no PHY backpressure) =================
    // With the burst FIFO absorbing the deframer's 2-blocks/PCLK peak and the CDC draining it, a
    // recovered block is only dropped if the FIFO itself overflows -- i.e. the sustained recovered
    // rate exceeded the CDC drain (the RDI sink cannot keep up). Surface each drop as a one-pclk
    // pulse; a real controller sizes the RDI clock/width/credits so this never fires.
    always_ff @(posedge pclk or negedge rst_n) begin
        if (!rst_n) rx_overflow <= 1'b0;
        else        rx_overflow <= rxb_overflow;
    end

endmodule
