
`timescale 1ns/1ps

/**
 * pipe7_pkg -- centralized dimensions and control-plane encodings for the
 * UCIe RDI -> PCIe 6.x / PIPE 7.1 MAC-facing bridge.
 *
 * Single source of truth for geometry (mirrors RTL module parameters).
 *
 * NOTE (closure-plan item 0): the control-plane enum encodings below are
 * WORKING-KNOWLEDGE PLACEHOLDERS. They MUST be reconciled against the
 * controlled Intel PIPE 7.1 specification before they are consumed by the
 * control FSM (item 3) or message bus (item 4). Item 1 does not use them.
 */
package pipe7_pkg;

    // --- Geometry (datapath-only in item 1) ---
    parameter int NUM_LANES       = 4;
    parameter int RDI_DATA_WIDTH  = 16;  // bits per lane on the RDI side
    parameter int PIPE_DATA_WIDTH = 32;  // bits per lane on the PIPE side
    parameter int BUFFER_DEPTH    = 16;  // elastic-buffer entries per lane

    // Packed-bus convenience widths (consumed by the TB/UVM env in later items).
    /* verilator lint_off UNUSEDPARAM */
    parameter int RDI_BUS_WIDTH   = NUM_LANES * RDI_DATA_WIDTH;
    parameter int PIPE_BUS_WIDTH  = NUM_LANES * PIPE_DATA_WIDTH;
    /* verilator lint_on UNUSEDPARAM */

    // --- Placeholder control-plane encodings (item 0 must confirm) ---
    typedef enum logic [1:0] {
        PD_P0  = 2'd0,
        PD_P0S = 2'd1,
        PD_P1  = 2'd2,
        PD_P2  = 2'd3
    } powerdown_e;

    // Gen5 (32 GT/s, 128b/130b) and Gen6 (64 GT/s, PAM4 FLIT) only.
    typedef enum logic [1:0] {
        RATE_GEN5 = 2'd0,
        RATE_GEN6 = 2'd1
    } rate_e;

endpackage
