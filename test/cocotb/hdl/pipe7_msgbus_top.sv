
`timescale 1ns/1ps

/**
 * pipe7_msgbus_top -- cocotb DUT wrapper for the message-bus cross-check (item 14). Exposes
 * pipe7_msgbus_master's request/response interface and the M2P/P2M buses so an INDEPENDENT
 * PyUVM PHY message-bus responder drives P2M (read_completion / write_ack) while the Python
 * model independently decodes the M2P framing the DUT produced.
 */
module pipe7_msgbus_top
    import pipe7_pkg::*;
(
    input  logic                      clk,
    input  logic                      reset_n,

    input  logic                      req_valid,
    input  logic                      req_write,
    input  logic                      req_committed,
    input  logic [MB_ADDR_WIDTH-1:0]  req_addr,
    input  logic [MB_DATA_WIDTH-1:0]  req_wdata,
    output logic                      req_ready,
    output logic                      busy,

    output logic                      rsp_valid,
    output logic                      rsp_is_read,
    output logic [MB_DATA_WIDTH-1:0]  rsp_rdata,
    output logic                      rsp_error,

    output logic [MB_BUS_WIDTH-1:0]   m2p,
    input  logic [MB_BUS_WIDTH-1:0]   p2m
);

    pipe7_msgbus_master master (
        .pclk(clk), .reset_n,
        .req_valid, .req_write, .req_committed, .req_addr, .req_wdata,
        .req_ready, .busy,
        .rsp_valid, .rsp_is_read, .rsp_rdata, .rsp_error,
        .m2p, .p2m
    );

endmodule
