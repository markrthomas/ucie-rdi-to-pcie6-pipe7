
`timescale 1ns/1ps

/**
 * pipe7_mac_bridge_assertions -- PIPE 7.1 MAC-facing protocol assertions (closure-plan
 * item 7). A reusable, parameterizable SVA checker instantiated (or bound) alongside the
 * control + datapath blocks. Each property group is guarded by a CHECK_* parameter so a given
 * instance only asserts over the signals that are meaningful in its context.
 *
 * Properties:
 *   P1 (CHECK_TX_EI)   -- no Tx while TxElecIdle: when TxElecIdle is fully asserted (4'hF)
 *                         there must be no valid Tx data (crosscheck E5; a data phase must
 *                         deassert TxElecIdle before driving TxDataValid).
 *   P2 (CHECK_RATE_PD) -- a Rate change may occur only in a legal PowerDown state, P0 or P1
 *                         (PIPE 7.1 §8.4.1, crosscheck B5/D3).
 *   P3 (CHECK_PHYSTAT) -- every accepted control request (busy rising) completes via
 *                         PhyStatus within a PHY-specific bound. The bound is a PARAMETER,
 *                         not a spec constant (crosscheck D4).
 *   P4 (CHECK_SYNC)    -- sync-header legality: on a correctly framed Gen5 link the deframer
 *                         never flags an illegal sync header (crosscheck H1/H2).
 *
 * Requires Verilator `--assert` (or a vendor sim's SVA). A violation calls $fatal so CI fails
 * with a non-zero exit.
 */
module pipe7_mac_bridge_assertions
    import pipe7_pkg::*;
#(
    parameter int PHYSTATUS_MAX_LATENCY = 32,   // PHY-specific completion bound (D4)
    parameter bit CHECK_TX_EI   = 1'b1,
    parameter bit CHECK_RATE_PD = 1'b1,
    parameter bit CHECK_PHYSTAT = 1'b1,
    parameter bit CHECK_SYNC    = 1'b1
) (
    input logic       clk,
    input logic       reset_n,

    // P1: Tx / electrical idle
    input logic       tx_data_valid,
    input logic [3:0] tx_elec_idle,

    // P2: control state
    input logic [3:0] power_down,
    input logic [3:0] rate,

    // P3: PhyStatus completion
    input logic       ctrl_busy,
    input logic       phy_status,

    // P4: Gen5 sync-header legality
    input logic       sync_error
);

    generate
        if (CHECK_TX_EI) begin : g_tx_ei
            a_no_tx_when_ei : assert property (@(posedge clk) disable iff (!reset_n)
                (tx_elec_idle == 4'hF) |-> !tx_data_valid)
                else $fatal(1, "[ASSN] P1: TxDataValid high while TxElecIdle asserted");
        end

        if (CHECK_RATE_PD) begin : g_rate_pd
            a_rate_change_legal : assert property (@(posedge clk) disable iff (!reset_n)
                $changed(rate) |-> (power_down == PD_P0) || (power_down == PD_P1))
                else $fatal(1, "[ASSN] P2: Rate changed outside P0/P1 (power_down=%0d)", power_down);
        end

        if (CHECK_PHYSTAT) begin : g_phystat
            a_phystatus_bound : assert property (@(posedge clk) disable iff (!reset_n)
                $rose(ctrl_busy) |-> ##[1:PHYSTATUS_MAX_LATENCY] phy_status)
                else $fatal(1, "[ASSN] P3: PhyStatus did not complete within %0d cycles",
                            PHYSTATUS_MAX_LATENCY);
        end

        if (CHECK_SYNC) begin : g_sync
            a_sync_legal : assert property (@(posedge clk) disable iff (!reset_n)
                !sync_error)
                else $fatal(1, "[ASSN] P4: illegal Gen5 sync header (sync_error)");
        end
    endgenerate

endmodule
