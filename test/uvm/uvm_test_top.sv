
`timescale 1ns/1ps

/**
 * uvm_test_top -- UVM harness for the PIPE 7.1 MAC bridge datapath env (closure-plan item 8).
 * Instantiates the RDI + PIPE-MAC interfaces, the datapath DUT (framer/deframer), and a PHY
 * BFM that loops TxData back to RxData so the RDI-payload round-trip closes. VCS/UVM 1.2,
 * authored-and-review-validated (not run in the OSS environment).
 *
 * Item 8 drives static Gen5 command values on the PIPE MAC interface; the control-plane
 * PHY-responder agent that answers PowerDown/Rate/Width and drives PhyStatus is item 9, and
 * the Gen6/message-bus paths are item 10.
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
    pipe7_mac_if #(.TX_DATA_WIDTH(PIPE_WIDTH), .RX_DATA_WIDTH(PIPE_WIDTH))
                 mac_if (.pclk(clk), .rx_clk(rx_clk));

    // --- Static MAC command values (Gen5 data phase). Control plane = item 9. ---
    assign mac_if.reset_n                = rst_n;
    assign mac_if.power_down             = PD_P0;
    assign mac_if.rate                   = RATE_GEN5;
    assign mac_if.width                  = W_80;
    assign mac_if.rx_width               = W_80;
    assign mac_if.tx_elec_idle           = 4'h0;      // deasserted: data phase
    assign mac_if.tx_detect_rx_loopback  = 1'b0;
    assign mac_if.serdes_arch            = 1'b1;      // SerDes architecture strap
    assign mac_if.rx_standby             = 1'b0;
    assign mac_if.sris_enable            = 1'b0;
    assign mac_if.pclk_change_ack        = 1'b0;
    assign mac_if.async_power_change_ack = 1'b0;
    assign mac_if.tx_commonmode_disable  = 1'b0;
    assign mac_if.rx_ei_detect_disable   = 1'b0;
    assign mac_if.deep_pm_req_n          = 1'b1;
    assign mac_if.restore_n              = 1'b1;

    // --- DUT: RDI payload <-> PIPE MAC datapath (framer/deframer) ---
    pipe7_mac_dut #(.PIPE_WIDTH(PIPE_WIDTH)) dut (
        .clk(clk), .reset_n(rst_n),
        .rdi_tx_valid(rdi_tx_if.valid), .rdi_tx_data(rdi_tx_if.data),
        .rdi_tx_is_os(rdi_tx_if.is_os), .rdi_tx_ready(rdi_tx_if.ready),
        .rdi_rx_valid(rdi_rx_if.valid), .rdi_rx_data(rdi_rx_if.data),
        .rdi_rx_is_os(rdi_rx_if.is_os),
        .tx_data(mac_if.tx_data), .tx_data_valid(mac_if.tx_data_valid),
        .rx_data(mac_if.rx_data), .rx_valid(mac_if.rx_valid),
        .block_locked(), .sync_error()
    );
    assign rdi_rx_if.ready = 1'b1;    // RX sink always ready (deframer has no backpressure)

    // --- PHY BFM: loopback TxData -> RxData (same clock/width) so the round-trip closes ---
    assign mac_if.rx_data           = mac_if.tx_data;
    assign mac_if.rx_valid          = mac_if.tx_data_valid;
    // PHY-driven status defaults (spec-timed responder = item 9).
    assign mac_if.phy_status        = 1'b0;
    assign mac_if.rx_status         = 3'b000;
    assign mac_if.rx_elec_idle      = 1'b0;
    assign mac_if.rx_standby_status = 1'b0;
    assign mac_if.pclk_change_ok    = 1'b0;
    assign mac_if.refclk_required_n = 1'b1;
    assign mac_if.deep_pm_ack_n     = 1'b1;
    assign mac_if.p2m_message_bus   = '0;

    // --- UVM config + run ---
    initial begin
        uvm_config_db#(virtual ucie_rdi_if)::set(null, "*rdi_tx_agent.drv", "rdi_tx_vif", rdi_tx_if);
        uvm_config_db#(virtual ucie_rdi_if)::set(null, "*rdi_tx_agent.mon", "vif",        rdi_tx_if);
        uvm_config_db#(virtual ucie_rdi_if)::set(null, "*rdi_rx_mon",       "vif",        rdi_rx_if);
        uvm_config_db#(virtual pipe7_mac_if)::set(null, "*mac_mon",         "mac_vif",    mac_if);
        run_test("pipe7_mac_sanity_test");
    end

endmodule
