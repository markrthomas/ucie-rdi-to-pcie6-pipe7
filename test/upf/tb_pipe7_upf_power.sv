
`timescale 1ns/1ps

/**
 * tb_pipe7_upf_power -- power-aware directed test for ucie_rdi_to_pipe7_mac_bridge.
 *
 * INTENT: exercise the UPF power intent in test/upf/bridge.upf -- the switchable datapath domain
 * PD_DP (power switch), its output isolation, and config-regfile retention -- across a real PIPE
 * low-power episode (P0 -> P2 -> P0). Self-checking; bounded waits with a global timeout.
 *
 * TWO BUILD MODES (see test/upf/README.md):
 *   * VCS -upf (+define+UPF_POWER_AWARE): the power-intent checks below are live -- isolation
 *     clamp values while gated, and config retention across the OFF episode. This is the real
 *     sign-off run. NOT run in this OSS environment (no power-aware simulator here).
 *   * Plain Verilator/Icarus (no define): a *skeleton* run -- the DUT+PMU elaborate, the control
 *     FSM sequences P0<->P2, the PMU produces the expected switch/iso/retention waveform, and data
 *     round-trips before and after. The UPF-only power checks are compiled out. This is what keeps
 *     the artifact from bit-rotting as the RTL evolves; it does NOT verify power intent.
 *
 * DUT graph: bridge <-> PHY loopback (TxData->RxData) + PhyStatus responder + msgbus responder;
 * pmu decodes dut.power_down into the UPF controls; item-7 assertions bound.
 */
module tb_pipe7_upf_power;
    import pipe7_pkg::*;

    localparam int PIPE_WIDTH = 80;
    localparam int RDI_WIDTH  = 64;
    localparam int CREDITS    = 8;
    localparam logic [MB_DATA_WIDTH-1:0] PAM4_CFG = 8'hA5;   // config value we expect to survive P2

    logic pclk, rdi_clk, rst_n;
    initial pclk = 1'b0;
    initial rdi_clk = 1'b0;
    always #5 pclk = ~pclk;         // 100 MHz
    always #7 rdi_clk = ~rdi_clk;   // ~71 MHz

`ifdef ENABLE_WAVES
    initial begin
        string wf;
        if ($value$plusargs("wavefile=%s", wf)) $dumpfile(wf); else $dumpfile("waves.vcd");
        $dumpvars(0, tb_pipe7_upf_power);
    end
`endif

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
    logic                 block_locked, sync_error, in_data_phase, rx_overflow;

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
        .block_locked, .sync_error, .in_data_phase, .rx_overflow
    );

    // PHY loopback + responders (same stubs as the integrated smoke).
    assign rx_data  = tx_data;
    assign rx_valid = tx_data_valid;
    pipe7_phy_responder_stub #(.LATENCY(4)) phy (
        .pclk, .reset_n(rst_n), .power_down, .rate, .width, .rx_width,
        .pclk_change_ack, .phy_status, .pclk_change_ok
    );
    pipe7_msgbus_responder_stub #(.RC_LATENCY(3), .MEM_BITS(4)) mbresp (
        .pclk, .reset_n(rst_n), .m2p, .p2m
    );

    // Power-management sequencer: decodes PowerDown into the UPF switch/iso/retention controls.
    logic pmu_pwr_en, pmu_iso_en, pmu_ret_save, pmu_ret_restore;
    pipe7_pmu pmu (
        .clk(pclk), .rst_n(rst_n), .power_down(power_down),
        .dp_pwr_en(pmu_pwr_en), .dp_iso_en(pmu_iso_en),
        .dp_ret_save(pmu_ret_save), .dp_ret_restore(pmu_ret_restore)
    );

    // Item-7 assertions bound.
    pipe7_mac_bridge_assertions #(.PHYSTATUS_MAX_LATENCY(64)) assn_chk (
        .clk(pclk), .reset_n(rst_n),
        .tx_data_valid, .tx_elec_idle, .power_down, .rate,
        .ctrl_busy(busy), .phy_status, .sync_error
    );

    // ---- RDI data source: send only while in P0 (no traffic while gated) ----
    localparam int FLITS_ALL = 64;
    logic [RDI_WIDTH-1:0] in_data [FLITS_ALL];
    logic                 in_os   [FLITS_ALL];
    initial for (int k = 0; k < FLITS_ALL; k++) begin in_data[k] = $random; in_os[k] = 1'b0; end

    int  avail, sent, recv, rdi_errors;
    logic src_en;   // gate traffic to P0 windows only
    wire  can_send = src_en && (avail > 0) && (sent < FLITS_ALL) && rst_n && (power_down == PD_P0);
    assign rdi_tx_valid = can_send;
    assign rdi_tx_data  = in_data[sent];
    assign rdi_tx_sob   = 1'b1;
    assign rdi_tx_is_os = (sent < FLITS_ALL) ? in_os[sent] : 1'b0;
    always_ff @(posedge rdi_clk or negedge rst_n)
        if (!rst_n) begin avail <= CREDITS; sent <= 0; end
        else begin
            if (can_send) sent <= sent + 1;
            avail <= avail - (can_send ? 1 : 0) + int'(rdi_tx_crd);
        end

    // ---- RDI sink: return a credit per flit; check in-order round-trip ----
    always_ff @(posedge rdi_clk or negedge rst_n) begin
        if (!rst_n) begin rdi_rx_crd <= 2'd0; recv <= 0; rdi_errors <= 0; end
        else begin
            rdi_rx_crd <= {1'b0, rdi_rx_valid};
            if (rdi_rx_valid && recv < FLITS_ALL) begin
                if (rdi_rx_data !== in_data[recv] || rdi_rx_is_os !== in_os[recv])
                    rdi_errors <= rdi_errors + 1;
                recv <= recv + 1;
            end
        end
    end

    int errors;

    // ---- Control / message-bus helpers (bounded waits) ----
    task automatic do_ctrl(input logic [1:0] k, input logic [3:0] pd, input logic [3:0] rt);
        int w;
        @(negedge pclk);
        req_kind = k; req_power_down = pd; req_rate = rt; req_width = W_80; req_rxwidth = W_80;
        req_valid = 1'b1;
        @(negedge pclk); req_valid = 1'b0;
        w = 0; while (!done && !req_error) begin w++; if (w > 300) break; @(negedge pclk); end
        if (!done) begin errors++; $display("[UPF POWER] FAIL: ctrl no completion (pd=%0h rt=%0h)", pd, rt); end
    endtask

    task automatic do_mb(input logic wr, input logic com, input logic [MB_ADDR_WIDTH-1:0] a,
                         input logic [MB_DATA_WIDTH-1:0] d);
        int w;
        @(negedge pclk);
        mb_req_write = wr; mb_req_committed = com; mb_req_addr = a; mb_req_wdata = d;
        mb_req_valid = 1'b1;
        @(negedge pclk); mb_req_valid = 1'b0;
        w = 0; while (!mb_rsp_valid) begin w++; if (w > 300) break; @(negedge pclk); end
        if (!mb_rsp_valid) begin errors++; $display("[UPF POWER] FAIL: mb no completion"); end
    endtask

    // Wait (bounded) for a condition on pclk; flag + return on timeout.
    task automatic wait_pclk(input int max_cyc, input string what, ref logic sig, input logic val);
        int w; w = 0;
        while (sig !== val) begin w++; if (w > max_cyc) begin
            errors++; $display("[UPF POWER] FAIL: timeout waiting for %s", what); return; end
            @(posedge pclk); end
    endtask

    // ---- Main stimulus ----
    initial begin
        errors = 0; src_en = 1'b0;
        req_valid = 1'b0; req_kind = REQ_POWER; req_power_down = PD_P0;
        req_rate = RATE_GEN5; req_width = W_80; req_rxwidth = W_80;
        mb_req_valid = 1'b0; mb_req_write = 1'b0; mb_req_committed = 1'b0;
        mb_req_addr = '0; mb_req_wdata = '0;

        rst_n = 1'b0;
        repeat (6) @(negedge pclk);
        rst_n = 1'b1;

        // (1) P0 data window -- datapath alive, block round-trip works.
        src_en = 1'b1;
        wait (recv >= 16);
        src_en = 1'b0;
        if (rdi_errors != 0) begin errors++; $display("[UPF POWER] FAIL: pre-sleep RDI errors=%0d", rdi_errors); end

        // (2) Program the config register (PAM4RestrictedLevels) that must survive low power.
        do_mb(1'b1, 1'b1, REG_PHY_PAM4_RESTRICTED_LEVELS, PAM4_CFG);
        if (dut.pam4_levels !== PAM4_CFG) begin
            errors++; $display("[UPF POWER] FAIL: config not programmed 0x%02x != 0x%02x", dut.pam4_levels, PAM4_CFG);
        end

        // (3) Enter P2 -> PMU gates PD_DP. Isolation asserts, retention saves, VDD_DP collapses.
        do_ctrl(REQ_POWER, PD_P2, RATE_GEN5);
        wait_pclk(64, "PMU isolate",  pmu_iso_en, 1'b1);
        wait_pclk(64, "PMU power-off", pmu_pwr_en, 1'b0);

`ifdef UPF_POWER_AWARE
        // Power-aware-only checks: with VDD_DP off, PD_DP outputs must read their isolation clamps
        // (0 for data/valid, 1 for TxElecIdle) rather than X-corruption from the collapsed domain.
        @(posedge pclk);
        if (tx_data_valid !== 1'b0)
            begin errors++; $display("[UPF POWER] FAIL: TxDataValid not isolated to 0 while gated (=%0b)", tx_data_valid); end
        if (tx_elec_idle !== 4'hF)
            begin errors++; $display("[UPF POWER] FAIL: TxElecIdle not isolated to 1 while gated (=%0h)", tx_elec_idle); end
        if (^tx_data === 1'bx)
            begin errors++; $display("[UPF POWER] FAIL: TxData corruption leaked past isolation"); end
`endif

        // (4) Control plane stays alive while the datapath is gated: a msgbus read still completes.
        do_mb(1'b0, 1'b0, REG_PHY_TX_CTRL_BASE + 1, 8'h00);

        // (5) Exit to P0 -> PMU powers PD_DP, restores retention, de-isolates.
        do_ctrl(REQ_POWER, PD_P0, RATE_GEN5);
        wait_pclk(64, "PMU power-on",   pmu_pwr_en, 1'b1);
        wait_pclk(64, "PMU de-isolate", pmu_iso_en, 1'b0);

        // (6) Retention proof: the programmed config survived the OFF episode.
        //     (Meaningful under -upf, where PD_DP was actually corrupted; trivially true otherwise.)
        if (dut.pam4_levels !== PAM4_CFG) begin
            errors++; $display("[UPF POWER] FAIL: config lost across P2 0x%02x != 0x%02x (retention)", dut.pam4_levels, PAM4_CFG);
        end

        // (7) Post-wake data window: the (non-retained) datapath re-locks and traffic resumes.
        repeat (8) @(negedge pclk);
        src_en = 1'b1;
        wait (recv >= 32);
        src_en = 1'b0;
        if (rdi_errors != 0) begin errors++; $display("[UPF POWER] FAIL: post-wake RDI errors=%0d", rdi_errors); end

        repeat (10) @(negedge pclk);

        if (errors == 0) begin
`ifdef UPF_POWER_AWARE
            $display("[UPF POWER] PASS  (power-aware: switch+isolation+retention across P2, recv=%0d)", recv);
`else
            $display("[UPF POWER] PASS  (skeleton: control+PMU+data OK; UPF power intent requires VCS -upf, recv=%0d)", recv);
`endif
            $finish;
        end else begin
            $fatal(1, "[UPF POWER] FAIL  (errors=%0d)", errors);
        end
    end

    initial begin
        #3000000;
        $fatal(1, "[UPF POWER] FAIL  (global timeout recv=%0d)", recv);
    end

endmodule
