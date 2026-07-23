
`timescale 1ns/1ps

/**
 * pipe7_regfile -- MAC-side register file for the PIPE message-bus register space.
 * Closure-plan item 4.
 *
 * A compact, parameterizable 8-bit register file addressed in the 12-bit message-bus
 * address space (PIPE 7.1 §6.1.4.2). It provides the local storage that the message-bus
 * master writes toward / reads back for the MAC-owned configuration this IP programs into
 * the PHY -- Tx equalization presets / de-emphasis and the PAM4RestrictedLevels field in
 * the PHY Tx Control block (0x400..0x40A), and Rx-margining control (crosscheck G4/G5/G6).
 * There is deliberately NO FEC register: FEC lives controller-side and nothing FEC crosses
 * the PIPE boundary (crosscheck G7).
 *
 * The window is [BASE_ADDR, BASE_ADDR+NUM_REGS). Item 0 confirmed the PHY Tx Control base
 * (0x400) and the Rx-margin addresses but did not pin the sub-offset of every named field
 * inside that block, so this file stays a generic addressable window (named fields are
 * documented in docs/pipe71_mac_signal_map.md) rather than hard-coding unverified offsets.
 *
 * Ports: a synchronous host write and a combinational host read (single-cycle), plus a
 * flattened `regs_flat` snapshot for TB/UVM monitors. `host_hit` decodes whether host_addr
 * falls in this file's window. Reset clears all registers.
 */
module pipe7_regfile
    import pipe7_pkg::*;
#(
    parameter int                     NUM_REGS  = 8,
    parameter logic [MB_ADDR_WIDTH-1:0] BASE_ADDR = REG_PHY_TX_CTRL_BASE
) (
    input  logic                       pclk,
    input  logic                       reset_n,

    // ---- Host (controller) access port ----
    input  logic                       host_we,
    input  logic                       host_re,
    input  logic [MB_ADDR_WIDTH-1:0]   host_addr,
    input  logic [MB_DATA_WIDTH-1:0]   host_wdata,
    output logic [MB_DATA_WIDTH-1:0]   host_rdata,
    output logic                       host_hit,     // host_addr is within this window

    // ---- Observation ----
    output logic [NUM_REGS*MB_DATA_WIDTH-1:0] regs_flat
);

    localparam int IDX_W = $clog2(NUM_REGS);

    logic [MB_DATA_WIDTH-1:0] regs [NUM_REGS];

    // Window decode. `idx` is meaningful only when in-range (guarded by host_hit); the
    // offset is explicitly truncated to the index width.
    logic [IDX_W-1:0] idx;
    assign idx      = IDX_W'(host_addr - BASE_ADDR);
    assign host_hit = (host_addr >= BASE_ADDR) &&
                      (host_addr <  BASE_ADDR + MB_ADDR_WIDTH'(NUM_REGS));

    // Combinational host read (0 when out of window / not reading).
    always_comb begin
        host_rdata = '0;
        if (host_re && host_hit) host_rdata = regs[idx];
    end

    // Synchronous host write; reset clears the file.
    always_ff @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            for (int i = 0; i < NUM_REGS; i++) regs[i] <= '0;
        end else if (host_we && host_hit) begin
            regs[idx] <= host_wdata;
        end
    end

    // Flattened snapshot for monitors.
    always_comb begin
        for (int i = 0; i < NUM_REGS; i++)
            regs_flat[i*MB_DATA_WIDTH +: MB_DATA_WIDTH] = regs[i];
    end

endmodule
