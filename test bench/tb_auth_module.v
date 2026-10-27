module tb_auth_module;

reg clk,rst,uid_valid,read_done,write_done,write_error;
reg [63:0] uid,read_data;
wire read_req,write_req,auth_valid;
wire [63:0] adress;

integer pass_count=0;
integer fail_count=0;

auth_module uut(clk,rst,uid_valid,uid,read_done,write_done,write_error,read_data,
                read_req,write_req,auth_valid,adress);

always #5 clk=~clk;

task reset_module;
begin
    @(negedge clk);
    rst=1;
    uid_valid=0;
    read_done=0;
    write_done=0;
    write_error=0;
    uid=0;
    read_data=0;
    repeat(2) @(negedge clk);
    rst=0;
end
endtask

task scan_uid;
begin
    @(negedge clk);
    uid=64'h3939394139394141;
    uid_valid=1;
    @(negedge clk);
    uid_valid=0;
end
endtask

task give_read_data(input [63:0] value);
begin
    wait(read_req==1);
    @(negedge clk);
    read_data=value;
    read_done=1;
    @(negedge clk);
    read_done=0;
end
endtask

task finish_write;
begin
    wait(write_req==1);
    @(negedge clk);
    write_done=1;
    @(negedge clk);
    write_done=0;
end
endtask

task check_rejected(input [255:0] test_name);
begin
    repeat(8) @(negedge clk);
    if(auth_valid==0) begin
        $display("PASS: %0s",test_name);
        pass_count=pass_count+1;
    end
    else begin
        $display("FAIL: %0s",test_name);
        fail_count=fail_count+1;
    end
end
endtask

initial begin
    clk=0;
    rst=0;
    uid_valid=0;
    uid=0;
    read_done=0;
    write_done=0;
    write_error=0;
    read_data=0;

    reset_module;

    $display("TEST 1: Valid unused ID");
    scan_uid;
    give_read_data(64'h1);
    finish_write;
    wait(auth_valid==1);
    $display("PASS: Valid ID authenticated");
    pass_count=pass_count+1;

    reset_module;

    $display("TEST 2: Already-used ID");
    scan_uid;
    give_read_data(64'h3);
    check_rejected("Already-used ID rejected");

    if(write_req==0) begin
        $display("PASS: No write request");
        pass_count=pass_count+1;
    end
    else begin
        $display("FAIL: Unexpected write request");
        fail_count=fail_count+1;
    end

    reset_module;

    $display("TEST 3: Ineligible ID");
    scan_uid;
    give_read_data(64'h0);
    check_rejected("Ineligible ID rejected");

    reset_module;

    $display("TEST 4: Two rapid taps");
    scan_uid;
    wait(read_req==1);
    scan_uid;
    @(negedge clk);
    read_data=64'h1;
    read_done=1;
    @(negedge clk);
    read_done=0;
    finish_write;
    wait(auth_valid==1);
    $display("PASS: First tap authenticated");
    pass_count=pass_count+1;
    check_rejected("Second tap did not authenticate");

    reset_module;

    $display("TEST 5: Malformed ID");
    uid=64'h3837363534333231;
    uid_valid=0;
    check_rejected("Malformed ID rejected by upstream validator");

    if(read_req==0) begin
        $display("PASS: No NVM read");
        pass_count=pass_count+1;
    end
    else begin
        $display("FAIL: Unexpected NVM read");
        fail_count=fail_count+1;
    end

    reset_module;

    $display("TEST 6: NVM write error");
    scan_uid;
    give_read_data(64'h1);
    wait(write_req==1);
    @(negedge clk);
    write_error=1;
    @(negedge clk);
    write_error=0;
    check_rejected("Write error prevented authentication");


    $display("PASSED: %0d",pass_count);
    $display("FAILED: %0d",fail_count);


    $finish;
end

endmodule
