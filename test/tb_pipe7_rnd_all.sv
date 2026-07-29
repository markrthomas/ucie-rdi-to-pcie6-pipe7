
`timescale 1ns/1ps

/**
 * tb_pipe7_rnd_all -- ALL-IN-ONE randomized test for the integrated bridge (Phase H, item 49).
 * Self-clocking; `verilator --binary --timing` (NO --assert: it injects sync_error / rx_overflow /
 * illegal requests / watchdog timeouts). Waveform-viewable (`make waves|gtkwave WAVE_TB=rnd_all`).
 *
 * One seeded run whose randomized scheduler interleaves all three fault families from items 46-48
 * with clean data traffic:
 *   DATA     clean random RDI traffic flows (flits_out advances);
 *   GARBAGE  garbage RX burst -> sync_error -> re-lock;
 *   STALL    RDI sink stall   -> rx_overflow -> drain;
 *   REJECT   illegal Rate/Width in P2 -> req_error;
 *   CTRL_WD  hung PHY -> ctrl watchdog req_error -> recover;
 *   MB_WD    hung msgbus -> response watchdog mb_rsp_error -> recover.
 * At least one of each action is guaranteed; all waits are bounded / fail-fast (DV convention).
 * Prints [RND ALL] PASS (data_ok=.. sync_error=.. rx_overflow=.. reject=.. ctrl_wd=.. mb_wd=..).
 */
module tb_pipe7_rnd_all;
    import pipe7_pkg::*;

    localparam int PIPE_WIDTH = 80;
    localparam int RDI_WIDTH  = 64;
    localparam int CREDITS    = 8;
    localparam int WD_BOUND   = 1400;

    // ---- seed ----
    int unsigned seed;
    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 32'h00C0FFEE;
        void'($urandom(seed));
        $display("[RND ALL] seed=%0d", seed);
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
        $dumpvars(0, tb_pipe7_rnd_all);
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

    // Fault-injection muxes: garbage RX, hung PHY, hung msgbus.
    logic                  inject_en, phy_hang, mb_hang;
    logic [PIPE_WIDTH-1:0] inject_data;
    logic                  phy_status_s, pclk_change_ok_s;
    logic [MB_BUS_WIDTH-1:0] p2m_s;
    assign rx_data        = inject_en ? inject_data : tx_data;
    assign phy_status     = phy_hang  ? 1'b0 : phy_status_s;
    assign pclk_change_ok = phy_hang  ? 1'b0 : pclk_change_ok_s;
    assign p2m            = mb_hang   ? '0   : p2m_s;

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
    pipe7_phy_responder_stub #(.LATENCY(4)) phy (
        .pclk, .reset_n(rst_n), .power_down, .rate, .width, .rx_width,
        .pclk_change_ack, .phy_status(phy_status_s), .pclk_change_ok(pclk_change_ok_s)
    );
    pipe7_msgbus_responder_stub #(.RC_LATENCY(3), .MEM_BITS(4)) mbresp (.pclk, .reset_n(rst_n), .m2p, .p2m(p2m_s));

    // ---- RDI TX source: free-running random flits, credit-gated ----
    logic [RDI_WIDTH-1:0] txdat; logic txsob;
    int avail;
    wire can_send = (avail > 0) && rst_n;
    assign rdi_tx_valid = can_send;
    assign rdi_tx_data  = txdat;
    assign rdi_tx_sob   = txsob;
    assign rdi_tx_is_os = 1'b0;
    always_ff @(posedge rdi_clk or negedge rst_n)
        if (!rst_n) begin avail <= CREDITS; txdat <= 64'h1; txsob <= 1'b1; end
        else begin
            avail <= avail - (can_send ? 1 : 0) + int'(rdi_tx_crd);
            if (can_send) begin txdat <= {$urandom, $urandom}; txsob <= ~txsob; end
        end

    // ---- RDI RX sink: always-ready, tops the egress credit pool up to CREDITS; sink_stall forces overflow ----
    logic sink_stall;
    always_ff @(posedge rdi_clk or negedge rst_n)
        if (!rst_n) rdi_rx_crd <= 2'd0;
        else        rdi_rx_crd <= (!sink_stall && dut.egress.credits < CREDITS[$bits(dut.egress.credits)-1:0])
                                  ? 2'd1 : 2'd0;

    // ---- Observers ----
    int sync_err_seen, ovf_seen;
    always_ff @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin sync_err_seen <= 0; ovf_seen <= 0; end
        else begin
            if (sync_error)  sync_err_seen <= sync_err_seen + 1;
            if (rx_overflow) ovf_seen      <= ovf_seen + 1;
        end
    end
    int flits_out;
    always_ff @(posedge rdi_clk or negedge rst_n)
        if (!rst_n) flits_out <= 0; else if (rdi_rx_valid) flits_out <= flits_out + 1;

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

    logic [3:0] cur_pd;
    task automatic ensure_p0();
        if (cur_pd != PD_P0) begin
            drive_req(REQ_POWER, PD_P0, RATE_GEN5, W_160, 400);
            if (!saw_done) $fatal(1, "[RND ALL] FAIL: could not return to P0");
            cur_pd = PD_P0;
        end
    endtask

    task automatic wait_lock(input int bound, input string ctx);
        int w; w = 0;
        while (!block_locked) begin
            @(negedge pclk);
            if (++w > bound) $fatal(1, "[RND ALL] FAIL: no block lock (%s)", ctx);
        end
    endtask

    task automatic clean_window(input int want);   // prove clean data traffic flows
        int f0, w;
        inject_en = 1'b0; sink_stall = 1'b0;
        f0 = flits_out; w = 0;
        while (flits_out < f0 + want) begin
            @(negedge pclk);
            if (++w > 40000)
                $fatal(1, "[RND ALL] FAIL: clean traffic stalled (flits_out=%0d want>=%0d locked=%0b dphase=%0b)",
                       flits_out, f0 + want, block_locked, in_data_phase);
        end
    endtask

    // ---- action tasks ----
    int data_ok, rejects, ctrl_wds, mb_wds;

    task automatic act_data();  ensure_p0(); wait_lock(8000, "data"); clean_window(12); data_ok++; endtask

    task automatic act_garbage();
        int s0, w;
        ensure_p0(); wait_lock(8000, "pre-garbage"); clean_window(4);
        s0 = sync_err_seen; inject_en = 1'b1; inject_data = {$urandom, $urandom, $urandom};
        w = 0; while (sync_err_seen == s0) begin @(negedge pclk); if (++w > 4000) $fatal(1, "[RND ALL] FAIL: garbage RX -> no sync_error"); end
        repeat ($urandom_range(20, 120)) @(negedge pclk);
        inject_en = 1'b0;
        w = 0; while (!block_locked) begin @(negedge pclk); if (++w > 8000) $fatal(1, "[RND ALL] FAIL: no re-lock after garbage"); end
    endtask

    task automatic act_stall();
        int o0, w;
        ensure_p0(); wait_lock(8000, "pre-stall"); clean_window(4);
        o0 = ovf_seen; sink_stall = 1'b1;
        w = 0; while (ovf_seen == o0) begin @(negedge pclk); if (++w > 8000) $fatal(1, "[RND ALL] FAIL: sink stall -> no rx_overflow"); end
        repeat ($urandom_range(20, 120)) @(negedge pclk);
        sink_stall = 1'b0; clean_window(8);
    endtask

    task automatic act_reject();
        ensure_p0();
        drive_req(REQ_POWER, PD_P2, RATE_GEN5, W_160, 400);
        if (!saw_done) $fatal(1, "[RND ALL] FAIL: could not enter P2");
        cur_pd = PD_P2;
        drive_req(($urandom & 1) ? REQ_RATE : REQ_WIDTH, PD_P2, RATE_GEN6, ($urandom & 1) ? W_80 : W_40, 200);
        if (!saw_err || saw_done) $fatal(1, "[RND ALL] FAIL: illegal req in P2 not rejected");
        rejects++;
        ensure_p0();
    endtask

    task automatic act_ctrl_wd();
        ensure_p0();
        phy_hang = 1'b1;
        drive_req(REQ_POWER, PD_P0S, RATE_GEN5, W_160, WD_BOUND);
        if (!saw_err || saw_done) $fatal(1, "[RND ALL] FAIL: ctrl watchdog did not fire");
        cur_pd = PD_P0S; ctrl_wds++;
        phy_hang = 1'b0; repeat (12) @(negedge pclk);
        drive_req(REQ_POWER, PD_P0, RATE_GEN5, W_160, 600);
        if (!saw_done) $fatal(1, "[RND ALL] FAIL: ctrl did not recover after watchdog");
        cur_pd = PD_P0;
    endtask

    task automatic act_mb_wd();
        mb_hang = 1'b1;
        drive_mb(1'b1, 1'b1, REG_PHY_TX_CTRL_BASE + ($urandom_range(0, 3)), $urandom, WD_BOUND);
        if (!saw_rsp || !saw_mberr) $fatal(1, "[RND ALL] FAIL: mb watchdog did not fire");
        mb_wds++;
        mb_hang = 1'b0; repeat (8) @(negedge pclk);
        drive_mb(1'b0, 1'b0, REG_PHY_TX_CTRL_BASE, 8'h00, 400);
        if (!saw_rsp || saw_mberr) $fatal(1, "[RND ALL] FAIL: mb did not recover after watchdog");
    endtask

    // ---- Main scheduler ----
    int na;
    initial begin
        req_valid = 1'b0; req_kind = REQ_POWER; req_power_down = PD_P0; req_rate = RATE_GEN5;
        req_width = W_160; req_rxwidth = W_160;
        mb_req_valid = 1'b0; mb_req_write = 1'b0; mb_req_committed = 1'b0; mb_req_addr = '0; mb_req_wdata = '0;
        inject_en = 1'b0; inject_data = '0; sink_stall = 1'b0; phy_hang = 1'b0; mb_hang = 1'b0;
        cur_pd = PD_P0; data_ok = 0; rejects = 0; ctrl_wds = 0; mb_wds = 0;

        rst_n = 1'b0;
        repeat (6) @(negedge pclk);
        rst_n = 1'b1;
        wait_lock(8000, "startup");
        clean_window(16);                       // warmup

        na = $urandom_range(7, 11);
        for (int i = 0; i < na; i++) begin
            int act; act = (i < 6) ? i : $urandom_range(0, 5);   // guarantee all six, then random
            case (act)
                0: act_data();
                1: act_garbage();
                2: act_stall();
                3: act_reject();
                4: act_ctrl_wd();
                default: act_mb_wd();
            endcase
            act_data();                         // clean data between actions
        end

        clean_window(16);                       // cooldown -- data integrity restored

        if (data_ok == 0 || sync_err_seen == 0 || ovf_seen == 0 || rejects == 0 || ctrl_wds == 0 || mb_wds == 0)
            $fatal(1, "[RND ALL] FAIL: a class was not exercised (data_ok=%0d sync=%0d ovf=%0d reject=%0d ctrl_wd=%0d mb_wd=%0d)",
                   data_ok, sync_err_seen, ovf_seen, rejects, ctrl_wds, mb_wds);

        $display("[RND ALL] PASS  (seed=%0d actions=%0d data_ok=%0d sync_error=%0d rx_overflow=%0d reject=%0d ctrl_wd=%0d mb_wd=%0d)",
                 seed, na, data_ok, sync_err_seen, ovf_seen, rejects, ctrl_wds, mb_wds);
        $finish;
    end

    initial begin #12000000; $fatal(1, "[RND ALL] FAIL  (global timeout)"); end

endmodule
