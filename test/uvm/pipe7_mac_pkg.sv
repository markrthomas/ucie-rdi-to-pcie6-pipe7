
`timescale 1ns/1ps

/**
 * pipe7_mac_pkg -- UVM base environment for the PIPE 7.1 MAC-facing bridge (closure-plan
 * item 8). VCS/UVM 1.2, authored-and-review-validated (not run in the OSS environment).
 *
 * This item stands up the DATAPATH env: an active RDI agent drives 128-bit block payloads,
 * a passive MAC monitor observes the PIPE MAC interface, an RDI-RX monitor captures the
 * recovered payloads, and a scoreboard checks the RDI-payload round-trip through the Gen5
 * 128b/130b framer/deframer (looped back by the PHY BFM in the top). Coverage samples the
 * framing mode + Rate/Width. The control-plane PHY-responder agent + checker (item 9), the
 * Gen6/message-bus paths (item 10), and full coverage closure (item 11) extend this env.
 *
 * Mirrors the predecessor's agent/scoreboard structure (queue/drain per-stream compare).
 */
package pipe7_mac_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import pipe7_pkg::*;

    // ==================================================================
    // Transaction
    // ==================================================================
    class rdi_transaction extends uvm_sequence_item;
        rand bit [BLOCK_PAYLOAD-1:0] data;
        rand bit                     is_os;

        `uvm_object_utils_begin(rdi_transaction)
            `uvm_field_int(data,  UVM_ALL_ON)
            `uvm_field_int(is_os, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "rdi_transaction");
            super.new(name);
        endfunction

        function string convert2string();
            return $sformatf("data=0x%032x is_os=%0b", data, is_os);
        endfunction
    endclass

    // ==================================================================
    // RDI active agent: driver / monitor / sequencer
    // ==================================================================
    class rdi_driver extends uvm_driver #(rdi_transaction);
        `uvm_component_utils(rdi_driver)
        virtual ucie_rdi_if vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual ucie_rdi_if)::get(this, "", "rdi_tx_vif", vif))
                `uvm_fatal("NOVIF", "rdi_tx_vif not set for rdi_driver")
        endfunction

        task run_phase(uvm_phase phase);
            @(vif.drv_cb);
            vif.drv_cb.valid <= 1'b0;   // idle via the clocking block (single driver)
            forever begin
                rdi_transaction tr;
                seq_item_port.get_next_item(tr);
                drive(tr);
                seq_item_port.item_done();
            end
        endtask

        // Single-accept handshake: assert valid, hold until a clocked sample shows ready,
        // then deassert (one beat per posedge where ready is high).
        task drive(rdi_transaction tr);
            @(vif.drv_cb);
            vif.drv_cb.data  <= tr.data;
            vif.drv_cb.is_os <= tr.is_os;
            vif.drv_cb.valid <= 1'b1;
            do @(vif.drv_cb); while (vif.drv_cb.ready !== 1'b1);
            vif.drv_cb.valid <= 1'b0;
        endtask
    endclass

    class rdi_monitor extends uvm_monitor;
        `uvm_component_utils(rdi_monitor)
        virtual ucie_rdi_if vif;
        bit check_ready = 1'b1;                     // TX honors ready; RX (deframer) has none
        uvm_analysis_port #(rdi_transaction) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual ucie_rdi_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "vif not set for rdi_monitor")
            void'(uvm_config_db#(bit)::get(this, "", "check_ready", check_ready));
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(vif.mon_cb);
                if (vif.mon_cb.valid === 1'b1 &&
                    (!check_ready || vif.mon_cb.ready === 1'b1)) begin
                    rdi_transaction tr = rdi_transaction::type_id::create("tr");
                    tr.data  = vif.mon_cb.data;
                    tr.is_os = vif.mon_cb.is_os;
                    ap.write(tr);
                end
            end
        endtask
    endclass

    class rdi_agent extends uvm_agent;
        `uvm_component_utils(rdi_agent)
        rdi_driver                            drv;
        rdi_monitor                           mon;
        uvm_sequencer #(rdi_transaction)      seqr;
        uvm_analysis_port #(rdi_transaction)  ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            mon = rdi_monitor::type_id::create("mon", this);
            if (get_is_active() == UVM_ACTIVE) begin
                drv  = rdi_driver::type_id::create("drv", this);
                seqr = uvm_sequencer#(rdi_transaction)::type_id::create("seqr", this);
            end
        endfunction

        function void connect_phase(uvm_phase phase);
            ap = mon.ap;
            if (get_is_active() == UVM_ACTIVE)
                drv.seq_item_port.connect(seqr.seq_item_export);
        endfunction
    endclass

    // ==================================================================
    // Passive MAC monitor: observes the PIPE MAC interface (control + Tx stream)
    // ==================================================================
    class pipe7_mac_sample extends uvm_object;
        bit [3:0] rate;
        bit [2:0] width;
        bit [3:0] power_down;
        bit       tx_data_valid;
        `uvm_object_utils(pipe7_mac_sample)
        function new(string name = "pipe7_mac_sample"); super.new(name); endfunction
    endclass

    class pipe7_mac_monitor extends uvm_monitor;
        `uvm_component_utils(pipe7_mac_monitor)
        virtual pipe7_mac_if vif;
        uvm_analysis_port #(pipe7_mac_sample) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual pipe7_mac_if)::get(this, "", "mac_vif", vif))
                `uvm_fatal("NOVIF", "mac_vif not set for pipe7_mac_monitor")
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(vif.mon_cb);
                begin
                    pipe7_mac_sample s = pipe7_mac_sample::type_id::create("s");
                    s.rate          = vif.mon_cb.rate;
                    s.width         = vif.mon_cb.width;
                    s.power_down    = vif.mon_cb.power_down;
                    s.tx_data_valid = vif.mon_cb.tx_data_valid;
                    ap.write(s);
                end
            end
        endtask
    endclass

    // ==================================================================
    // Coverage: framing mode + Rate x Width + PowerDown state
    // ==================================================================
    class pipe7_mac_coverage extends uvm_subscriber #(pipe7_mac_sample);
        `uvm_component_utils(pipe7_mac_coverage)
        pipe7_mac_sample cur;

        covergroup cg_ctrl;
            cp_rate: coverpoint cur.rate {
                bins gen5 = {4};
                bins gen6 = {5};
            }
            cp_width: coverpoint cur.width {
                bins w10 = {0}; bins w20 = {1}; bins w40 = {2};
                bins w80 = {3}; bins w160 = {4};
            }
            cp_pd: coverpoint cur.power_down {
                bins p0 = {0}; bins p0s = {1}; bins p1 = {2}; bins p2 = {3};
            }
            x_rate_width: cross cp_rate, cp_width;
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_ctrl = new();
        endfunction

        function void write(pipe7_mac_sample t);
            cur = t;
            cg_ctrl.sample();
        endfunction
    endclass

    // is_os / framing-mode coverage off the recovered RDI stream.
    class pipe7_framing_coverage extends uvm_subscriber #(rdi_transaction);
        `uvm_component_utils(pipe7_framing_coverage)
        rdi_transaction cur;
        covergroup cg_frame;
            cp_is_os: coverpoint cur.is_os { bins data = {0}; bins os = {1}; }
        endgroup
        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_frame = new();
        endfunction
        function void write(rdi_transaction t);
            cur = t;
            cg_frame.sample();
        endfunction
    endclass

    // ==================================================================
    // Scoreboard: RDI-payload round-trip (TX driven == RX recovered, in order)
    // ==================================================================
    class pipe7_mac_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(pipe7_mac_scoreboard)

        uvm_tlm_analysis_fifo #(rdi_transaction) exp_fifo;   // driven TX payloads
        uvm_tlm_analysis_fifo #(rdi_transaction) act_fifo;   // recovered RX payloads
        int unsigned matched;
        int unsigned mismatched;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            exp_fifo = new("exp_fifo", this);
            act_fifo = new("act_fifo", this);
        endfunction

        // Each recovered payload must match the next driven payload in order.
        task run_phase(uvm_phase phase);
            rdi_transaction act, exp;
            forever begin
                act_fifo.get(act);
                exp_fifo.get(exp);
                if (act.data === exp.data && act.is_os === exp.is_os) begin
                    matched++;
                end else begin
                    mismatched++;
                    `uvm_error("SB", $sformatf("round-trip mismatch:\n  exp %s\n  act %s",
                                               exp.convert2string(), act.convert2string()))
                end
            end
        endtask

        function void check_phase(uvm_phase phase);
            // Drain: any payload driven but never recovered is a leak.
            if (exp_fifo.used() != 0)
                `uvm_error("SB", $sformatf("%0d driven payloads never recovered", exp_fifo.used()))
            if (matched == 0)
                `uvm_error("SB", "no payloads matched (empty run?)")
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SB", $sformatf("round-trip: matched=%0d mismatched=%0d", matched, mismatched),
                      UVM_LOW)
        endfunction
    endclass

    // ==================================================================
    // Control plane (item 9): request transaction, active control agent,
    // PHY-responder BFM, and a legality scoreboard.
    // ==================================================================
    class ctrl_transaction extends uvm_sequence_item;
        rand bit [1:0] kind;    // 0=REQ_POWER, 1=REQ_RATE, 2=REQ_WIDTH
        rand bit [3:0] pd;
        rand bit [3:0] rate;
        rand bit [2:0] width;
        rand bit [2:0] rxw;
        // Captured by the driver after the request completes:
        bit           outcome_done;
        bit           outcome_error;
        bit [3:0]     act_pd, act_rate;
        bit [2:0]     act_width, act_rxw;

        constraint c_kind  { kind inside {0, 1, 2}; }
        constraint c_pd    { pd inside {PD_P0, PD_P0S, PD_P1, PD_P2}; }
        constraint c_rate  { rate inside {RATE_GEN5, RATE_GEN6}; }
        constraint c_width { width inside {W_80, W_160}; rxw inside {W_80, W_160}; }

        `uvm_object_utils_begin(ctrl_transaction)
            `uvm_field_int(kind,  UVM_ALL_ON)
            `uvm_field_int(pd,    UVM_ALL_ON)
            `uvm_field_int(rate,  UVM_ALL_ON)
            `uvm_field_int(width, UVM_ALL_ON)
            `uvm_field_int(rxw,   UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "ctrl_transaction");
            super.new(name);
        endfunction
    endclass

    class ctrl_driver extends uvm_driver #(ctrl_transaction);
        `uvm_component_utils(ctrl_driver)
        virtual pipe7_ctrl_if cvif;
        virtual pipe7_mac_if  mvif;
        uvm_analysis_port #(ctrl_transaction) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual pipe7_ctrl_if)::get(this, "", "ctrl_vif", cvif))
                `uvm_fatal("NOVIF", "ctrl_vif not set for ctrl_driver")
            if (!uvm_config_db#(virtual pipe7_mac_if)::get(this, "", "mac_vif", mvif))
                `uvm_fatal("NOVIF", "mac_vif not set for ctrl_driver")
        endfunction

        task run_phase(uvm_phase phase);
            @(cvif.drv_cb);
            cvif.drv_cb.req_valid <= 1'b0;
            forever begin
                ctrl_transaction tr;
                seq_item_port.get_next_item(tr);
                drive(tr);
                ap.write(tr);
                seq_item_port.item_done();
            end
        endtask

        task drive(ctrl_transaction tr);
            int wcnt;
            @(cvif.drv_cb);
            cvif.drv_cb.req_kind       <= tr.kind;
            cvif.drv_cb.req_power_down <= tr.pd;
            cvif.drv_cb.req_rate       <= tr.rate;
            cvif.drv_cb.req_width      <= tr.width;
            cvif.drv_cb.req_rxwidth    <= tr.rxw;
            cvif.drv_cb.req_valid      <= 1'b1;
            @(cvif.drv_cb);
            cvif.drv_cb.req_valid      <= 1'b0;
            tr.outcome_done  = 1'b0;
            tr.outcome_error = 1'b0;
            for (wcnt = 0; wcnt < 200; wcnt++) begin
                @(cvif.drv_cb);
                if (cvif.drv_cb.done === 1'b1)      begin tr.outcome_done  = 1'b1; break; end
                if (cvif.drv_cb.req_error === 1'b1) begin tr.outcome_error = 1'b1; break; end
            end
            // Capture the resulting PIPE command state (driven by the FSM).
            tr.act_pd    = mvif.power_down;
            tr.act_rate  = mvif.rate;
            tr.act_width = mvif.width;
            tr.act_rxw   = mvif.rx_width;
        endtask
    endclass

    class pipe7_ctrl_agent extends uvm_agent;
        `uvm_component_utils(pipe7_ctrl_agent)
        ctrl_driver                            drv;
        uvm_sequencer #(ctrl_transaction)      seqr;
        uvm_analysis_port #(ctrl_transaction)  ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            drv  = ctrl_driver::type_id::create("drv", this);
            seqr = uvm_sequencer#(ctrl_transaction)::type_id::create("seqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            ap = drv.ap;
            drv.seq_item_port.connect(seqr.seq_item_export);
        endfunction
    endclass

    // Independently-timed PHY responder: answers each PowerDown/Rate/Width change with a
    // single-cycle PhyStatus after `latency` cycles (mirrors pipe7_phy_responder_stub).
    class pipe7_phy_agent extends uvm_component;
        `uvm_component_utils(pipe7_phy_agent)
        virtual pipe7_mac_if vif;
        int unsigned latency = 4;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual pipe7_mac_if)::get(this, "", "mac_vif", vif))
                `uvm_fatal("NOVIF", "mac_vif not set for pipe7_phy_agent")
            void'(uvm_config_db#(int unsigned)::get(this, "", "latency", latency));
        endfunction

        task run_phase(uvm_phase phase);
            bit [3:0] prev_pd, prev_rate, cur_pd, cur_rate;
            bit [2:0] prev_w, prev_rxw, cur_w, cur_rxw;
            bit       servicing;
            int       cnt;
            // Default the PHY-driven status/response signals.
            @(vif.phy_cb);
            vif.phy_cb.phy_status        <= 1'b0;
            vif.phy_cb.rx_status         <= 3'b000;
            vif.phy_cb.rx_elec_idle      <= 1'b0;
            vif.phy_cb.rx_standby_status <= 1'b0;
            vif.phy_cb.pclk_change_ok    <= 1'b0;
            vif.phy_cb.refclk_required_n <= 1'b1;
            vif.phy_cb.deep_pm_ack_n     <= 1'b1;
            vif.phy_cb.p2m_message_bus   <= '0;
            prev_pd = vif.phy_cb.power_down; prev_rate = vif.phy_cb.rate;
            prev_w  = vif.phy_cb.width;      prev_rxw  = vif.phy_cb.rx_width;
            servicing = 1'b0; cnt = 0;
            forever begin
                @(vif.phy_cb);
                vif.phy_cb.phy_status <= 1'b0;      // default-low; pulse for one cycle
                if (vif.phy_cb.reset_n !== 1'b1) begin
                    prev_pd = vif.phy_cb.power_down; prev_rate = vif.phy_cb.rate;
                    prev_w  = vif.phy_cb.width;      prev_rxw  = vif.phy_cb.rx_width;
                    servicing = 1'b0;
                    continue;
                end
                cur_pd = vif.phy_cb.power_down; cur_rate = vif.phy_cb.rate;
                cur_w  = vif.phy_cb.width;      cur_rxw  = vif.phy_cb.rx_width;
                if (!servicing) begin
                    if (cur_pd !== prev_pd || cur_rate !== prev_rate ||
                        cur_w  !== prev_w  || cur_rxw  !== prev_rxw) begin
                        prev_pd = cur_pd; prev_rate = cur_rate; prev_w = cur_w; prev_rxw = cur_rxw;
                        servicing = 1'b1; cnt = latency;
                    end
                end else begin
                    if (cnt > 1) cnt--;
                    else begin
                        vif.phy_cb.phy_status <= 1'b1;
                        servicing = 1'b0;
                    end
                end
            end
        endtask
    endclass

    // Control-plane legality scoreboard: replays an independent model and checks each request's
    // outcome (done vs req_error) and resulting command state (PIPE 7.1 Sec 8.4.1: a Rate/Width
    // change is legal only in PowerDown P0/P1).
    class pipe7_ctrl_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(pipe7_ctrl_scoreboard)
        uvm_tlm_analysis_fifo #(ctrl_transaction) fifo;
        // Model state (mirrors the FSM reset defaults).
        bit [3:0] m_pd   = PD_P0;
        bit [3:0] m_rate = RATE_GEN5;
        bit [2:0] m_w    = W_160;
        bit [2:0] m_rxw  = W_160;
        int unsigned n_done, n_reject, n_err;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            fifo = new("fifo", this);
        endfunction

        function bit rw_legal();
            return (m_pd == PD_P0) || (m_pd == PD_P1);
        endfunction

        task run_phase(uvm_phase phase);
            ctrl_transaction tr;
            forever begin
                fifo.get(tr);
                check(tr);
            end
        endtask

        function void check(ctrl_transaction tr);
            bit exp_done, exp_reject;
            exp_done = 1'b0; exp_reject = 1'b0;
            case (tr.kind)
                2'd0: begin  // REQ_POWER
                    m_pd = tr.pd; exp_done = 1'b1;
                end
                2'd1: begin  // REQ_RATE
                    if (rw_legal()) begin m_rate = tr.rate; exp_done = 1'b1; end
                    else exp_reject = 1'b1;
                end
                2'd2: begin  // REQ_WIDTH
                    if (rw_legal()) begin m_w = tr.width; m_rxw = tr.rxw; exp_done = 1'b1; end
                    else exp_reject = 1'b1;
                end
                default: exp_reject = 1'b1;
            endcase

            if (exp_done) begin
                if (!tr.outcome_done)
                    `uvm_error("CTRL_SB", $sformatf("kind=%0d expected done, got done=%0b err=%0b",
                                                    tr.kind, tr.outcome_done, tr.outcome_error))
                else begin
                    n_done++;
                    if (tr.act_pd !== m_pd || tr.act_rate !== m_rate ||
                        tr.act_width !== m_w || tr.act_rxw !== m_rxw)
                        `uvm_error("CTRL_SB", $sformatf(
                            "command-state mismatch kind=%0d: act(pd=%0d rate=%0d w=%0d rxw=%0d) exp(pd=%0d rate=%0d w=%0d rxw=%0d)",
                            tr.kind, tr.act_pd, tr.act_rate, tr.act_width, tr.act_rxw,
                            m_pd, m_rate, m_w, m_rxw))
                end
            end else begin
                if (!tr.outcome_error)
                    `uvm_error("CTRL_SB", $sformatf("kind=%0d expected reject, got done=%0b err=%0b",
                                                    tr.kind, tr.outcome_done, tr.outcome_error))
                else n_reject++;
            end
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("CTRL_SB", $sformatf("control-plane: done=%0d reject=%0d", n_done, n_reject),
                      UVM_LOW)
        endfunction
    endclass

    // ==================================================================
    // Environment
    // ==================================================================
    class pipe7_mac_env extends uvm_env;
        `uvm_component_utils(pipe7_mac_env)

        rdi_agent               rdi_tx_agent;   // active (datapath)
        rdi_monitor             rdi_rx_mon;     // passive (recovered payloads)
        pipe7_mac_monitor       mac_mon;
        pipe7_mac_scoreboard    sb;
        pipe7_mac_coverage      ctrl_cov;
        pipe7_framing_coverage  frame_cov;
        // Control plane (item 9)
        pipe7_ctrl_agent        ctrl_agent;     // active (PowerDown/Rate/Width requests)
        pipe7_phy_agent         phy_agent;      // PHY-responder BFM (drives PhyStatus)
        pipe7_ctrl_scoreboard   ctrl_sb;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            rdi_tx_agent = rdi_agent::type_id::create("rdi_tx_agent", this);
            uvm_config_db#(uvm_active_passive_enum)::set(this, "rdi_tx_agent", "is_active", UVM_ACTIVE);

            rdi_rx_mon = rdi_monitor::type_id::create("rdi_rx_mon", this);
            uvm_config_db#(bit)::set(this, "rdi_rx_mon", "check_ready", 1'b0);  // RX has no ready

            mac_mon   = pipe7_mac_monitor::type_id::create("mac_mon", this);
            sb        = pipe7_mac_scoreboard::type_id::create("sb", this);
            ctrl_cov  = pipe7_mac_coverage::type_id::create("ctrl_cov", this);
            frame_cov = pipe7_framing_coverage::type_id::create("frame_cov", this);

            ctrl_agent = pipe7_ctrl_agent::type_id::create("ctrl_agent", this);
            phy_agent  = pipe7_phy_agent::type_id::create("phy_agent", this);
            ctrl_sb    = pipe7_ctrl_scoreboard::type_id::create("ctrl_sb", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            // Datapath: TX driven payloads -> expected; RX recovered payloads -> actual.
            rdi_tx_agent.ap.connect(sb.exp_fifo.analysis_export);
            rdi_rx_mon.ap.connect(sb.act_fifo.analysis_export);
            rdi_rx_mon.ap.connect(frame_cov.analysis_export);
            mac_mon.ap.connect(ctrl_cov.analysis_export);
            // Control plane: each completed request -> legality scoreboard.
            ctrl_agent.ap.connect(ctrl_sb.fifo.analysis_export);
        endfunction
    endclass

    // Sequences and tests live in the pipe7_seq_lib package (it imports this one), which keeps
    // the env free of any sequence/test dependency and avoids a circular package import.

endpackage
