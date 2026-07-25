
`timescale 1ns/1ps

/**
 * uvm_test_top -- UVM harness for the PIPE 7.1 MAC bridge env (closure-plan items 8-9).
 * Instantiates the RDI + control + PIPE-MAC interfaces, the datapath+control DUT, a PHY BFM
 * that loops TxData back to RxData (datapath round-trip), and drives PhyStatus from the UVM
 * PHY-responder agent (control-plane handshake). VCS/UVM 1.2, authored-and-review-validated.
 *
 * The FSM now drives the PIPE command signals (PowerDown/Rate/Width/...) and the PHY-responder
 * agent drives the PHY status signals, so only the truly-static straps are tied off here.
 * Default test is pipe7_full_test; override with +UVM_TESTNAME.
 */
module uvm_test_top;

    import uvm_pkg::*;
    import pipe7_pkg::*;
    import pipe7_mac_pkg::*;
    import pipe7_seq_lib::*;

    localparam int PIPE_WIDTH = 80;   // Gen5 SerDes width (single-block-per-cycle framer)

    // --- Clocks / reset ---
    logic clk, rx_clk, rst_n;
    initial begin
        clk = 1'b0;
        forever #5ns clk = ~clk;      // 100 MHz PCLK
    end
    assign rx_clk = clk;              // SerDes recovered clock modeled as PCLK for the loopback
    initial begin
        rst_n = 1'b0;
        #53ns rst_n = 1'b1;
    end

    // --- Interfaces ---
    ucie_rdi_if  #(.PAYLOAD_WIDTH(BLOCK_PAYLOAD)) rdi_tx_if (.clk(clk), .rst_n(rst_n));
    ucie_rdi_if  #(.PAYLOAD_WIDTH(BLOCK_PAYLOAD)) rdi_rx_if (.clk(clk), .rst_n(rst_n));
    pipe7_ctrl_if                                 ctrl_if   (.clk(clk), .rst_n(rst_n));
    pipe7_msgbus_if #(.ADDR_WIDTH(MB_ADDR_WIDTH), .DATA_WIDTH(MB_DATA_WIDTH))
                 mbus_if (.clk(clk), .rst_n(rst_n));
    pipe7_mac_if #(.TX_DATA_WIDTH(PIPE_WIDTH), .RX_DATA_WIDTH(PIPE_WIDTH))
                 mac_if (.pclk(clk), .rx_clk(rx_clk));

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

    // --- DUT: control FSM + Gen5 datapath ---
    pipe7_mac_dut #(.PIPE_WIDTH(PIPE_WIDTH)) dut (
        .clk(clk), .reset_n(rst_n),
        // control request (from ctrl_if / UVM control agent)
        .req_valid(ctrl_if.req_valid), .req_kind(ctrl_if.req_kind),
        .req_power_down(ctrl_if.req_power_down), .req_rate(ctrl_if.req_rate),
        .req_width(ctrl_if.req_width), .req_rxwidth(ctrl_if.req_rxwidth),
        .busy(ctrl_if.busy), .done(ctrl_if.done), .req_error(ctrl_if.req_error),
        // PIPE MAC command outputs (FSM -> interface)
        .power_down(mac_if.power_down), .rate(mac_if.rate), .width(mac_if.width),
        .rx_width(mac_if.rx_width), .tx_elec_idle(mac_if.tx_elec_idle),
        .rx_standby(mac_if.rx_standby), .pclk_change_ack(mac_if.pclk_change_ack),
        // PIPE MAC status inputs (PHY responder -> FSM)
        .phy_status(mac_if.phy_status), .pclk_change_ok(mac_if.pclk_change_ok),
        // RDI datapath
        .rdi_tx_valid(rdi_tx_if.valid), .rdi_tx_data(rdi_tx_if.data),
        .rdi_tx_is_os(rdi_tx_if.is_os), .rdi_tx_ready(rdi_tx_if.ready),
        .rdi_rx_valid(rdi_rx_if.valid), .rdi_rx_data(rdi_rx_if.data),
        .rdi_rx_is_os(rdi_rx_if.is_os),
        // PIPE MAC Tx/Rx datapath
        .tx_data(mac_if.tx_data), .tx_data_valid(mac_if.tx_data_valid),
        .rx_data(mac_if.rx_data), .rx_valid(mac_if.rx_valid),
        .block_locked(), .sync_error(),
        // Message bus (request from mbus_if; M2P/P2M on mac_if)
        .mb_req_valid(mbus_if.req_valid), .mb_req_write(mbus_if.req_write),
        .mb_req_committed(mbus_if.req_committed), .mb_req_addr(mbus_if.req_addr),
        .mb_req_wdata(mbus_if.req_wdata), .mb_req_ready(mbus_if.req_ready),
        .mb_busy(mbus_if.busy), .mb_rsp_valid(mbus_if.rsp_valid),
        .mb_rsp_is_read(mbus_if.rsp_is_read), .mb_rsp_rdata(mbus_if.rsp_rdata),
        .mb_rsp_error(mbus_if.rsp_error),
        .m2p_message_bus(mac_if.m2p_message_bus), .p2m_message_bus(mac_if.p2m_message_bus),
        .regfile_snapshot()
    );
    assign rdi_rx_if.ready = 1'b1;    // RX sink always ready (deframer has no backpressure)

    // PHY BFM (pipe7_phy_agent) drives RxData (loopback of the framed TxData) + PhyStatus;
    // pipe7_msgbus_responder drives P2M. No datapath loopback assign here anymore.

    // --- UVM config + run ---
    initial begin
        uvm_config_db#(virtual ucie_rdi_if)::set(null, "*rdi_tx_agent.drv", "rdi_tx_vif", rdi_tx_if);
        uvm_config_db#(virtual ucie_rdi_if)::set(null, "*rdi_tx_agent.mon", "vif",        rdi_tx_if);
        uvm_config_db#(virtual ucie_rdi_if)::set(null, "*rdi_rx_mon",       "vif",        rdi_rx_if);
        uvm_config_db#(virtual pipe7_mac_if)::set(null, "*mac_mon",         "mac_vif",    mac_if);
        uvm_config_db#(virtual pipe7_ctrl_if)::set(null, "*ctrl_agent.drv", "ctrl_vif",   ctrl_if);
        uvm_config_db#(virtual pipe7_mac_if)::set(null, "*ctrl_agent.drv",  "mac_vif",    mac_if);
        uvm_config_db#(virtual pipe7_mac_if)::set(null, "*phy_agent",       "mac_vif",    mac_if);
        uvm_config_db#(virtual pipe7_msgbus_if)::set(null, "*mbus_agent.drv","mbus_vif",  mbus_if);
        uvm_config_db#(virtual pipe7_mac_if)::set(null, "*mbus_resp",       "mac_vif",    mac_if);
        run_test("pipe7_full_test");
    end

endmodule
