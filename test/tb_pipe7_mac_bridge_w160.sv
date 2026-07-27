
`timescale 1ns/1ps

/**
 * tb_pipe7_mac_bridge_w160 -- integrated bridge at PIPE_WIDTH=160 (closure-plan item 29).
 * Self-clocking; `verilator --binary --timing --assert`.
 *
 * Validates the rate-aware-datapath fold at the full SerDes width (160): the Gen5 gearbox emits
 * 160-bit words (where a block straddles two words) and the RX deframer can recover up to two
 * blocks/PCLK, absorbed by the burst FIFO before the RDI<->PCLK CDC. Drives the RDI credit-flit
 * round-trip and checks every flit is recovered in order with no RX overflow. Prints
 * [BRIDGE W160] PASS / FAIL.
 */
module tb_pipe7_mac_bridge_w160;
    import pipe7_pkg::*;

    localparam int PIPE_WIDTH = 160;
    localparam int RDI_WIDTH  = 64;
    localparam int CREDITS    = 8;
    localparam int N          = 20;
    localparam int FLUSH      = 8;
    localparam int TOTAL      = N + FLUSH;
    localparam int FPB        = BLOCK_PAYLOAD / RDI_WIDTH;
    localparam int FLITS      = N * FPB;
    localparam int FLITS_ALL  = TOTAL * FPB;

    logic pclk, rdi_clk, rst_n;
    initial pclk = 1'b0;
    initial rdi_clk = 1'b0;
    always #5 pclk = ~pclk;
    always #7 rdi_clk = ~rdi_clk;

    logic [RDI_WIDTH-1:0] in_data [FLITS_ALL];
    logic                 in_sob  [FLITS_ALL];
    logic                 in_os   [FLITS_ALL];
    initial begin
        for (int k = 0; k < TOTAL; k++) begin
            logic o; o = ($random & 1);
            in_data[2*k]   = {$random, $random}; in_sob[2*k]   = 1'b1; in_os[2*k]   = o;
            in_data[2*k+1] = {$random, $random}; in_sob[2*k+1] = 1'b0; in_os[2*k+1] = o;
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
    logic                 block_locked, sync_error, in_data_phase, rx_overflow;
    logic                 busy, done, req_error, mb_req_ready, mb_busy, mb_rsp_valid, mb_rsp_is_read, mb_rsp_error;
    logic [MB_DATA_WIDTH-1:0] mb_rsp_rdata;

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
    assign rx_data = tx_data;
    pipe7_phy_responder_stub #(.LATENCY(4)) phy (
        .pclk, .reset_n(rst_n), .power_down, .rate, .width, .rx_width,
        .pclk_change_ack, .phy_status, .pclk_change_ok
    );
    pipe7_msgbus_responder_stub #(.RC_LATENCY(3), .MEM_BITS(4)) mbresp (.pclk, .reset_n(rst_n), .m2p, .p2m);

    // RX overflow must never fire in this envelope (burst FIFO + CDC absorb the recovered rate).
    always @(posedge pclk) if (rst_n && rx_overflow)
        $fatal(1, "[BRIDGE W160] FAIL  (RX overflow: recovered block dropped)");

    // Credit-tracking RDI source.
    int avail, sent;
    wire can_send = (avail > 0) && (sent < FLITS_ALL) && rst_n;
    assign rdi_tx_valid = can_send;
    assign rdi_tx_data  = in_data[sent];
    assign rdi_tx_sob   = in_sob[sent];
    assign rdi_tx_is_os = in_os[sent];
    always_ff @(posedge rdi_clk or negedge rst_n)
        if (!rst_n) begin avail <= CREDITS; sent <= 0; end
        else begin if (can_send) sent <= sent + 1; avail <= avail - (can_send ? 1 : 0) + int'(rdi_tx_crd); end

    // RDI sink: return a credit per recovered flit; check the round-trip.
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
        repeat (10) @(negedge pclk);
        if (errors == 0) begin
            $display("[BRIDGE W160] PASS  (%0d RDI blocks @ PIPE_WIDTH=160, locked=%0b)", N, block_locked);
            $finish;
        end else
            $fatal(1, "[BRIDGE W160] FAIL  (errors=%0d)", errors);
    end
    initial begin #3000000; $fatal(1, "[BRIDGE W160] FAIL  (timeout recv=%0d)", recv); end

endmodule
