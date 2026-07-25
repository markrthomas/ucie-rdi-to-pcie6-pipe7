
`timescale 1ns/1ps

/**
 * pipe7_msgbus_if -- controller-side request/response interface for pipe7_msgbus_master
 * (closure-plan item 10). The UVM message-bus agent drives register read/write requests and
 * samples the master's response (rsp_valid / rsp_is_read / rsp_rdata). Clocking blocks are
 * excluded from the Verilator lint pass.
 */
interface pipe7_msgbus_if #(
    parameter int ADDR_WIDTH = 12,
    parameter int DATA_WIDTH = 8
) (
    input logic clk,
    input logic rst_n
);
    logic                  req_valid;
    logic                  req_write;
    logic                  req_committed;
    logic [ADDR_WIDTH-1:0] req_addr;
    logic [DATA_WIDTH-1:0] req_wdata;
    logic                  req_ready;
    logic                  busy;
    logic                  rsp_valid;
    logic                  rsp_is_read;
    logic [DATA_WIDTH-1:0] rsp_rdata;
    logic                  rsp_error;

`ifndef VERILATOR
    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output req_valid, req_write, req_committed, req_addr, req_wdata;
        input  req_ready, busy, rsp_valid, rsp_is_read, rsp_rdata, rsp_error;
    endclocking

    clocking mon_cb @(posedge clk);
        default input #1step;
        input req_valid, req_write, req_committed, req_addr, req_wdata,
              req_ready, busy, rsp_valid, rsp_is_read, rsp_rdata, rsp_error;
    endclocking
`endif

    modport drv (clocking drv_cb, input clk, rst_n);
    modport mon (clocking mon_cb, input clk, rst_n);

endinterface
