
`timescale 1ns/1ps

/**
 * pipe7_ctrl_if -- controller-side request/status interface for pipe7_mac_ctrl_fsm
 * (closure-plan item 9). The UVM control agent drives PowerDown/Rate/Width requests and
 * samples the FSM's busy/done/req_error status; the resulting PIPE command state is read from
 * pipe7_mac_if. Clocking blocks are excluded from the Verilator lint pass.
 */
interface pipe7_ctrl_if (
    input logic clk,
    input logic rst_n
);
    logic       req_valid;
    logic [1:0] req_kind;
    logic [3:0] req_power_down;
    logic [3:0] req_rate;
    logic [2:0] req_width;
    logic [2:0] req_rxwidth;
    logic       busy;
    logic       done;
    logic       req_error;

`ifndef VERILATOR
    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output req_valid, req_kind, req_power_down, req_rate, req_width, req_rxwidth;
        input  busy, done, req_error;
    endclocking

    clocking mon_cb @(posedge clk);
        default input #1step;
        input req_valid, req_kind, req_power_down, req_rate, req_width, req_rxwidth,
              busy, done, req_error;
    endclocking
`endif

    modport drv (clocking drv_cb, input clk, rst_n);
    modport mon (clocking mon_cb, input clk, rst_n);

endinterface
