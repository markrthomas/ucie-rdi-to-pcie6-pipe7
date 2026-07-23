
`timescale 1ns/1ps

/**
 * tb_pipe7_ctrl_fsm -- self-checking control-plane smoke for pipe7_mac_ctrl_fsm
 * (closure-plan item 3). Self-clocking; built with `verilator --binary --timing`.
 *
 * Exercises, in PCLK-as-PHY-output mode: the P0<->P0s<->P1<->P2 power ladder, Gen5<->Gen6
 * rate changes and a Width change (both legal in P0), and rejection of illegal Rate changes
 * (requested in P2 and in P0s). A second FSM+responder pair validates the PCLK-as-PHY-input
 * handshake (PclkChangeOk -> PclkChangeAck -> PhyStatus) on one rate change.
 *
 * Pass criterion: every legal request completes via PhyStatus, every illegal request is
 * rejected via req_error, command outputs land on the requested values, and illegal
 * requests leave the outputs unchanged.  Prints [CTRL FSM] PASS / FAIL and $finish.
 */
module tb_pipe7_ctrl_fsm;
    import pipe7_pkg::*;

    // Clock: initialized in its own initial (no declaration initializer, so no
    // PROCASSINIT -- keeps the build portable across Verilator versions in CI).
    logic pclk;
    logic reset_n;
    initial pclk = 1'b0;
    always #5 pclk = ~pclk;

    int errors;
    int comp_ok;   // legal requests that completed (done)
    int err_ok;    // illegal requests that were rejected (req_error)

    // ---------------- Output-mode DUT (primary) ----------------
    logic       req_valid;
    ctrl_req_e  req_kind;
    logic [3:0] req_power_down;
    logic [3:0] req_rate;
    logic [2:0] req_width;
    logic [2:0] req_rxwidth;
    logic       busy, done, req_error;
    logic [3:0] power_down, rate, tx_elec_idle;
    logic [2:0] width, rx_width;
    logic       rx_standby, pclk_change_ack;
    logic       phy_status, pclk_change_ok;

    pipe7_mac_ctrl_fsm #(.PCLK_IS_PHY_INPUT(1'b0)) dut (
        .pclk, .reset_n,
        .req_valid, .req_kind, .req_power_down, .req_rate, .req_width, .req_rxwidth,
        .busy, .done, .req_error,
        .power_down, .rate, .width, .rx_width, .tx_elec_idle, .rx_standby, .pclk_change_ack,
        .phy_status, .pclk_change_ok
    );

    pipe7_phy_responder_stub #(.LATENCY(4), .PCLK_IS_PHY_INPUT(1'b0)) phy (
        .pclk, .reset_n,
        .power_down, .rate, .width, .rx_width, .pclk_change_ack,
        .phy_status, .pclk_change_ok
    );

    // ---------------- Input-mode DUT (secondary, PCLK-as-PHY-input) ----------------
    logic       i_req_valid;
    ctrl_req_e  i_req_kind;
    logic [3:0] i_req_power_down;
    logic [3:0] i_req_rate;
    logic [2:0] i_req_width;
    logic [2:0] i_req_rxwidth;
    logic       i_busy, i_done, i_req_error;
    logic [3:0] i_power_down, i_rate, i_tx_elec_idle;
    logic [2:0] i_width, i_rx_width;
    logic       i_rx_standby, i_pclk_change_ack;
    logic       i_phy_status, i_pclk_change_ok;

    pipe7_mac_ctrl_fsm #(.PCLK_IS_PHY_INPUT(1'b1)) dut_i (
        .pclk, .reset_n,
        .req_valid(i_req_valid), .req_kind(i_req_kind), .req_power_down(i_req_power_down),
        .req_rate(i_req_rate), .req_width(i_req_width), .req_rxwidth(i_req_rxwidth),
        .busy(i_busy), .done(i_done), .req_error(i_req_error),
        .power_down(i_power_down), .rate(i_rate), .width(i_width), .rx_width(i_rx_width),
        .tx_elec_idle(i_tx_elec_idle), .rx_standby(i_rx_standby),
        .pclk_change_ack(i_pclk_change_ack),
        .phy_status(i_phy_status), .pclk_change_ok(i_pclk_change_ok)
    );

    pipe7_phy_responder_stub #(.LATENCY(4), .PCLK_IS_PHY_INPUT(1'b1)) phy_i (
        .pclk, .reset_n,
        .power_down(i_power_down), .rate(i_rate), .width(i_width), .rx_width(i_rx_width),
        .pclk_change_ack(i_pclk_change_ack),
        .phy_status(i_phy_status), .pclk_change_ok(i_pclk_change_ok)
    );

    // ---------------- Helpers ----------------
    function automatic void check_eq(input logic [3:0] got, input logic [3:0] exp,
                                     input string what);
        if (got !== exp) begin
            errors = errors + 1;
            $display("[CTRL FSM] FAIL %s: got %0d expected %0d", what, got, exp);
        end
    endfunction

    // Drive one request on the output-mode DUT and wait for done/req_error. Stimulus is
    // blocking on negedge (race-free vs the DUT's posedge sampling); the request is held
    // for exactly one posedge, and the req_error/done pulse is first sampled at the negedge
    // after acceptance.
    task automatic do_req(input ctrl_req_e kind,
                          input logic [3:0] pd, input logic [3:0] rt,
                          input logic [2:0] wd, input logic [2:0] rxw,
                          input bit exp_err, input string name);
        int wcnt;
        @(negedge pclk);
        req_kind       = kind;
        req_power_down = pd;
        req_rate       = rt;
        req_width      = wd;
        req_rxwidth    = rxw;
        req_valid      = 1'b1;
        @(negedge pclk);
        req_valid = 1'b0;
        wcnt = 0;
        while (!done && !req_error) begin
            wcnt = wcnt + 1;                 // split out of the if-condition; older tools
            if (wcnt > 200) break;           // hit an internal error on ++ inside an if
            @(negedge pclk);
        end
        if (exp_err) begin
            if (req_error && !done) err_ok = err_ok + 1;
            else begin errors = errors + 1; $display("[CTRL FSM] FAIL %s: expected reject, done=%0b err=%0b",
                                           name, done, req_error); end
        end else begin
            if (done && !req_error) comp_ok = comp_ok + 1;
            else begin errors = errors + 1; $display("[CTRL FSM] FAIL %s: no completion, done=%0b err=%0b",
                                          name, done, req_error); end
        end
    endtask

    // ---------------- Stimulus ----------------
    initial begin
        // Initial values set here (not at declaration) to avoid PROCASSINIT.
        errors = 0; comp_ok = 0; err_ok = 0;
        req_valid = 1'b0; req_kind = REQ_POWER; req_power_down = PD_P0;
        req_rate = RATE_GEN5; req_width = W_160; req_rxwidth = W_160;
        i_req_valid = 1'b0; i_req_kind = REQ_RATE; i_req_power_down = PD_P0;
        i_req_rate = RATE_GEN5; i_req_width = W_160; i_req_rxwidth = W_160;

        reset_n = 1'b0;
        repeat (4) @(negedge pclk);
        reset_n = 1'b1;
        repeat (2) @(negedge pclk);

        // Power ladder P0 -> P0s -> P1 -> P2 -> P0
        do_req(REQ_POWER, PD_P0S, RATE_GEN5, W_160, W_160, 1'b0, "P0->P0s");
        check_eq(power_down, PD_P0S, "power=P0s");
        do_req(REQ_POWER, PD_P1,  RATE_GEN5, W_160, W_160, 1'b0, "P0s->P1");
        check_eq(power_down, PD_P1, "power=P1");
        do_req(REQ_POWER, PD_P2,  RATE_GEN5, W_160, W_160, 1'b0, "P1->P2");
        check_eq(power_down, PD_P2, "power=P2");
        do_req(REQ_POWER, PD_P0,  RATE_GEN5, W_160, W_160, 1'b0, "P2->P0");
        check_eq(power_down, PD_P0, "power=P0");

        // Rate changes (legal in P0): Gen5 -> Gen6 -> Gen5
        do_req(REQ_RATE, PD_P0, RATE_GEN6, W_160, W_160, 1'b0, "rate Gen5->Gen6");
        check_eq(rate, RATE_GEN6, "rate=Gen6");
        do_req(REQ_RATE, PD_P0, RATE_GEN5, W_160, W_160, 1'b0, "rate Gen6->Gen5");
        check_eq(rate, RATE_GEN5, "rate=Gen5");

        // Width change (legal in P0): 160 -> 80
        do_req(REQ_WIDTH, PD_P0, RATE_GEN5, W_80, W_80, 1'b0, "width 160->80");
        check_eq({1'b0, width},    {1'b0, W_80}, "width=80");
        check_eq({1'b0, rx_width}, {1'b0, W_80}, "rxwidth=80");

        // Illegal Rate change in P2 -> reject, rate unchanged
        do_req(REQ_POWER, PD_P2, RATE_GEN5, W_80, W_80, 1'b0, "P0->P2");
        do_req(REQ_RATE,  PD_P2, RATE_GEN6, W_80, W_80, 1'b1, "rate-in-P2 (illegal)");
        check_eq(rate, RATE_GEN5, "rate unchanged after illegal P2");
        do_req(REQ_POWER, PD_P0, RATE_GEN5, W_80, W_80, 1'b0, "P2->P0");

        // Illegal Rate change in P0s -> reject
        do_req(REQ_POWER, PD_P0S, RATE_GEN5, W_80, W_80, 1'b0, "P0->P0s");
        do_req(REQ_RATE,  PD_P0S, RATE_GEN6, W_80, W_80, 1'b1, "rate-in-P0s (illegal)");
        check_eq(rate, RATE_GEN5, "rate unchanged after illegal P0s");
        do_req(REQ_POWER, PD_P0,  RATE_GEN5, W_80, W_80, 1'b0, "P0s->P0");

        // ---- PCLK-as-PHY-input handshake: one rate change on dut_i ----
        begin
            int wcnt2;
            @(negedge pclk);
            i_req_kind = REQ_RATE; i_req_power_down = PD_P0; i_req_rate = RATE_GEN6;
            i_req_width = W_160; i_req_rxwidth = W_160; i_req_valid = 1'b1;
            @(negedge pclk); i_req_valid = 1'b0;
            wcnt2 = 0;
            while (!i_done && !i_req_error) begin
                wcnt2 = wcnt2 + 1;
                if (wcnt2 > 200) break;
                @(negedge pclk);
            end
            if (i_done && !i_req_error) comp_ok = comp_ok + 1;
            else begin errors = errors + 1; $display("[CTRL FSM] FAIL input-mode rate: done=%0b err=%0b",
                                          i_done, i_req_error); end
            check_eq(i_rate, RATE_GEN6, "input-mode rate=Gen6");
        end

        // ---- Report ----
        // Expected: 11 output-mode completions + 1 input-mode completion, 2 rejections.
        if (comp_ok != 12) begin
            errors = errors + 1;
            $display("[CTRL FSM] FAIL: completions=%0d expected 12", comp_ok);
        end
        if (err_ok != 2) begin
            errors = errors + 1;
            $display("[CTRL FSM] FAIL: rejections=%0d expected 2", err_ok);
        end

        if (errors == 0) begin
            $display("[CTRL FSM] PASS  (completions=%0d rejections=%0d)", comp_ok, err_ok);
            $finish;
        end else begin
            $fatal(1, "[CTRL FSM] FAIL  (errors=%0d)", errors);
        end
    end

    // Global watchdog so a hang fails loudly (non-zero exit) instead of running forever.
    initial begin
        #200000;
        $fatal(1, "[CTRL FSM] FAIL  (global timeout)");
    end

endmodule
