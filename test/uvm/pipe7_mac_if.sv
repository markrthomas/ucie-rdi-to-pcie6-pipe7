
`timescale 1ns/1ps

/**
 * pipe7_mac_if -- PIPE 7.1 MAC-facing interface (SerDes architecture, PCIe Gen5+Gen6).
 *
 * CLOSURE-PLAN ITEM 2 (contract first, NO behavior). This interface enumerates every
 * PIPE MAC-side signal the bridge drives/samples, with spec-accurate widths and
 * directions expressed from the MAC (bridge) perspective via the `mac` modport.
 *
 * Signal names, widths, and directions are confirmed against the controlled Intel PIPE
 * 7.1 spec (Ref 643108, Rev 7.1, Sep 2025). See docs/pipe71_spec_crosscheck.md for the
 * row-by-row reconciliation and docs/pipe71_mac_signal_map.md for per-signal §refs and
 * the message-bus register map. Scope is SerDes architecture, PCIe mode, Gen5 (Rate=4)
 * and Gen6 (Rate=5) only -- Original-PIPE-only block-coding pins (TxStartBlock /
 * TxSyncHeader / RxStartBlock / RxSyncHeader / TxDataK / RxDataK / RxDataValid /
 * TxCompliance / AlignDetect) do NOT exist here (the MAC does 128b/130b in-band).
 *
 * The parallel command/status/message-bus signals are synchronous to `pclk`; RxData /
 * RxValid are synchronous to the recovered `rx_clk` (SerDes). Reset# and the deep-PM /
 * L1-substate strobes are asynchronous.
 *
 * TX_DATA_WIDTH / RX_DATA_WIDTH are the per-lane SerDes parallel widths and must be one
 * of {10, 20, 40, 80, 160} (PCIe), selected by Width / RxWidth. Defaults are the x16
 * maximum (160). MB_WIDTH / MB_ADDR_WIDTH mirror pipe7_pkg::MB_BUS_WIDTH (8) and
 * MB_ADDR_WIDTH (12).
 */
interface pipe7_mac_if #(
    parameter int TX_DATA_WIDTH = 160,  // SerDes Tx parallel width; valid {10,20,40,80,160}
    parameter int RX_DATA_WIDTH = 160,  // SerDes Rx parallel width; valid {10,20,40,80,160}
    parameter int MB_WIDTH      = 8,    // M2P/P2M message bus width  (pipe7_pkg::MB_BUS_WIDTH)
    parameter int MB_ADDR_WIDTH = 12    // register address space width (pipe7_pkg::MB_ADDR_WIDTH)
) (
    input logic pclk,    // parallel-interface clock: command/status/message-bus domain
    input logic rx_clk   // SerDes recovered Rx clock: RxData / RxValid domain
);

    // Suppress "parameter unused in this interface" -- MB_ADDR_WIDTH documents the
    // register address space and is consumed by the msgbus master (item 4), not here.
    /* verilator lint_off UNUSEDPARAM */
    localparam int MB_ADDR_W_DOC = MB_ADDR_WIDTH;
    /* verilator lint_on UNUSEDPARAM */

    // ---------------- Clocks & reset (external / common) ----------------
    logic reset_n;                  // Reset#            (active-low, async)  -- MAC-driven

    // ---------------- MAC -> PHY : Tx data ----------------
    logic [TX_DATA_WIDTH-1:0] tx_data;        // TxData
    logic                     tx_data_valid;  // TxDataValid

    // ---------------- MAC -> PHY : command / config ----------------
    logic [3:0] power_down;            // PowerDown[3:0]   (P0=0,P0s=1,P1=2,P2=3; 4..15 PHY-specific)
    logic [3:0] rate;                  // Rate[3:0]        (Gen5=4 / Gen6=5)
    logic [2:0] width;                 // Width[2:0]       Tx datapath (SerDes: 10/20/40/80/160)
    logic [2:0] rx_width;              // RxWidth[2:0]     Rx datapath (SerDes-only)
    logic [3:0] tx_elec_idle;          // TxElecIdle[3:0]  (1b/2sym <=32GT/s; 1b/4sym at 64/128GT/s)
    logic       tx_detect_rx_loopback; // TxDetectRx/Loopback (loopback N/A in SerDes)
    logic       serdes_arch;           // SerDesArch       (static high; change only during Reset#)
    logic       rx_standby;            // RxStandby        (Rx active/standby in P0/P0s)
    logic       sris_enable;           // SRISEnable       (PCIe SRIS config)
    logic       pclk_change_ack;       // PclkChangeAck    (PCLK-as-PHY-input rate/width change)
    logic       async_power_change_ack;// AsyncPowerChangeAck (L1 substate power change w/o PCLK)

    // ---------------- MAC -> PHY : message-bus master ----------------
    logic [MB_WIDTH-1:0] m2p_message_bus;     // M2P_MessageBus[7:0]

    // ---------------- MAC -> PHY : optional L1-substate / deep-PM (may be tied off) ----------------
    logic       tx_commonmode_disable; // TxCommonmodeDisable (optional, async)
    logic       rx_ei_detect_disable;  // RxEIDetectDisable   (optional, async)
    logic       deep_pm_req_n;         // DeepPMReq#          (optional, async; full handshake)
    logic       restore_n;             // Restore#           (optional, async)

    // ---------------- PHY -> MAC : Rx data ----------------
    logic [RX_DATA_WIDTH-1:0] rx_data;        // RxData   (synchronous to rx_clk)
    logic                     rx_valid;       // RxValid  (SerDes: "rx_clk stable")

    // ---------------- PHY -> MAC : status ----------------
    logic       phy_status;            // PhyStatus        (single-cycle completion; async w/o PCLK)
    logic [2:0] rx_status;             // RxStatus[2:0]    (only 0b011 "Rx detected" in SerDes)
    logic       rx_elec_idle;          // RxElecIdle       (async; MAC self-detects EI-entry Gen5/6)
    logic       rx_standby_status;     // RxStandbyStatus
    logic       pclk_change_ok;        // PclkChangeOk     (PHY ready for PCLK/rate/width change)
    logic       refclk_required_n;     // RefClkRequired#
    logic       deep_pm_ack_n;         // DeepPMAck#       (if DeepPMReq# implemented)

    // ---------------- PHY -> MAC : message-bus responses ----------------
    logic [MB_WIDTH-1:0] p2m_message_bus;     // P2M_MessageBus[7:0]

    // =================================================================
    // Modports
    // =================================================================

    // MAC (our bridge): drives Tx + command + M2P; samples Rx + status + P2M.
    modport mac (
        input  pclk, rx_clk,
        output reset_n, tx_data, tx_data_valid,
               power_down, rate, width, rx_width, tx_elec_idle,
               tx_detect_rx_loopback, serdes_arch, rx_standby, sris_enable,
               pclk_change_ack, async_power_change_ack, m2p_message_bus,
               tx_commonmode_disable, rx_ei_detect_disable, deep_pm_req_n, restore_n,
        input  rx_data, rx_valid, phy_status, rx_status, rx_elec_idle,
               rx_standby_status, pclk_change_ok, refclk_required_n, deep_pm_ack_n,
               p2m_message_bus
    );

    // PHY (responder / BFM): mirror of `mac`.
    modport phy (
        input  pclk, rx_clk,
        input  reset_n, tx_data, tx_data_valid,
               power_down, rate, width, rx_width, tx_elec_idle,
               tx_detect_rx_loopback, serdes_arch, rx_standby, sris_enable,
               pclk_change_ack, async_power_change_ack, m2p_message_bus,
               tx_commonmode_disable, rx_ei_detect_disable, deep_pm_req_n, restore_n,
        output rx_data, rx_valid, phy_status, rx_status, rx_elec_idle,
               rx_standby_status, pclk_change_ok, refclk_required_n, deep_pm_ack_n,
               p2m_message_bus
    );

    // Passive monitor: everything input.
    modport mon (
        input pclk, rx_clk, reset_n, tx_data, tx_data_valid,
              power_down, rate, width, rx_width, tx_elec_idle,
              tx_detect_rx_loopback, serdes_arch, rx_standby, sris_enable,
              pclk_change_ack, async_power_change_ack, m2p_message_bus,
              tx_commonmode_disable, rx_ei_detect_disable, deep_pm_req_n, restore_n,
              rx_data, rx_valid, phy_status, rx_status, rx_elec_idle,
              rx_standby_status, pclk_change_ok, refclk_required_n, deep_pm_ack_n,
              p2m_message_bus
    );

`ifndef VERILATOR
    // UVM/VCS clocking blocks (Tier-2 UVM, item 8, and PyUVM Tier 1b consume these).
    // Excluded from the open-source Verilator lint pass; validated by review under VCS.
    clocking mac_cb @(posedge pclk);
        default input #1step output #1;
        output reset_n, tx_data, tx_data_valid, power_down, rate, width, rx_width,
               tx_elec_idle, tx_detect_rx_loopback, serdes_arch, rx_standby, sris_enable,
               pclk_change_ack, async_power_change_ack, m2p_message_bus;
        input  phy_status, rx_status, rx_elec_idle, rx_standby_status, pclk_change_ok,
               refclk_required_n, deep_pm_ack_n, p2m_message_bus;
    endclocking

    clocking rx_cb @(posedge rx_clk);
        default input #1step;
        input rx_data, rx_valid;
    endclocking

    clocking mon_cb @(posedge pclk);
        default input #1step;
        input reset_n, tx_data, tx_data_valid, power_down, rate, width, rx_width,
              tx_elec_idle, tx_detect_rx_loopback, rx_standby, m2p_message_bus,
              phy_status, rx_status, rx_elec_idle, rx_standby_status, pclk_change_ok,
              p2m_message_bus;
    endclocking
`endif

endinterface

`ifdef PIPE7_MAC_IF_LINT
// Lint-only elaboration wrapper (open-source gate). Instantiates the interface so the
// tool elaborates and width-checks the contract. Not compiled by VCS/UVM.
module pipe7_mac_if_lint_top (input logic pclk, input logic rx_clk);
    pipe7_mac_if u_if (.pclk(pclk), .rx_clk(rx_clk));
endmodule
`endif
