
`timescale 1ns/1ps

/**
 * tb_pipe7_mac_bridge -- item 1 datapath-only smoke.
 *
 * Clocks/reset are driven externally by sim_main.cpp (Verilator ignores #
 * delays), so stimulus is event-driven off the two clocks. This is a
 * liveness + basic transport check for the pass-through bridge:
 *   - a TX beat driven on RDI lane 0 must appear on PIPE TX lane 0 with the
 *     RDI payload in the low bits and the upper bits zero-extended;
 *   - a PIPE RX beat driven on lane 0 must emerge on RDI RX lane 0 (low bits).
 * A watchdog checks both were observed and prints [SMOKE] PASS/FAIL.
 */
module tb_pipe7_mac_bridge (
    // Clocks/reset are top-level inputs driven by sim_main.cpp.
    input logic rst_n,
    input logic rdi_clk,
    input logic pclk
);

    localparam int NUM_LANES       = 4;
    localparam int RDI_DATA_WIDTH  = 16;
    localparam int PIPE_DATA_WIDTH = 32;

    localparam logic [RDI_DATA_WIDTH-1:0]  TX_PAYLOAD = 16'hABCD;
    localparam logic [PIPE_DATA_WIDTH-1:0] RX_PAYLOAD = 32'h0000_BEEF;

    // RDI TX
    logic [NUM_LANES-1:0]                 rdi_valid;
    logic [NUM_LANES-1:0]                 rdi_ready;
    logic [NUM_LANES*RDI_DATA_WIDTH-1:0]  rdi_data;
    logic [NUM_LANES-1:0]                 rdi_error;
    logic [NUM_LANES-1:0]                 rdi_flow_ctrl;

    // PIPE TX
    logic [NUM_LANES-1:0]                 pipe_tx_valid;
    logic [NUM_LANES-1:0]                 pipe_tx_ready;
    logic [NUM_LANES*PIPE_DATA_WIDTH-1:0] pipe_tx_data;
    logic [NUM_LANES-1:0]                 pipe_tx_error;

    // PIPE RX
    logic [NUM_LANES-1:0]                 pipe_rx_valid;
    logic [NUM_LANES-1:0]                 pipe_rx_ready;
    logic [NUM_LANES*PIPE_DATA_WIDTH-1:0] pipe_rx_data;
    logic [NUM_LANES-1:0]                 pipe_rx_error;

    // RDI RX
    logic [NUM_LANES-1:0]                 rdi_rx_valid;
    logic [NUM_LANES-1:0]                 rdi_rx_ready;
    logic [NUM_LANES*RDI_DATA_WIDTH-1:0]  rdi_rx_data;
    logic [NUM_LANES-1:0]                 rdi_rx_error;

    ucie_rdi_to_pipe7_mac_bridge #(
        .NUM_LANES      (NUM_LANES),
        .RDI_DATA_WIDTH (RDI_DATA_WIDTH),
        .PIPE_DATA_WIDTH(PIPE_DATA_WIDTH)
    ) dut (
        .rst_n        (rst_n),
        .rdi_clk      (rdi_clk),
        .pclk         (pclk),
        .rdi_valid    (rdi_valid),
        .rdi_ready    (rdi_ready),
        .rdi_data     (rdi_data),
        .rdi_error    (rdi_error),
        .rdi_flow_ctrl(rdi_flow_ctrl),
        .pipe_tx_valid(pipe_tx_valid),
        .pipe_tx_ready(pipe_tx_ready),
        .pipe_tx_data (pipe_tx_data),
        .pipe_tx_error(pipe_tx_error),
        .pipe_rx_valid(pipe_rx_valid),
        .pipe_rx_ready(pipe_rx_ready),
        .pipe_rx_data (pipe_rx_data),
        .pipe_rx_error(pipe_rx_error),
        .rdi_rx_valid (rdi_rx_valid),
        .rdi_rx_ready (rdi_rx_ready),
        .rdi_rx_data  (rdi_rx_data),
        .rdi_rx_error (rdi_rx_error)
    );

    // Observation flags
    bit saw_tx;
    bit saw_rx;
    bit tx_bad;
    bit rx_bad;

    integer rdi_cycle;
    integer pclk_cycle;

    // --- RDI-domain stimulus: drive one lane-0 TX beat, sink RDI RX ---
    always_ff @(posedge rdi_clk or negedge rst_n) begin
        if (!rst_n) begin
            rdi_cycle    <= 0;
            rdi_valid    <= '0;
            rdi_data     <= '0;
            rdi_error    <= '0;
            rdi_rx_ready <= '1;   // always accept RX egress
        end else begin
            rdi_cycle <= rdi_cycle + 1;

            // Present a single lane-0 beat around cycle 5 and hold until accepted.
            if (rdi_cycle == 5) begin
                rdi_valid <= 4'b0001;
                rdi_data  <= {{(NUM_LANES-1)*RDI_DATA_WIDTH{1'b0}}, TX_PAYLOAD};
            end
            if (rdi_valid[0] && rdi_ready[0]) begin
                rdi_valid <= '0;  // beat accepted; deassert
            end

            // Check RDI RX egress on lane 0.
            if (rdi_rx_valid[0] && rdi_rx_ready[0]) begin
                saw_rx <= 1'b1;
                if (rdi_rx_data[0 +: RDI_DATA_WIDTH] !== RX_PAYLOAD[RDI_DATA_WIDTH-1:0])
                    rx_bad <= 1'b1;
            end

            // Watchdog / verdict.
            if (rdi_cycle == 400) begin
                if (saw_tx && saw_rx && !tx_bad && !rx_bad)
                    $display("[SMOKE] PASS  (tx=%0d rx=%0d @ rdi_cycle=%0d)",
                             saw_tx, saw_rx, rdi_cycle);
                else
                    $display("[SMOKE] FAIL  saw_tx=%0d saw_rx=%0d tx_bad=%0d rx_bad=%0d",
                             saw_tx, saw_rx, tx_bad, rx_bad);
                $finish;
            end
        end
    end

    // --- PCLK-domain stimulus: accept PIPE TX, drive one PIPE RX beat ---
    always_ff @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            pclk_cycle    <= 0;
            pipe_tx_ready <= '1;   // always accept TX toward PHY
            pipe_rx_valid <= '0;
            pipe_rx_data  <= '0;
            pipe_rx_error <= '0;
        end else begin
            pclk_cycle <= pclk_cycle + 1;

            // Observe PIPE TX lane 0.
            if (pipe_tx_valid[0] && pipe_tx_ready[0]) begin
                saw_tx <= 1'b1;
                if (pipe_tx_data[0 +: RDI_DATA_WIDTH] !== TX_PAYLOAD)
                    tx_bad <= 1'b1;
                if (pipe_tx_data[RDI_DATA_WIDTH +: (PIPE_DATA_WIDTH-RDI_DATA_WIDTH)] !== '0)
                    tx_bad <= 1'b1;  // upper bits must be zero-extended
            end

            // Drive a single lane-0 RX beat around cycle 8, hold until accepted.
            if (pclk_cycle == 8) begin
                pipe_rx_valid <= 4'b0001;
                pipe_rx_data  <= {{(NUM_LANES-1)*PIPE_DATA_WIDTH{1'b0}}, RX_PAYLOAD};
            end
            if (pipe_rx_valid[0] && pipe_rx_ready[0]) begin
                pipe_rx_valid <= '0;
            end
        end
    end

endmodule
