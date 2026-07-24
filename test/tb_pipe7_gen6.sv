
`timescale 1ns/1ps

/**
 * tb_pipe7_gen6 -- self-checking Gen6 (64 GT/s, Rate=5) smoke (closure-plan item 6).
 * Self-clocking; built with `verilator --binary --timing`.
 *
 * Covers the item-6 bullets by composing proven blocks with the new Gen6 datapath:
 *   1. Control: via pipe7_mac_ctrl_fsm + the PHY-responder stub, switch Rate to Gen6 and
 *      perform L0p as an ordinary Width change (160->80->160), each completing via PhyStatus
 *      (crosscheck B5/C3/C4). Rate/Width legality is the same handshake as Gen5.
 *   2. Datapath: through pipe7_gen6_datapath (looped back), round-trip random 160-bit words
 *      and prove the Gen6 path is RAW -- TxData carries the payload bit-for-bit with NO sync
 *      header / no 128b/130b coding overhead (crosscheck I1/I3), recovered exactly.
 *   3. PAM4: drive PAM4RestrictedLevels config and confirm the datapath carries it
 *      (pam4_cfg_out); the precoding math itself is PHY-side (crosscheck G5/I4).
 *
 * Pass criterion: all control requests complete, every wide word round-trips bit-exact with
 * no header overhead, and the PAM4 config is carried. Prints [GEN6] PASS / FAIL and $finish.
 */
module tb_pipe7_gen6;
    import pipe7_pkg::*;

    localparam int PIPE_WIDTH = 160;
    localparam int N_WORDS    = 16;

    logic clk;
    logic reset_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    int errors;
    int comp_ok;   // control completions
    int recv;      // datapath words recovered

    // ---------------- Control: ctrl FSM + PHY responder ----------------
    logic       req_valid;
    ctrl_req_e  req_kind;
    logic [3:0] req_power_down, req_rate;
    logic [2:0] req_width, req_rxwidth;
    logic       busy, done, req_error;
    logic [3:0] power_down, rate, tx_elec_idle;
    logic [2:0] width, rx_width;
    logic       rx_standby, pclk_change_ack;
    logic       phy_status, pclk_change_ok;

    pipe7_mac_ctrl_fsm #(.PCLK_IS_PHY_INPUT(1'b0)) ctrl (
        .pclk(clk), .reset_n,
        .req_valid, .req_kind, .req_power_down, .req_rate, .req_width, .req_rxwidth,
        .busy, .done, .req_error,
        .power_down, .rate, .width, .rx_width, .tx_elec_idle, .rx_standby, .pclk_change_ack,
        .phy_status, .pclk_change_ok
    );

    pipe7_phy_responder_stub #(.LATENCY(4), .PCLK_IS_PHY_INPUT(1'b0)) phy (
        .pclk(clk), .reset_n,
        .power_down, .rate, .width, .rx_width, .pclk_change_ack,
        .phy_status, .pclk_change_ok
    );

    // ---------------- Datapath: Gen6 wide raw path (looped back) ----------------
    logic                     gen6_mode;
    logic [MB_DATA_WIDTH-1:0] pam4_rlvl;
    logic                     tx_pl_valid, tx_pl_ready;
    logic [PIPE_WIDTH-1:0]    tx_pl_data;
    logic [PIPE_WIDTH-1:0]    pipe_tx, pipe_rx;
    logic                     pipe_tx_valid, pipe_rx_valid;
    logic                     rx_pl_valid;
    logic [PIPE_WIDTH-1:0]    rx_pl_data;
    logic [MB_DATA_WIDTH-1:0] pam4_cfg_out;

    pipe7_gen6_datapath #(.PIPE_WIDTH(PIPE_WIDTH)) dp (
        .clk, .reset_n,
        .gen6_mode, .pam4_restricted_levels(pam4_rlvl),
        .tx_pl_valid, .tx_pl_data, .tx_pl_ready,
        .tx_data(pipe_tx), .tx_data_valid(pipe_tx_valid),
        .rx_data(pipe_rx), .rx_data_valid(pipe_rx_valid),
        .rx_pl_valid, .rx_pl_data,
        .pam4_cfg_out
    );

    // Loopback the wide PIPE data straight back (models the raw Gen6 conduit).
    assign pipe_rx       = pipe_tx;
    assign pipe_rx_valid = pipe_tx_valid;

    // Expected-word queue + a shadow of what was actually put on TxData (to prove raw).
    logic [PIPE_WIDTH-1:0] exp_word [$];

    // ---- Control request helper (blocking on negedge; race-free vs posedge sampling) ----
    task automatic do_req(input ctrl_req_e kind,
                          input logic [3:0] pd, input logic [3:0] rt,
                          input logic [2:0] wd, input logic [2:0] rxw,
                          input string name);
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
        else begin
            errors = errors + 1;
            $display("[GEN6] FAIL %s: done=%0b err=%0b", name, done, req_error);
        end
    endtask

    function automatic logic [PIPE_WIDTH-1:0] rand_word();
        logic [PIPE_WIDTH-1:0] v;
        for (int k = 0; k < PIPE_WIDTH; k += 32) v[k +: 32] = $random;
        return v;
    endfunction

    // ---------------- Stimulus ----------------
    initial begin
        errors = 0; comp_ok = 0; recv = 0;
        req_valid = 1'b0; req_kind = REQ_POWER; req_power_down = PD_P0;
        req_rate = RATE_GEN5; req_width = W_160; req_rxwidth = W_160;
        gen6_mode = 1'b0; pam4_rlvl = '0; tx_pl_valid = 1'b0; tx_pl_data = '0;

        reset_n = 1'b0;
        repeat (4) @(negedge clk);
        reset_n = 1'b1;
        repeat (2) @(negedge clk);

        // ---- 1. Control: enter Gen6, then L0p width changes (all legal in P0) ----
        do_req(REQ_RATE,  PD_P0, RATE_GEN6, W_160, W_160, "rate -> Gen6");
        if (rate !== RATE_GEN6) begin errors = errors + 1; $display("[GEN6] FAIL: rate!=Gen6"); end
        do_req(REQ_WIDTH, PD_P0, RATE_GEN6, W_80,  W_80,  "L0p width 160->80");
        if (width !== W_80) begin errors = errors + 1; $display("[GEN6] FAIL: width!=80"); end
        do_req(REQ_WIDTH, PD_P0, RATE_GEN6, W_160, W_160, "L0p width 80->160");
        if (width !== W_160) begin errors = errors + 1; $display("[GEN6] FAIL: width!=160"); end

        // ---- 3. PAM4RestrictedLevels config ----
        @(negedge clk);
        pam4_rlvl  = 8'hA5;      // representative PAM4RestrictedLevels value
        gen6_mode  = 1'b1;       // Gen6 datapath active
        repeat (2) @(negedge clk);
        if (pam4_cfg_out !== 8'hA5) begin
            errors = errors + 1;
            $display("[GEN6] FAIL: pam4_cfg_out=0x%02x expected 0xA5", pam4_cfg_out);
        end

        // ---- 2. Datapath: raw wide round-trip ----
        fork
            // Producer: one wide word per cycle for N_WORDS.
            begin
                for (int i = 0; i < N_WORDS; i++) begin
                    logic [PIPE_WIDTH-1:0] d;
                    @(negedge clk);
                    d = rand_word();
                    tx_pl_data  = d;
                    tx_pl_valid = 1'b1;
                    exp_word.push_back(d);
                end
                @(negedge clk);
                tx_pl_valid = 1'b0;
            end
            // Consumer: collect recovered words and check bit-exact + raw (no header).
            begin
                for (int r = 0; r < N_WORDS; r++) begin
                    logic [PIPE_WIDTH-1:0] ew;
                    @(negedge clk);
                    while (!rx_pl_valid) @(negedge clk);
                    ew = exp_word.pop_front();
                    if (rx_pl_data !== ew) begin
                        errors = errors + 1;
                        $display("[GEN6] FAIL word %0d: data mismatch", r);
                    end
                    recv = recv + 1;
                end
            end
        join

        // ---- Report ----
        if (comp_ok != 3) begin
            errors = errors + 1;
            $display("[GEN6] FAIL: control completions=%0d expected 3", comp_ok);
        end
        if (recv != N_WORDS) begin
            errors = errors + 1;
            $display("[GEN6] FAIL: recovered=%0d expected %0d", recv, N_WORDS);
        end

        if (errors == 0) begin
            $display("[GEN6] PASS  (rate=Gen6, control=%0d, words=%0d, pam4=0x%02x)",
                     comp_ok, recv, pam4_cfg_out);
            $finish;
        end else begin
            $fatal(1, "[GEN6] FAIL  (errors=%0d)", errors);
        end
    end

    // ---- Raw-path check: whenever TxData is valid, it equals the last accepted payload
    //      (one-cycle registered) -- proves no sync header / no coding overhead is inserted.
    logic [PIPE_WIDTH-1:0] last_tx_pl;
    logic                  last_tx_pl_vld;
    always @(negedge clk) begin
        if (reset_n && pipe_tx_valid && last_tx_pl_vld && (pipe_tx !== last_tx_pl)) begin
            errors = errors + 1;
            $display("[GEN6] FAIL: TxData altered payload (header/coding leaked into Gen6 path)");
        end
        // capture the payload accepted this cycle for comparison next cycle
        last_tx_pl     <= tx_pl_data;
        last_tx_pl_vld <= gen6_mode && tx_pl_valid;
    end

    // Global watchdog.
    initial begin
        #500000;
        $fatal(1, "[GEN6] FAIL  (global timeout)");
    end

endmodule
