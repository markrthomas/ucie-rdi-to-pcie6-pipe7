
`timescale 1ns/1ps

/**
 * uvm_test_top -- UVM harness for the integrated PIPE 7.1 MAC bridge env (closure-plan item 22).
 * Retargeted at the real `ucie_rdi_to_pipe7_mac_bridge` via `pipe7_mac_dut`: it instantiates the
 * credit-based flit RDI interfaces (rdi_clk domain), the control + message-bus + PIPE-MAC
 * interfaces (pclk domain), a PHY BFM that loops TxData back to RxData and drives PhyStatus, and
 * a message-bus responder. Dual-clock: the bridge owns the RDI<->PCLK CDC internally.
 *
 * The Gen6-wide RX cross-check (the deferred item-10 follow-on) runs against an auxiliary
 * rate-aware datapath (`pipe7_mac_datapath_ra`) held in Gen6 data phase; the UVM gen6_rx_agent
 * injects raw wide words and the mirrored-queue scoreboard checks the recovered stream.
 *
 * VCS/UVM 1.2, authored-and-review-validated. Default test is pipe7_full_test.
 */
module uvm_test_top;

    import uvm_pkg::*;
    import pipe7_pkg::*;
    import pipe7_mac_pkg::*;
    import pipe7_seq_lib::*;

    localparam int PIPE_WIDTH = 80;    // Gen5 SerDes width (single-block-per-cycle datapath)
    localparam int RDI_WIDTH  = RDI_FLIT_WIDTH;
    localparam int CREDITS    = 8;
    localparam int G6_WIDTH   = GEN6_RX_WIDTH;

    // --- Clocks / reset ---
    logic pclk, rdi_clk, rx_clk, rst_n;
    initial begin
        pclk = 1'b0;
        forever #5ns pclk = ~pclk;      // 100 MHz PCLK
    end
    initial begin
        rdi_clk = 1'b0;
        forever #7ns rdi_clk = ~rdi_clk; // ~71 MHz RDI clock (independent domain)
    end
    assign rx_clk = pclk;               // SerDes recovered clock modeled as PCLK for the loopback
    initial begin
        rst_n = 1'b0;
        #53ns rst_n = 1'b1;
    end

    // --- Interfaces ---
    ucie_rdi_if  #(.RDI_WIDTH(RDI_WIDTH)) rdi_tx_if (.clk(rdi_clk), .rst_n(rst_n));
    ucie_rdi_if  #(.RDI_WIDTH(RDI_WIDTH)) rdi_rx_if (.clk(rdi_clk), .rst_n(rst_n));
    pipe7_ctrl_if                         ctrl_if   (.clk(pclk), .rst_n(rst_n));
    pipe7_msgbus_if #(.ADDR_WIDTH(MB_ADDR_WIDTH), .DATA_WIDTH(MB_DATA_WIDTH))
                 mbus_if (.clk(pclk), .rst_n(rst_n));
    pipe7_mac_if #(.TX_DATA_WIDTH(PIPE_WIDTH), .RX_DATA_WIDTH(PIPE_WIDTH))
                 mac_if (.pclk(pclk), .rx_clk(rx_clk));
    pipe7_gen6_rx_if #(.WIDTH(G6_WIDTH)) g6_rx_if (.clk(pclk), .rst_n(rst_n));

    // --- Static straps (not driven by the FSM or the PHY responder) ---
    assign mac_if.reset_n                = rst_n;
    assign mac_if.tx_detect_rx_loopback  = 1'b0;
    assign mac_if.serdes_arch            = 1'b1;      // SerDes architecture strap
    assign mac_if.sris_enable            = 1'b0;
    assign mac_if.async_power_change_ack = 1'b0;
    assign mac_if.tx_commonmode_disable  = 1'b0;
    assign mac_if.rx_ei_detect_disable   = 1'b0;
    assign mac_if.deep_pm_req_n          = 1'b1;
    assign mac_if.restore_n              = 1'b1;

    // --- DUT: integrated UCIe RDI <-> PIPE 7.1 MAC bridge ---
    pipe7_mac_dut #(.PIPE_WIDTH(PIPE_WIDTH), .RDI_WIDTH(RDI_WIDTH), .CREDITS(CREDITS)) dut (
        .pclk(pclk), .rdi_clk(rdi_clk), .reset_n(rst_n),
        // control request (from ctrl_if / UVM control agent)
        .req_valid(ctrl_if.req_valid), .req_kind(ctrl_if.req_kind),
        .req_power_down(ctrl_if.req_power_down), .req_rate(ctrl_if.req_rate),
        .req_width(ctrl_if.req_width), .req_rxwidth(ctrl_if.req_rxwidth),
        .busy(ctrl_if.busy), .done(ctrl_if.done), .req_error(ctrl_if.req_error),
        // PIPE MAC command outputs (bridge -> interface)
        .power_down(mac_if.power_down), .rate(mac_if.rate), .width(mac_if.width),
        .rx_width(mac_if.rx_width), .tx_elec_idle(mac_if.tx_elec_idle),
        .rx_standby(mac_if.rx_standby), .pclk_change_ack(mac_if.pclk_change_ack),
        // PIPE MAC status inputs (PHY responder -> bridge)
        .phy_status(mac_if.phy_status), .pclk_change_ok(mac_if.pclk_change_ok),
        // UCIe RDI TX flit source
        .rdi_tx_valid(rdi_tx_if.valid), .rdi_tx_data(rdi_tx_if.data),
        .rdi_tx_sob(rdi_tx_if.sob), .rdi_tx_is_os(rdi_tx_if.is_os), .rdi_tx_crd(rdi_tx_if.crd),
        // UCIe RDI RX flit sink
        .rdi_rx_valid(rdi_rx_if.valid), .rdi_rx_data(rdi_rx_if.data),
        .rdi_rx_sob(rdi_rx_if.sob), .rdi_rx_is_os(rdi_rx_if.is_os), .rdi_rx_crd(rdi_rx_if.crd),
        // PIPE MAC Tx/Rx datapath
        .tx_data(mac_if.tx_data), .tx_data_valid(mac_if.tx_data_valid),
        .rx_data(mac_if.rx_data), .rx_valid(mac_if.rx_valid),
        .block_locked(), .sync_error(), .in_data_phase(), .rx_overflow(),
        // Message bus (request from mbus_if; M2P/P2M on mac_if)
        .mb_req_valid(mbus_if.req_valid), .mb_req_write(mbus_if.req_write),
        .mb_req_committed(mbus_if.req_committed), .mb_req_addr(mbus_if.req_addr),
        .mb_req_wdata(mbus_if.req_wdata), .mb_req_ready(mbus_if.req_ready),
        .mb_busy(mbus_if.busy), .mb_rsp_valid(mbus_if.rsp_valid),
        .mb_rsp_is_read(mbus_if.rsp_is_read), .mb_rsp_rdata(mbus_if.rsp_rdata),
        .mb_rsp_error(mbus_if.rsp_error),
        .m2p_message_bus(mac_if.m2p_message_bus), .p2m_message_bus(mac_if.p2m_message_bus)
    );

    // --- Aux Gen6-wide RX datapath: held in Gen6 data phase; env injects raw RX words ---
    logic [G6_WIDTH-1:0] g6_recov_data;
    logic                g6_recov_valid;
    pipe7_mac_datapath_ra #(.PIPE_WIDTH(G6_WIDTH)) g6_aux (
        .clk(pclk), .reset_n(rst_n),
        .rate(RATE_GEN6), .power_down(PD_P0), .data_enable(1'b1),
        .pam4_restricted_levels('0),
        // Gen5 block inputs unused in Gen6 mode
        .g5_pl_cnt(2'd0), .g5_pl_data0('0), .g5_pl_is_os0(1'b0),
        .g5_pl_data1('0), .g5_pl_is_os1(1'b0), .g5_pl_acc(),
        // Gen6 TX payload off (RX-only cross-check)
        .g6_pl_valid(1'b0), .g6_pl_data('0), .g6_pl_ready(),
        // TX outputs unobserved
        .tx_data(), .tx_data_valid(), .tx_elec_idle(),
        // Injected RX word
        .rx_data(g6_rx_if.rx_data), .rx_valid(g6_rx_if.rx_valid),
        // Gen5 recovered outputs unused
        .g5_rx_cnt(), .g5_rx_data0(), .g5_rx_os0(), .g5_rx_data1(), .g5_rx_os1(),
        // Gen6 recovered word -> interface
        .g6_rx_valid(g6_recov_valid), .g6_rx_data(g6_recov_data),
        .block_locked(), .sync_error(), .in_data_phase(), .pam4_cfg_out()
    );
    assign g6_rx_if.g6_rx_data  = g6_recov_data;
    assign g6_rx_if.g6_rx_valid = g6_recov_valid;

    // PHY BFM (pipe7_phy_agent) drives RxData (loopback of the framed TxData) + PhyStatus;
    // pipe7_msgbus_responder drives P2M.

    // --- UVM config + run ---
    initial begin
        uvm_config_db#(virtual ucie_rdi_if)::set(null, "*rdi_tx_agent.drv",  "rdi_tx_vif", rdi_tx_if);
        uvm_config_db#(int unsigned)::set(null,        "*rdi_tx_agent.drv",  "credits",    CREDITS);
        uvm_config_db#(virtual ucie_rdi_if)::set(null, "*rdi_tx_agent.mon",  "vif",        rdi_tx_if);
        uvm_config_db#(virtual ucie_rdi_if)::set(null, "*rdi_rx_mon",        "vif",        rdi_rx_if);
        uvm_config_db#(virtual ucie_rdi_if)::set(null, "*rdi_rx_sink_c",     "vif",        rdi_rx_if);
        uvm_config_db#(virtual pipe7_mac_if)::set(null, "*mac_mon",          "mac_vif",    mac_if);
        uvm_config_db#(virtual pipe7_ctrl_if)::set(null, "*ctrl_agent.drv",  "ctrl_vif",   ctrl_if);
        uvm_config_db#(virtual pipe7_mac_if)::set(null, "*ctrl_agent.drv",   "mac_vif",    mac_if);
        uvm_config_db#(virtual pipe7_mac_if)::set(null, "*phy_agent",        "mac_vif",    mac_if);
        uvm_config_db#(virtual pipe7_msgbus_if)::set(null, "*mbus_agent.drv", "mbus_vif",  mbus_if);
        uvm_config_db#(virtual pipe7_mac_if)::set(null, "*mbus_resp",        "mac_vif",    mac_if);
        uvm_config_db#(virtual pipe7_gen6_rx_if)::set(null, "*g6_rx_agent*", "g6_vif",     g6_rx_if);
        run_test("pipe7_full_test");
    end

endmodule
