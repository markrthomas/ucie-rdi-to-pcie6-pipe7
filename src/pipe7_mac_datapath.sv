
`timescale 1ns/1ps

/**
 * pipe7_mac_datapath -- Gen5 128b/130b MAC datapath with TxElecIdle data-phase gating.
 * Closure-plan follow-on (item 15): closes the integration gap where the control FSM held
 * TxElecIdle asserted while framed data was driven (which the item-7 P1 assertion forbids).
 *
 * A small data-phase FSM owns TxElecIdle: it is asserted (4'hF, electrical idle) when idle and
 * deasserted (0, data phase) only while actively transmitting. A data phase may start only in
 * PowerDown P0 (data is not driven in low-power states); it ends once the controller stops
 * offering payloads AND the framer has fully drained, so TxDataValid is never high while
 * TxElecIdle is asserted (P1 holds by construction). The RDI payload handshake to the framer is
 * gated by the data phase, so no block is accepted (hence none is transmitted) outside it.
 *
 * Composes pipe7_tx_framer -> (PHY) -> pipe7_rx_deframer. PIPE_WIDTH is a Gen5 SerDes width
 * <= 130 (single-block-per-cycle framer), default 80.
 */
module pipe7_mac_datapath
    import pipe7_pkg::*;
#(
    parameter int PIPE_WIDTH = 80
) (
    input  logic                     clk,
    input  logic                     reset_n,

    // ---- Control context (from pipe7_mac_ctrl_fsm) ----
    input  logic [3:0]               power_down,     // data phase allowed only in P0
    input  logic                     data_enable,    // controller requests transmission

    // ---- RDI payload in (TX) ----
    input  logic                     pl_valid,
    input  logic [BLOCK_PAYLOAD-1:0] pl_data,
    input  logic                     pl_is_os,
    output logic                     pl_ready,

    // ---- RDI payload out (recovered RX) ----
    output logic                     rx_pl_valid,
    output logic [BLOCK_PAYLOAD-1:0] rx_pl_data,
    output logic                     rx_pl_is_os,

    // ---- PIPE MAC Tx ----
    output logic [PIPE_WIDTH-1:0]    tx_data,
    output logic                     tx_data_valid,
    output logic [3:0]               tx_elec_idle,   // owned here (data-phase gated)

    // ---- PIPE MAC Rx ----
    input  logic [PIPE_WIDTH-1:0]    rx_data,
    input  logic                     rx_valid,

    // ---- Status ----
    output logic                     block_locked,
    output logic                     sync_error,
    output logic                     in_data_phase
);

    typedef enum logic {DP_IDLE, DP_DATA} dp_e;
    dp_e         state;
    logic        f_tx_valid;
    logic        f_pl_ready;
    logic        gated_pl_valid;
    logic [1:0]  drain_cnt;

    // Payloads reach the framer only during a data phase; nothing is transmitted otherwise.
    assign gated_pl_valid = pl_valid && (state == DP_DATA);
    assign pl_ready       = f_pl_ready && (state == DP_DATA);
    assign tx_data_valid  = f_tx_valid;
    // Electrical idle when not in a data phase; data drive requires EI deasserted.
    assign tx_elec_idle   = (state == DP_DATA) ? 4'h0 : 4'hF;
    assign in_data_phase  = (state == DP_DATA);

    pipe7_tx_framer #(.PIPE_WIDTH(PIPE_WIDTH)) framer (
        .clk, .reset_n,
        .pl_valid(gated_pl_valid), .pl_data(pl_data), .pl_is_os(pl_is_os),
        .pl_ready(f_pl_ready),
        .tx_data(tx_data), .tx_data_valid(f_tx_valid)
    );

    pipe7_rx_deframer #(.PIPE_WIDTH(PIPE_WIDTH)) deframer (
        .clk, .reset_n,
        .rx_data(rx_data), .rx_valid(rx_valid),
        .pl_valid(rx_pl_valid), .pl_data(rx_pl_data), .pl_is_os(rx_pl_is_os),
        .block_locked(block_locked), .sync_error(sync_error)
    );

    // Data-phase FSM. Enter only in P0 with data_enable; leave only once the framer has drained
    // (TxDataValid low for two cycles) so EI is never re-asserted while Tx data is in flight.
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state     <= DP_IDLE;
            drain_cnt <= 2'd0;
        end else begin
            unique case (state)
                DP_IDLE: begin
                    drain_cnt <= 2'd0;
                    if (data_enable && (power_down == PD_P0))
                        state <= DP_DATA;
                end
                DP_DATA: begin
                    if (!data_enable && !f_tx_valid) begin
                        if (drain_cnt >= 2'd2) begin
                            state     <= DP_IDLE;
                            drain_cnt <= 2'd0;
                        end else begin
                            drain_cnt <= drain_cnt + 2'd1;
                        end
                    end else begin
                        drain_cnt <= 2'd0;
                    end
                end
                default: state <= DP_IDLE;
            endcase
        end
    end

endmodule
