
`timescale 1ns/1ps

/**
 * pipe7_gen6_datapath -- Gen6 (64 GT/s, Rate=5) wide raw datapath. Closure-plan item 6.
 *
 * Item 0 established that Gen6 at the PIPE interface is NOT "flit mode" and carries NO
 * 128b/130b sync header: it is a wider parallel TxData/RxData conduit of already-encoded
 * data (1b/1b at the PIPE datapath). The 256B flit + FEC + LCRC are built controller-side
 * and arrive on RDI; the bridge does not frame flits on the PIPE side, and PAM4
 * precoding/gray-code is entirely PHY-side (crosscheck B2/I1/I3/I4/G5). So unlike the Gen5
 * path (pipe7_tx_framer/pipe7_rx_deframer, which embed a 2-bit sync header), the Gen6 path
 * is a registered wide pass-through with no block coding and no RX block-alignment hunt --
 * word boundaries are an above-PIPE (controller) concern.
 *
 * The MAC's only PAM4 knob is PAM4RestrictedLevels (a PHY Tx Control field programmed over
 * the message bus, item 4); the precoding math is PHY-side. This block just carries/holds
 * that config value (pam4_cfg_out) alongside the datapath -- there is no generic
 * "precoding-enable" register (crosscheck G5).
 *
 * Active only in gen6_mode (Rate=Gen6); when low the Gen5 framer owns TxData and this block
 * drives no valid. PIPE_WIDTH is the wide Gen6 width (default 160). Rate/Width/L0p control is
 * the ordinary pipe7_mac_ctrl_fsm handshake (L0p = a plain Width/RxWidth change, crosscheck
 * C3/C4) -- not modelled here.
 */
module pipe7_gen6_datapath
    import pipe7_pkg::*;
#(
    parameter int PIPE_WIDTH = 160
) (
    input  logic                        clk,
    input  logic                        reset_n,

    input  logic                        gen6_mode,     // 1 = Rate=Gen6 (this path active)
    input  logic [MB_DATA_WIDTH-1:0]    pam4_restricted_levels, // MAC PAM4 config (carried)

    // ---- TX payload in (from RDI datapath / elastic buffer) ----
    input  logic                        tx_pl_valid,
    input  logic [PIPE_WIDTH-1:0]       tx_pl_data,
    output logic                        tx_pl_ready,

    // ---- PIPE MAC Tx (raw wide data; no sync header) ----
    output logic [PIPE_WIDTH-1:0]       tx_data,
    output logic                        tx_data_valid,

    // ---- PIPE MAC Rx (raw wide data; no sync header) ----
    input  logic [PIPE_WIDTH-1:0]       rx_data,
    input  logic                        rx_data_valid,

    // ---- RX payload out ----
    output logic                        rx_pl_valid,
    output logic [PIPE_WIDTH-1:0]       rx_pl_data,

    // ---- Observability ----
    output logic [MB_DATA_WIDTH-1:0]    pam4_cfg_out
);

    // One wide word per PCLK, no coding overhead: accept whenever active.
    assign tx_pl_ready = gen6_mode;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            tx_data       <= '0;
            tx_data_valid <= 1'b0;
            rx_pl_data    <= '0;
            rx_pl_valid   <= 1'b0;
            pam4_cfg_out  <= '0;
        end else begin
            // TX: drive the payload straight onto TxData (no sync header, no 128b/130b).
            tx_data_valid <= gen6_mode && tx_pl_valid;
            if (gen6_mode && tx_pl_valid)
                tx_data <= tx_pl_data;

            // RX: recover the payload directly from RxData (no deframing).
            rx_pl_valid <= gen6_mode && rx_data_valid;
            if (gen6_mode && rx_data_valid)
                rx_pl_data <= rx_data;

            // Hold the MAC-side PAM4 config (programmed via the message bus).
            pam4_cfg_out <= pam4_restricted_levels;
        end
    end

endmodule
