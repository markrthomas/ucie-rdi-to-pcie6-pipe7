
`timescale 1ns/1ps

/**
 * ucie_rdi_if -- UCIe RDI-side payload interface for the PIPE 7.1 MAC bridge UVM env
 * (closure-plan item 8). Carries the block-payload view the bridge datapath consumes/produces:
 * a 128-bit payload word tagged data vs ordered-set (the Gen5 128b/130b block payload; the
 * Gen6 raw path uses the low bits). The RDI byte/flit gearbox that assembles these payloads is
 * an upstream integration detail (see PLAN.md) -- this interface starts at the assembled
 * payload so the datapath framing round-trip can be driven and checked.
 *
 * valid/ready is a standard handshake; is_os selects the Gen5 sync-header type on TX and
 * reports it on RX. Driver/monitor clocking blocks are excluded from the Verilator lint pass.
 */
interface ucie_rdi_if #(
    parameter int PAYLOAD_WIDTH = 128
) (
    input logic clk,
    input logic rst_n
);
    logic                       valid;
    logic                       ready;
    logic [PAYLOAD_WIDTH-1:0]   data;
    logic                       is_os;   // 1 = ordered-set block, 0 = data block

`ifndef VERILATOR
    // Active driver (RDI source -> bridge).
    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output valid, data, is_os;
        input  ready;
    endclocking

    // Passive monitor.
    clocking mon_cb @(posedge clk);
        default input #1step;
        input valid, ready, data, is_os;
    endclocking
`endif

    modport drv (clocking drv_cb, input clk, rst_n);
    modport mon (clocking mon_cb, input clk, rst_n);

endinterface
