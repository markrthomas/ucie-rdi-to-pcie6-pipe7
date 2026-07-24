
`timescale 1ns/1ps

/**
 * tb_pipe7_assertions -- exercises pipe7_mac_bridge_assertions (closure-plan item 7) against
 * a coherent good scenario built from the proven control + framing blocks. Self-clocking;
 * built with `verilator --binary --timing --assert`.
 *
 * Scenario (all four properties hold; a violation would $fatal from the assertion):
 *   - Idle:    TxElecIdle = 4'hF, no Tx  (P1 antecedent true, consequent holds).
 *   - Control: via pipe7_mac_ctrl_fsm + PHY responder, Rate -> Gen6 in P0 (P2), then L0p
 *              width 160->80->160; each accepted request completes via PhyStatus within the
 *              parameterized bound (P3).
 *   - Data:    TxElecIdle deasserted (0), then the Gen5 128b/130b framer streams to the
 *              deframer -- TxDataValid is high only with EI deasserted (P1), and no illegal
 *              sync header ever appears (P4).
 *   - Re-idle: stop Tx, let the framer drain, re-assert TxElecIdle (P1 again).
 *
 * The TB also counts each property's antecedent so a vacuous pass (assertion never armed) is
 * itself a failure. Prints [ASSN] PASS / FAIL and $finish.
 */
module tb_pipe7_assertions;
    import pipe7_pkg::*;

    localparam int PIPE_WIDTH = 80;
    localparam int N_BLOCKS   = 24;
    localparam int MAX_LAT    = 32;

    logic clk;
    logic reset_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    int errors;
    int comp_ok;
    // Non-vacuity counters (each assertion's antecedent must fire at least once).
    int cov_ei_idle;    // cycles with TxElecIdle == F
    int cov_tx_active;  // cycles with tx_data_valid high (EI deasserted)
    int cov_rate_chg;   // rate transitions
    int cov_busy_rose;  // accepted control requests

    // ---------------- Control: ctrl FSM + responder ----------------
    logic       req_valid;
    ctrl_req_e  req_kind;
    logic [3:0] req_power_down, req_rate;
    logic [2:0] req_width, req_rxwidth;
    logic       busy, done, req_error;
    logic [3:0] power_down, rate, tx_elec_idle_ctrl;
    logic [2:0] width, rx_width;
    logic       rx_standby, pclk_change_ack;
    logic       phy_status, pclk_change_ok;

    pipe7_mac_ctrl_fsm #(.PCLK_IS_PHY_INPUT(1'b0)) ctrl (
        .pclk(clk), .reset_n,
        .req_valid, .req_kind, .req_power_down, .req_rate, .req_width, .req_rxwidth,
        .busy, .done, .req_error,
        .power_down, .rate, .width, .rx_width,
        .tx_elec_idle(tx_elec_idle_ctrl), .rx_standby, .pclk_change_ack,
        .phy_status, .pclk_change_ok
    );

    pipe7_phy_responder_stub #(.LATENCY(4), .PCLK_IS_PHY_INPUT(1'b0)) phy (
        .pclk(clk), .reset_n,
        .power_down, .rate, .width, .rx_width, .pclk_change_ack,
        .phy_status, .pclk_change_ok
    );

    // ---------------- Data: Gen5 framer + deframer loopback ----------------
    logic                     pl_valid_i, pl_is_os_i, pl_ready_i;
    logic [BLOCK_PAYLOAD-1:0] pl_data_i;
    logic [PIPE_WIDTH-1:0]    stream;
    logic                     stream_valid;
    logic                     pl_valid_o, pl_is_os_o, blk_locked_o, sync_err_o;
    logic [BLOCK_PAYLOAD-1:0] pl_data_o;

    pipe7_tx_framer #(.PIPE_WIDTH(PIPE_WIDTH)) framer (
        .clk, .reset_n,
        .pl_valid(pl_valid_i), .pl_data(pl_data_i), .pl_is_os(pl_is_os_i), .pl_ready(pl_ready_i),
        .tx_data(stream), .tx_data_valid(stream_valid)
    );
    pipe7_rx_deframer #(.PIPE_WIDTH(PIPE_WIDTH)) deframer (
        .clk, .reset_n,
        .rx_data(stream), .rx_valid(stream_valid),
        .pl_valid(pl_valid_o), .pl_data(pl_data_o), .pl_is_os(pl_is_os_o),
        .block_locked(blk_locked_o), .sync_error(sync_err_o)
    );

    // ---------------- TxElecIdle model (idle vs data phase) ----------------
    // 4'hF while idle / during control; 0 during the data phase. This is what a real datapath
    // must drive; the assertion (P1) guards that Tx never occurs while it is F.
    logic [3:0] tx_elec_idle;

    // ---------------- Assertions under test ----------------
    pipe7_mac_bridge_assertions #(.PHYSTATUS_MAX_LATENCY(MAX_LAT)) assn_chk (
        .clk, .reset_n,
        .tx_data_valid(stream_valid),
        .tx_elec_idle(tx_elec_idle),
        .power_down(power_down),
        .rate(rate),
        .ctrl_busy(busy),
        .phy_status(phy_status),
        .sync_error(sync_err_o)
    );

    // ---------------- Helpers ----------------
    task automatic do_req(input ctrl_req_e kind,
                          input logic [3:0] pd, input logic [3:0] rt,
                          input logic [2:0] wd, input logic [2:0] rxw, input string name);
        int wcnt;
        @(negedge clk);
        req_kind = kind; req_power_down = pd; req_rate = rt;
        req_width = wd; req_rxwidth = rxw; req_valid = 1'b1;
        @(negedge clk);
        req_valid = 1'b0;
        wcnt = 0;
        while (!done && !req_error) begin
            wcnt = wcnt + 1;
            if (wcnt > 200) break;
            @(negedge clk);
        end
        if (done && !req_error) comp_ok = comp_ok + 1;
        else begin errors = errors + 1; $display("[ASSN] FAIL %s: done=%0b err=%0b", name, done, req_error); end
    endtask

    function automatic logic [BLOCK_PAYLOAD-1:0] rand128();
        logic [BLOCK_PAYLOAD-1:0] v;
        v = {$random, $random, $random, $random};
        return v;
    endfunction

    task automatic send_block(input logic [BLOCK_PAYLOAD-1:0] d, input logic o);
        @(negedge clk);
        pl_data_i = d; pl_is_os_i = o; pl_valid_i = 1'b1;
        #1;
        while (!pl_ready_i) begin @(negedge clk); #1; end
        @(posedge clk);
        @(negedge clk);
        pl_valid_i = 1'b0;
    endtask

    // ---------------- Coverage sampling ----------------
    always @(negedge clk) begin
        if (reset_n) begin
            if (tx_elec_idle == 4'hF)         cov_ei_idle   = cov_ei_idle + 1;
            if (stream_valid)                 cov_tx_active = cov_tx_active + 1;
            if (busy && !$past(busy))         cov_busy_rose = cov_busy_rose + 1;
            if (rate != $past(rate))          cov_rate_chg  = cov_rate_chg + 1;
        end
    end

    // ---------------- Stimulus ----------------
    initial begin
        errors = 0; comp_ok = 0;
        cov_ei_idle = 0; cov_tx_active = 0; cov_rate_chg = 0; cov_busy_rose = 0;
        req_valid = 1'b0; req_kind = REQ_POWER; req_power_down = PD_P0;
        req_rate = RATE_GEN5; req_width = W_160; req_rxwidth = W_160;
        pl_valid_i = 1'b0; pl_is_os_i = 1'b0; pl_data_i = '0;
        tx_elec_idle = 4'hF;   // idle

        reset_n = 1'b0;
        repeat (4) @(negedge clk);
        reset_n = 1'b1;
        repeat (4) @(negedge clk);   // idle cycles: EI=F, no Tx (P1)

        // ---- Control (P2 rate-in-P0, P3 PhyStatus bound) ----
        do_req(REQ_RATE,  PD_P0, RATE_GEN6, W_160, W_160, "rate -> Gen6");
        do_req(REQ_WIDTH, PD_P0, RATE_GEN6, W_80,  W_80,  "L0p width 160->80");
        do_req(REQ_WIDTH, PD_P0, RATE_GEN6, W_160, W_160, "L0p width 80->160");
        repeat (2) @(negedge clk);

        // ---- Data phase: deassert TxElecIdle, then stream framed blocks (P1, P4) ----
        @(negedge clk);
        tx_elec_idle = 4'h0;
        fork
            begin : producer
                for (int i = 0; i < N_BLOCKS; i++)
                    send_block(rand128(), ($random & 1));
            end
            begin : consumer
                for (int r = 0; r < N_BLOCKS; r++) begin
                    @(negedge clk);
                    while (!pl_valid_o) @(negedge clk);
                end
            end
        join
        // Let the framer drain before re-asserting electrical idle.
        repeat (20) @(negedge clk);
        @(negedge clk);
        tx_elec_idle = 4'hF;         // re-idle; framer has drained (P1 must still hold)
        repeat (4) @(negedge clk);

        // ---- Report ----
        if (comp_ok != 3) begin errors = errors + 1; $display("[ASSN] FAIL: completions=%0d expected 3", comp_ok); end
        if (cov_ei_idle   == 0) begin errors = errors + 1; $display("[ASSN] FAIL: P1 vacuous (no EI-idle cycles)"); end
        if (cov_tx_active == 0) begin errors = errors + 1; $display("[ASSN] FAIL: P1 vacuous (no Tx-active cycles)"); end
        if (cov_rate_chg  == 0) begin errors = errors + 1; $display("[ASSN] FAIL: P2 vacuous (no rate change)"); end
        if (cov_busy_rose == 0) begin errors = errors + 1; $display("[ASSN] FAIL: P3 vacuous (no accepted request)"); end
        if (!blk_locked_o)      begin errors = errors + 1; $display("[ASSN] FAIL: deframer not locked"); end

        if (errors == 0) begin
            $display("[ASSN] PASS  (control=%0d, ei_idle=%0d, tx_active=%0d, rate_chg=%0d, busy_rose=%0d)",
                     comp_ok, cov_ei_idle, cov_tx_active, cov_rate_chg, cov_busy_rose);
            $finish;
        end else begin
            $fatal(1, "[ASSN] FAIL  (errors=%0d)", errors);
        end
    end

    // Global watchdog.
    initial begin
        #500000;
        $fatal(1, "[ASSN] FAIL  (global timeout)");
    end

endmodule
