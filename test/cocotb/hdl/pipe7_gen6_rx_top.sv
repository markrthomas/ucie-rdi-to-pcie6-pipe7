
`timescale 1ns/1ps

/**
 * pipe7_gen6_rx_top -- thin cocotb DUT wrapper for the Gen6-wide RX cross-check
 * (Tier 1b PyUVM, closure-plan item 23; the deferred item-10 Gen6-wide RX follow-on).
 *
 * Wraps pipe7_mac_datapath_ra held in Gen6 data phase (Rate=Gen6, PowerDown=P0, data_enable=1)
 * and exposes only the raw wide RX injection port (rx_data/rx_valid) and the recovered word
 * (g6_rx_data/g6_rx_valid), so the PyUVM env can inject Gen6 raw words and cross-check the
 * recovered stream against an independent Python model. Gen5 inputs and the Gen6 TX payload are
 * tied off (RX-only check). PIPE_WIDTH defaults to the x16 Gen6 wide width (160).
 */
module pipe7_gen6_rx_top
    import pipe7_pkg::*;
#(
    parameter int PIPE_WIDTH = 160
) (
    input  logic                  clk,
    input  logic                  reset_n,

    // Injected raw RX word (env -> datapath)
    input  logic [PIPE_WIDTH-1:0] rx_data,
    input  logic                  rx_valid,

    // Recovered raw word (datapath -> env)
    output logic [PIPE_WIDTH-1:0] g6_rx_data,
    output logic                  g6_rx_valid,
    output logic                  in_data_phase
);

    // Route the rate/power-state constants through explicit 4-bit nets rather than connecting
    // the enum members straight to the ports: Icarus (the independent-engine cross-check, Phase G)
    // sizes a package enum member as 1 bit in a direct port connection and truncates RATE_GEN6
    // (4'd5) to its LSB (=1), so the datapath never enters Gen6 -- an assignment preserves the
    // full 4-bit value in both Icarus and Verilator.
    logic [3:0] rate_sel = RATE_GEN6;
    logic [3:0] pd_sel   = PD_P0;

    pipe7_mac_datapath_ra #(.PIPE_WIDTH(PIPE_WIDTH)) dp (
        .clk, .reset_n,
        .rate(rate_sel), .power_down(pd_sel), .data_enable(1'b1),
        .pam4_restricted_levels('0),
        // Gen5 block inputs unused in Gen6 mode
        .g5_pl_cnt(2'd0), .g5_pl_data0('0), .g5_pl_is_os0(1'b0),
        .g5_pl_data1('0), .g5_pl_is_os1(1'b0), .g5_pl_acc(),
        // Gen6 TX payload off (RX-only)
        .g6_pl_valid(1'b0), .g6_pl_data('0), .g6_pl_ready(),
        // TX outputs unobserved
        .tx_data(), .tx_data_valid(), .tx_elec_idle(),
        // Injected RX
        .rx_data(rx_data), .rx_valid(rx_valid),
        // Gen5 recovered outputs unused
        .g5_rx_cnt(), .g5_rx_data0(), .g5_rx_os0(), .g5_rx_data1(), .g5_rx_os1(),
        // Gen6 recovered word out
        .g6_rx_valid(g6_rx_valid), .g6_rx_data(g6_rx_data),
        .block_locked(), .sync_error(), .in_data_phase(in_data_phase), .pam4_cfg_out()
    );

endmodule
