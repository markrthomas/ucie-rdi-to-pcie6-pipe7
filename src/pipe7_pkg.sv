
`timescale 1ns/1ps

/**
 * pipe7_pkg -- centralized dimensions and control-plane encodings for the
 * UCIe RDI -> PCIe 6.x / PIPE 7.1 MAC-facing bridge.
 *
 * Single source of truth for geometry (mirrors RTL module parameters).
 *
 * CONTROL-PLANE ENCODINGS: confirmed vs the controlled spec in closure-plan
 * item 0 -- Intel "PHY Interface for the PCI Express, SATA, USB 3.2,
 * DisplayPort, and USB4 Architectures", Reference Number 643108, Revision 7.1
 * (Sep 2025). See docs/pipe71_spec_crosscheck.md for the row-by-row
 * reconciliation and section refs. Widths/encodings below are spec-accurate;
 * message-bus opcode/address and register-map constants are added in item 4.
 */
package pipe7_pkg;

    // --- Geometry ---
    // NOTE: In the SerDes architecture the PIPE parallel datapath width is set
    // by Width/RxWidth (10/20/40/80/160 bits, PCIe) x PCLK rate -- NOT a fixed
    // 32. PIPE_DATA_WIDTH below remains the item-1 pass-through placeholder for
    // the datapath-only smoke build; item 5/6 re-derive per-lane width from
    // width_e/rxwidth_e. (crosscheck E1/F1/E10)
    parameter int NUM_LANES       = 4;
    parameter int RDI_DATA_WIDTH  = 16;  // bits per lane on the RDI side
    parameter int PIPE_DATA_WIDTH = 32;  // item-1 pass-through placeholder (see note)
    parameter int BUFFER_DEPTH    = 16;  // elastic-buffer entries per lane

    // Packed-bus convenience widths (consumed by the TB/UVM env in later items).
    /* verilator lint_off UNUSEDPARAM */
    parameter int RDI_BUS_WIDTH   = NUM_LANES * RDI_DATA_WIDTH;
    parameter int PIPE_BUS_WIDTH  = NUM_LANES * PIPE_DATA_WIDTH;
    /* verilator lint_on UNUSEDPARAM */

    // --- PowerDown[3:0] (PIPE 7.1 Table 6-5, PCIe mode). 4-bit field.
    //     0..3 legacy P-states; 4..15 PHY-specific (L1 substates). (crosscheck C1/C2)
    typedef enum logic [3:0] {
        PD_P0  = 4'h0,  // normal operation
        PD_P0S = 4'h1,  // low recovery-time latency, power saving
        PD_P1  = 4'h2,  // longer recovery-time latency, lower power
        PD_P2  = 4'h3   // lowest power state
    } powerdown_e;

    // --- Rate[3:0] (PIPE 7.1 Table 6-5, PCIe mode). 4-bit field.
    //     Gen5 = 32 GT/s = 4; Gen6 = 64 GT/s = 5. Lower rates listed for context
    //     but out of this IP's Gen5+Gen6 scope. (crosscheck B1/B2/B3/B4)
    typedef enum logic [3:0] {
        RATE_2P5    = 4'd0,  // 2.5 GT/s  (out of scope)
        RATE_5P0    = 4'd1,  // 5.0 GT/s  (out of scope)
        RATE_8P0    = 4'd2,  // 8.0 GT/s  (out of scope)
        RATE_16P0   = 4'd3,  // 16.0 GT/s (out of scope)
        RATE_GEN5   = 4'd4,  // 32 GT/s, 128b/130b   (in scope)
        RATE_GEN6   = 4'd5,  // 64 GT/s, PAM4         (in scope)
        RATE_128    = 4'd6   // 128 GT/s (out of scope)
    } rate_e;

    // --- Width[2:0] Tx datapath / RxWidth[2:0] Rx datapath (SerDes-arch
    //     encoding, PIPE 7.1 Tables 6-5 / 6-16). PCIe SerDes: 10/20/40/80/160.
    //     (crosscheck E10)
    typedef enum logic [2:0] {
        W_10  = 3'd0,   // 10 bits
        W_20  = 3'd1,   // 20 bits
        W_40  = 3'd2,   // 40 bits
        W_80  = 3'd3,   // 80 bits  (PCIe SerDes only)
        W_160 = 3'd4    // 160 bits (PCIe SerDes only)
    } width_e;

    // --- Message-bus 4-bit command opcodes (PIPE 7.1 Table 6-10).
    //     Register maps + 12-bit address constants are added in item 4.
    //     (crosscheck G3)
    typedef enum logic [3:0] {
        MB_NOP              = 4'h0,
        MB_WRITE_UNCOMMIT   = 4'h1,
        MB_WRITE_COMMIT     = 4'h2,
        MB_READ             = 4'h3,
        MB_READ_COMPLETION  = 4'h4,
        MB_WRITE_ACK        = 4'h5
    } msgbus_cmd_e;

    /* verilator lint_off UNUSEDPARAM */
    parameter int MB_BUS_WIDTH  = 8;   // M2P/P2M_MessageBus[7:0]
    parameter int MB_ADDR_WIDTH = 12;  // 12-bit PHY/MAC register address spaces
    /* verilator lint_on UNUSEDPARAM */

    // --- Control FSM request kinds (item 3). Which command the controller is
    //     asking pipe7_mac_ctrl_fsm to sequence toward the PHY.
    typedef enum logic [1:0] {
        REQ_POWER = 2'd0,  // change PowerDown[3:0]
        REQ_RATE  = 2'd1,  // change Rate[3:0]
        REQ_WIDTH = 2'd2   // change Width[2:0] / RxWidth[2:0]
    } ctrl_req_e;

endpackage
