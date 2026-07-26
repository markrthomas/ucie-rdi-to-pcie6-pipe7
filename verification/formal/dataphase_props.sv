// dataphase_props.sv — SymbiYosys formal proof for the rate-aware datapath's data-phase FSM
// and rate mux (closure-plan item 24). Yosys cannot parse the SV package-import header of
// src/pipe7_mac_datapath_ra.sv, so — following the fifo_cdc methodology — this is a faithful
// plain-Verilog model of that block's control logic (the DP_IDLE/DP_DATA FSM that owns
// TxElecIdle, plus the Gen5/Gen6 gating and the Rate mux). The physical framer/Gen6 datapaths
// are abstracted (tx_data_valid is a free input into the drain logic); the properties are about
// the control plane, which is what carries the safety obligations.
//
// Proved:
//   P1  active  <-> tx_elec_idle==0           (data phase de-asserts TxElecIdle)
//   P2  !active <-> tx_elec_idle==4'hF        (idle asserts TxElecIdle on all sub-lanes)
//   P3  never both Gen5 blocks and Gen6 driven  (!(g5_cnt_gated!=0 && g6_mode))  [rate-mux safety]
//   P4  g6_mode      -> is_gen6 && active
//   P5  g5_cnt_gated!=0 -> (!is_gen6 && active)
//   P6  a data phase is entered only from PowerDown P0  (item-7 assertion P-EI, formalised)

`default_nettype none
`timescale 1ns/1ps

module dataphase_props (
    input wire clk,
    input wire rst_n
);
    localparam [3:0] PD_P0     = 4'd0;
    localparam [3:0] RATE_GEN6 = 4'd5;

    // Free inputs (environment).
    wire [3:0] rate;
    wire [3:0] power_down;
    wire       data_enable;
    wire       tx_data_valid;   // abstract framer/Gen6 valid feeding the drain logic
    wire [1:0] pl_cnt;

    // State (mirrors pipe7_mac_datapath_ra).
    localparam DP_IDLE = 1'b0, DP_DATA = 1'b1;
    reg       state     = DP_IDLE;
    reg [1:0] drain_cnt = 2'd0;

    wire active  = (state == DP_DATA);
    wire is_gen6 = (rate == RATE_GEN6);

    wire [3:0] tx_elec_idle  = active ? 4'h0 : 4'hF;
    wire [1:0] g5_cnt_gated  = (active && !is_gen6) ? pl_cnt : 2'd0;
    wire       g6_mode       = active && is_gen6;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= DP_IDLE;
            drain_cnt <= 2'd0;
        end else begin
            case (state)
                DP_IDLE: begin
                    drain_cnt <= 2'd0;
                    if (data_enable && (power_down == PD_P0))
                        state <= DP_DATA;
                end
                DP_DATA: begin
                    if (!data_enable && !tx_data_valid) begin
                        if (drain_cnt >= 2'd2) begin state <= DP_IDLE; drain_cnt <= 2'd0; end
                        else                        drain_cnt <= drain_cnt + 2'd1;
                    end else begin
                        drain_cnt <= 2'd0;
                    end
                end
                default: state <= DP_IDLE;
            endcase
        end
    end

`ifdef FORMAL
    reg f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;

    always @(*) assume(pl_cnt <= 2);

    always @(posedge clk) if (rst_n) begin
        assert(active == (tx_elec_idle == 4'h0));                 // P1
        assert((!active) == (tx_elec_idle == 4'hF));              // P2
        assert(!((g5_cnt_gated != 2'd0) && g6_mode));             // P3 rate-mux safety
        if (g6_mode)              assert(is_gen6 && active);      // P4
        if (g5_cnt_gated != 2'd0) assert(!is_gen6 && active);     // P5
    end

    // P6: a data phase is entered only from PowerDown P0.
    always @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
        if (!$past(active) && active)
            assert($past(data_enable) && ($past(power_down) == PD_P0));
    end

    // Cover: reach a Gen5 data phase and a Gen6 data phase.
    always @(posedge clk) if (rst_n && f_past_valid) begin
        cover(active && !is_gen6 && (g5_cnt_gated != 2'd0));
        cover(g6_mode);
    end
`endif
endmodule
`default_nettype wire
