
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

endpackage
