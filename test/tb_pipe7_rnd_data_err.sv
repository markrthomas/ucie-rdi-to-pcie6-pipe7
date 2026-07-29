
`timescale 1ns/1ps

/**
 * tb_pipe7_rnd_data_err -- RANDOMIZED data-with-errors test for the integrated bridge
 * (Phase H, item 47). Self-clocking; `verilator --binary --timing` (NO --assert: the item-7
 * SVA `a_sync_legal` asserts !sync_error, which we deliberately violate by injection).
 * Waveform-viewable (`make waves|gtkwave WAVE_TB=rnd_data_err [SEED=N]`).
 *
 * Random clean traffic interleaved with randomly-timed DATAPATH faults:
 *   - garbage RX burst  -> deframer slips -> sync_error pulses; on release the link re-locks;
 *   - RDI sink stall     -> RX burst-FIFO / CDC fill -> rx_overflow pulses; on release it drains.
 * Each fault is checked to (a) raise its expected flag and (b) recover (re-lock + traffic
 * resumes). Episode types are randomized but at least one of each fault is guaranteed. All waits
 * are bounded and fail-fast (DV convention). Prints [RND DATA ERR] PASS / FAIL.
 */
module tb_pipe7_rnd_data_err;
    import pipe7_pkg::*;

    localparam int PIPE_WIDTH = 80;
    localparam int RDI_WIDTH  = 64;
    localparam int CREDITS    = 8;

    // ---- seed ----
    int unsigned seed;
    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 32'h00C0FFEE;
        void'($urandom(seed));
        $display("[RND DATA ERR] seed=%0d", seed);
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
        $dumpvars(0, tb_pipe7_rnd_data_err);
    end
`endif

    // ---- DUT signals ----
    logic [RDI_WIDTH-1:0] rdi_tx_data, rdi_rx_data;
    logic                 rdi_tx_valid, rdi_tx_sob, rdi_tx_is_os, rdi_rx_valid, rdi_rx_sob, rdi_rx_is_os;
    logic [1:0]           rdi_tx_crd, rdi_rx_crd;
    logic [PIPE_WIDTH-1:0] tx_data, rx_data;
    logic                 tx_data_valid;
    logic [3:0]           tx_elec_idle, power_down, rate;
    logic [2:0]           width, rx_width;
    logic                 rx_standby, pclk_change_ack, phy_status, pclk_change_ok;
    logic [MB_BUS_WIDTH-1:0] m2p, p2m;
    logic                 block_locked, sync_error, in_data_phase, rx_overflow;
    logic                 busy, done, req_error, mb_req_ready, mb_busy, mb_rsp_valid, mb_rsp_is_read, mb_rsp_error;
    logic [MB_DATA_WIDTH-1:0] mb_rsp_rdata;

    // RxData mux: clean loopback, or injected garbage (consumed while TxDataValid pulses).
    logic                  inject_en;
    logic [PIPE_WIDTH-1:0] inject_data;
    assign rx_data = inject_en ? inject_data : tx_data;

    ucie_rdi_to_pipe7_mac_bridge #(.PIPE_WIDTH(PIPE_WIDTH), .RDI_WIDTH(RDI_WIDTH), .CREDITS(CREDITS)) dut (
        .rst_n, .rdi_clk, .pclk,
        .rdi_tx_valid, .rdi_tx_data, .rdi_tx_sob, .rdi_tx_is_os, .rdi_tx_crd,
        .rdi_rx_valid, .rdi_rx_data, .rdi_rx_sob, .rdi_rx_is_os, .rdi_rx_crd,
        .req_valid(1'b0), .req_kind(2'd0), .req_power_down(PD_P0), .req_rate(RATE_GEN5),
        .req_width(W_160), .req_rxwidth(W_160), .busy, .done, .req_error,
        .mb_req_valid(1'b0), .mb_req_write(1'b0), .mb_req_committed(1'b0), .mb_req_addr('0),
        .mb_req_wdata('0), .mb_req_ready, .mb_busy, .mb_rsp_valid, .mb_rsp_is_read,
        .mb_rsp_rdata, .mb_rsp_error,
        .tx_data, .tx_data_valid, .tx_elec_idle, .power_down, .rate, .width, .rx_width,
        .rx_standby, .pclk_change_ack, .m2p_message_bus(m2p),
        .rx_data, .rx_valid(tx_data_valid), .phy_status, .pclk_change_ok, .p2m_message_bus(p2m),
        .block_locked, .sync_error, .in_data_phase, .rx_overflow
    );
    pipe7_phy_responder_stub #(.LATENCY(4)) phy (
        .pclk, .reset_n(rst_n), .power_down, .rate, .width, .rx_width,
        .pclk_change_ack, .phy_status, .pclk_change_ok
    );
    pipe7_msgbus_responder_stub #(.RC_LATENCY(3), .MEM_BITS(4)) mbresp (.pclk, .reset_n(rst_n), .m2p, .p2m);

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

    // ---- RDI RX sink: always-ready consumer that tops the egress credit pool back up to CREDITS
    // (gated on the egress's own counter so it never over-credits). `sink_stall` withholds credits
    // to back the RX CDC up and force rx_overflow; on release the pool refills and the egress
    // resumes -- unlike a return-on-valid sink, which cannot bootstrap from 0 credits after a stall.
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

    // ---- Episode helpers (all bounded / fail-fast) ----
    task automatic clean_window(input int want);   // prove clean traffic flows
        int f0, w;
        inject_en = 1'b0; sink_stall = 1'b0;
        f0 = flits_out; w = 0;
        while (flits_out < f0 + want) begin
            @(negedge pclk);
            if (++w > 40000)
                $fatal(1, "[RND DATA ERR] FAIL: clean traffic stalled (flits_out=%0d want>=%0d locked=%0b dphase=%0b avail=%0d tx_v=%0b tx_crd=%0d rx_v=%0b)",
                       flits_out, f0 + want, block_locked, in_data_phase, avail, rdi_tx_valid, rdi_tx_crd, rdi_rx_valid);
        end
    endtask

    task automatic ep_garbage();                   // garbage RX -> sync_error -> re-lock
        int s0, w;
        s0 = sync_err_seen;
        inject_en = 1'b1; inject_data = {$urandom, $urandom, $urandom};
        w = 0;
        while (sync_err_seen == s0) begin
            @(negedge pclk);
            if (++w > 4000) $fatal(1, "[RND DATA ERR] FAIL: garbage RX did not raise sync_error");
        end
        repeat ($urandom_range(20, 120)) @(negedge pclk);
        inject_en = 1'b0;
        w = 0;                                      // recovery: link must re-lock
        while (!block_locked) begin
            @(negedge pclk);
            if (++w > 8000) $fatal(1, "[RND DATA ERR] FAIL: link did not re-lock after garbage RX");
        end
    endtask

    task automatic ep_stall();                     // sink stall -> rx_overflow -> drain
        int o0, w;
        o0 = ovf_seen;
        sink_stall = 1'b1;
        w = 0;
        while (ovf_seen == o0) begin
            @(negedge pclk);
            if (++w > 8000) $fatal(1, "[RND DATA ERR] FAIL: sink stall did not raise rx_overflow");
        end
        repeat ($urandom_range(20, 120)) @(negedge pclk);
        sink_stall = 1'b0;
        clean_window(8);                            // recovery: traffic resumes
    endtask

    // ---- Main ----
    initial begin
        int nep, w;
        inject_en = 1'b0; inject_data = '0; sink_stall = 1'b0;
        rst_n = 1'b0;
        repeat (6) @(negedge pclk);
        rst_n = 1'b1;

        w = 0;                                      // initial lock
        while (!block_locked) begin
            @(negedge pclk);
            if (++w > 8000) $fatal(1, "[RND DATA ERR] FAIL: never reached initial block lock");
        end
        clean_window(16);                           // clean warmup

        nep = $urandom_range(4, 7);
        for (int ep = 0; ep < nep; ep++) begin
            // guarantee both fault types, randomize the rest
            if      (ep == 0)            ep_garbage();
            else if (ep == 1)            ep_stall();
            else if ($urandom & 1)       ep_garbage();
            else                         ep_stall();
            clean_window(8);                        // clean traffic between faults
        end

        clean_window(16);                           // clean cooldown -- integrity restored

        if (sync_err_seen == 0) $fatal(1, "[RND DATA ERR] FAIL: no sync_error observed");
        if (ovf_seen == 0)      $fatal(1, "[RND DATA ERR] FAIL: no rx_overflow observed");

        $display("[RND DATA ERR] PASS  (seed=%0d episodes=%0d sync_error=%0d rx_overflow=%0d flits_out=%0d)",
                 seed, nep, sync_err_seen, ovf_seen, flits_out);
        $finish;
    end

    initial begin #6000000; $fatal(1, "[RND DATA ERR] FAIL  (global timeout)"); end

endmodule
