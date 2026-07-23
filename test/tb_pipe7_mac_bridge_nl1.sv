
`timescale 1ns/1ps

/**
 * tb_pipe7_mac_bridge_nl1 -- NUM_LANES=1 parameter smoke.
 * Verifies the pass-through bridge elaborates and transports one beat at the
 * minimum lane width. Clocks/reset are driven by sim_main_nl1.cpp.
 */
module tb_pipe7_mac_bridge_nl1 (
    // Clocks/reset are top-level inputs driven by sim_main_nl1.cpp.
    input logic rst_n,
    input logic rdi_clk,
    input logic pclk
);

    localparam int NUM_LANES       = 1;
    localparam int RDI_DATA_WIDTH  = 16;
    localparam int PIPE_DATA_WIDTH = 32;

    localparam logic [RDI_DATA_WIDTH-1:0] TX_PAYLOAD = 16'h1234;

    logic [NUM_LANES-1:0]                 rdi_valid;
    logic [NUM_LANES-1:0]                 rdi_ready;
    logic [NUM_LANES*RDI_DATA_WIDTH-1:0]  rdi_data;
    logic [NUM_LANES-1:0]                 rdi_error;
    logic [NUM_LANES-1:0]                 rdi_flow_ctrl;

    logic [NUM_LANES-1:0]                 pipe_tx_valid;
    logic [NUM_LANES-1:0]                 pipe_tx_ready;
    logic [NUM_LANES*PIPE_DATA_WIDTH-1:0] pipe_tx_data;
    logic [NUM_LANES-1:0]                 pipe_tx_error;

    logic [NUM_LANES-1:0]                 pipe_rx_valid;
    logic [NUM_LANES-1:0]                 pipe_rx_ready;
    logic [NUM_LANES*PIPE_DATA_WIDTH-1:0] pipe_rx_data;
    logic [NUM_LANES-1:0]                 pipe_rx_error;

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

    bit saw_tx;
    bit tx_bad;
    integer rdi_cycle;

    always_ff @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            pipe_tx_ready <= '1;
            pipe_rx_valid <= '0;
            pipe_rx_data  <= '0;
            pipe_rx_error <= '0;
        end else begin
            if (pipe_tx_valid[0] && pipe_tx_ready[0]) begin
                saw_tx <= 1'b1;
                if (pipe_tx_data[0 +: RDI_DATA_WIDTH] !== TX_PAYLOAD)
                    tx_bad <= 1'b1;
            end
        end
    end

    always_ff @(posedge rdi_clk or negedge rst_n) begin
        if (!rst_n) begin
            rdi_cycle    <= 0;
            rdi_valid    <= '0;
            rdi_data     <= '0;
            rdi_error    <= '0;
            rdi_rx_ready <= '1;
        end else begin
            rdi_cycle <= rdi_cycle + 1;
            if (rdi_cycle == 5) begin
                rdi_valid <= 1'b1;
                rdi_data  <= TX_PAYLOAD;
            end
            if (rdi_valid[0] && rdi_ready[0])
                rdi_valid <= '0;

            if (rdi_cycle == 280) begin
                if (saw_tx && !tx_bad)
                    $display("[SMOKE NL1] PASS  (saw_tx=%0d @ rdi_cycle=%0d)", saw_tx, rdi_cycle);
                else
                    $display("[SMOKE NL1] FAIL  saw_tx=%0d tx_bad=%0d", saw_tx, tx_bad);
                $finish;
            end
        end
    end

endmodule
