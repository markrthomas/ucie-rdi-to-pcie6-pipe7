
`timescale 1ns/1ps

/**
 * tb_pipe7_mac_bridge -- integrated bridge release smoke (closure-plan item 20). Self-clocking;
 * built with `verilator --binary --timing --assert`.
 *
 * Drives the integrated ucie_rdi_to_pipe7_mac_bridge end-to-end against a PHY loopback
 * (TxData -> RxData), a PHY-responder stub (PhyStatus) and a message-bus responder stub (P2M):
 *   - RDI round-trip: credit-gated RDI TX flits -> bridge -> RDI RX flits, checked in order.
 *   - Control: a Gen5<->Gen6 rate change completes via PhyStatus.
 *   - Message bus: a committed write then a read complete via P2M.
 * The item-7 protocol assertions are bound. Prints [BRIDGE] PASS / FAIL.
 */
module tb_pipe7_mac_bridge;
    import pipe7_pkg::*;

    localparam int PIPE_WIDTH = 80;
    localparam int RDI_WIDTH  = 64;
    localparam int CREDITS    = 8;
    localparam int N          = 16;            // RDI blocks to check
    localparam int FLUSH      = 6;             // trailing filler blocks (flush the last real block)
    localparam int TOTAL      = N + FLUSH;
    localparam int FPB        = BLOCK_PAYLOAD / RDI_WIDTH;
    localparam int FLITS      = N * FPB;       // flits to check
    localparam int FLITS_ALL  = TOTAL * FPB;   // flits to send

    logic pclk, rdi_clk, rst_n;
    initial pclk = 1'b0;
    initial rdi_clk = 1'b0;
    always #5 pclk = ~pclk;       // 100 MHz
    always #7 rdi_clk = ~rdi_clk; // ~71 MHz

`ifdef ENABLE_WAVES
    initial begin
        string wf;
        if ($value$plusargs("wavefile=%s", wf)) $dumpfile(wf); else $dumpfile("waves.vcd");
        $dumpvars(0, tb_pipe7_mac_bridge);
    end
`endif

    // ---- Golden RDI flit stream ----
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

    // ---- DUT signals ----
    logic [RDI_WIDTH-1:0] rdi_tx_data, rdi_rx_data;
    logic                 rdi_tx_valid, rdi_tx_sob, rdi_tx_is_os;
    logic [1:0]           rdi_tx_crd, rdi_rx_crd;
    logic                 rdi_rx_valid, rdi_rx_sob, rdi_rx_is_os;
    logic                 req_valid; logic [1:0] req_kind;
    logic [3:0]           req_power_down, req_rate; logic [2:0] req_width, req_rxwidth;
    logic                 busy, done, req_error;
    logic                 mb_req_valid, mb_req_write, mb_req_committed;
    logic [MB_ADDR_WIDTH-1:0] mb_req_addr; logic [MB_DATA_WIDTH-1:0] mb_req_wdata;
    logic                 mb_req_ready, mb_busy, mb_rsp_valid, mb_rsp_is_read, mb_rsp_error;
    logic [MB_DATA_WIDTH-1:0] mb_rsp_rdata;
    logic [PIPE_WIDTH-1:0] tx_data, rx_data;
    logic                 tx_data_valid, rx_valid;
    logic [3:0]           tx_elec_idle, power_down, rate;
    logic [2:0]           width, rx_width;
    logic                 rx_standby, pclk_change_ack, phy_status, pclk_change_ok;
    logic [MB_BUS_WIDTH-1:0] m2p, p2m;
    logic                 block_locked, sync_error, in_data_phase;

    ucie_rdi_to_pipe7_mac_bridge #(.PIPE_WIDTH(PIPE_WIDTH), .RDI_WIDTH(RDI_WIDTH), .CREDITS(CREDITS)) dut (
        .rst_n, .rdi_clk, .pclk,
        .rdi_tx_valid, .rdi_tx_data, .rdi_tx_sob, .rdi_tx_is_os, .rdi_tx_crd,
        .rdi_rx_valid, .rdi_rx_data, .rdi_rx_sob, .rdi_rx_is_os, .rdi_rx_crd,
        .req_valid, .req_kind, .req_power_down, .req_rate, .req_width, .req_rxwidth,
        .busy, .done, .req_error,
        .mb_req_valid, .mb_req_write, .mb_req_committed, .mb_req_addr, .mb_req_wdata,
        .mb_req_ready, .mb_busy, .mb_rsp_valid, .mb_rsp_is_read, .mb_rsp_rdata, .mb_rsp_error,
        .tx_data, .tx_data_valid, .tx_elec_idle, .power_down, .rate, .width, .rx_width,
        .rx_standby, .pclk_change_ack, .m2p_message_bus(m2p),
        .rx_data, .rx_valid, .phy_status, .pclk_change_ok, .p2m_message_bus(p2m),
        .block_locked, .sync_error, .in_data_phase
    );

    // PHY loopback + responders.
    assign rx_data  = tx_data;
    assign rx_valid = tx_data_valid;
    pipe7_phy_responder_stub #(.LATENCY(4)) phy (
        .pclk, .reset_n(rst_n), .power_down, .rate, .width, .rx_width,
        .pclk_change_ack, .phy_status, .pclk_change_ok
    );
    pipe7_msgbus_responder_stub #(.RC_LATENCY(3), .MEM_BITS(4)) mbresp (
        .pclk, .reset_n(rst_n), .m2p, .p2m
    );

    // Item-7 assertions bound.
    pipe7_mac_bridge_assertions #(.PHYSTATUS_MAX_LATENCY(64)) assn_chk (
        .clk(pclk), .reset_n(rst_n),
        .tx_data_valid, .tx_elec_idle, .power_down, .rate,
        .ctrl_busy(busy), .phy_status, .sync_error
    );

    // ---- RDI credit-tracking source ----
    int avail, sent;
    wire can_send = (avail > 0) && (sent < FLITS_ALL) && rst_n;
    assign rdi_tx_valid = can_send;
    assign rdi_tx_data  = in_data[sent];
    assign rdi_tx_sob   = in_sob[sent];
    assign rdi_tx_is_os = in_os[sent];
    always_ff @(posedge rdi_clk or negedge rst_n)
        if (!rst_n) begin avail <= CREDITS; sent <= 0; end
        else begin
            if (can_send) sent <= sent + 1;
            avail <= avail - (can_send ? 1 : 0) + int'(rdi_tx_crd);
        end

    // ---- RDI sink: return a credit per consumed flit; check the round-trip ----
    int recv, rdi_errors;
    always_ff @(posedge rdi_clk or negedge rst_n) begin
        if (!rst_n) begin rdi_rx_crd <= 2'd0; recv <= 0; rdi_errors <= 0; end
        else begin
            rdi_rx_crd <= {1'b0, rdi_rx_valid};
            if (rdi_rx_valid && recv < FLITS_ALL) begin
                if (rdi_rx_data !== in_data[recv] || rdi_rx_sob !== in_sob[recv] || rdi_rx_is_os !== in_os[recv])
                    rdi_errors <= rdi_errors + 1;
                recv <= recv + 1;
            end
        end
    end

    int errors;

    // ---- Control / message-bus helpers ----
    task automatic do_ctrl(input logic [1:0] k, input logic [3:0] pd, input logic [3:0] rt);
        int w;
        @(negedge pclk);
        req_kind = k; req_power_down = pd; req_rate = rt; req_width = W_160; req_rxwidth = W_160;
        req_valid = 1'b1;
        @(negedge pclk); req_valid = 1'b0;
        w = 0; while (!done && !req_error) begin w++; if (w > 300) break; @(negedge pclk); end
        if (!done) begin errors = errors + 1; $display("[BRIDGE] FAIL: ctrl no completion"); end
    endtask

    task automatic do_mb(input logic wr, input logic com, input logic [MB_ADDR_WIDTH-1:0] a,
                         input logic [MB_DATA_WIDTH-1:0] d);
        int w;
        @(negedge pclk);
        mb_req_write = wr; mb_req_committed = com; mb_req_addr = a; mb_req_wdata = d;
        mb_req_valid = 1'b1;
        @(negedge pclk); mb_req_valid = 1'b0;
        w = 0; while (!mb_rsp_valid) begin w++; if (w > 300) break; @(negedge pclk); end
        if (!mb_rsp_valid) begin errors = errors + 1; $display("[BRIDGE] FAIL: mb no completion"); end
    endtask

    // ---- Main stimulus ----
    initial begin
        errors = 0;
        req_valid = 1'b0; req_kind = REQ_POWER; req_power_down = PD_P0;
        req_rate = RATE_GEN5; req_width = W_160; req_rxwidth = W_160;
        mb_req_valid = 1'b0; mb_req_write = 1'b0; mb_req_committed = 1'b0;
        mb_req_addr = '0; mb_req_wdata = '0;

        rst_n = 1'b0;
        repeat (6) @(negedge pclk);
        rst_n = 1'b1;

        // RDI round-trip (data phase in P0).
        wait (recv >= FLITS);
        if (rdi_errors != 0) begin errors = errors + 1; $display("[BRIDGE] FAIL: RDI round-trip errors=%0d", rdi_errors); end

        // Message bus: committed write then read-back.
        do_mb(1'b1, 1'b1, REG_PHY_TX_CTRL_BASE + 3, 8'h9C);
        do_mb(1'b0, 1'b0, REG_PHY_TX_CTRL_BASE + 3, 8'h00);
        if (mb_rsp_rdata !== 8'h9C) begin errors = errors + 1; $display("[BRIDGE] FAIL: mb read 0x%02x != 0x9C", mb_rsp_rdata); end

        // Control: Gen5 -> Gen6 -> Gen5 rate change (idle; P0).
        do_ctrl(REQ_RATE, PD_P0, RATE_GEN6);
        if (rate !== RATE_GEN6) begin errors = errors + 1; $display("[BRIDGE] FAIL: rate != Gen6"); end
        do_ctrl(REQ_RATE, PD_P0, RATE_GEN5);

        repeat (10) @(negedge pclk);

        if (errors == 0) begin
            $display("[BRIDGE] PASS  (RDI blocks=%0d, control OK, msgbus OK, locked=%0b)", N, block_locked);
            $finish;
        end else begin
            $fatal(1, "[BRIDGE] FAIL  (errors=%0d)", errors);
        end
    end

    initial begin
        #2000000;
        $fatal(1, "[BRIDGE] FAIL  (global timeout recv=%0d)", recv);
    end

endmodule
