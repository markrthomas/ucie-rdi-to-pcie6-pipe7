
`timescale 1ns/1ps

/**
 * tb_pipe7_rnd_nondata_err -- RANDOMIZED non-data (control / message-bus) error test for the
 * integrated bridge (Phase H, item 48). Self-clocking; `verilator --binary --timing` (NO --assert:
 * illegal rate changes + hung-PHY timeouts deliberately violate the item-7 SVA P2/P3).
 * Waveform-viewable (`make waves|gtkwave WAVE_TB=rnd_nondata_err [SEED=N]`).
 *
 * Random control-plane / message-bus error stimulus, three fault classes (order randomized, at
 * least one of each guaranteed):
 *   - REJECT      : illegal Rate/Width change in P2 -> req_error pulse, no completion;
 *   - CTRL_WD     : legal request while the PHY is hung (phy_status held low) -> ctrl-FSM watchdog
 *                   (TIMEOUT_CYCLES=1024) fires req_error and recovers; next legal request completes;
 *   - MB_WD       : committed write while the msgbus responder is hung (p2m held idle) -> response
 *                   watchdog fires mb_rsp_valid+mb_rsp_error and recovers; next read completes.
 * All waits are bounded / fail-fast. Prints [RND NONDATA ERR] PASS / FAIL.
 */
module tb_pipe7_rnd_nondata_err;
    import pipe7_pkg::*;

    localparam int PIPE_WIDTH = 80;
    localparam int RDI_WIDTH  = 64;
    localparam int CREDITS    = 8;
    localparam int WD_BOUND   = 1400;   // > ctrl/msgbus TIMEOUT_CYCLES (1024) so the watchdog fires

    // ---- seed ----
    int unsigned seed;
    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 32'h00C0FFEE;
        void'($urandom(seed));
        $display("[RND NONDATA ERR] seed=%0d", seed);
    end

    logic pclk, rdi_clk, rst_n;
    initial pclk = 1'b0;
    initial rdi_clk = 1'b0;
    always #5 pclk = ~pclk;
    always #7 rdi_clk = ~rdi_clk;

`ifdef ENABLE_WAVES
    initial begin
        string wf;
        if ($value$plusargs("wavefile=%s", wf)) $dumpfile(wf); else $dumpfile("waves.vcd");
        $dumpvars(0, tb_pipe7_rnd_nondata_err);
    end
`endif

    // ---- DUT signals ----
    logic [RDI_WIDTH-1:0] rdi_tx_data, rdi_rx_data;
    logic                 rdi_tx_valid, rdi_tx_sob, rdi_tx_is_os, rdi_rx_valid, rdi_rx_sob, rdi_rx_is_os;
    logic [1:0]           rdi_tx_crd, rdi_rx_crd;
    logic                 req_valid; logic [1:0] req_kind;
    logic [3:0]           req_power_down, req_rate; logic [2:0] req_width, req_rxwidth;
    logic                 busy, done, req_error;
    logic                 mb_req_valid, mb_req_write, mb_req_committed;
    logic [MB_ADDR_WIDTH-1:0] mb_req_addr; logic [MB_DATA_WIDTH-1:0] mb_req_wdata;
    logic                 mb_req_ready, mb_busy, mb_rsp_valid, mb_rsp_is_read, mb_rsp_error;
    logic [MB_DATA_WIDTH-1:0] mb_rsp_rdata;
    logic [PIPE_WIDTH-1:0] tx_data, rx_data;
    logic                 tx_data_valid;
    logic [3:0]           tx_elec_idle, power_down, rate;
    logic [2:0]           width, rx_width;
    logic                 rx_standby, pclk_change_ack, phy_status, pclk_change_ok;
    logic [MB_BUS_WIDTH-1:0] m2p, p2m;
    logic                 block_locked, sync_error, in_data_phase, rx_overflow;

    // Hung-responder muxes: hold the PHY / msgbus completion low to fire the watchdogs.
    logic phy_hang, mb_hang;
    logic phy_status_s, pclk_change_ok_s;
    logic [MB_BUS_WIDTH-1:0] p2m_s;
    assign phy_status     = phy_hang ? 1'b0 : phy_status_s;
    assign pclk_change_ok = phy_hang ? 1'b0 : pclk_change_ok_s;
    assign p2m            = mb_hang  ? '0   : p2m_s;

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
        .rx_data, .rx_valid(tx_data_valid), .phy_status, .pclk_change_ok, .p2m_message_bus(p2m),
        .block_locked, .sync_error, .in_data_phase, .rx_overflow
    );
    // clean PHY data loopback (data path idle -- this test targets control/msgbus)
    assign rx_data = tx_data;
    pipe7_phy_responder_stub #(.LATENCY(4)) phy (
        .pclk, .reset_n(rst_n), .power_down, .rate, .width, .rx_width,
        .pclk_change_ack, .phy_status(phy_status_s), .pclk_change_ok(pclk_change_ok_s)
    );
    pipe7_msgbus_responder_stub #(.RC_LATENCY(3), .MEM_BITS(4)) mbresp (.pclk, .reset_n(rst_n), .m2p, .p2m(p2m_s));

    // RDI idle (no data traffic): sink returns credits, source drives nothing.
    assign rdi_tx_valid = 1'b0; assign rdi_tx_data = '0; assign rdi_tx_sob = 1'b0; assign rdi_tx_is_os = 1'b0;
    always_ff @(posedge rdi_clk or negedge rst_n)
        if (!rst_n) rdi_rx_crd <= 2'd0; else rdi_rx_crd <= {1'b0, rdi_rx_valid};

    // ---- control / msgbus drivers (bounded, capture the pulse outcome) ----
    logic saw_done, saw_err;
    task automatic drive_req(input logic [1:0] k, input logic [3:0] pd, input logic [3:0] rt,
                             input logic [2:0] wd, input int bound);
        int w;
        saw_done = 1'b0; saw_err = 1'b0;
        @(negedge pclk);
        req_kind = k; req_power_down = pd; req_rate = rt; req_width = wd; req_rxwidth = wd; req_valid = 1'b1;
        @(negedge pclk); req_valid = 1'b0;
        w = 0;
        forever begin
            if (done)      saw_done = 1'b1;
            if (req_error) saw_err  = 1'b1;
            if (saw_done || saw_err) break;
            @(negedge pclk);
            if (++w > bound) break;
        end
        repeat (2) @(negedge pclk);
    endtask

    logic saw_rsp, saw_mberr;
    task automatic drive_mb(input logic wr, input logic com, input logic [MB_ADDR_WIDTH-1:0] a,
                            input logic [MB_DATA_WIDTH-1:0] d, input int bound);
        int w;
        saw_rsp = 1'b0; saw_mberr = 1'b0;
        @(negedge pclk);
        mb_req_write = wr; mb_req_committed = com; mb_req_addr = a; mb_req_wdata = d; mb_req_valid = 1'b1;
        @(negedge pclk); mb_req_valid = 1'b0;
        w = 0;
        forever begin
            if (mb_rsp_valid) begin saw_rsp = 1'b1; saw_mberr = mb_rsp_error; end
            if (saw_rsp) break;
            @(negedge pclk);
            if (++w > bound) break;
        end
        repeat (2) @(negedge pclk);
    endtask

    // ---- Main ----
    int rejects, ctrl_wds, mb_wds, nep;
    initial begin
        req_valid = 1'b0; req_kind = REQ_POWER; req_power_down = PD_P0; req_rate = RATE_GEN5;
        req_width = W_160; req_rxwidth = W_160;
        mb_req_valid = 1'b0; mb_req_write = 1'b0; mb_req_committed = 1'b0; mb_req_addr = '0; mb_req_wdata = '0;
        phy_hang = 1'b0; mb_hang = 1'b0;
        rejects = 0; ctrl_wds = 0; mb_wds = 0;

        rst_n = 1'b0;
        repeat (6) @(negedge pclk);
        rst_n = 1'b1;
        repeat (10) @(negedge pclk);

        nep = $urandom_range(4, 7);
        for (int ep = 0; ep < nep; ep++) begin
            int cls; cls = (ep < 3) ? ep : $urandom_range(0, 2);  // guarantee all three, then random

            if (cls == 0) begin
                // ---- REJECT: illegal Rate/Width in P2 ----
                drive_req(REQ_POWER, PD_P2, RATE_GEN5, W_160, 400);       // enter P2 (legal)
                if (!saw_done) $fatal(1, "[RND NONDATA ERR] FAIL: could not enter P2");
                drive_req(($urandom & 1) ? REQ_RATE : REQ_WIDTH, PD_P2,
                          RATE_GEN6, ($urandom & 1) ? W_80 : W_40, 200);   // illegal in P2
                if (!saw_err || saw_done) $fatal(1, "[RND NONDATA ERR] FAIL: illegal req in P2 not rejected");
                rejects++;
                drive_req(REQ_POWER, PD_P0, RATE_GEN5, W_160, 400);       // back to P0
                if (!saw_done) $fatal(1, "[RND NONDATA ERR] FAIL: P2->P0 recovery failed");

            end else if (cls == 1) begin
                // ---- CTRL_WD: hung PHY -> ctrl watchdog req_error, then recover ----
                phy_hang = 1'b1;
                drive_req(REQ_RATE, PD_P0, ($urandom & 1) ? RATE_GEN6 : RATE_GEN5, W_160, WD_BOUND);
                if (!saw_err || saw_done) $fatal(1, "[RND NONDATA ERR] FAIL: ctrl watchdog did not fire on hung PHY");
                ctrl_wds++;
                phy_hang = 1'b0;
                repeat (8) @(negedge pclk);
                drive_req(REQ_RATE, PD_P0, RATE_GEN5, W_160, 400);       // recovery: completes
                if (!saw_done) $fatal(1, "[RND NONDATA ERR] FAIL: ctrl did not recover after watchdog");

            end else begin
                // ---- MB_WD: hung msgbus -> response watchdog mb_rsp_error, then recover ----
                mb_hang = 1'b1;
                drive_mb(1'b1, 1'b1, REG_PHY_TX_CTRL_BASE + ($urandom_range(0, 3)), $urandom, WD_BOUND);
                if (!saw_rsp || !saw_mberr) $fatal(1, "[RND NONDATA ERR] FAIL: mb watchdog did not fire on hung responder");
                mb_wds++;
                mb_hang = 1'b0;
                repeat (8) @(negedge pclk);
                drive_mb(1'b0, 1'b0, REG_PHY_TX_CTRL_BASE, 8'h00, 400);  // recovery: read completes
                if (!saw_rsp || saw_mberr) $fatal(1, "[RND NONDATA ERR] FAIL: mb did not recover after watchdog");
            end
        end

        if (rejects == 0 || ctrl_wds == 0 || mb_wds == 0)
            $fatal(1, "[RND NONDATA ERR] FAIL: missing a fault class (reject=%0d ctrl_wd=%0d mb_wd=%0d)",
                   rejects, ctrl_wds, mb_wds);

        $display("[RND NONDATA ERR] PASS  (seed=%0d episodes=%0d reject=%0d ctrl_wd=%0d mb_wd=%0d)",
                 seed, nep, rejects, ctrl_wds, mb_wds);
        $finish;
    end

    initial begin #8000000; $fatal(1, "[RND NONDATA ERR] FAIL  (global timeout)"); end

endmodule
