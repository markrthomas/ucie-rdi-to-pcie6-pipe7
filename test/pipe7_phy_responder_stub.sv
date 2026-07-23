
`timescale 1ns/1ps

/**
 * pipe7_phy_responder_stub -- lightweight, non-UVM PHY-side responder for the Verilator
 * control-plane smoke (closure-plan item 3). It watches the MAC command signals and
 * answers each PowerDown / Rate / Width change with a spec-shaped completion:
 *   - PCLK-as-PHY-output (default): after LATENCY pclk cycles, a single-cycle PhyStatus.
 *   - PCLK-as-PHY-input: on a Rate/Width change, assert PclkChangeOk, wait for the MAC's
 *     PclkChangeAck, then after LATENCY cycles pulse PhyStatus and drop PclkChangeOk.
 *
 * This is NOT a PHY model -- one well-defined role (answer control handshakes). The
 * spec-timed BFM with RxStatus/RxData/P2M lives in the UVM/PyUVM tiers (items 9/14).
 */
module pipe7_phy_responder_stub #(
    parameter int LATENCY           = 4,
    parameter bit PCLK_IS_PHY_INPUT = 1'b0
) (
    input  logic       pclk,
    input  logic       reset_n,
    input  logic [3:0] power_down,
    input  logic [3:0] rate,
    input  logic [2:0] width,
    input  logic [2:0] rx_width,
    input  logic       pclk_change_ack,
    output logic       phy_status,
    output logic       pclk_change_ok
);

    logic [3:0] pd_q, rate_q;
    logic [2:0] w_q, rxw_q;
    logic       servicing, waiting_ack;
    int         cnt;

    wire changed    = (power_down != pd_q) || (rate != rate_q) ||
                      (width != w_q)       || (rx_width != rxw_q);
    wire rw_changed = (rate != rate_q) || (width != w_q) || (rx_width != rxw_q);

    always_ff @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            pd_q           <= power_down;
            rate_q         <= rate;
            w_q            <= width;
            rxw_q          <= rx_width;
            servicing      <= 1'b0;
            waiting_ack    <= 1'b0;
            cnt            <= 0;
            phy_status     <= 1'b0;
            pclk_change_ok <= 1'b0;
        end else begin
            phy_status <= 1'b0;                 // default-low; pulse for one cycle

            if (!servicing) begin
                if (changed) begin
                    // Latch the new command values so `changed` clears during service.
                    pd_q      <= power_down;
                    rate_q    <= rate;
                    w_q       <= width;
                    rxw_q     <= rx_width;
                    servicing <= 1'b1;
                    if (PCLK_IS_PHY_INPUT && rw_changed) begin
                        pclk_change_ok <= 1'b1;   // request the PCLK/rate/width handshake
                        waiting_ack    <= 1'b1;
                    end else begin
                        cnt         <= LATENCY;
                        waiting_ack <= 1'b0;
                    end
                end
            end else if (waiting_ack) begin
                if (pclk_change_ack) begin
                    waiting_ack <= 1'b0;
                    cnt         <= LATENCY;
                end
            end else begin
                if (cnt > 1) begin
                    cnt <= cnt - 1;
                end else begin
                    phy_status     <= 1'b1;       // single-cycle completion
                    pclk_change_ok <= 1'b0;
                    servicing      <= 1'b0;
                end
            end
        end
    end

endmodule
