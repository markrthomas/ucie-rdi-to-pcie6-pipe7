
`timescale 1ns/1ps

/**
 * pipe7_msgbus_master -- PIPE 7.1 MAC-side message-bus (M2P) master. Closure-plan item 4.
 *
 * Role: turn a single register-access request from the controller side into the spec-shaped
 * M2P framing (PIPE 7.1 §6.1.4.2, Tables 6-10..6-14) and process the PHY's P2M response.
 * The 8-bit bus is PCLK-synchronous and reset by Reset#; idle = 0x00, and any non-idle byte
 * begins a transaction (crosscheck G1/G2/G3/G8).
 *
 * Framing driven on M2P (cmd in the upper nibble, Addr[11:8] in the lower nibble of byte 0):
 *   read              : {READ,        Addr[11:8]}, Addr[7:0]                 (2 bytes)
 *   write_uncommitted : {WR_UNCOMMIT, Addr[11:8]}, Addr[7:0], Data[7:0]      (3 bytes)
 *   write_committed   : {WR_COMMIT,   Addr[11:8]}, Addr[7:0], Data[7:0]      (3 bytes)
 *
 * Response consumed on P2M:
 *   read              : read_completion = {READ_COMPLETION, x}, Data[7:0]    (2 bytes)
 *   write_committed   : write_ack       = {WRITE_ACK, x}                     (start byte)
 *   write_uncommitted : none (completes once framed)
 *
 * Flow control (crosscheck G8): one outstanding transaction per master (enforced structurally
 * -- the FSM is single-transaction and holds `busy`); a committed write blocks until write_ack.
 *
 * Scope: control-plane message framing only. There is intentionally no response-timeout here
 * (the P2M max-latency timeout assertion is item 7); rsp_error is reserved for that item and
 * held low. A real design multiplexes several logical requesters ahead of this master; that
 * arbitration is added with the regfile write-through path in item 5+.
 */
module pipe7_msgbus_master
    import pipe7_pkg::*;
(
    input  logic                      pclk,
    input  logic                      reset_n,        // PIPE Reset# (async, active-low)

    // ---- Request interface (controller side) ----
    input  logic                      req_valid,      // accepted for one cycle when req_ready
    input  logic                      req_write,      // 1 = write, 0 = read
    input  logic                      req_committed,  // write only: 1 = committed (wait ack)
    input  logic [MB_ADDR_WIDTH-1:0]  req_addr,
    input  logic [MB_DATA_WIDTH-1:0]  req_wdata,
    output logic                      req_ready,      // high in idle (can accept a request)
    output logic                      busy,           // transaction in flight

    // ---- Response interface (controller side) ----
    output logic                      rsp_valid,      // 1-cycle pulse: transaction complete
    output logic                      rsp_is_read,    // qualifies rsp_rdata
    output logic [MB_DATA_WIDTH-1:0]  rsp_rdata,      // valid with rsp_valid when rsp_is_read
    output logic                      rsp_error,      // reserved (timeout/protocol) -- item 7

    // ---- Message bus ----
    output logic [MB_BUS_WIDTH-1:0]   m2p,            // M2P_MessageBus[7:0] (MAC -> PHY)
    input  logic [MB_BUS_WIDTH-1:0]   p2m             // P2M_MessageBus[7:0] (PHY -> MAC)
);

    localparam logic [7:0] MB_IDLE = 8'h00;

    typedef enum logic [2:0] {
        S_IDLE,        // driving idle; can accept a request
        S_ADDR,        // byte 1: Addr[7:0]
        S_WDATA,       // byte 2: Data[7:0] (writes)
        S_WR_FIN,      // uncommitted write framed -> completion pulse
        S_WACK_WAIT,   // committed write: await write_ack start byte
        S_RC_WAIT1,    // read: await read_completion start byte
        S_RC_WAIT2     // read: capture Data[7:0]
    } state_e;

    state_e                     state;
    logic                       wr_q;        // latched: this is a write
    logic                       committed_q; // latched: committed write
    logic [7:0]                 addr_lo_q;   // Addr[7:0] (byte 1); Addr[11:8] is sent in byte 0
    logic [MB_DATA_WIDTH-1:0]   wdata_q;

    // Command opcode for byte 0 from the latched request kind.
    function automatic logic [3:0] cmd_of(input logic wr, input logic committed);
        if (!wr)            return MB_READ;
        else if (committed) return MB_WRITE_COMMIT;
        else                return MB_WRITE_UNCOMMIT;
    endfunction

    assign req_ready = (state == S_IDLE);
    assign busy      = (state != S_IDLE);

    always_ff @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            state       <= S_IDLE;
            m2p         <= MB_IDLE;
            wr_q        <= 1'b0;
            committed_q <= 1'b0;
            addr_lo_q   <= '0;
            wdata_q     <= '0;
            rsp_valid   <= 1'b0;
            rsp_is_read <= 1'b0;
            rsp_rdata   <= '0;
            rsp_error   <= 1'b0;
        end else begin
            rsp_valid <= 1'b0;          // default-low 1-cycle pulse
            rsp_error <= 1'b0;          // reserved; never asserted this item
            m2p       <= MB_IDLE;       // default idle unless a state drives a byte

            unique case (state)
                S_IDLE: begin
                    if (req_valid) begin
                        wr_q        <= req_write;
                        committed_q <= req_write && req_committed;
                        addr_lo_q   <= req_addr[7:0];
                        wdata_q     <= req_wdata;
                        // byte 0: {cmd, Addr[11:8]}
                        m2p   <= {cmd_of(req_write, req_write && req_committed),
                                  req_addr[MB_ADDR_WIDTH-1:8]};
                        state <= S_ADDR;
                    end
                end

                S_ADDR: begin
                    m2p <= addr_lo_q;               // byte 1: Addr[7:0]
                    if (wr_q) state <= S_WDATA;
                    else      state <= S_RC_WAIT1;
                end

                S_WDATA: begin
                    m2p <= wdata_q;                 // byte 2: Data[7:0]
                    if (committed_q) state <= S_WACK_WAIT;
                    else             state <= S_WR_FIN;
                end

                S_WR_FIN: begin
                    // Uncommitted write is complete once framed on the bus.
                    rsp_valid   <= 1'b1;
                    rsp_is_read <= 1'b0;
                    state       <= S_IDLE;
                end

                S_WACK_WAIT: begin
                    if (p2m[7:4] == MB_WRITE_ACK) begin
                        rsp_valid   <= 1'b1;
                        rsp_is_read <= 1'b0;
                        state       <= S_IDLE;
                    end
                end

                S_RC_WAIT1: begin
                    // read_completion start byte: {READ_COMPLETION, x}
                    if (p2m[7:4] == MB_READ_COMPLETION) state <= S_RC_WAIT2;
                end

                S_RC_WAIT2: begin
                    rsp_rdata   <= p2m;             // second byte carries Data[7:0]
                    rsp_valid   <= 1'b1;
                    rsp_is_read <= 1'b1;
                    state       <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
