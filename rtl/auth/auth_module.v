module auth_module(input clk, rst,uid_valid,[63:0] uid,read_done,write_done,write_error,[63:0] read_data,
                   output reg read_req,write_req,auth_valid,[63:0] adress);

parameter idle=3'b000;
parameter READ_REQ_STATE=3'b001;
parameter read_wait=3'b010;
parameter WRITE_REQ_STATE=3'b011;
parameter write_wait=3'b100;

reg [2:0] state;

always @(posedge clk)
begin
    if(rst) begin
        state<=idle;
        read_req<=0;
        write_req<=0;
        auth_valid<=0;
        adress<=0;
    end
    else begin
        read_req<=0;
        write_req<=0;
        auth_valid<=0;

        case(state)
            idle:
                if(uid_valid) begin
                    adress<=uid;
                    state<=READ_REQ_STATE;
                end
                else
                    state<=idle;

            READ_REQ_STATE: begin
                read_req<=1'b1;
                state<=read_wait;
            end

            read_wait:
                if(read_done) begin
		//1st is for the voting eligibility 
		//2nd bit is for voting status
                    if(read_data[0]==1'b1 && read_data[1]==1'b0)
                        state<=WRITE_REQ_STATE;
                    else
                        state<=idle;
                end

            WRITE_REQ_STATE: begin
                write_req<=1'b1;
                state<=write_wait;
            end

            write_wait:
                if(write_done) begin
                    auth_valid<=1'b1;
                    state<=idle;
                end
                else if(write_error) begin
                    auth_valid<=1'b0;
                    state<=idle;
                end

            default:
                state<=idle;
        endcase
    end
end

endmodule
