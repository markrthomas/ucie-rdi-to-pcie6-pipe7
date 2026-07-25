
`timescale 1ns/1ps

/**
 * pipe7_seq_lib -- sequences + tests for the PIPE 7.1 MAC UVM env (closure-plan item 8).
 * Imports pipe7_mac_pkg (transactions/env) so the env package stays sequence/test-free
 * (no circular package import). VCS/UVM 1.2, authored-and-review-validated.
 */
package pipe7_seq_lib;

    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import pipe7_pkg::*;
    import pipe7_mac_pkg::*;

    // ---------------- Sequences ----------------
    class pipe7_rdi_base_seq extends uvm_sequence #(rdi_transaction);
        `uvm_object_utils(pipe7_rdi_base_seq)
        int unsigned n = 16;
        function new(string name = "pipe7_rdi_base_seq");
            super.new(name);
        endfunction
    endclass

    // Random 128-bit payloads, randomly tagged data / ordered-set.
    class pipe7_rdi_random_seq extends pipe7_rdi_base_seq;
        `uvm_object_utils(pipe7_rdi_random_seq)
        function new(string name = "pipe7_rdi_random_seq");
            super.new(name);
        endfunction
        task body();
            repeat (n) begin
                rdi_transaction tr = rdi_transaction::type_id::create("tr");
                start_item(tr);
                if (!tr.randomize())
                    `uvm_error("SEQ", "randomize failed")
                finish_item(tr);
            end
        endtask
    endclass

    // All data blocks (sync header 0b10 only) -- exercises the common framing path.
    class pipe7_rdi_data_seq extends pipe7_rdi_base_seq;
        `uvm_object_utils(pipe7_rdi_data_seq)
        function new(string name = "pipe7_rdi_data_seq");
            super.new(name);
        endfunction
        task body();
            repeat (n) begin
                rdi_transaction tr = rdi_transaction::type_id::create("tr");
                start_item(tr);
                if (!tr.randomize() with { is_os == 1'b0; })
                    `uvm_error("SEQ", "randomize failed")
                finish_item(tr);
            end
        endtask
    endclass

    // Ordered-set-heavy stream -- exercises the OS sync header (0b01).
    class pipe7_rdi_os_seq extends pipe7_rdi_base_seq;
        `uvm_object_utils(pipe7_rdi_os_seq)
        function new(string name = "pipe7_rdi_os_seq");
            super.new(name);
        endfunction
        task body();
            repeat (n) begin
                rdi_transaction tr = rdi_transaction::type_id::create("tr");
                start_item(tr);
                if (!tr.randomize() with { is_os == 1'b1; })
                    `uvm_error("SEQ", "randomize failed")
                finish_item(tr);
            end
        endtask
    endclass

    // ---------------- Control-plane sequences (item 9) ----------------
    class pipe7_ctrl_base_seq extends uvm_sequence #(ctrl_transaction);
        `uvm_object_utils(pipe7_ctrl_base_seq)
        function new(string name = "pipe7_ctrl_base_seq"); super.new(name); endfunction

        // Helper: issue one request with explicit fields.
        task do_req(bit [1:0] kind, bit [3:0] pd, bit [3:0] rate, bit [2:0] w, bit [2:0] rxw);
            ctrl_transaction tr = ctrl_transaction::type_id::create("tr");
            start_item(tr);
            tr.kind = kind; tr.pd = pd; tr.rate = rate; tr.width = w; tr.rxw = rxw;
            finish_item(tr);
        endtask
    endclass

    // Directed scenario mirroring the SV item-3 smoke: power ladder, Gen5<->Gen6 rate, a Width
    // change, and two illegal Rate changes (in P2 and P0s) that must be rejected.
    class pipe7_ctrl_directed_seq extends pipe7_ctrl_base_seq;
        `uvm_object_utils(pipe7_ctrl_directed_seq)
        function new(string name = "pipe7_ctrl_directed_seq"); super.new(name); endfunction
        task body();
            do_req(0, PD_P0S, RATE_GEN5, W_160, W_160);   // power ladder
            do_req(0, PD_P1,  RATE_GEN5, W_160, W_160);
            do_req(0, PD_P2,  RATE_GEN5, W_160, W_160);
            do_req(0, PD_P0,  RATE_GEN5, W_160, W_160);
            do_req(1, PD_P0,  RATE_GEN6, W_160, W_160);   // rate Gen5->Gen6 (legal in P0)
            do_req(1, PD_P0,  RATE_GEN5, W_160, W_160);   // rate Gen6->Gen5
            do_req(2, PD_P0,  RATE_GEN5, W_80,  W_80);    // width 160->80
            do_req(0, PD_P2,  RATE_GEN5, W_80,  W_80);    // enter P2
            do_req(1, PD_P2,  RATE_GEN6, W_80,  W_80);    // illegal rate in P2 -> reject
            do_req(0, PD_P0,  RATE_GEN5, W_80,  W_80);    // back to P0
            do_req(0, PD_P0S, RATE_GEN5, W_80,  W_80);    // enter P0s
            do_req(1, PD_P0S, RATE_GEN6, W_80,  W_80);    // illegal rate in P0s -> reject
            do_req(0, PD_P0,  RATE_GEN5, W_80,  W_80);    // back to P0
        endtask
    endclass

    // ---------------- Message-bus sequences (item 10) ----------------
    class pipe7_msgbus_base_seq extends uvm_sequence #(msgbus_transaction);
        `uvm_object_utils(pipe7_msgbus_base_seq)
        function new(string name = "pipe7_msgbus_base_seq"); super.new(name); endfunction

        task do_txn(bit write, bit committed, bit [MB_ADDR_WIDTH-1:0] addr,
                    bit [MB_DATA_WIDTH-1:0] wdata);
            msgbus_transaction tr = msgbus_transaction::type_id::create("tr");
            start_item(tr);
            tr.write = write; tr.committed = committed; tr.addr = addr; tr.wdata = wdata;
            finish_item(tr);
        endtask
    endclass

    // Directed scenario mirroring the SV item-4 smoke: uncommitted/committed writes, a read of
    // a preloaded address, and a committed-write -> read round-trip.
    class pipe7_msgbus_directed_seq extends pipe7_msgbus_base_seq;
        `uvm_object_utils(pipe7_msgbus_directed_seq)
        function new(string name = "pipe7_msgbus_directed_seq"); super.new(name); endfunction
        task body();
            do_txn(1'b1, 1'b0, REG_PHY_TX_CTRL_BASE + 1, 8'h5A);   // write_uncommitted
            do_txn(1'b1, 1'b1, REG_PHY_TX_CTRL_BASE + 2, 8'h3C);   // write_committed
            do_txn(1'b0, 1'b0, REG_PHY_TX_CTRL_BASE + 5, 8'h00);   // read preloaded (0xA5)
            do_txn(1'b1, 1'b1, REG_PHY_TX_CTRL_BASE + 7, 8'hE1);   // write_committed
            do_txn(1'b0, 1'b0, REG_PHY_TX_CTRL_BASE + 7, 8'h00);   // read back -> 0xE1
        endtask
    endclass

    // ---------------- Tests ----------------
    class pipe7_mac_base_test extends uvm_test;
        `uvm_component_utils(pipe7_mac_base_test)
        pipe7_mac_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = pipe7_mac_env::type_id::create("env", this);
        endfunction

        function void end_of_elaboration_phase(uvm_phase phase);
            uvm_top.print_topology();
        endfunction
    endclass

    // Sanity: drive N random payloads and check the RDI round-trip through the framer/deframer.
    class pipe7_mac_sanity_test extends pipe7_mac_base_test;
        `uvm_component_utils(pipe7_mac_sanity_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            pipe7_rdi_random_seq seq;
            phase.raise_objection(this);
            seq = pipe7_rdi_random_seq::type_id::create("seq");
            seq.n = 32;
            seq.start(env.rdi_tx_agent.seqr);
            #2000ns;   // let the framer drain and the round-trip complete
            phase.drop_objection(this);
        endtask
    endclass

    // Control-plane test: the directed PowerDown/Rate/Width scenario against the PHY responder,
    // checked by the legality scoreboard (expect 11 completions + 2 rejections).
    class pipe7_ctrl_test extends pipe7_mac_base_test;
        `uvm_component_utils(pipe7_ctrl_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            pipe7_ctrl_directed_seq seq;
            phase.raise_objection(this);
            seq = pipe7_ctrl_directed_seq::type_id::create("seq");
            seq.start(env.ctrl_agent.seqr);
            #500ns;
            phase.drop_objection(this);
        endtask
    endclass

    // Message-bus test: directed register read/writes checked by the msgbus scoreboard.
    class pipe7_msgbus_test extends pipe7_mac_base_test;
        `uvm_component_utils(pipe7_msgbus_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            pipe7_msgbus_directed_seq seq;
            phase.raise_objection(this);
            seq = pipe7_msgbus_directed_seq::type_id::create("seq");
            seq.start(env.mbus_agent.seqr);
            #500ns;
            phase.drop_objection(this);
        endtask
    endclass

    // RX-path test: the PHY BFM drives RxData (loopback of the framed stream); the deframer
    // recovers it and the round-trip (mirrored-queue) scoreboard checks the RX direction.
    class pipe7_rx_test extends pipe7_mac_base_test;
        `uvm_component_utils(pipe7_rx_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            pipe7_rdi_random_seq seq;
            phase.raise_objection(this);
            seq = pipe7_rdi_random_seq::type_id::create("seq");
            seq.n = 48;
            seq.start(env.rdi_tx_agent.seqr);
            #3000ns;
            phase.drop_objection(this);
        endtask
    endclass

    // Combined: datapath round-trip + control scenario + message-bus scenario together.
    class pipe7_full_test extends pipe7_mac_base_test;
        `uvm_component_utils(pipe7_full_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            pipe7_rdi_random_seq      dseq;
            pipe7_ctrl_directed_seq   cseq;
            pipe7_msgbus_directed_seq mseq;
            phase.raise_objection(this);
            dseq = pipe7_rdi_random_seq::type_id::create("dseq");
            dseq.n = 32;
            cseq = pipe7_ctrl_directed_seq::type_id::create("cseq");
            mseq = pipe7_msgbus_directed_seq::type_id::create("mseq");
            fork
                dseq.start(env.rdi_tx_agent.seqr);
                cseq.start(env.ctrl_agent.seqr);
                mseq.start(env.mbus_agent.seqr);
            join
            #2000ns;
            phase.drop_objection(this);
        endtask
    endclass

endpackage
