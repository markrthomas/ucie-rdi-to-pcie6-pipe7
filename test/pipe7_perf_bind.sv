
`timescale 1ns/1ps

/**
 * pipe7_perf_bind -- binds pipe7_perf_monitor (item 36) into every ucie_rdi_to_pipe7_mac_bridge
 * instance in the compilation. The port connections are evaluated in the bridge's scope, so they
 * reach the internal occupancy nets of the sub-instances (ingress/egress/tx_cdc/rx_cdc/rx_burst)
 * and the bridge-level signals -- no RTL change, DV-only. Compile this file (with
 * pipe7_perf_monitor.sv) alongside a bridge testbench to get its [PERF] line.
 */
bind ucie_rdi_to_pipe7_mac_bridge pipe7_perf_monitor #(
    .RDI_WIDTH(RDI_WIDTH), .PIPE_WIDTH(PIPE_WIDTH), .CREDITS(CREDITS),
    .BUF_DEPTH(BUF_DEPTH), .BURST_DEPTH(4), .PCLK_PERIOD_NS(10.0)
) u_perf (
    .pclk(pclk), .rdi_clk(rdi_clk), .rst_n(rst_n),
    // rdi_clk domain
    .rdi_tx_valid(rdi_tx_valid), .rdi_rx_valid(rdi_rx_valid), .ig_blk_ready(ig_blk_ready),
    .ingress_count(ingress.count), .egress_credits(egress.credits),
    .txc_wr_ptr(tx_cdc.wr_ptr), .txc_wr_rd_ptr(tx_cdc.wr_rd_ptr),
    // pclk domain
    .tx_data_valid(tx_data_valid), .rx_overflow(rx_overflow),
    .fifo_count(rx_burst.count),
    .rxc_wr_ptr(rx_cdc.wr_ptr), .rxc_wr_rd_ptr(rx_cdc.wr_rd_ptr)
);
