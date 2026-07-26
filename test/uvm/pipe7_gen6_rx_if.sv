
`timescale 1ns/1ps

/**
 * pipe7_gen6_rx_if -- Gen6 raw wide RX interface for the PIPE 7.1 MAC bridge UVM env
 * (closure-plan item 22, the deferred item-10 Gen6-wide RX follow-on).
 *
 * The integrated bridge's data plane is the single-block Gen5 path, so the Gen6-wide RX
 * cross-check runs against an auxiliary rate-aware datapath (`pipe7_mac_datapath_ra`) held in
 * Gen6 data phase. This interface carries the PHY->MAC raw RX word the env injects
 * (`rx_data`/`rx_valid`) and the datapath's recovered raw word (`g6_rx_data`/`g6_rx_valid`)
 * the monitor samples for the mirrored-queue scoreboard.
 *
 * Clocking blocks are excluded from the Verilator lint pass (validated by review under VCS).
 */
interface pipe7_gen6_rx_if #(
    parameter int WIDTH = 160
) (
    input logic clk,
    input logic rst_n
);
    // Env -> datapath: injected raw RX word.
    logic [WIDTH-1:0] rx_data;
    logic             rx_valid;
    // Datapath -> env: recovered raw word.
    logic [WIDTH-1:0] g6_rx_data;
    logic             g6_rx_valid;

`ifndef VERILATOR
    // RX injector: drives rx_data/rx_valid.
    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output rx_data, rx_valid;
        input  g6_rx_data, g6_rx_valid;
    endclocking

    // Passive monitor of the recovered word.
    clocking mon_cb @(posedge clk);
        default input #1step;
        input rx_data, rx_valid, g6_rx_data, g6_rx_valid;
    endclocking
`endif

    modport drv (clocking drv_cb, input clk, rst_n);
    modport mon (clocking mon_cb, input clk, rst_n);

endinterface
