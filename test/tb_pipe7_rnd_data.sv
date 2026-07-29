
`timescale 1ns/1ps

/**
 * tb_pipe7_rnd_data -- RANDOMIZED data test for the integrated bridge (Phase G, item 46).
 * Self-clocking; built with `verilator --binary --timing --assert`. Waveform-viewable
 * (`make waves|gtkwave WAVE_TB=rnd_data`).
 *
 * A seeded random RDI flit stream (random data, random is_os, random inter-flit gaps / credit
 * backpressure) is driven through ucie_rdi_to_pipe7_mac_bridge against a clean PHY loopback and
 * checked bit-exact, in order, on the RDI RX side. No errors are injected -- this is the "golden"
 * data path under random traffic. Seed via `+seed=N` (default 0xC0FFEE) for reproducible sweeps.
 * Prints [RND DATA] PASS / FAIL.
 */
module tb_pipe7_rnd_data;
    import pipe7_pkg::*;

    localparam int PIPE_WIDTH = 80;
    localparam int RDI_WIDTH  = 64;
    localparam int CREDITS    = 8;
    localparam int FPB        = BLOCK_PAYLOAD / RDI_WIDTH;   // flits per 128b block (=2)
    localparam int FLUSH      = 6;                           // trailing filler blocks
    localparam int TOTAL_MAX  = 90;
    localparam int FLITS_MAX  = TOTAL_MAX * FPB;

    // ---- seed ----
    int unsigned seed;
    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 32'h00C0FFEE;
        void'($urandom(seed));
        $display("[RND DATA] seed=%0d", seed);
    end

    logic pclk, rdi_clk, rst_n;
    initial pclk = 1'b0;
    initial rdi_clk = 1'b0;
    always #5 pclk = ~pclk;       // 100 MHz
    always #7 rdi_clk = ~rdi_clk; // ~71 MHz

`ifdef ENABLE_WAVES
    initial begin
        string wf;
        if ($value$plusargs("wavefile=%s", wf)) $dumpfile(wf); else $dumpfile("waves.vcd");
        $dumpvars(0, tb_pipe7_rnd_data);
    end
`endif

    // ---- randomized golden RDI flit stream ----
    logic [RDI_WIDTH-1:0] in_data [FLITS_MAX];
    logic                 in_sob  [FLITS_MAX];
    logic                 in_os   [FLITS_MAX];
    int nblk, total, flits_chk, flits_all;
    initial begin
        nblk      = $urandom_range(40, 80);   // real blocks to check
        total     = nblk + FLUSH;
        flits_chk = nblk  * FPB;
        flits_all = total * FPB;
        for (int k = 0; k < total; k++) begin
            logic o; o = $urandom & 1;
            in_data[2*k]   = {$urandom, $urandom}; in_sob[2*k]   = 1'b1; in_os[2*k]   = o;
            in_data[2*k+1] = {$urandom, $urandom}; in_sob[2*k+1] = 1'b0; in_os[2*k+1] = o;
        end
    end

    // ---- DUT signals ----
    logic [RDI_WIDTH-1:0] rdi_tx_data, rdi_rx_data;
    logic                 rdi_tx_valid, rdi_tx_sob, rdi_tx_is_os;
    logic [1:0]           rdi_tx_crd, rdi_rx_crd;
    logic                 rdi_rx_valid, rdi_rx_sob, rdi_rx_is_os;
    logic [PIPE_WIDTH-1:0] tx_data, rx_data;
    logic                 tx_data_valid, rx_valid;
    logic [3:0]           tx_elec_idle, power_down, rate;
    logic [2:0]           width, rx_width;
    logic                 rx_standby, pclk_change_ack, phy_status, pclk_change_ok;
    logic [MB_BUS_WIDTH-1:0] m2p, p2m;
    logic                 block_locked, sync_error, in_data_phase, rx_overflow;
    logic                 busy, done, req_error;
    logic                 mb_req_ready, mb_busy, mb_rsp_valid, mb_rsp_is_read, mb_rsp_error;
    logic [MB_DATA_WIDTH-1:0] mb_rsp_rdata;

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
        .rx_data, .rx_valid, .phy_status, .pclk_change_ok, .p2m_message_bus(p2m),
        .block_locked, .sync_error, .in_data_phase, .rx_overflow
    );

    // Clean-loopback data test: a recovered block must never be dropped (RX CDC full).
    property p_no_rx_overflow;
        @(posedge pclk) disable iff (!rst_n) (rx_overflow == 1'b0);
    endproperty
    a_no_rx_overflow: assert property (p_no_rx_overflow)
        else $error("[RND DATA] RX overflow: a recovered block was dropped");

    // PHY loopback + responders (idle control/msgbus).
    assign rx_data  = tx_data;
    assign rx_valid = tx_data_valid;
    pipe7_phy_responder_stub #(.LATENCY(4)) phy (
        .pclk, .reset_n(rst_n), .power_down, .rate, .width, .rx_width,
        .pclk_change_ack, .phy_status, .pclk_change_ok
    );
    pipe7_msgbus_responder_stub #(.RC_LATENCY(3), .MEM_BITS(4)) mbresp (.pclk, .reset_n(rst_n), .m2p, .p2m);

    // Item-7 assertions bound (active in every random run).
    pipe7_mac_bridge_assertions #(.PHYSTATUS_MAX_LATENCY(64)) assn_chk (
        .clk(pclk), .reset_n(rst_n),
        .tx_data_valid, .tx_elec_idle, .power_down, .rate,
        .ctrl_busy(busy), .phy_status, .sync_error
    );

    // ---- RDI credit-tracking source with random bubbles ----
    int  avail, sent;
    logic send_en;
    wire can_send = (avail > 0) && (sent < flits_all) && rst_n && send_en;
    assign rdi_tx_valid = can_send;
    assign rdi_tx_data  = in_data[(sent < flits_all) ? sent : flits_all-1];
    assign rdi_tx_sob   = in_sob [(sent < flits_all) ? sent : flits_all-1];
    assign rdi_tx_is_os = in_os  [(sent < flits_all) ? sent : flits_all-1];
    always_ff @(posedge rdi_clk or negedge rst_n)
        if (!rst_n) begin avail <= CREDITS; sent <= 0; send_en <= 1'b1; end
        else begin
            if (can_send) sent <= sent + 1;
            avail   <= avail - (can_send ? 1 : 0) + int'(rdi_tx_crd);
            send_en <= ($urandom_range(0, 3) != 0);   // ~75% duty -> random inter-flit gaps
        end

    // ---- RDI sink: return a credit per consumed flit; check the round-trip in order ----
    int recv, rdi_errors;
    always_ff @(posedge rdi_clk or negedge rst_n) begin
        if (!rst_n) begin rdi_rx_crd <= 2'd0; recv <= 0; rdi_errors <= 0; end
        else begin
            rdi_rx_crd <= {1'b0, rdi_rx_valid};
            if (rdi_rx_valid && recv < flits_all) begin
                if (rdi_rx_data !== in_data[recv] || rdi_rx_sob !== in_sob[recv] || rdi_rx_is_os !== in_os[recv])
                    rdi_errors <= rdi_errors + 1;
                recv <= recv + 1;
            end
        end
    end

    // ---- Main ----
    initial begin
        int w;
        rst_n = 1'b0;
        repeat (6) @(negedge pclk);
        rst_n = 1'b1;

        // Bounded, fail-fast wait for the checked flits to round-trip.
        w = 0;
        while (recv < flits_chk) begin
            @(negedge rdi_clk);
            if (++w > 200000)
                $fatal(1, "[RND DATA] FAIL: stalled at recv=%0d/%0d (sent=%0d avail=%0d locked=%0b) -- data did not round-trip",
                       recv, flits_chk, sent, avail, block_locked);
        end

        if (rdi_errors != 0)
            $fatal(1, "[RND DATA] FAIL: %0d flit mismatch(es) over %0d checked flits (seed=%0d)", rdi_errors, flits_chk, seed);

        $display("[RND DATA] PASS  (seed=%0d blocks=%0d flits=%0d locked=%0b)", seed, nblk, flits_chk, block_locked);
        $finish;
    end

    initial begin #4000000; $fatal(1, "[RND DATA] FAIL  (global timeout recv=%0d)", recv); end

endmodule
