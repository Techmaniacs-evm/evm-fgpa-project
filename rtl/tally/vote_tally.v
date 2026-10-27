`timescale 1ns/1ps
// Module 4.3: Vote Counting Module.
//
// DOCUMENT REQUIREMENTS: count only vote_enable + valid candidate_sel; perform
// internal edge detection; restore counts from NVM at boot; wait for write_done
// before accepting the next vote; expose total_votes_cast and packed results_bus.
//
// ASSUMPTIONS (confirm with NVM/top-level owners):
// A1. Four candidates by default; candidate_sel is a zero-based index.
// A2. NVM address/data widths are 24/32 bits; each count is one 32-bit word,
//     at BASE_ADDR + 4*candidate_index. BASE_ADDR is only a placeholder.
// A3. Report does not specify read_done/read_valid. This implementation assumes
//     read_data is valid one clock after read_req. If NVM has a read handshake,
//     add it and wait for it before capturing read_data.
// A4. write_done and write_error are one-cycle response pulses. write_req stays
//     asserted until one response arrives.
// A5. Synchronous active-high reset. On write_error, fail closed until reset.
// A6. results_bus is not gated here; the Display module must prevent result
//     exposure while reveal_enable is low, as required by the report.
module vote_tally #(
    parameter integer CANDIDATES = 4,
    parameter integer COUNT_WIDTH = 32,
    parameter [23:0] BASE_ADDR = 24'h200000,
    parameter integer ADDR_WIDTH = 24,
    parameter integer DATA_WIDTH = 32
)(
    input wire clk, input wire rst,
    input wire vote_enable,
    input wire [((CANDIDATES<=2)?1:$clog2(CANDIDATES))-1:0] candidate_sel,
    output reg read_req,
    output reg [ADDR_WIDTH-1:0] address,
    input wire [DATA_WIDTH-1:0] read_data,
    output reg write_req,
    output reg [ADDR_WIDTH-1:0] write_address,
    output reg [DATA_WIDTH-1:0] write_data,
    input wire write_done, input wire write_error,
    output reg [31:0] total_votes_cast,
    output wire [CANDIDATES*COUNT_WIDTH-1:0] results_bus,
    output wire busy, output reg nvm_fault, output reg ready
);
    localparam integer SW = (CANDIDATES<=2)?1:$clog2(CANDIDATES);
    localparam [2:0] S_READ_REQ=0, S_READ_WAIT=1, S_IDLE=2, S_WRITE=3, S_FAULT=4;
    reg [2:0] state;
    reg [COUNT_WIDTH-1:0] counts [0:CANDIDATES-1];
    reg [SW-1:0] idx, pending_idx;
    reg [COUNT_WIDTH-1:0] pending_count;
    reg vote_enable_d;
    reg [31:0] restore_sum;
    integer i;
    genvar g;
    generate for (g=0; g<CANDIDATES; g=g+1) begin: PACK
        assign results_bus[g*COUNT_WIDTH +: COUNT_WIDTH] = counts[g];
    end endgenerate
    assign busy = (state != S_IDLE) && (state != S_FAULT);

    always @(posedge clk) begin
        if (rst) begin
            state<=S_READ_REQ; idx<=0; pending_idx<=0; pending_count<=0;
            vote_enable_d<=0; restore_sum<=0; total_votes_cast<=0;
            read_req<=0; address<=0; write_req<=0; write_address<=0;
            write_data<=0; nvm_fault<=0; ready<=0;
            for (i=0;i<CANDIDATES;i=i+1) counts[i]<=0;
        end else begin
            vote_enable_d <= vote_enable;
            read_req <= 0;
            case (state)
                S_READ_REQ: begin
                    address <= BASE_ADDR + (idx*4);
                    read_req <= 1;
                    state <= S_READ_WAIT;
                end
                S_READ_WAIT: begin
                    // ASSUMPTION A3: read_data is valid after the request cycle.
                    counts[idx] <= read_data[COUNT_WIDTH-1:0];
                    restore_sum <= restore_sum + read_data[COUNT_WIDTH-1:0];
                    if (idx == CANDIDATES-1) begin
                        total_votes_cast <= restore_sum + read_data[COUNT_WIDTH-1:0];
                        state <= S_IDLE; ready <= 1;
                    end else begin
                        idx <= idx + 1'b1;
                        state <= S_READ_REQ;
                    end
                end
                S_IDLE: begin
                    write_req <= 0;
                    if (vote_enable && !vote_enable_d && ready && !nvm_fault) begin
                        if (candidate_sel < CANDIDATES) begin
                            pending_idx <= candidate_sel;
                            pending_count <= counts[candidate_sel] + 1'b1;
                            write_address <= BASE_ADDR + (candidate_sel*4);
                            write_data <= counts[candidate_sel] + 1'b1;
                            write_req <= 1;
                            state <= S_WRITE;
                        end
                    end
                end
                S_WRITE: begin
                    write_req <= 1;
                    if (write_error) begin
                        write_req<=0; nvm_fault<=1; ready<=0; state<=S_FAULT;
                    end else if (write_done) begin
                        write_req<=0;
                        counts[pending_idx] <= pending_count;
                        total_votes_cast <= total_votes_cast + 1'b1;
                        state <= S_IDLE;
                    end
                end
                S_FAULT: begin write_req<=0; read_req<=0; ready<=0; end
                default: begin state<=S_FAULT; nvm_fault<=1; end
            endcase
        end
    end
endmodule
