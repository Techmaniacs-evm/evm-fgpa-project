`timescale 1ns/1ps
// Audit logger testbench with behavioral write acknowledgements.
module tb_audit_logger;
    reg clk=0; always #5 clk=~clk;
    reg rst=1; reg [2:0] event_code=0; reg [31:0] timestamp=0;
    reg log_write_req=0; wire write_req; wire [23:0] address;
    wire [31:0] write_data; reg write_done=0,write_error=0;
    reg log_read_req=0; reg [9:0] log_read_address=0;
    wire [31:0] log_read_data; wire log_read_valid;
    wire [255:0] entry_count_by_type; wire [10:0] log_count;
    wire log_full,busy,log_error; reg pending=0;
    wire [31:0] auth_count=entry_count_by_type[1*32 +: 32];
    wire [31:0] vote_count=entry_count_by_type[2*32 +: 32];
    wire [31:0] tamper_count=entry_count_by_type[3*32 +: 32];
    wire [31:0] reset_count=entry_count_by_type[4*32 +: 32];
    wire [31:0] closed_count=entry_count_by_type[5*32 +: 32];

    audit_logger dut(.clk(clk),.rst(rst),.event_code(event_code),
      .timestamp(timestamp),.log_write_req(log_write_req),.write_req(write_req),
      .address(address),.write_data(write_data),.write_done(write_done),
      .write_error(write_error),.log_read_req(log_read_req),
      .log_read_address(log_read_address),.log_read_data(log_read_data),
      .log_read_valid(log_read_valid),.entry_count_by_type(entry_count_by_type),
      .log_count(log_count),.log_full(log_full),.busy(busy),.log_error(log_error));

    always @(posedge clk) begin
      write_done<=0;
      if(write_req && !pending) pending<=1;
      else if(pending) begin write_done<=1; pending<=0; end
    end
    task log_event(input [2:0] code,input [31:0] ts);
      begin
        wait(!busy); @(negedge clk); event_code=code; timestamp=ts; log_write_req=1;
        @(negedge clk); log_write_req=0;
        wait(!busy); repeat(2) @(negedge clk);
      end
    endtask
    initial begin
      repeat(3) @(negedge clk); rst=0;
      log_event(1,100); log_event(2,110); log_event(2,120);
      log_event(3,130); log_event(4,140); log_event(5,150);
      if(auth_count!==1 || vote_count!==2 || tamper_count!==1 ||
         reset_count!==1 || closed_count!==1 || log_count!==6)
        $fatal(1,"Event counters incorrect");
      @(negedge clk); log_read_address=1; log_read_req=1;
      @(negedge clk); log_read_req=0;
      wait(log_read_valid);
      if(log_read_data[31:29]!==2 || log_read_data[28:0]!==110)
        $fatal(1,"Raw log readback incorrect");
      $display("PASS: tb_audit_logger"); $finish;
    end
endmodule
