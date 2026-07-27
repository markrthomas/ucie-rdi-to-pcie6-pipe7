
`timescale 1ns/1ps

/**
 * tb_pipe7_timeout -- directed completion-watchdog test (closure-plan item 28). Self-clocking;
 * `verilator --binary --timing`.
 *
 * Drives pipe7_mac_ctrl_fsm and pipe7_msgbus_master with a small TIMEOUT_CYCLES and NO responder
 * (phy_status / p2m held idle) to prove the watchdogs fire, report an error, and recover to idle
 * on a hung PHY -- then shows the normal path still completes (recovery + no false timeout):
 *   - control: a PowerDown request with phy_status stuck low -> req_error + !busy (timeout);
 *              a second request with phy_status pulsed -> done (recovery).
 *   - msgbus:  a read with p2m stuck idle -> rsp_valid + rsp_error (timeout);
 *              an uncommitted write (no P2M needed) -> rsp_valid, rsp_error=0 (normal).
 * Prints [TIMEOUT] PASS / FAIL.
 */
module tb_pipe7_timeout;
    import pipe7_pkg::*;

    localparam int TO = 8;   // small watchdog for a fast test

    logic clk, reset_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- Control FSM ----
    logic       c_req_valid; ctrl_req_e c_req_kind;
    logic [3:0] c_req_pd, c_req_rate; logic [2:0] c_req_w, c_req_rxw;
    logic       c_busy, c_done, c_req_error;
    logic [3:0] c_pd, c_rate; logic [2:0] c_w, c_rxw; logic [3:0] c_ei;
    logic       c_rx_standby, c_pclk_ack;
    logic       phy_status, pclk_change_ok;

    pipe7_mac_ctrl_fsm #(.TIMEOUT_CYCLES(TO)) ctrl (
        .pclk(clk), .reset_n,
        .req_valid(c_req_valid), .req_kind(c_req_kind), .req_power_down(c_req_pd),
        .req_rate(c_req_rate), .req_width(c_req_w), .req_rxwidth(c_req_rxw),
        .busy(c_busy), .done(c_done), .req_error(c_req_error),
        .power_down(c_pd), .rate(c_rate), .width(c_w), .rx_width(c_rxw),
        .tx_elec_idle(c_ei), .rx_standby(c_rx_standby), .pclk_change_ack(c_pclk_ack),
        .phy_status, .pclk_change_ok
    );

    // ---- Message-bus master ----
    logic       m_req_valid, m_req_write, m_req_committed;
    logic [MB_ADDR_WIDTH-1:0] m_req_addr; logic [MB_DATA_WIDTH-1:0] m_req_wdata;
    logic       m_req_ready, m_busy, m_rsp_valid, m_rsp_is_read, m_rsp_error;
    logic [MB_DATA_WIDTH-1:0] m_rsp_rdata;
    logic [MB_BUS_WIDTH-1:0]  m2p, p2m;

    pipe7_msgbus_master #(.TIMEOUT_CYCLES(TO)) mbus (
        .pclk(clk), .reset_n,
        .req_valid(m_req_valid), .req_write(m_req_write), .req_committed(m_req_committed),
        .req_addr(m_req_addr), .req_wdata(m_req_wdata), .req_ready(m_req_ready), .busy(m_busy),
        .rsp_valid(m_rsp_valid), .rsp_is_read(m_rsp_is_read), .rsp_rdata(m_rsp_rdata),
        .rsp_error(m_rsp_error), .m2p(m2p), .p2m(p2m)
    );

    int errors;

    // Wait up to `lim` cycles for `sig`; returns 1 if seen.
    task automatic wait_pulse(ref logic sig, input int lim, output bit seen);
        int w; seen = 1'b0;
        for (w = 0; w < lim; w++) begin
            @(negedge clk);
            if (sig) begin seen = 1'b1; return; end
        end
    endtask

    initial begin
        errors = 0;
        c_req_valid = 0; c_req_kind = REQ_POWER; c_req_pd = PD_P0S;
        c_req_rate = RATE_GEN5; c_req_w = W_160; c_req_rxw = W_160;
        phy_status = 0; pclk_change_ok = 0;
        m_req_valid = 0; m_req_write = 0; m_req_committed = 0; m_req_addr = '0; m_req_wdata = '0;
        p2m = 8'h00;

        reset_n = 0;
        repeat (4) @(negedge clk);
        reset_n = 1;
        repeat (2) @(negedge clk);

        // ---- Control watchdog: phy_status stuck low -> req_error + recovery to idle ----
        begin
            bit seen;
            @(negedge clk); c_req_kind = REQ_POWER; c_req_pd = PD_P0S; c_req_valid = 1;
            @(negedge clk); c_req_valid = 0;
            wait_pulse(c_req_error, TO + 6, seen);
            if (!seen)  begin errors++; $display("[TIMEOUT] FAIL: control watchdog never fired"); end
            @(negedge clk);
            if (c_busy) begin errors++; $display("[TIMEOUT] FAIL: control still busy after timeout"); end
        end

        // ---- Control recovery: a fresh request completes when the PHY responds ----
        begin
            bit seen;
            @(negedge clk); c_req_kind = REQ_POWER; c_req_pd = PD_P0; c_req_valid = 1;
            @(negedge clk); c_req_valid = 0;
            phy_status = 1;                 // PHY now responds; hold until completion
            wait_pulse(c_done, 10, seen);
            phy_status = 0;
            if (!seen) begin errors++; $display("[TIMEOUT] FAIL: control did not recover/complete"); end
        end

        // ---- Message-bus watchdog: read with p2m idle -> rsp_valid + rsp_error ----
        begin
            bit seen;
            @(negedge clk); m_req_write = 0; m_req_committed = 0; m_req_addr = 12'h401; m_req_valid = 1;
            @(negedge clk); m_req_valid = 0;
            wait_pulse(m_rsp_valid, TO + 8, seen);
            if (!seen)          begin errors++; $display("[TIMEOUT] FAIL: msgbus watchdog never completed"); end
            else if (!m_rsp_error) begin errors++; $display("[TIMEOUT] FAIL: msgbus timeout without rsp_error"); end
            @(negedge clk);
            if (m_busy) begin errors++; $display("[TIMEOUT] FAIL: msgbus still busy after timeout"); end
        end

        // ---- Message-bus normal: uncommitted write completes with no P2M and no error ----
        begin
            bit seen;
            @(negedge clk); m_req_write = 1; m_req_committed = 0; m_req_addr = 12'h402;
            m_req_wdata = 8'h5A; m_req_valid = 1;
            @(negedge clk); m_req_valid = 0;
            wait_pulse(m_rsp_valid, 12, seen);
            if (!seen)         begin errors++; $display("[TIMEOUT] FAIL: uncommitted write did not complete"); end
            else if (m_rsp_error) begin errors++; $display("[TIMEOUT] FAIL: normal write flagged rsp_error"); end
        end

        repeat (4) @(negedge clk);
        if (errors == 0) begin
            $display("[TIMEOUT] PASS  (control + msgbus watchdogs fire, report error, and recover)");
            $finish;
        end else
            $fatal(1, "[TIMEOUT] FAIL  (errors=%0d)", errors);
    end

    initial begin #500000; $fatal(1, "[TIMEOUT] FAIL  (global timeout)"); end

endmodule
