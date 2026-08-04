
`timescale 1ns/1ps

/**
 * pipe7_pmu -- DV-ONLY PIPE power-management sequencer.
 *
 * NOT part of the shipped IP (lives under test/, never in src/). It models the SoC-side
 * power controller that a UPF-managed integration would provide, so the authored power-aware
 * test (tb_pipe7_upf_power) can drive the bridge's switchable datapath domain.
 *
 * It decodes the PIPE PowerDown state the bridge drives to the PHY (dut.power_down) into the
 * UPF control signals for domain PD_DP (see test/upf/bridge.upf):
 *   power_down in {P1, P2}       => datapath OFF: isolate outputs, save retention, gate VDD_DP.
 *   power_down back to {P0, P0s} => datapath ON : ungate VDD_DP, restore retention, de-isolate.
 *
 * The sequence is deliberately ordered so no corrupted datapath value can reach the always-on
 * domain: on the way down we isolate BEFORE gating and save retention while still powered; on the
 * way up we restore retention AFTER power is good and de-isolate LAST. Delays are a few pclk each
 * (representative, not spec constants -- real gate-collapse/ramp times are PHY/PMU-specific).
 *
 * Under a power-aware run (VCS -upf) these outputs are consumed by the UPF switch/isolation/
 * retention strategies. Under plain Verilator/Icarus (no UPF) nothing consumes them -- the module
 * is still a legal RTL sequencer, so the skeleton test elaborates and the sequence is observable,
 * but the power semantics themselves are only exercised with -upf.
 */
module pipe7_pmu
    import pipe7_pkg::*;
(
    input  logic       clk,             // pclk domain (same as the bridge control/datapath)
    input  logic       rst_n,
    input  logic [3:0] power_down,      // driven by the bridge (dut.power_down)

    output logic       dp_pwr_en,       // 1 = datapath rail (VDD_DP) powered  -> UPF power switch
    output logic       dp_iso_en,       // 1 = isolate PD_DP outputs           -> UPF isolation
    output logic       dp_ret_save,     // 1-cycle pulse: save retention regs   -> UPF retention
    output logic       dp_ret_restore   // 1-cycle pulse: restore retention regs-> UPF retention
);
    // Gate the datapath in the two deep low-power states (P1 longer-latency, P2 lowest power).
    // P0 (normal) and P0s (fast-recovery) keep the datapath powered.
    wire gated_req = (power_down == PD_P1) || (power_down == PD_P2);

    typedef enum logic [2:0] {
        S_RUN,        // datapath powered, running
        S_DN_ISO,     // isolation asserted, waiting before save
        S_DN_SAVE,    // pulse retention save, then gate
        S_OFF,        // datapath gated off
        S_UP_ON,      // power restored, waiting before restore
        S_UP_RESTORE  // pulse retention restore, then de-isolate
    } pmu_state_e;

    pmu_state_e st;
    logic [2:0] dly;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st             <= S_RUN;
            dly            <= '0;
            dp_pwr_en      <= 1'b1;
            dp_iso_en      <= 1'b0;
            dp_ret_save    <= 1'b0;
            dp_ret_restore <= 1'b0;
        end else begin
            dp_ret_save    <= 1'b0;   // retention controls are single-cycle pulses
            dp_ret_restore <= 1'b0;
            unique case (st)
                S_RUN:        if (gated_req) begin dp_iso_en <= 1'b1; dly <= 3'd2; st <= S_DN_ISO; end
                S_DN_ISO:     if (dly == 0) begin dp_ret_save <= 1'b1; st <= S_DN_SAVE; end
                              else            dly <= dly - 3'd1;
                S_DN_SAVE:    begin dp_pwr_en <= 1'b0; st <= S_OFF; end
                S_OFF:        if (!gated_req) begin dp_pwr_en <= 1'b1; dly <= 3'd2; st <= S_UP_ON; end
                S_UP_ON:      if (dly == 0) begin dp_ret_restore <= 1'b1; st <= S_UP_RESTORE; end
                              else            dly <= dly - 3'd1;
                S_UP_RESTORE: begin dp_iso_en <= 1'b0; st <= S_RUN; end
                default:      st <= S_RUN;
            endcase
        end
    end
endmodule
