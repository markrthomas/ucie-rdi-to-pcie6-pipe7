
`timescale 1ns/1ps

/**
 * pipe7_perf_monitor -- passive performance-metric collector for the integrated bridge
 * (closure-plan item 36). DV-only: `bind`-attached to ucie_rdi_to_pipe7_mac_bridge so it reaches
 * the internal occupancy nets and the boundary signals without touching the RTL. Prints one
 * machine-readable `[PERF] key=val ...` line at end-of-sim (a `final` block), following the
 * existing `[TAG]` stdout convention so scripts/gen_report.py (item 37) can scrape it.
 *
 * Metrics (all four categories):
 *   - throughput/BW : accepted & recovered RDI flits, PIPE tx beats, TX utilization %, bits/PCLK,
 *                     GT/s-equivalent from the PCLK period.
 *   - latency       : round-trip RDI-in -> RDI-out, min/avg/max (FIFO order, timestamp queue).
 *   - occupancy     : peak ingress/egress/burst-FIFO/CDC occupancy.
 *   - backpressure  : TX-CDC-full stall cycles, RX overflow pulses.
 *
 * Latency/throughput are SIMULATION figures at the smoke operating point, not silicon timing.
 */
module pipe7_perf_monitor #(
    parameter int  RDI_WIDTH      = 64,
    parameter int  PIPE_WIDTH     = 80,
    parameter int  CREDITS        = 8,
    parameter int  BUF_DEPTH      = 8,
    parameter int  BURST_DEPTH    = 4,
    parameter real PCLK_PERIOD_NS = 10.0
) (
    input logic pclk,
    input logic rdi_clk,
    input logic rst_n,

    // ---- rdi_clk domain ----
    input logic                                 rdi_tx_valid,   // 1 accepted TX flit/cycle
    input logic                                 rdi_rx_valid,   // 1 recovered RX flit/cycle
    input logic                                 ig_blk_ready,   // low = TX CDC full (stall)
    input logic [$clog2(CREDITS+1)-1:0]         ingress_count,  // ingress FIFO occupancy (flits)
    input logic [$clog2(2*CREDITS+1)-1:0]       egress_credits, // egress sink credits available
    input logic [$clog2(BUF_DEPTH):0]           txc_wr_ptr,
    input logic [$clog2(BUF_DEPTH):0]           txc_wr_rd_ptr,

    // ---- pclk domain ----
    input logic                                 tx_data_valid,  // PIPE TX beat
    input logic                                 rx_overflow,    // dropped recovered block
    input logic [$clog2(BURST_DEPTH):0]         fifo_count,     // RX burst-FIFO occupancy
    input logic [$clog2(BUF_DEPTH):0]           rxc_wr_ptr,
    input logic [$clog2(BUF_DEPTH):0]           rxc_wr_rd_ptr
);
    // This is a passive DV monitor: blocking assignments in the clocked accumulator processes are
    // intentional (sequential metric accumulation, not synthesizable RTL).
    /* verilator lint_off BLKSEQ */

    // ---- RDI-domain accumulators + latency queue ----
    longint unsigned rdi_flits_in, rdi_flits_out, rdi_cycles, tx_stall_cyc;
    real             lat_pend [$];               // pending in-timestamps (FIFO order)
    real             lat_min, lat_max, lat_sum;
    longint unsigned lat_n;
    int unsigned     ingress_peak, egress_min_credits, txc_occ_peak;

    initial begin
        rdi_flits_in = 0; rdi_flits_out = 0; rdi_cycles = 0; tx_stall_cyc = 0;
        lat_min = 0; lat_max = 0; lat_sum = 0; lat_n = 0;
        ingress_peak = 0; egress_min_credits = CREDITS; txc_occ_peak = 0;
    end

    always @(posedge rdi_clk) if (rst_n) begin
        int unsigned occ;
        rdi_cycles++;
        if (!ig_blk_ready) tx_stall_cyc++;
        if (rdi_tx_valid) begin rdi_flits_in++;  lat_pend.push_back($realtime); end
        if (rdi_rx_valid) begin
            rdi_flits_out++;
            if (lat_pend.size() > 0) begin
                real l; l = $realtime - lat_pend.pop_front();
                if (lat_n == 0 || l < lat_min) lat_min = l;
                if (l > lat_max) lat_max = l;
                lat_sum += l; lat_n++;
            end
        end
        if (int'(ingress_count)  > ingress_peak)       ingress_peak = int'(ingress_count);
        if (int'(egress_credits) < egress_min_credits) egress_min_credits = int'(egress_credits);
        occ = int'((txc_wr_ptr - txc_wr_rd_ptr));
        if (occ > txc_occ_peak) txc_occ_peak = occ;
    end

    // ---- PCLK-domain accumulators ----
    longint unsigned pclk_cycles, tx_beats, rx_overflow_cnt;
    int unsigned     fifo_peak, rxc_occ_peak;

    initial begin
        pclk_cycles = 0; tx_beats = 0; rx_overflow_cnt = 0; fifo_peak = 0; rxc_occ_peak = 0;
    end

    always @(posedge pclk) if (rst_n) begin
        int unsigned occ;
        pclk_cycles++;
        if (tx_data_valid) tx_beats++;
        if (rx_overflow)   rx_overflow_cnt++;
        if (int'(fifo_count) > fifo_peak) fifo_peak = int'(fifo_count);
        occ = int'((rxc_wr_ptr - rxc_wr_rd_ptr));
        if (occ > rxc_occ_peak) rxc_occ_peak = occ;
    end

    // ---- Emit one machine-readable line at end of sim ----
    final begin
        real tx_util_pct, bits_per_pclk, gbps, lat_avg;
        tx_util_pct   = (pclk_cycles == 0) ? 0.0 : 100.0 * real'(tx_beats) / real'(pclk_cycles);
        bits_per_pclk = (pclk_cycles == 0) ? 0.0 :
                        real'(rdi_flits_out) * real'(RDI_WIDTH) / real'(pclk_cycles);
        gbps          = bits_per_pclk / PCLK_PERIOD_NS;                 // bits/ns == Gbit/s
        lat_avg       = (lat_n == 0) ? 0.0 : lat_sum / real'(lat_n);
        // One line, built from $write pieces (Verilator does not apply %-formats to a
        // brace-concatenated format string).
        $write("[PERF] pipe_width=%0d rdi_width=%0d flits_in=%0d flits_out=%0d ",
               PIPE_WIDTH, RDI_WIDTH, rdi_flits_in, rdi_flits_out);
        $write("tx_beats=%0d tx_util_pct=%0.1f bits_per_pclk=%0.2f gbps_eff=%0.2f ",
               tx_beats, tx_util_pct, bits_per_pclk, gbps);
        $write("lat_ns_min=%0.1f lat_ns_avg=%0.1f lat_ns_max=%0.1f ",
               lat_min, lat_avg, lat_max);
        $write("ingress_peak=%0d egress_peak_outstanding=%0d burst_fifo_peak=%0d ",
               ingress_peak, (CREDITS - egress_min_credits), fifo_peak);
        $write("txc_occ_peak=%0d rxc_occ_peak=%0d tx_stall_cyc=%0d rx_overflow=%0d ",
               txc_occ_peak, rxc_occ_peak, tx_stall_cyc, rx_overflow_cnt);
        $display("pclk_cycles=%0d rdi_cycles=%0d", pclk_cycles, rdi_cycles);
    end
    /* verilator lint_on BLKSEQ */
endmodule
