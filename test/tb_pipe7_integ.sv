
`timescale 1ns/1ps

/**
 * tb_pipe7_integ -- integration smoke (closure-plan follow-on, item 15). Composes the control
 * FSM + PHY responder + the TxElecIdle-gated datapath (pipe7_mac_datapath) and binds the item-7
 * protocol assertions, proving the integrated behavior is clean where the standalone pieces left
 * a gap: TxElecIdle is now deasserted during a data phase (so P1 -- no Tx while TxElecIdle -- is
 * satisfied with real gating, not by holding the framer off). Self-clocking; --binary --timing.
 *
 * Scenario:
 *   1. Data phase in P0: assert data_enable, stream random payloads, check the RDI round-trip
 *      (TxElecIdle=0 while transmitting).
 *   2. Idle: drop data_enable; the datapath drains and re-asserts TxElecIdle (=4'hF).
 *   3. Control: a Gen5->Gen6 rate change in P0 (exercises assertion P2/P3) while idle.
 *   4. Negative: in P2, assert data_enable -- NO data phase may start (data only in P0); verify
 *      in_data_phase and TxDataValid stay low, then return to P0.
 *
 * Pass: every payload round-trips, no assertion fires, the P2 negative holds, and P1 is
 * non-vacuous (both TxElecIdle-idle and Tx-active cycles occur). Prints [INTEG] PASS / FAIL.
 */
module tb_pipe7_integ;
    import pipe7_pkg::*;

    localparam int PIPE_WIDTH = 80;
    localparam int N_BLOCKS   = 24;

    logic clk;
    logic reset_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

`ifdef ENABLE_WAVES
    initial begin
        string wf;
        if ($value$plusargs("wavefile=%s", wf)) $dumpfile(wf);
        else                                     $dumpfile("waves.vcd");
        $dumpvars(0, tb_pipe7_integ);
    end
`endif

    int errors;
    int recv;
    int cov_ei_idle;    // cycles with TxElecIdle == F
    int cov_tx_active;  // cycles with tx_data_valid high
    bit checking_p2;    // during the P2 negative window

    // ---- Control: FSM + PHY responder ----
    logic       req_valid;
    ctrl_req_e  req_kind;
    logic [3:0] req_power_down, req_rate;
    logic [2:0] req_width, req_rxwidth;
    logic       busy, done, req_error;
    logic [3:0] power_down, rate, fsm_tx_elec_idle;
    logic [2:0] width, rx_width;
    logic       rx_standby, pclk_change_ack;
    logic       phy_status, pclk_change_ok;

    pipe7_mac_ctrl_fsm #(.PCLK_IS_PHY_INPUT(1'b0)) ctrl (
        .pclk(clk), .reset_n,
        .req_valid, .req_kind, .req_power_down, .req_rate, .req_width, .req_rxwidth,
        .busy, .done, .req_error,
        .power_down, .rate, .width, .rx_width,
        .tx_elec_idle(fsm_tx_elec_idle), .rx_standby, .pclk_change_ack,
        .phy_status, .pclk_change_ok
    );

    pipe7_phy_responder_stub #(.LATENCY(4), .PCLK_IS_PHY_INPUT(1'b0)) phy (
        .pclk(clk), .reset_n,
        .power_down, .rate, .width, .rx_width, .pclk_change_ack,
        .phy_status, .pclk_change_ok
    );

    // ---- Datapath (TxElecIdle-gated) + PHY loopback ----
    logic                     data_enable;
    logic                     pl_valid_i, pl_is_os_i, pl_ready_i;
    logic [BLOCK_PAYLOAD-1:0] pl_data_i;
    logic                     rx_pl_valid_o, rx_pl_is_os_o;
    logic [BLOCK_PAYLOAD-1:0] rx_pl_data_o;
    logic [PIPE_WIDTH-1:0]    dp_tx_data, dp_rx_data;
    logic                     dp_tx_valid, dp_rx_valid;
    logic [3:0]               dp_tx_elec_idle;
    logic                     blk_locked, sync_err, in_data_phase;

    pipe7_mac_datapath #(.PIPE_WIDTH(PIPE_WIDTH)) dp (
        .clk, .reset_n,
        .power_down, .data_enable,
        .pl_valid(pl_valid_i), .pl_data(pl_data_i), .pl_is_os(pl_is_os_i), .pl_ready(pl_ready_i),
        .rx_pl_valid(rx_pl_valid_o), .rx_pl_data(rx_pl_data_o), .rx_pl_is_os(rx_pl_is_os_o),
        .tx_data(dp_tx_data), .tx_data_valid(dp_tx_valid), .tx_elec_idle(dp_tx_elec_idle),
        .rx_data(dp_rx_data), .rx_valid(dp_rx_valid),
        .block_locked(blk_locked), .sync_error(sync_err), .in_data_phase(in_data_phase)
    );

    // PHY loopback: framed TxData -> RxData.
    assign dp_rx_data  = dp_tx_data;
    assign dp_rx_valid = dp_tx_valid;

    // ---- Item-7 protocol assertions bound to the integrated signals ----
    pipe7_mac_bridge_assertions #(.PHYSTATUS_MAX_LATENCY(32)) assn_chk (
        .clk, .reset_n,
        .tx_data_valid(dp_tx_valid),
        .tx_elec_idle(dp_tx_elec_idle),
        .power_down(power_down),
        .rate(rate),
        .ctrl_busy(busy),
        .phy_status(phy_status),
        .sync_error(sync_err)
    );

    // ---- Helpers ----
    task automatic do_req(input ctrl_req_e kind, input logic [3:0] pd, input logic [3:0] rt,
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
        if (!done && !req_error) begin errors = errors + 1; $display("[INTEG] FAIL %s: no completion", name); end
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

    logic [BLOCK_PAYLOAD-1:0] exp_q [$];

    // ---- Coverage / negative-window monitor ----
    always @(negedge clk) begin
        if (reset_n) begin
            if (dp_tx_elec_idle == 4'hF) cov_ei_idle   = cov_ei_idle + 1;
            if (dp_tx_valid)             cov_tx_active = cov_tx_active + 1;
            if (checking_p2 && (in_data_phase || dp_tx_valid)) begin
                errors = errors + 1;
                $display("[INTEG] FAIL: data phase / Tx active in P2 (data only allowed in P0)");
            end
        end
    end

    // ---- Stimulus ----
    initial begin
        errors = 0; recv = 0; cov_ei_idle = 0; cov_tx_active = 0; checking_p2 = 1'b0;
        req_valid = 1'b0; req_kind = REQ_POWER; req_power_down = PD_P0;
        req_rate = RATE_GEN5; req_width = W_160; req_rxwidth = W_160;
        data_enable = 1'b0; pl_valid_i = 1'b0; pl_is_os_i = 1'b0; pl_data_i = '0;

        reset_n = 1'b0;
        repeat (4) @(negedge clk);
        reset_n = 1'b1;
        repeat (4) @(negedge clk);

        // ---- 1. Data phase in P0 ----
        @(negedge clk);
        data_enable = 1'b1;
        fork
            begin : producer
                for (int i = 0; i < N_BLOCKS; i++) begin
                    logic [BLOCK_PAYLOAD-1:0] d;
                    logic                     o;
                    d = rand128(); o = ($random & 1);
                    exp_q.push_back(d);
                    send_block(d, o);
                end
            end
            begin : consumer
                for (int r = 0; r < N_BLOCKS; r++) begin
                    logic [BLOCK_PAYLOAD-1:0] ed;
                    @(negedge clk);
                    while (!rx_pl_valid_o) @(negedge clk);
                    ed = exp_q.pop_front();
                    if (rx_pl_data_o !== ed) begin
                        errors = errors + 1;
                        $display("[INTEG] FAIL block %0d: data mismatch", r);
                    end
                    recv = recv + 1;
                end
            end
        join

        // ---- 2. Idle: drop data_enable, datapath drains and re-asserts TxElecIdle ----
        @(negedge clk);
        data_enable = 1'b0;
        repeat (20) @(negedge clk);
        if (dp_tx_elec_idle !== 4'hF) begin errors = errors + 1; $display("[INTEG] FAIL: EI not re-asserted when idle"); end
        if (in_data_phase) begin errors = errors + 1; $display("[INTEG] FAIL: still in data phase when idle"); end

        // ---- 3. Rate change in P0 while idle (exercises assertions P2/P3) ----
        do_req(REQ_RATE, PD_P0, RATE_GEN6, W_160, W_160, "rate -> Gen6");
        do_req(REQ_RATE, PD_P0, RATE_GEN5, W_160, W_160, "rate -> Gen5");

        // ---- 4. Negative: in P2, data_enable must NOT start a data phase ----
        do_req(REQ_POWER, PD_P2, RATE_GEN5, W_160, W_160, "P0 -> P2");
        @(negedge clk);
        checking_p2 = 1'b1;
        data_enable = 1'b1;
        repeat (30) @(negedge clk);
        data_enable = 1'b0;
        checking_p2 = 1'b0;
        do_req(REQ_POWER, PD_P0, RATE_GEN5, W_160, W_160, "P2 -> P0");

        // ---- Report ----
        if (recv != N_BLOCKS) begin errors = errors + 1; $display("[INTEG] FAIL: recovered=%0d expected %0d", recv, N_BLOCKS); end
        if (cov_ei_idle == 0)   begin errors = errors + 1; $display("[INTEG] FAIL: no TxElecIdle-idle cycles (P1 vacuous)"); end
        if (cov_tx_active == 0) begin errors = errors + 1; $display("[INTEG] FAIL: no Tx-active cycles (P1 vacuous)"); end
        if (!blk_locked)        begin errors = errors + 1; $display("[INTEG] FAIL: deframer never locked"); end

        if (errors == 0) begin
            $display("[INTEG] PASS  (blocks=%0d, ei_idle=%0d, tx_active=%0d)", recv, cov_ei_idle, cov_tx_active);
            $finish;
        end else begin
            $fatal(1, "[INTEG] FAIL  (errors=%0d)", errors);
        end
    end

    initial begin
        #500000;
        $fatal(1, "[INTEG] FAIL  (global timeout)");
    end

endmodule
