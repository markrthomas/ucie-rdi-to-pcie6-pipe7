
`timescale 1ns/1ps

/**
 * tb_pipe7_mac_bridge_nl1 -- reduced-config parameter smoke for the integrated bridge
 * (closure-plan item 20/21). Self-clocking; `verilator --binary --timing`.
 *
 * Exercises ucie_rdi_to_pipe7_mac_bridge at a smaller configuration (CREDITS=4, shallow CDC) on
 * the RDI round-trip only, so the parameterization and credit accounting are checked at a
 * different operating point than the main smoke. Prints [BRIDGE MIN] PASS / FAIL.
 */
module tb_pipe7_mac_bridge_nl1;
    import pipe7_pkg::*;

    localparam int PIPE_WIDTH = 80;
    localparam int RDI_WIDTH  = 64;
    localparam int CREDITS    = 4;
    localparam int BUF_DEPTH  = 8;
    localparam int N          = 10;
    localparam int FLUSH      = 6;
    localparam int TOTAL      = N + FLUSH;
    localparam int FPB        = BLOCK_PAYLOAD / RDI_WIDTH;
    localparam int FLITS      = N * FPB;
    localparam int FLITS_ALL  = TOTAL * FPB;

    logic pclk, rdi_clk, rst_n;
    initial pclk = 1'b0;
    initial rdi_clk = 1'b0;
    always #5  pclk = ~pclk;
    always #11 rdi_clk = ~rdi_clk;   // slower RDI clock

    logic [RDI_WIDTH-1:0] in_data [FLITS_ALL];
    logic                 in_sob  [FLITS_ALL];
    logic                 in_os   [FLITS_ALL];
    initial begin
        for (int k = 0; k < TOTAL; k++) begin
            logic o; o = ($random & 1);
            in_data[2*k]   = $random; in_sob[2*k]   = 1'b1; in_os[2*k]   = o;
            in_data[2*k+1] = $random; in_sob[2*k+1] = 1'b0; in_os[2*k+1] = o;
        end
    end

    logic [RDI_WIDTH-1:0] rdi_tx_data, rdi_rx_data;
    logic                 rdi_tx_valid, rdi_tx_sob, rdi_tx_is_os, rdi_rx_valid, rdi_rx_sob, rdi_rx_is_os;
    logic [1:0]           rdi_tx_crd, rdi_rx_crd;
    logic [PIPE_WIDTH-1:0] tx_data, rx_data;
    logic                 tx_data_valid;
    logic [3:0]           tx_elec_idle, power_down, rate;
    logic [2:0]           width, rx_width;
    logic                 rx_standby, pclk_change_ack, phy_status, pclk_change_ok;
    logic [MB_BUS_WIDTH-1:0] m2p, p2m;
    logic                 block_locked, sync_error, in_data_phase;
    logic                 busy, done, req_error, mb_req_ready, mb_busy, mb_rsp_valid, mb_rsp_is_read, mb_rsp_error;
    logic [MB_DATA_WIDTH-1:0] mb_rsp_rdata;

    ucie_rdi_to_pipe7_mac_bridge #(.PIPE_WIDTH(PIPE_WIDTH), .RDI_WIDTH(RDI_WIDTH),
                                   .CREDITS(CREDITS), .BUF_DEPTH(BUF_DEPTH)) dut (
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
        .block_locked, .sync_error, .in_data_phase
    );
    assign rx_data = tx_data;
    pipe7_phy_responder_stub #(.LATENCY(4)) phy (
        .pclk, .reset_n(rst_n), .power_down, .rate, .width, .rx_width,
        .pclk_change_ack, .phy_status, .pclk_change_ok
    );
    pipe7_msgbus_responder_stub #(.RC_LATENCY(3), .MEM_BITS(4)) mbresp (.pclk, .reset_n(rst_n), .m2p, .p2m);

    // Throttle TX so the PIPE-side RX rate stays within the (slower-rdi_clk, 2-flit egress) RDI
    // sink bandwidth -- the RX elastic buffer cannot backpressure the PHY, so the operating
    // point must keep PIPE-RX <= RDI-sink. A real controller sizes the RDI clock/width for this.
    int thr;
    always_ff @(posedge rdi_clk or negedge rst_n) if (!rst_n) thr <= 0; else thr <= thr + 1;
    int avail, sent;
    wire can_send = (avail > 0) && (sent < FLITS_ALL) && rst_n && (thr[1:0] == 2'd0);
    assign rdi_tx_valid = can_send;
    assign rdi_tx_data  = in_data[sent];
    assign rdi_tx_sob   = in_sob[sent];
    assign rdi_tx_is_os = in_os[sent];
    always_ff @(posedge rdi_clk or negedge rst_n)
        if (!rst_n) begin avail <= CREDITS; sent <= 0; end
        else begin if (can_send) sent <= sent + 1; avail <= avail - (can_send ? 1 : 0) + int'(rdi_tx_crd); end

    int recv, errors;
    always_ff @(posedge rdi_clk or negedge rst_n) begin
        if (!rst_n) begin rdi_rx_crd <= 2'd0; recv <= 0; errors <= 0; end
        else begin
            rdi_rx_crd <= {1'b0, rdi_rx_valid};
            if (rdi_rx_valid && recv < FLITS_ALL) begin
                if (rdi_rx_data !== in_data[recv] || rdi_rx_sob !== in_sob[recv] || rdi_rx_is_os !== in_os[recv])
                    errors <= errors + 1;
                recv <= recv + 1;
            end
        end
    end

    initial begin
        rst_n = 1'b0;
        repeat (6) @(negedge pclk);
        rst_n = 1'b1;
        wait (recv >= FLITS);
        repeat (6) @(negedge pclk);
        if (errors == 0) begin
            $display("[BRIDGE MIN] PASS  (%0d RDI blocks, CREDITS=%0d, locked=%0b)", N, CREDITS, block_locked);
            $finish;
        end else
            $fatal(1, "[BRIDGE MIN] FAIL  (errors=%0d)", errors);
    end
    initial begin #2000000; $fatal(1, "[BRIDGE MIN] FAIL  (timeout recv=%0d)", recv); end

endmodule
