
`timescale 1ns/1ps

/**
 * ucie_rdi_if -- UCIe RDI-side flit interface for the PIPE 7.1 MAC bridge UVM env.
 *
 * Retargeted at the integrated bridge (closure-plan item 22): the front end is now a fuller,
 * credit-based UCIe RDI. Each beat is an RDI_WIDTH-bit flit carrying a start-of-block marker
 * (`sob`, high on the first flit of a 128b/130b block) and the block's data/ordered-set tag
 * (`is_os`). Flow control is credit-based, not ready/valid: the sink returns `crd` credits (0..2
 * per cycle) and the source may drive `valid` only while it holds a credit.
 *
 * The same interface type is reused for the TX stream (env drives valid/data/sob/is_os, samples
 * the bridge's returned `crd`) and the RX stream (env samples the bridge's recovered
 * valid/data/sob/is_os, drives `crd` back). Clocking blocks are excluded from the Verilator
 * lint pass and validated by review under VCS.
 */
interface ucie_rdi_if #(
    parameter int RDI_WIDTH = 64
) (
    input logic clk,       // RDI clock domain (rdi_clk)
    input logic rst_n
);
    logic                   valid;
    logic [RDI_WIDTH-1:0]   data;
    logic                   sob;     // start-of-block: first flit of a 128b/130b block
    logic                   is_os;   // 1 = ordered-set block, 0 = data block
    logic [1:0]             crd;     // credit return (source: input; sink: output)

`ifndef VERILATOR
    // Active source (RDI TX driver -> bridge): drives flits, consumes returned credits.
    clocking src_cb @(posedge clk);
        default input #1step output #1;
        output valid, data, sob, is_os;
        input  crd;
    endclocking

    // Active sink (env -> bridge RX): drives credit return, samples recovered flits.
    clocking snk_cb @(posedge clk);
        default input #1step output #1;
        output crd;
        input  valid, data, sob, is_os;
    endclocking

    // Passive monitor.
    clocking mon_cb @(posedge clk);
        default input #1step;
        input valid, data, sob, is_os, crd;
    endclocking
`endif

    modport src (clocking src_cb, input clk, rst_n);
    modport snk (clocking snk_cb, input clk, rst_n);
    modport mon (clocking mon_cb, input clk, rst_n);

endinterface
