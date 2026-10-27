`timescale 1ns/1ps
// Module 4.6: append-only, identity-free audit logger.
//
// Event codes from report: 1 AUTH_SUCCESS, 2 VOTE_CAST, 3 TAMPER_DETECTED,
// 4 UNEXPECTED_RESET, 5 POLL_CLOSED.
//
// ASSUMPTIONS (confirm with team):
// A1. Each entry is 32 bits: {event_code[2:0], timestamp[28:0]}; timestamp is
//     truncated to 29 bits. Code 0 and codes >5 are rejected.
// A2. LOG_DEPTH=1024; entries are four bytes at BASE_ADDR + 4*entry_index.
//     BASE_ADDR is a placeholder and must match the agreed NVM map.
// A3. write_done/write_error are response pulses; write_req remains asserted
//     until one arrives.
// A4. Report does not define raw-log read request pins. Added log_read_req,
//     log_read_address, log_read_data, log_read_valid. Here readback is from a
//     local mirror for simulation; production must route reads through the
//     shared NVM controller/arbiter.
// A5. A new event is accepted on a rising edge of log_write_req while idle.
//     Producer must pulse once per event and retry if busy.
// A6. entry_count_by_type is 8 x 32 bits; event code N counter is bits
//     [N*32 +: 32]. Counts saturate rather than wrap.
// A7. This module does not store identity or candidate information.
module audit_logger #(
    parameter integer LOG_DEPTH=1024,
    parameter [23:0] BASE_ADDR=24'h300000,
    parameter integer ADDR_WIDTH=24,
    parameter integer DATA_WIDTH=32
)(
    input wire clk, input wire rst,
    input wire [2:0] event_code,
    input wire [31:0] timestamp,
    input wire log_write_req,
    output reg write_req,
    output reg [ADDR_WIDTH-1:0] address,
    output reg [DATA_WIDTH-1:0] write_data,
    input wire write_done, input wire write_error,
    input wire log_read_req,
    input wire [((LOG_DEPTH<=2)?1:$clog2(LOG_DEPTH))-1:0] log_read_address,
    output reg [31:0] log_read_data,
    output reg log_read_valid,
    output reg [255:0] entry_count_by_type,
    output reg [((LOG_DEPTH<=2)?1:$clog2(LOG_DEPTH+1))-1:0] log_count,
    output wire log_full, output wire busy, output reg log_error
);
    localparam integer PW=(LOG_DEPTH<=2)?1:$clog2(LOG_DEPTH);
    localparam integer CW=(LOG_DEPTH<=2)?1:$clog2(LOG_DEPTH+1);
    localparam [1:0] S_IDLE=0, S_WRITE=1, S_FAULT=2;
    reg [1:0] state;
    reg [2:0] pending_code;
    reg [31:0] pending_timestamp;
    reg req_d, read_req_d;
    reg [31:0] log_mem [0:LOG_DEPTH-1];
    integer i;
    assign log_full = (log_count >= LOG_DEPTH);
    assign busy = (state != S_IDLE);

    always @(posedge clk) begin
        if (rst) begin
            state<=S_IDLE; write_req<=0; address<=0; write_data<=0;
            pending_code<=0; pending_timestamp<=0; req_d<=0;
            read_req_d<=0; log_read_data<=32'hFFFFFFFF; log_read_valid<=0;
            entry_count_by_type<=0; log_count<=0; log_error<=0;
            for (i=0;i<LOG_DEPTH;i=i+1) log_mem[i]<=32'hFFFFFFFF;
        end else begin
            req_d<=log_write_req; read_req_d<=log_read_req;
            log_read_valid<=0;
            if (log_read_req && !read_req_d) begin
                log_read_valid<=1;
                if (log_read_address < log_count)
                    log_read_data<=log_mem[log_read_address];
                else log_read_data<=32'hFFFFFFFF;
            end
            case (state)
                S_IDLE: begin
                    write_req<=0;
                    if (log_write_req && !req_d) begin
                        if ((event_code==0)||(event_code>5)) begin
                            log_error<=1;
                        end else if (log_count>=LOG_DEPTH) begin
                            log_error<=1;
                        end else begin
                            pending_code<=event_code;
                            pending_timestamp<=timestamp;
                            address<=BASE_ADDR+(log_count*4);
                            write_data<={event_code,timestamp[28:0]};
                            write_req<=1; state<=S_WRITE;
                        end
                    end
                end
                S_WRITE: begin
                    write_req<=1;
                    if (write_error) begin
                        write_req<=0; log_error<=1; state<=S_FAULT;
                    end else if (write_done) begin
                        write_req<=0;
                        log_mem[log_count]<={pending_code,pending_timestamp[28:0]};
                        if (entry_count_by_type[pending_code*32 +: 32] != 32'hFFFFFFFF)
                            entry_count_by_type[pending_code*32 +: 32] <=
                                entry_count_by_type[pending_code*32 +: 32]+1'b1;
                        log_count<=log_count+1'b1;
                        state<=S_IDLE;
                    end
                end
                S_FAULT: write_req<=0;
                default: begin state<=S_FAULT; log_error<=1; end
            endcase
        end
    end
endmodule
