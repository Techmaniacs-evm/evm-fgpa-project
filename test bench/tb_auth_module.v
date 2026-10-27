
/*
ASSUMPTIONS AND INTEGRATION NOTES

1. rst is active-high and asynchronous.
2. uid_valid is a one-cycle pulse for a completed UID.
3. read_req and write_req indicate NVM requests.
4. read_done indicates that read_data is available.
5. write_done indicates a successful write.
6. write_error indicates a failed write.
7. read_data[0] = eligible and read_data[1] = already voted.
8. The testbench assumes the auth_module interface includes
   uid_data, address and write_data.
9. The test UID must match the format LLDDLDDD:
   2 uppercase letters, 2 digits, 1 uppercase letter, 3 digits.
*/

module tb_auth_module;

reg clk, rst, uid_valid, read_done, write_done, write_error;
reg [63:0] uid_data, read_data;
wire read_req, write_req, auth_valid;
wire [63:0] address, write_data;

integer pass_count = 0;
integer fail_count = 0;

auth_module uut(
    .clk(clk),
    .rst(rst),
    .uid_valid(uid_valid),
    .uid_data(uid_data),
    .read_done(read_done),
    .write_done(write_done),
    .write_error(write_error),
    .read_data(read_data),
    .read_req(read_req),
    .write_req(write_req),
    .auth_valid(auth_valid),
    .address(address),
    .write_data(write_data)
);

always #5 clk = ~clk;

task reset_module;
begin
    @(negedge clk);
    rst = 1;
    uid_valid = 0;
    read_done = 0;
    write_done = 0;
    write_error = 0;
    uid_data = 0;
    read_data = 0;
    repeat(2) @(negedge clk);
    rst = 0;
end
endtask

task scan_uid;
begin
    @(negedge clk);
    // ABCD-style bytes are checked by the format validator.
    // Example valid UID: AB12C345.
    uid_data = 64'h4142313243333435;
    uid_valid = 1;
    @(negedge clk);
    uid_valid = 0;
end
endtask

task give_read_data(input [63:0] value);
begin
    wait(read_req == 1);
    @(negedge clk);
    read_data = value;
    read_done = 1;
    @(negedge clk);
    read_done = 0;
end
endtask

task finish_write;
begin
    wait(write_req == 1);
    @(negedge clk);
    write_done = 1;
    @(negedge clk);
    write_done = 0;
end
endtask

task check_rejected(input [255:0] test_name);
begin
    repeat(8) @(negedge clk);
    if(auth_valid == 0) begin
        $display("PASS: %0s", test_name);
        pass_count = pass_count + 1;
    end
    else begin
        $display("FAIL: %0s", test_name);
        fail_count = fail_count + 1;
    end
end
endtask

initial begin
    clk = 0;
    rst = 0;
    uid_valid = 0;
    uid_data = 0;
    read_done = 0;
    write_done = 0;
    write_error = 0;
    read_data = 0;

    reset_module;

    // Test 1: Valid and unused ID
    $display("TEST 1: Valid unused ID");
    scan_uid;
    give_read_data(64'h1);
    finish_write;
    wait(auth_valid == 1);
    $display("PASS: Valid ID authenticated");
    pass_count = pass_count + 1;

    reset_module;

    // Test 2: Already-used ID
    $display("TEST 2: Already-used ID");
    scan_uid;
    give_read_data(64'h3);
    check_rejected("Already-used ID rejected");

    if(write_req == 0) begin
        $display("PASS: No write request");
        pass_count = pass_count + 1;
    end
    else begin
        $display("FAIL: Unexpected write request");
        fail_count = fail_count + 1;
    end

    reset_module;

    // Test 3: Ineligible ID
    $display("TEST 3: Ineligible ID");
    scan_uid;
    give_read_data(64'h0);
    check_rejected("Ineligible ID rejected");

    reset_module;

    // Test 4: Two rapid taps of the same ID
    $display("TEST 4: Two rapid taps");
    scan_uid;
    wait(read_req == 1);
    scan_uid;
    @(negedge clk);
    read_data = 64'h1;
    read_done = 1;
    @(negedge clk);
    read_done = 0;
    finish_write;
    wait(auth_valid == 1);
    $display("PASS: First tap authenticated");
    pass_count = pass_count + 1;
    check_rejected("Second tap did not authenticate");

    reset_module;

    // Test 5: Malformed ID
    $display("TEST 5: Malformed ID");
    @(negedge clk);
    uid_data = 64'h3837363534333231;
    uid_valid = 1;
    @(negedge clk);
    uid_valid = 0;
    check_rejected("Malformed ID rejected");

    if(read_req == 0) begin
        $display("PASS: No NVM read");
        pass_count = pass_count + 1;
    end
    else begin
        $display("FAIL: Unexpected NVM read");
        fail_count = fail_count + 1;
    end

    reset_module;

    // Test 6: NVM write error
    $display("TEST 6: NVM write error");
    scan_uid;
    give_read_data(64'h1);
    wait(write_req == 1);
    @(negedge clk);
    write_error = 1;
    @(negedge clk);
    write_error = 0;
    check_rejected("Write error prevented authentication");

    $display("PASSED: %0d", pass_count);
    $display("FAILED: %0d", fail_count);

    $finish;
end

endmodule


    $finish;
end

endmodule
