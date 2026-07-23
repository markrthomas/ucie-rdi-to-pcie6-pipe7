
`timescale 1ns/1ps

/**
 * tb_pipe7_msgbus -- self-checking message-bus smoke for pipe7_msgbus_master + pipe7_regfile
 * (closure-plan item 4). Self-clocking; built with `verilator --binary --timing`.
 *
 * Exercises against the non-UVM PHY responder stub:
 *   - write_uncommitted : framed on M2P, completes with no P2M response.
 *   - write_committed    : framed on M2P, completes on the PHY's write_ack.
 *   - read               : framed on M2P, PHY returns read_completion; captured data must
 *                          match the responder's known register contents (0xA0 + addr[3:0]).
 *   - a committed write then a read of the same address: read-back must equal what was written
 *     (proves the write actually landed in the PHY-side store).
 *   - the MAC-side regfile: reset-clears, host write/read round-trip, out-of-window miss.
 *
 * Pass criterion: every transaction completes, read data matches expectation, and the regfile
 * honors its window. Prints [MSGBUS] PASS / FAIL and $finish (uses $fatal on failure so CI
 * catches regressions).
 */
module tb_pipe7_msgbus;
    import pipe7_pkg::*;

    logic pclk;
    logic reset_n;
    initial pclk = 1'b0;
    always #5 pclk = ~pclk;

    int errors;
    int completions;

    // ---- Master <-> responder wiring ----
    logic                      req_valid, req_write, req_committed;
    logic [MB_ADDR_WIDTH-1:0]  req_addr;
    logic [MB_DATA_WIDTH-1:0]  req_wdata;
    logic                      req_ready, busy;
    logic                      rsp_valid, rsp_is_read, rsp_error;
    logic [MB_DATA_WIDTH-1:0]  rsp_rdata;
    logic [MB_BUS_WIDTH-1:0]   m2p, p2m;

    pipe7_msgbus_master master (
        .pclk, .reset_n,
        .req_valid, .req_write, .req_committed, .req_addr, .req_wdata,
        .req_ready, .busy,
        .rsp_valid, .rsp_is_read, .rsp_rdata, .rsp_error,
        .m2p, .p2m
    );

    pipe7_msgbus_responder_stub #(.RC_LATENCY(3), .MEM_BITS(4)) responder (
        .pclk, .reset_n, .m2p, .p2m
    );

    // ---- MAC-side regfile (exercised on its host port) ----
    logic                                 rf_we, rf_re, rf_hit;
    logic [MB_ADDR_WIDTH-1:0]             rf_addr;
    logic [MB_DATA_WIDTH-1:0]             rf_wdata, rf_rdata;
    localparam int RF_NUM = 8;
    logic [RF_NUM*MB_DATA_WIDTH-1:0]      rf_flat;

    pipe7_regfile #(.NUM_REGS(RF_NUM), .BASE_ADDR(REG_PHY_TX_CTRL_BASE)) rf (
        .pclk, .reset_n,
        .host_we(rf_we), .host_re(rf_re), .host_addr(rf_addr),
        .host_wdata(rf_wdata), .host_rdata(rf_rdata), .host_hit(rf_hit),
        .regs_flat(rf_flat)
    );

    // ---- Helpers ----
    task automatic bus_xfer(input logic wr, input logic committed,
                            input logic [MB_ADDR_WIDTH-1:0] addr,
                            input logic [MB_DATA_WIDTH-1:0] wdata,
                            input logic expect_read, input logic [MB_DATA_WIDTH-1:0] exp_rdata,
                            input string name);
        int wcnt;
        @(negedge pclk);
        req_write     = wr;
        req_committed = committed;
        req_addr      = addr;
        req_wdata     = wdata;
        req_valid     = 1'b1;
        @(negedge pclk);
        req_valid = 1'b0;
        wcnt = 0;
        while (!rsp_valid) begin
            wcnt = wcnt + 1;
            if (wcnt > 200) break;
            @(negedge pclk);
        end
        if (!rsp_valid) begin
            errors = errors + 1;
            $display("[MSGBUS] FAIL %s: no completion", name);
        end else begin
            completions = completions + 1;
            if (expect_read) begin
                if (!rsp_is_read) begin
                    errors = errors + 1;
                    $display("[MSGBUS] FAIL %s: rsp_is_read=0 on a read", name);
                end
                if (rsp_rdata !== exp_rdata) begin
                    errors = errors + 1;
                    $display("[MSGBUS] FAIL %s: rdata=0x%02x expected 0x%02x", name, rsp_rdata, exp_rdata);
                end
            end
        end
    endtask

    task automatic rf_write(input logic [MB_ADDR_WIDTH-1:0] a, input logic [MB_DATA_WIDTH-1:0] d);
        @(negedge pclk);
        rf_addr = a; rf_wdata = d; rf_we = 1'b1;
        @(negedge pclk);
        rf_we = 1'b0;
    endtask

    task automatic rf_check(input logic [MB_ADDR_WIDTH-1:0] a, input logic [MB_DATA_WIDTH-1:0] exp,
                            input logic exp_hit, input string name);
        @(negedge pclk);
        rf_addr = a; rf_re = 1'b1;
        #1;                                       // let combinational read settle
        if (rf_hit !== exp_hit) begin
            errors = errors + 1;
            $display("[MSGBUS] FAIL %s: hit=%0b expected %0b", name, rf_hit, exp_hit);
        end
        if (exp_hit && (rf_rdata !== exp)) begin
            errors = errors + 1;
            $display("[MSGBUS] FAIL %s: rf_rdata=0x%02x expected 0x%02x", name, rf_rdata, exp);
        end
        @(negedge pclk);
        rf_re = 1'b0;
    endtask

    // ---- Stimulus ----
    initial begin
        errors = 0; completions = 0;
        req_valid = 1'b0; req_write = 1'b0; req_committed = 1'b0;
        req_addr = '0; req_wdata = '0;
        rf_we = 1'b0; rf_re = 1'b0; rf_addr = '0; rf_wdata = '0;

        reset_n = 1'b0;
        repeat (4) @(negedge pclk);
        reset_n = 1'b1;
        repeat (2) @(negedge pclk);

        // ---- Message-bus transactions ----
        // Uncommitted write (no ack expected, but master completes once framed).
        bus_xfer(1'b1, 1'b0, 12'h401, 8'h5A, 1'b0, 8'h00, "write_uncommitted 0x401<=0x5A");

        // Committed write (completes on write_ack).
        bus_xfer(1'b1, 1'b1, 12'h402, 8'h3C, 1'b0, 8'h00, "write_committed 0x402<=0x3C");

        // Read a preloaded address: responder mem[idx] = 0xA0 + idx; addr[3:0]=5 -> 0xA5.
        bus_xfer(1'b0, 1'b0, 12'h405, 8'h00, 1'b1, 8'hA5, "read 0x405 -> 0xA5");

        // Round-trip: committed write then read the same address; read-back must equal write.
        bus_xfer(1'b1, 1'b1, 12'h407, 8'hE1, 1'b0, 8'h00, "write_committed 0x407<=0xE1");
        bus_xfer(1'b0, 1'b0, 12'h407, 8'h00, 1'b1, 8'hE1, "read 0x407 -> 0xE1 (round-trip)");

        // ---- Regfile host port ----
        rf_check(REG_PHY_TX_CTRL_BASE + 0, 8'h00, 1'b1, "regfile reset=0");
        rf_write(REG_PHY_TX_CTRL_BASE + 2, 8'h7E);
        rf_check(REG_PHY_TX_CTRL_BASE + 2, 8'h7E, 1'b1, "regfile write/read 0x402");
        rf_check(REG_PHY_TX_CTRL_BASE + 0, 8'h00, 1'b1, "regfile other reg untouched");
        rf_check(12'h300, 8'h00, 1'b0, "regfile out-of-window miss");

        // ---- Report ----
        if (completions != 5) begin
            errors = errors + 1;
            $display("[MSGBUS] FAIL: completions=%0d expected 5", completions);
        end

        if (errors == 0) begin
            $display("[MSGBUS] PASS  (completions=%0d)", completions);
            $finish;
        end else begin
            $fatal(1, "[MSGBUS] FAIL  (errors=%0d)", errors);
        end
    end

    // Global watchdog.
    initial begin
        #200000;
        $fatal(1, "[MSGBUS] FAIL  (global timeout)");
    end

endmodule
