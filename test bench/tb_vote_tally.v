`timescale 1ns/1ps
// Vote tally testbench with behavioral NVM.
// Assumption: read model presents read_data in response to read_req; writes
// complete after one model cycle. This is not a model of physical Flash.
module tb_vote_tally;
    reg clk=0; always #5 clk=~clk;
    reg rst=1, vote_enable=0;
    reg [1:0] candidate_sel=0;
    wire read_req; wire [23:0] address; reg [31:0] read_data=0;
    wire write_req; wire [23:0] write_address; wire [31:0] write_data;
    reg write_done=0, write_error=0;
    wire [31:0] total_votes_cast; wire [127:0] results_bus;
    wire busy,nvm_fault,ready;
    reg [31:0] mem[0:3];
    reg write_pending=0;
    reg [23:0] waddr; reg [31:0] wdata;
    integer i;

    vote_tally dut(.clk(clk),.rst(rst),.vote_enable(vote_enable),
      .candidate_sel(candidate_sel),.read_req(read_req),.address(address),
      .read_data(read_data),.write_req(write_req),.write_address(write_address),
      .write_data(write_data),.write_done(write_done),.write_error(write_error),
      .total_votes_cast(total_votes_cast),.results_bus(results_bus),.busy(busy),
      .nvm_fault(nvm_fault),.ready(ready));

    // Asynchronous combinational read is used to satisfy the stated one-cycle
    // read timing assumption. Real controller timing must be verified.
    always @(*) begin
        if (address >= 24'h200000 && address < 24'h200010)
            read_data = mem[(address-24'h200000)>>2];
        else read_data = 0;
    end
    always @(posedge clk) begin
        write_done<=0;
        if (write_req && !write_pending) begin
            write_pending<=1; waddr<=write_address; wdata<=write_data;
        end else if (write_pending) begin
            mem[(waddr-24'h200000)>>2]<=wdata;
            write_done<=1; write_pending<=0;
        end
    end
    task vote(input [1:0] c);
      begin
        wait(ready); @(negedge clk); candidate_sel=c; vote_enable=1;
        repeat(3) @(negedge clk); vote_enable=0;
        wait(!busy); repeat(2) @(negedge clk);
      end
    endtask
    initial begin
        for(i=0;i<4;i=i+1) mem[i]=0;
        repeat(3) @(negedge clk); rst=0;
        wait(ready);
        vote(0); vote(2); vote(2);
        if(results_bus[31:0]!==1 || results_bus[95:64]!==2 ||
           total_votes_cast!==3) $fatal(1,"Tally mismatch");
        // Held-high vote_enable must count once only.
        @(negedge clk); candidate_sel=1; vote_enable=1;
        repeat(5) @(negedge clk); vote_enable=0;
        wait(!busy); repeat(2) @(negedge clk);
        if(results_bus[63:32]!==1 || total_votes_cast!==4)
            $fatal(1,"Held-high vote counted incorrectly");
        rst=1; repeat(2) @(negedge clk); rst=0;
        wait(ready);
        if(results_bus[31:0]!==1 || results_bus[63:32]!==1 ||
           results_bus[95:64]!==2 || total_votes_cast!==4)
            $fatal(1,"Restore from NVM failed");
        $display("PASS: tb_vote_tally"); $finish;
    end
endmodule
