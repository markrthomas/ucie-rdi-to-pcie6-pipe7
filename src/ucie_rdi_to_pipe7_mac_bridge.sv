
`timescale 1ns/1ps

/**
 * ucie_rdi_to_pipe7_mac_bridge -- UCIe 1.0 RDI <-> PCIe 6.x / PIPE 7.1
 * MAC-facing bridge.
 *
 * CLOSURE-PLAN ITEM 1 SCOPE: datapath-only pass-through.
 * This revision instantiates the dual-clock elastic buffers in both
 * directions and presents a plain per-lane valid/ready datapath on the PIPE
 * side. It is the CDC/skeleton baseline ONLY -- it deliberately does NOT yet
 * implement the real PIPE 7.1 MAC control plane:
 *   - PowerDown/Rate/Width request FSM gated on PhyStatus   (item 3)
 *   - M2P/P2M message-bus master                            (item 4)
 *   - Gen5 128b/130b framing / Gen6 PAM4 FLIT framing        (items 5-6)
 * Those ports/behaviors are added in later closure-plan items. See PLAN.md.
 */
module ucie_rdi_to_pipe7_mac_bridge #(
    parameter int NUM_LANES       = pipe7_pkg::NUM_LANES,
    parameter int RDI_DATA_WIDTH  = pipe7_pkg::RDI_DATA_WIDTH,
    parameter int PIPE_DATA_WIDTH = pipe7_pkg::PIPE_DATA_WIDTH,
    parameter int BUFFER_DEPTH    = pipe7_pkg::BUFFER_DEPTH
) (
    input  logic                                 rst_n,
    input  logic                                 rdi_clk,
    input  logic                                 pclk,       // PIPE PCLK domain

    // RDI TX interface (RDI -> Bridge -> PIPE)
    input  logic [NUM_LANES-1:0]                 rdi_valid,
    output logic [NUM_LANES-1:0]                 rdi_ready,
    input  logic [NUM_LANES*RDI_DATA_WIDTH-1:0]  rdi_data,
    input  logic [NUM_LANES-1:0]                 rdi_error,
    output logic [NUM_LANES-1:0]                 rdi_flow_ctrl,

    // PIPE TX datapath toward PHY (pass-through in item 1)
    output logic [NUM_LANES-1:0]                 pipe_tx_valid,
    input  logic [NUM_LANES-1:0]                 pipe_tx_ready,
    output logic [NUM_LANES*PIPE_DATA_WIDTH-1:0] pipe_tx_data,
    output logic [NUM_LANES-1:0]                 pipe_tx_error,

    // PIPE RX datapath from PHY (pass-through in item 1)
    input  logic [NUM_LANES-1:0]                 pipe_rx_valid,
    output logic [NUM_LANES-1:0]                 pipe_rx_ready,
    input  logic [NUM_LANES*PIPE_DATA_WIDTH-1:0] pipe_rx_data,
    input  logic [NUM_LANES-1:0]                 pipe_rx_error,

    // RDI RX interface (PIPE -> Bridge -> RDI)
    output logic [NUM_LANES-1:0]                 rdi_rx_valid,
    input  logic [NUM_LANES-1:0]                 rdi_rx_ready,
    output logic [NUM_LANES*RDI_DATA_WIDTH-1:0]  rdi_rx_data,
    output logic [NUM_LANES-1:0]                 rdi_rx_error
);

    genvar lane;
    generate
        for (lane = 0; lane < NUM_LANES; lane++) begin : BRIDGE_LANE

            // --- Transmit path (RDI -> PIPE) ---
            logic tx_full;
            assign rdi_flow_ctrl[lane] = tx_full;

            pipe7_cdc_elastic_buf #(
                .INPUT_DATA_WIDTH (RDI_DATA_WIDTH),
                .OUTPUT_DATA_WIDTH(PIPE_DATA_WIDTH),
                .BUFFER_DEPTH     (BUFFER_DEPTH)
            ) tx_buf (
                .rst_n   (rst_n),
                .wr_clk  (rdi_clk),
                .wr_valid(rdi_valid[lane]),
                .wr_ready(rdi_ready[lane]),
                .wr_data (rdi_data[lane*RDI_DATA_WIDTH +: RDI_DATA_WIDTH]),
                .wr_error(rdi_error[lane]),
                .wr_full (tx_full),
                .rd_clk  (pclk),
                .rd_valid(pipe_tx_valid[lane]),
                .rd_ready(pipe_tx_ready[lane]),
                .rd_data (pipe_tx_data[lane*PIPE_DATA_WIDTH +: PIPE_DATA_WIDTH]),
                .rd_error(pipe_tx_error[lane])
            );

            // --- Receive path (PIPE -> RDI) ---
            /* verilator lint_off UNUSEDSIGNAL */
            logic rx_full;
            /* verilator lint_on UNUSEDSIGNAL */

            pipe7_cdc_elastic_buf #(
                .INPUT_DATA_WIDTH (PIPE_DATA_WIDTH),
                .OUTPUT_DATA_WIDTH(RDI_DATA_WIDTH),
                .BUFFER_DEPTH     (BUFFER_DEPTH)
            ) rx_buf (
                .rst_n   (rst_n),
                .wr_clk  (pclk),
                .wr_valid(pipe_rx_valid[lane]),
                .wr_ready(pipe_rx_ready[lane]), // real backpressure to PHY
                .wr_data (pipe_rx_data[lane*PIPE_DATA_WIDTH +: PIPE_DATA_WIDTH]),
                .wr_error(pipe_rx_error[lane]),
                .wr_full (rx_full),
                .rd_clk  (rdi_clk),
                .rd_valid(rdi_rx_valid[lane]),
                .rd_ready(rdi_rx_ready[lane]),
                .rd_data (rdi_rx_data[lane*RDI_DATA_WIDTH +: RDI_DATA_WIDTH]),
                .rd_error(rdi_rx_error[lane])
            );

        end : BRIDGE_LANE
    endgenerate

endmodule
