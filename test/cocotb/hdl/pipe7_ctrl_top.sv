
`timescale 1ns/1ps

/**
 * pipe7_ctrl_top -- cocotb DUT wrapper for the control-plane cross-check (item 14). Exposes
 * pipe7_mac_ctrl_fsm's request interface + command outputs, and takes phy_status /
 * pclk_change_ok as top-level inputs so an INDEPENDENT PyUVM PHY-responder agent (not the SV
 * stub) drives the completion handshake. req_kind is a plain 2-bit port cast to ctrl_req_e.
 */
module pipe7_ctrl_top
    import pipe7_pkg::*;
#(
    parameter bit PCLK_IS_PHY_INPUT = 1'b0
) (
    input  logic        clk,
    input  logic        reset_n,

    input  logic        req_valid,
    input  logic [1:0]  req_kind,
    input  logic [3:0]  req_power_down,
    input  logic [3:0]  req_rate,
    input  logic [2:0]  req_width,
    input  logic [2:0]  req_rxwidth,
    output logic        busy,
    output logic        done,
    output logic        req_error,

    output logic [3:0]  power_down,
    output logic [3:0]  rate,
    output logic [2:0]  width,
    output logic [2:0]  rx_width,
    output logic [3:0]  tx_elec_idle,
    output logic        rx_standby,
    output logic        pclk_change_ack,

    input  logic        phy_status,
    input  logic        pclk_change_ok
);

    pipe7_mac_ctrl_fsm #(.PCLK_IS_PHY_INPUT(PCLK_IS_PHY_INPUT)) fsm (
        .pclk(clk), .reset_n,
        .req_valid, .req_kind(ctrl_req_e'(req_kind)),
        .req_power_down, .req_rate, .req_width, .req_rxwidth,
        .busy, .done, .req_error,
        .power_down, .rate, .width, .rx_width, .tx_elec_idle, .rx_standby, .pclk_change_ack,
        .phy_status, .pclk_change_ok
    );

endmodule
