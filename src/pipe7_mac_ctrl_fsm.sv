
`timescale 1ns/1ps

/**
 * pipe7_mac_ctrl_fsm -- PIPE 7.1 MAC PowerDown / Rate / Width control sequencer,
 * gated on PhyStatus. Closure-plan item 3 (first behavioral core).
 *
 * Role: accept a control request from the controller side (REQ_POWER / REQ_RATE /
 * REQ_WIDTH), drive the corresponding PIPE MAC command signal(s), and wait for the PHY's
 * single-cycle PhyStatus completion before returning to idle. Enforces the spec legality
 * rule that a Rate/Width change may be requested only in P0 or P1 with TxElecIdle asserted
 * (PIPE 7.1 §8.4.1); illegal requests are rejected with a req_error pulse and no signal
 * change. See docs/interface_spec.md (handshake protocols) and docs/pipe71_spec_crosscheck.md.
 *
 * Clocking: all signals are in the pclk domain. PCLK_IS_PHY_INPUT selects the PCLK-as-PHY
 * -input rate/width handshake (PclkChangeOk -> PclkChangeAck -> PhyStatus); default 0 =
 * PCLK-as-PHY-output (completion is a single PhyStatus pulse). Reset# is async active-low.
 *
 * Scope: control plane only. TxElecIdle is held asserted here (no data phase yet); the
 * datapath deasserts it in P0 data mode from item 5 onward. There is intentionally no
 * completion watchdog -- the PhyStatus max-latency timeout assertion is item 7.
 */
module pipe7_mac_ctrl_fsm
    import pipe7_pkg::*;
#(
    parameter bit PCLK_IS_PHY_INPUT = 1'b0
) (
    input  logic        pclk,
    input  logic        reset_n,          // PIPE Reset# (async, active-low)

    // ---- Request interface (controller side) ----
    input  logic        req_valid,        // accepted for one cycle when !busy
    input  ctrl_req_e   req_kind,
    input  logic [3:0]  req_power_down,
    input  logic [3:0]  req_rate,
    input  logic [2:0]  req_width,
    input  logic [2:0]  req_rxwidth,
    output logic        busy,             // high while a request is in flight
    output logic        done,             // 1-cycle pulse: request completed via PhyStatus
    output logic        req_error,        // 1-cycle pulse: request rejected (illegal)

    // ---- PIPE MAC command outputs (MAC -> PHY) ----
    output logic [3:0]  power_down,       // PowerDown[3:0]
    output logic [3:0]  rate,             // Rate[3:0]
    output logic [2:0]  width,            // Width[2:0]
    output logic [2:0]  rx_width,         // RxWidth[2:0]
    output logic [3:0]  tx_elec_idle,     // TxElecIdle[3:0]
    output logic        rx_standby,       // RxStandby
    output logic        pclk_change_ack,  // PclkChangeAck (PCLK-as-PHY-input only)

    // ---- PIPE MAC status inputs (PHY -> MAC) ----
    input  logic        phy_status,       // single-cycle completion
    input  logic        pclk_change_ok    // PHY ready for PCLK/rate/width change
);

    typedef enum logic [2:0] {
        S_IDLE,
        S_PWR_WAIT,       // waiting PhyStatus after a PowerDown change
        S_RW_PREP,        // TxElecIdle asserted; apply Rate/Width next cycle
        S_RW_WAIT_OK,     // (PCLK-input) waiting PclkChangeOk
        S_RW_APPLY_WAIT   // waiting PhyStatus after Rate/Width change
    } state_e;

    state_e     state;
    logic [3:0] shadow_rate;
    logic [2:0] shadow_width;
    logic [2:0] shadow_rxw;

    // Rate/Width may be changed only in P0 or P1 (PIPE 7.1 §8.4.1). P0s (1) and P2 (3)
    // are illegal.
    function automatic logic rw_legal(input logic [3:0] pd);
        return (pd == PD_P0) || (pd == PD_P1);
    endfunction

    always_ff @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            state           <= S_IDLE;
            power_down      <= PD_P0;
            rate            <= RATE_GEN5;
            width           <= W_160;
            rx_width        <= W_160;
            tx_elec_idle    <= 4'hF;      // idle until a data phase exists (item 5+)
            rx_standby      <= 1'b1;
            pclk_change_ack <= 1'b0;
            busy            <= 1'b0;
            done            <= 1'b0;
            req_error       <= 1'b0;
            shadow_rate     <= RATE_GEN5;
            shadow_width    <= W_160;
            shadow_rxw      <= W_160;
        end else begin
            done      <= 1'b0;            // default-low pulses
            req_error <= 1'b0;

            unique case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (req_valid) begin
                        unique case (req_kind)
                            REQ_POWER: begin
                                power_down <= req_power_down;
                                busy       <= 1'b1;
                                state      <= S_PWR_WAIT;
                            end
                            REQ_RATE, REQ_WIDTH: begin
                                if (rw_legal(power_down)) begin
                                    tx_elec_idle <= 4'hF;   // required asserted for the change
                                    // latch only the requested field(s); others unchanged
                                    shadow_rate  <= (req_kind == REQ_RATE)  ? req_rate    : rate;
                                    shadow_width <= (req_kind == REQ_WIDTH) ? req_width   : width;
                                    shadow_rxw   <= (req_kind == REQ_WIDTH) ? req_rxwidth : rx_width;
                                    busy         <= 1'b1;
                                    state        <= S_RW_PREP;
                                end else begin
                                    req_error <= 1'b1;      // not in P0/P1: reject, no change
                                end
                            end
                            default: req_error <= 1'b1;
                        endcase
                    end
                end

                S_PWR_WAIT: begin
                    if (phy_status) begin
                        done  <= 1'b1;
                        busy  <= 1'b0;
                        state <= S_IDLE;
                    end
                end

                S_RW_PREP: begin
                    rate     <= shadow_rate;
                    width    <= shadow_width;
                    rx_width <= shadow_rxw;
                    state    <= PCLK_IS_PHY_INPUT ? S_RW_WAIT_OK : S_RW_APPLY_WAIT;
                end

                S_RW_WAIT_OK: begin
                    if (pclk_change_ok) begin
                        // In a real PCLK-input design the MAC changes PCLK here; modelled
                        // as an immediate ack once the PHY is ready.
                        pclk_change_ack <= 1'b1;
                        state           <= S_RW_APPLY_WAIT;
                    end
                end

                S_RW_APPLY_WAIT: begin
                    if (phy_status) begin
                        pclk_change_ack <= 1'b0;
                        done            <= 1'b1;
                        busy            <= 1'b0;
                        state           <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
