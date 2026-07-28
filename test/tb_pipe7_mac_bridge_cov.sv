
`timescale 1ns/1ps

/**
 * tb_pipe7_mac_bridge_cov -- directed coverage test for the integrated bridge's error paths
 * (closure-plan item 42). Self-clocking; `verilator --binary --timing`.
 *
 * The round-trip smokes loop TxData back cleanly, so the bridge's RX-error observability never
 * fires. This drives two real conditions:
 *   - misaligned RX: after block lock, inject garbage on RxData (break the loopback) -> the
 *     deframer slips and pulses sync_error (bridge + datapath + deframer_gb sync_error).
 *   - RX overflow: stall the RDI RX sink (return no credits) while TX flows -> the RX burst
 *     FIFO / CDC fill and a recovered block is dropped -> rx_overflow pulses.
 * Prints [BRIDGE COV] PASS / FAIL.
 */
module tb_pipe7_mac_bridge_cov;
    import pipe7_pkg::*;

    localparam int PIPE_WIDTH = 80;
    localparam int RDI_WIDTH  = 64;
    localparam int CREDITS    = 8;

    logic pclk, rdi_clk, rst_n;
    initial pclk = 1'b0;
    initial rdi_clk = 1'b0;
    always #5 pclk = ~pclk;
    always #7 rdi_clk = ~rdi_clk;

    // DUT signals
    logic [RDI_WIDTH-1:0] rdi_tx_data, rdi_rx_data;
    logic                 rdi_tx_valid, rdi_tx_sob, rdi_tx_is_os, rdi_rx_valid, rdi_rx_sob, rdi_rx_is_os;
    logic [1:0]           rdi_tx_crd, rdi_rx_crd;
    logic [PIPE_WIDTH-1:0] tx_data, rx_data;
    logic                 tx_data_valid;
    logic [3:0]           tx_elec_idle, power_down, rate;
    logic [2:0]           width, rx_width;
    logic                 rx_standby, pclk_change_ack, phy_status, pclk_change_ok;
    logic [MB_BUS_WIDTH-1:0] m2p, p2m;
    logic                 block_locked, sync_error, in_data_phase, rx_overflow;
    logic                 busy, done, req_error, mb_req_ready, mb_busy, mb_rsp_valid, mb_rsp_is_read, mb_rsp_error;
    logic [MB_DATA_WIDTH-1:0] mb_rsp_rdata;

    // RxData mux: normal loopback, or injected garbage.
    logic                  inject_en;
    logic [PIPE_WIDTH-1:0] inject_data;
    assign rx_data = inject_en ? inject_data : tx_data;

    ucie_rdi_to_pipe7_mac_bridge #(.PIPE_WIDTH(PIPE_WIDTH), .RDI_WIDTH(RDI_WIDTH), .CREDITS(CREDITS)) dut (
        .rst_n, .rdi_clk, .pclk,
        .rdi_tx_valid, .rdi_tx_data, .rdi_tx_sob, .rdi_tx_is_os, .rdi_tx_crd,
        .rdi_rx_valid, .rdi_rx_data, .rdi_rx_sob, .rdi_rx_is_os, .rdi_rx_crd,
        .req_valid(1'b0), .req_kind(2'd0), .req_power_down(PD_P0), .req_rate(RATE_GEN5),
        .req_width(W_160), .req_rxwidth(W_160), .busy, .done, .req_error,
        .mb_req_valid(1'b0), .mb_req_write(1'b0), .mb_req_committed(1'b0), .mb_req_addr('0),
        .mb_req_wdata('0), .mb_req_ready, .mb_busy, .mb_rsp_valid, .mb_rsp_is_read,
        .mb_rsp_rdata, .mb_rsp_error,
        .tx_data, .tx_data_valid, .tx_elec_idle, .power_down, .rate, .width, .rx_width,
        .rx_standby, .pclk_change_ack, .m2p_message_bus(m2p),
        .rx_data, .rx_valid(tx_data_valid), .phy_status, .pclk_change_ok, .p2m_message_bus(p2m),
        .block_locked, .sync_error, .in_data_phase, .rx_overflow
    );
    pipe7_phy_responder_stub #(.LATENCY(4)) phy (
        .pclk, .reset_n(rst_n), .power_down, .rate, .width, .rx_width,
        .pclk_change_ack, .phy_status, .pclk_change_ok
    );
    pipe7_msgbus_responder_stub #(.RC_LATENCY(3), .MEM_BITS(4)) mbresp (.pclk, .reset_n(rst_n), .m2p, .p2m);

    // RDI TX source: free-running credit-gated flits.
    logic [RDI_WIDTH-1:0] txdat; logic txsob;
    int avail;
    wire can_send = (avail > 0) && rst_n;
    assign rdi_tx_valid = can_send;
    assign rdi_tx_data  = txdat;
    assign rdi_tx_sob   = txsob;
    assign rdi_tx_is_os = 1'b0;
    always_ff @(posedge rdi_clk or negedge rst_n)
        if (!rst_n) begin avail <= CREDITS; txdat <= 64'h1; txsob <= 1'b1; end
        else begin
            avail <= avail - (can_send ? 1 : 0) + int'(rdi_tx_crd);
            if (can_send) begin txdat <= txdat + 1; txsob <= ~txsob; end
        end

    // RDI RX sink: normally returns a credit per flit; `sink_stall` holds credits to force overflow.
    logic sink_stall;
    always_ff @(posedge rdi_clk or negedge rst_n)
        if (!rst_n) rdi_rx_crd <= 2'd0;
        else        rdi_rx_crd <= (sink_stall) ? 2'd0 : {1'b0, rdi_rx_valid};

    // Observers.
    int sync_err_seen, ovf_seen;
    always @(posedge pclk) if (rst_n) begin
        if (sync_error) sync_err_seen <= sync_err_seen + 1;
        if (rx_overflow) ovf_seen <= ovf_seen + 1;
    end

    initial begin
        sync_err_seen = 0; ovf_seen = 0; inject_en = 0; inject_data = '0; sink_stall = 0;
        rst_n = 1'b0;
        repeat (6) @(negedge pclk);
        rst_n = 1'b1;

        // Let the clean loopback reach block lock.
        wait (block_locked);
        repeat (20) @(negedge pclk);

        // ---- Misaligned RX: inject garbage -> sync_error ----
        inject_en = 1'b1; inject_data = {PIPE_WIDTH{1'b1}};   // illegal sync candidates
        repeat (200) @(negedge pclk);
        inject_en = 1'b0;
        repeat (40) @(negedge pclk);
        if (sync_err_seen == 0) $fatal(1, "[BRIDGE COV] FAIL: sync_error never pulsed on garbage RX");

        // ---- RX overflow: stall the RDI sink while TX flows -> rx_overflow ----
        sink_stall = 1'b1;
        repeat (400) @(negedge pclk);
        sink_stall = 1'b0;
        repeat (40) @(negedge pclk);
        if (ovf_seen == 0) $fatal(1, "[BRIDGE COV] FAIL: rx_overflow never pulsed under sink stall");

        $display("[BRIDGE COV] PASS  (sync_error=%0d rx_overflow=%0d)", sync_err_seen, ovf_seen);
        $finish;
    end

    initial begin #3000000; $fatal(1, "[BRIDGE COV] FAIL  (global timeout)"); end

endmodule
