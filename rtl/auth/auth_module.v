
/*
ASSUMPTIONS AND INTEGRATION NOTES

1. rst is active-high and asynchronous.
2. uid_data contains an 8-character ASCII roll number.
3. uid_valid is a one-cycle pulse when a scan is complete.
4. read_data[0] = eligible and read_data[1] = already voted.
5. The UID is used as the NVM address. This is an assumption
   because the document does not specify the address mapping.
6. write_data sets bit 1 to mark the voter as used.
7. auth_valid is asserted only after write_done.
8. write_error means authentication fails.
*/

module auth_module(
    input clk, rst, uid_valid,
    input [63:0] uid_data,
    input read_done, write_done, write_error,
    input [63:0] read_data,
    output reg read_req, write_req, auth_valid,
    output reg [63:0] address, write_data
);

parameter idle = 3'b000;
parameter READ_REQ_STATE = 3'b001;
parameter read_wait = 3'b010;
parameter WRITE_REQ_STATE = 3'b011;
parameter write_wait = 3'b100;

reg [2:0] state;

function valid_format;
    input [63:0] value;
    begin
        valid_format =
            (value[63:56] >= 8'h41 && value[63:56] <= 8'h5A) &&
            (value[55:48] >= 8'h41 && value[55:48] <= 8'h5A) &&
            (value[47:40] >= 8'h30 && value[47:40] <= 8'h39) &&
            (value[39:32] >= 8'h30 && value[39:32] <= 8'h39) &&
            (value[31:24] >= 8'h41 && value[31:24] <= 8'h5A) &&
            (value[23:16] >= 8'h30 && value[23:16] <= 8'h39) &&
            (value[15:8] >= 8'h30 && value[15:8] <= 8'h39) &&
            (value[7:0] >= 8'h30 && value[7:0] <= 8'h39);
    end
endfunction

always @(posedge clk or posedge rst)
begin
    if (rst) begin
        state <= idle;
        read_req <= 0;
        write_req <= 0;
        auth_valid <= 0;
        address <= 0;
        write_data <= 0;
    end
    else begin
        read_req <= 0;
        write_req <= 0;
        auth_valid <= 0;

        case(state)

            idle: begin
                // Check the roll-number format before reading NVM
                if(uid_valid && valid_format(uid_data)) begin
                    address <= uid_data;
                    state <= READ_REQ_STATE;
                end
                else
                    state <= idle;
            end

            READ_REQ_STATE: begin
                read_req <= 1;
                state <= read_wait;
            end

            read_wait: begin
                if(read_done) begin
                    // Bit 0: eligible, bit 1: already voted
                    if(read_data[0] && !read_data[1]) begin
                        state <= WRITE_REQ_STATE;
                        write_data <= read_data | 64'h2;
                    end
                    else
                        state <= idle;
                end
            end

            WRITE_REQ_STATE: begin
                write_req <= 1;
                state <= write_wait;
            end

            write_wait: begin
                if(write_error)
                    state <= idle;
                else if(write_done) begin
                    auth_valid <= 1;
                    state <= idle;
                end
            end

            default:
                state <= idle;

        endcase
    end
end

endmodule

