
`timescale 1ns/1ps

/**
 * pipe7_mac_datapath_ra -- rate-aware MAC datapath (closure-plan item 17). Generalizes the
 * item-15 pipe7_mac_datapath: it muxes the Gen5 128b/130b gearbox (pipe7_tx_framer_gb /
 * pipe7_rx_deframer_gb, up to two blocks/PCLK) against the Gen6 raw wide path
 * (pipe7_gen6_datapath) by Rate, while a data-phase FSM owns TxElecIdle (asserted except while
 * transmitting; a data phase starts only in P0). So TxDataValid is never high while TxElecIdle
 * is asserted (assertion P1) in either rate.
 *
 * Both physical paths are PIPE_WIDTH wide (default 160). Each rate's RX only processes RxData in
 * that rate (rx_valid is gated by the mode) so the inactive deframer never mis-locks on the
 * other mode's data. Width/RxWidth are carried for observation; runtime sub-width (using only
 * the low bits) is a later refinement -- the datapath runs at the physical PIPE_WIDTH here.
 */
module pipe7_mac_datapath_ra
    import pipe7_pkg::*;
#(
    parameter int PIPE_WIDTH = 160
) (
    input  logic                     clk,
    input  logic                     reset_n,

    // ---- Control context ----
    input  logic [3:0]               rate,           // RATE_GEN5 / RATE_GEN6
    input  logic [3:0]               power_down,     // data phase only in P0
    input  logic                     data_enable,
    input  logic [MB_DATA_WIDTH-1:0] pam4_restricted_levels,

    // ---- Gen5 block payload in (up to two blocks/PCLK) ----
    input  logic [1:0]               g5_pl_cnt,
    input  logic [BLOCK_PAYLOAD-1:0] g5_pl_data0,
    input  logic                     g5_pl_is_os0,
    input  logic [BLOCK_PAYLOAD-1:0] g5_pl_data1,
    input  logic                     g5_pl_is_os1,
    output logic [1:0]               g5_pl_acc,

    // ---- Gen6 raw payload in (one wide word/PCLK) ----
    input  logic                     g6_pl_valid,
    input  logic [PIPE_WIDTH-1:0]    g6_pl_data,
    output logic                     g6_pl_ready,

    // ---- PIPE MAC Tx ----
    output logic [PIPE_WIDTH-1:0]    tx_data,
    output logic                     tx_data_valid,
    output logic [3:0]               tx_elec_idle,

    // ---- PIPE MAC Rx ----
    input  logic [PIPE_WIDTH-1:0]    rx_data,
    input  logic                     rx_valid,

    // ---- Gen5 recovered blocks out (up to two/PCLK) ----
    output logic [1:0]               g5_rx_cnt,
    output logic [BLOCK_PAYLOAD-1:0] g5_rx_data0,
    output logic                     g5_rx_os0,
    output logic [BLOCK_PAYLOAD-1:0] g5_rx_data1,
    output logic                     g5_rx_os1,

    // ---- Gen6 recovered raw out ----
    output logic                     g6_rx_valid,
    output logic [PIPE_WIDTH-1:0]    g6_rx_data,

    // ---- Status ----
    output logic                     block_locked,
    output logic                     sync_error,
    output logic                     in_data_phase,
    output logic [MB_DATA_WIDTH-1:0] pam4_cfg_out
);

    wire is_gen6 = (rate == RATE_GEN6);

    // ---------------- Data-phase FSM (owns TxElecIdle) ----------------
    typedef enum logic {DP_IDLE, DP_DATA} dp_e;
    dp_e        state;
    logic [1:0] drain_cnt;
    wire        active = (state == DP_DATA);

    assign tx_elec_idle  = active ? 4'h0 : 4'hF;
    assign in_data_phase = active;

    // ---------------- Gen5 gearbox path ----------------
    logic [1:0]            g5_cnt_gated;
    logic [PIPE_WIDTH-1:0] g5_tx_data;
    logic                  g5_tx_valid;

    assign g5_cnt_gated = (active && !is_gen6) ? g5_pl_cnt : 2'd0;

    pipe7_tx_framer_gb #(.PIPE_WIDTH(PIPE_WIDTH)) framer (
        .clk, .reset_n,
        .pl_cnt(g5_cnt_gated), .pl_data0(g5_pl_data0), .pl_is_os0(g5_pl_is_os0),
        .pl_data1(g5_pl_data1), .pl_is_os1(g5_pl_is_os1), .pl_acc(g5_pl_acc),
        .tx_data(g5_tx_data), .tx_data_valid(g5_tx_valid)
    );

    pipe7_rx_deframer_gb #(.PIPE_WIDTH(PIPE_WIDTH)) deframer (
        .clk, .reset_n,
        .rx_data(rx_data), .rx_valid(rx_valid && !is_gen6),
        .pl_cnt(g5_rx_cnt), .pl_data0(g5_rx_data0), .pl_is_os0(g5_rx_os0),
        .pl_data1(g5_rx_data1), .pl_is_os1(g5_rx_os1),
        .block_locked(block_locked), .sync_error(sync_error)
    );

    // ---------------- Gen6 raw path ----------------
    logic                  g6_tx_valid;
    logic [PIPE_WIDTH-1:0]  g6_tx_data;
    wire                    g6_mode = active && is_gen6;

    pipe7_gen6_datapath #(.PIPE_WIDTH(PIPE_WIDTH)) gen6 (
        .clk, .reset_n,
        .gen6_mode(g6_mode), .pam4_restricted_levels,
        .tx_pl_valid(g6_pl_valid), .tx_pl_data(g6_pl_data), .tx_pl_ready(g6_pl_ready),
        .tx_data(g6_tx_data), .tx_data_valid(g6_tx_valid),
        .rx_data(rx_data), .rx_data_valid(rx_valid && is_gen6),
        .rx_pl_valid(g6_rx_valid), .rx_pl_data(g6_rx_data),
        .pam4_cfg_out(pam4_cfg_out)
    );

    // ---------------- Tx mux by rate ----------------
    assign tx_data       = is_gen6 ? g6_tx_data  : g5_tx_data;
    assign tx_data_valid = is_gen6 ? g6_tx_valid : g5_tx_valid;

    // ---------------- Data-phase FSM ----------------
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
                    if (!data_enable && !tx_data_valid) begin
                        if (drain_cnt >= 2'd2) begin state <= DP_IDLE; drain_cnt <= 2'd0; end
                        else                        drain_cnt <= drain_cnt + 2'd1;
                    end else begin
                        drain_cnt <= 2'd0;
                    end
                end
                // coverage: unreachable defensive default (both states enumerated)
                /* verilator coverage_off */ default: state <= DP_IDLE; /* verilator coverage_on */
            endcase
        end
    end

endmodule
