// credit_fc_props.sv — SymbiYosys formal proof for the RDI egress credit flow control
// (closure-plan item 24). Yosys's Verilog frontend cannot parse the SV package-import module
// header of src/pipe7_rdi_egress.sv, so — following the established fifo_cdc methodology — this
// is a faithful plain-Verilog model of the egress credit counter + emit FSM (mirrors
// pipe7_rdi_egress.sv exactly: CW=$clog2(2*CREDITS+1), credits reset to CREDITS, one credit
// consumed per emitted word, rdi_crd added back).
//
// Assume-guarantee: the RDI sink only returns credits for words it has actually consumed, so
// the environment constraint is rdi_crd <= outstanding (words emitted but not yet freed). Under
// that protocol the proof establishes:
//   P1  no underflow : credits==0  ->  no word is emitted this cycle (emit_word low).
//   P2  no over-credit: credits <= CREDITS  (the sink never inflates the budget).
//   P3  word_idx stays in range [0, FPB-1].
// Cover:
//   C1  credits reaches 0 (fully in flight), then returns to CREDITS (fully drained).

`default_nettype none
`timescale 1ns/1ps

module credit_fc_props #(
    parameter integer RDI_WIDTH = 64,
    parameter integer CREDITS   = 8
) (
    input wire clk,
    input wire rst_n
);
    localparam integer FPB = 128 / RDI_WIDTH;      // flits per block (=2 at 64b)
    localparam integer IW  = (FPB <= 1) ? 1 : $clog2(FPB + 1);
    localparam integer CW  = $clog2(2*CREDITS + 1); // credit-counter width

    // Free inputs.
    wire        blk_valid;
    wire [1:0]  rdi_crd;         // credits returned by the sink this cycle (0..2)

    localparam E_IDLE = 1'b0, E_EMIT = 1'b1;
    // State (mirrors pipe7_rdi_egress). Explicit init = reset state so BMC starts clean.
    reg              state    = E_IDLE;
    reg [IW-1:0]     word_idx = {IW{1'b0}};
    reg [CW-1:0]     credits  = CREDITS[CW-1:0];

    wire have_credit = (credits != 0);
    wire emit_word   = (state == E_EMIT) && have_credit;

    // Outstanding words = emitted but not yet freed by the sink (for the assume-guarantee).
    reg [CW:0] outstanding = {(CW+1){1'b0}};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= E_IDLE;
            word_idx    <= {IW{1'b0}};
            credits     <= CREDITS[CW-1:0];
            outstanding <= {(CW+1){1'b0}};
        end else begin
            credits <= credits - (emit_word ? 1'b1 : 1'b0) + rdi_crd;
            outstanding <= outstanding + (emit_word ? 1'b1 : 1'b0) - rdi_crd;
            case (state)
                E_IDLE: begin
                    word_idx <= {IW{1'b0}};
                    if (blk_valid) state <= E_EMIT;
                end
                E_EMIT: if (emit_word) begin
                    if (word_idx == (FPB-1)) state <= E_IDLE;
                    else                     word_idx <= word_idx + 1'b1;
                end
                default: state <= E_IDLE;
            endcase
        end
    end

`ifdef FORMAL
    reg f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;

    // The sink protocol: it returns credits only for words it has actually consumed, so it
    // never returns more than are outstanding (assume-guarantee); the bus is 0..2 wide.
    always @(*) begin
        assume(rdi_crd <= 2);
        assume(rdi_crd <= outstanding);
    end

    always @(posedge clk) if (f_past_valid && rst_n) begin
        // P1 no underflow: a word is emitted only when a credit is available.
        assert(!(emit_word && credits == 0));
        // P2 the sink never inflates the budget beyond CREDITS.
        assert(credits <= CREDITS);
        // P3 word index bounded.
        assert(word_idx <= (FPB-1));
        // Bookkeeping invariant: credits + outstanding == CREDITS (closed loop).
        assert(credits + outstanding == CREDITS);
    end

    // Cover: fully in flight (credits==0), then later fully drained back to CREDITS.
    reg f_was_zero = 1'b0;
    always @(posedge clk or negedge rst_n)
        if (!rst_n)            f_was_zero <= 1'b0;
        else if (credits == 0) f_was_zero <= 1'b1;
    always @(posedge clk) if (rst_n) begin
        cover(f_past_valid && credits == 0);
        cover(f_past_valid && f_was_zero && credits == CREDITS);
    end
`endif
endmodule
`default_nettype wire
