
`timescale 1ns/1ps

/**
 * tb_pipe7_rate_dp -- rate-aware MAC datapath smoke (closure-plan item 17). Self-clocking;
 * built with `verilator --binary --timing --assert`.
 *
 * Runs a Gen5 128b/130b data phase (blocks through the gearbox, up to 2/cycle) then switches
 * Rate to Gen6 and runs a Gen6 raw wide data phase, all through pipe7_mac_datapath_ra with a
 * PHY loopback. The item-7 assertions (P1 no-Tx-while-EI, P2 rate-in-P0/P1, P4 sync legality)
 * are bound, proving TxElecIdle gating holds across the rate switch. Prints [RATE DP] PASS/FAIL.
 */
module tb_pipe7_rate_dp;
    import pipe7_pkg::*;

    localparam int PIPE_WIDTH = 160;
    localparam int N5   = 24;   // Gen5 real blocks
    localparam int FL5  = 6;    // Gen5 flush blocks
    localparam int T5   = N5 + FL5;
    localparam int N6   = 20;   // Gen6 raw words

    logic clk, reset_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    int errors, recv5, recv6, cov_ei_idle, cov_tx_active;

    // ---- DUT signals ----
    logic [3:0]               rate, power_down;
    logic                     data_enable;
    logic [1:0]               g5_cnt;
    logic [BLOCK_PAYLOAD-1:0] g5_d0, g5_d1;
    logic                     g5_o0, g5_o1;
    logic [1:0]               g5_acc;
    logic                     g6_valid, g6_ready;
    logic [PIPE_WIDTH-1:0]    g6_data;
    logic [PIPE_WIDTH-1:0]    tx_data, rx_data;
    logic                     tx_valid;
    logic [3:0]               tx_ei;
    logic [1:0]               g5_rcnt;
    logic [BLOCK_PAYLOAD-1:0] g5_rd0, g5_rd1;
    logic                     g5_ro0, g5_ro1;
    logic                     g6_rvalid;
    logic [PIPE_WIDTH-1:0]    g6_rdata;
    logic                     blk_locked, sync_err, in_dp;
    logic [MB_DATA_WIDTH-1:0] pam4_cfg;

    pipe7_mac_datapath_ra #(.PIPE_WIDTH(PIPE_WIDTH)) dp (
        .clk, .reset_n, .rate, .power_down, .data_enable, .pam4_restricted_levels(8'h00),
        .g5_pl_cnt(g5_cnt), .g5_pl_data0(g5_d0), .g5_pl_is_os0(g5_o0),
        .g5_pl_data1(g5_d1), .g5_pl_is_os1(g5_o1), .g5_pl_acc(g5_acc),
        .g6_pl_valid(g6_valid), .g6_pl_data(g6_data), .g6_pl_ready(g6_ready),
        .tx_data, .tx_data_valid(tx_valid), .tx_elec_idle(tx_ei),
        .rx_data, .rx_valid(tx_valid),
        .g5_rx_cnt(g5_rcnt), .g5_rx_data0(g5_rd0), .g5_rx_os0(g5_ro0),
        .g5_rx_data1(g5_rd1), .g5_rx_os1(g5_ro1),
        .g6_rx_valid(g6_rvalid), .g6_rx_data(g6_rdata),
        .block_locked(blk_locked), .sync_error(sync_err), .in_data_phase(in_dp),
        .pam4_cfg_out(pam4_cfg)
    );
    assign rx_data = tx_data;   // PHY loopback

    // Item-7 assertions (P1 + P2 + P4; no control FSM here so P3 off).
    pipe7_mac_bridge_assertions #(.PHYSTATUS_MAX_LATENCY(32),
        .CHECK_TX_EI(1), .CHECK_RATE_PD(1), .CHECK_PHYSTAT(0), .CHECK_SYNC(1)) assn_chk (
        .clk, .reset_n,
        .tx_data_valid(tx_valid), .tx_elec_idle(tx_ei),
        .power_down(power_down), .rate(rate),
        .ctrl_busy(1'b0), .phy_status(1'b0), .sync_error(sync_err)
    );

    logic [BLOCK_PAYLOAD-1:0] src5 [T5];
    logic                     src5_os [T5];
    logic [PIPE_WIDTH-1:0]    src6 [N6];

    always @(negedge clk) begin
        if (reset_n) begin
            if (tx_ei == 4'hF) cov_ei_idle   = cov_ei_idle + 1;
            if (tx_valid)      cov_tx_active = cov_tx_active + 1;
        end
    end

    // ---- Stimulus ----
    initial begin
        errors = 0; recv5 = 0; recv6 = 0; cov_ei_idle = 0; cov_tx_active = 0;
        rate = RATE_GEN5; power_down = PD_P0; data_enable = 1'b0;
        g5_cnt = 2'd0; g5_d0 = '0; g5_o0 = 1'b0; g5_d1 = '0; g5_o1 = 1'b0;
        g6_valid = 1'b0; g6_data = '0;

        reset_n = 1'b0;
        repeat (4) @(negedge clk);
        reset_n = 1'b1;
        repeat (2) @(negedge clk);

        // ================= Gen5 phase =================
        @(negedge clk); data_enable = 1'b1;
        for (int i = 0; i < T5; i++) begin src5[i] = {$random,$random,$random,$random}; src5_os[i] = ($random & 1); end
        fork
            begin : g5_prod
                int s; s = 0;
                while (s < T5) begin
                    int no;
                    @(negedge clk);
                    no = (T5 - s >= 2) ? 2 : 1;
                    g5_d0 = src5[s]; g5_o0 = src5_os[s];
                    if (no == 2) begin g5_d1 = src5[s+1]; g5_o1 = src5_os[s+1]; end
                    g5_cnt = no[1:0];
                    #1;
                    s = s + int'(g5_acc);
                end
                @(negedge clk); g5_cnt = 2'd0;
            end
            begin : g5_cons
                while (recv5 < N5) begin
                    @(negedge clk);
                    if (g5_rcnt >= 2'd1) begin
                        if (g5_rd0 !== src5[recv5] || g5_ro0 !== src5_os[recv5]) begin errors=errors+1; $display("[RATE DP] G5 FAIL blk %0d p0",recv5); end
                        recv5 = recv5 + 1;
                    end
                    if (g5_rcnt >= 2'd2 && recv5 < N5) begin
                        if (g5_rd1 !== src5[recv5] || g5_ro1 !== src5_os[recv5]) begin errors=errors+1; $display("[RATE DP] G5 FAIL blk %0d p1",recv5); end
                        recv5 = recv5 + 1;
                    end
                end
            end
        join
        @(negedge clk); data_enable = 1'b0;
        repeat (20) @(negedge clk);
        if (tx_ei !== 4'hF) begin errors=errors+1; $display("[RATE DP] FAIL: EI not re-asserted after Gen5"); end

        // ================= Gen6 phase (switch rate while idle) =================
        @(negedge clk); rate = RATE_GEN6;
        repeat (2) @(negedge clk);
        @(negedge clk); data_enable = 1'b1;
        for (int i = 0; i < N6; i++) src6[i] = {$random,$random,$random,$random,$random};
        fork
            begin : g6_prod
                for (int i = 0; i < N6; i++) begin
                    @(negedge clk);
                    g6_data = src6[i]; g6_valid = 1'b1;
                end
                @(negedge clk); g6_valid = 1'b0;
            end
            begin : g6_cons
                while (recv6 < N6) begin
                    @(negedge clk);
                    if (g6_rvalid) begin
                        if (g6_rdata !== src6[recv6]) begin errors=errors+1; $display("[RATE DP] G6 FAIL word %0d",recv6); end
                        recv6 = recv6 + 1;
                    end
                end
            end
        join
        @(negedge clk); data_enable = 1'b0;
        repeat (10) @(negedge clk);

        // ---- Report ----
        if (recv5 != N5) begin errors=errors+1; $display("[RATE DP] FAIL: Gen5 recovered=%0d",recv5); end
        if (recv6 != N6) begin errors=errors+1; $display("[RATE DP] FAIL: Gen6 recovered=%0d",recv6); end
        if (cov_ei_idle == 0)   begin errors=errors+1; $display("[RATE DP] FAIL: P1 vacuous (no EI-idle)"); end
        if (cov_tx_active == 0) begin errors=errors+1; $display("[RATE DP] FAIL: P1 vacuous (no Tx-active)"); end

        if (errors == 0) begin
            $display("[RATE DP] PASS  (Gen5 blocks=%0d, Gen6 words=%0d, ei_idle=%0d, tx_active=%0d)",
                     recv5, recv6, cov_ei_idle, cov_tx_active);
            $finish;
        end else begin
            $fatal(1, "[RATE DP] FAIL  (errors=%0d)", errors);
        end
    end

    initial begin
        #800000;
        $fatal(1, "[RATE DP] FAIL  (global timeout)");
    end

endmodule
