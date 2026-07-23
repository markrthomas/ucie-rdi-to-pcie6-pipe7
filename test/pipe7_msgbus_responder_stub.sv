
`timescale 1ns/1ps

/**
 * pipe7_msgbus_responder_stub -- lightweight, non-UVM PHY-side message-bus responder for the
 * Verilator item-4 smoke. It parses the MAC's M2P framing (PIPE 7.1 §6.1.4.2) and answers:
 *   - read              : after RC_LATENCY cycles, read_completion = {READ_COMPLETION,0}, Data
 *   - write_committed   : stores the byte, then write_ack = {WRITE_ACK,0}
 *   - write_uncommitted : stores the byte, no response
 *
 * It holds a tiny register array indexed by the low address bits (enough to prove a
 * read/write round-trip); the spec-timed BFM with the full register model lives in the
 * UVM/PyUVM tiers (items 10/14). Idle byte = 0x00 (crosscheck G1/G2/G3).
 */
module pipe7_msgbus_responder_stub
    import pipe7_pkg::*;
#(
    parameter int RC_LATENCY = 3,
    parameter int MEM_BITS   = 4          // 2**MEM_BITS registers indexed by addr[MEM_BITS-1:0]
) (
    input  logic                     pclk,
    input  logic                     reset_n,
    input  logic [MB_BUS_WIDTH-1:0]  m2p,
    output logic [MB_BUS_WIDTH-1:0]  p2m
);

    localparam logic [7:0] MB_IDLE = 8'h00;
    localparam int         MEM_N   = (1 << MEM_BITS);

    typedef enum logic [2:0] {
        R_IDLE,
        R_RD_ADDRLO,
        R_RC_DELAY,
        R_RC1,
        R_RC2,
        R_WR_ADDRLO,
        R_WR_DATA,
        R_WACK
    } rstate_e;

    rstate_e                  rstate;
    logic [3:0]               addr_hi;
    logic [MB_ADDR_WIDTH-1:0] addr;
    logic                     committed;
    int                       cnt;
    logic [7:0]               mem [MEM_N];

    wire [MEM_BITS-1:0] idx = addr[MEM_BITS-1:0];

    always_ff @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            rstate    <= R_IDLE;
            p2m       <= MB_IDLE;
            addr_hi   <= '0;
            addr      <= '0;
            committed <= 1'b0;
            cnt       <= 0;
            // Deterministic contents so reads return a known value: mem[i] = 0xA0 + i.
            for (int i = 0; i < MEM_N; i++) mem[i] <= 8'hA0 + i[7:0];
        end else begin
            p2m <= MB_IDLE;                      // default idle unless a response byte is driven

            unique case (rstate)
                R_IDLE: begin
                    if (m2p != MB_IDLE) begin
                        addr_hi <= m2p[3:0];
                        unique case (m2p[7:4])
                            MB_READ:            rstate <= R_RD_ADDRLO;
                            MB_WRITE_UNCOMMIT: begin committed <= 1'b0; rstate <= R_WR_ADDRLO; end
                            MB_WRITE_COMMIT:   begin committed <= 1'b1; rstate <= R_WR_ADDRLO; end
                            default:            rstate <= R_IDLE;   // NOP / reserved: ignore
                        endcase
                    end
                end

                R_RD_ADDRLO: begin
                    addr   <= {addr_hi, m2p};
                    cnt    <= RC_LATENCY;
                    rstate <= R_RC_DELAY;
                end

                R_RC_DELAY: begin
                    if (cnt > 1) cnt <= cnt - 1;
                    else         rstate <= R_RC1;
                end

                R_RC1: begin
                    p2m    <= {MB_READ_COMPLETION, 4'h0};
                    rstate <= R_RC2;
                end

                R_RC2: begin
                    p2m    <= mem[idx];
                    rstate <= R_IDLE;
                end

                R_WR_ADDRLO: begin
                    addr   <= {addr_hi, m2p};
                    rstate <= R_WR_DATA;
                end

                R_WR_DATA: begin
                    mem[idx] <= m2p;
                    if (committed) begin
                        cnt    <= RC_LATENCY;
                        rstate <= R_WACK;
                    end else begin
                        rstate <= R_IDLE;
                    end
                end

                R_WACK: begin
                    // Small delay then the single-byte write_ack.
                    if (cnt > 1) begin
                        cnt <= cnt - 1;
                    end else begin
                        p2m    <= {MB_WRITE_ACK, 4'h0};
                        rstate <= R_IDLE;
                    end
                end

                default: rstate <= R_IDLE;
            endcase
        end
    end

endmodule
