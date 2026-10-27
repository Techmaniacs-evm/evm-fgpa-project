`timescale 1ns / 1ps

module tb_tamper_detect;
    reg clk, rst, case_open_raw, admin_clear_tamper;
    reg [31:0] nvm_read_data;
    reg nvm_read_done, nvm_error;
    
    wire nvm_read_req;
    wire [31:0] nvm_read_addr;
    wire tamper_flag, boot_check_done;

    tamper_detect uut (
        .clk(clk), .rst(rst),
        .case_open_raw(case_open_raw), .admin_clear_tamper(admin_clear_tamper),
        .nvm_read_data(nvm_read_data), .nvm_read_done(nvm_read_done), .nvm_error(nvm_error),
        .nvm_read_req(nvm_read_req), .nvm_read_addr(nvm_read_addr),
        .tamper_flag(tamper_flag), .boot_check_done(boot_check_done)
    );

    // 100MHz Clock
    initial begin clk = 0; forever #5 clk = ~clk; end

    // Task: Simulate NVM latency
    task respond_nvm(input [31:0] data, input err);
        begin
            wait(nvm_read_req);
            @(posedge clk); @(posedge clk); // 2-cycle read delay
            nvm_read_data = data;
            nvm_error = err;
            nvm_read_done = ~err;
            @(posedge clk);
            nvm_read_done = 0;
            nvm_error = 0;
        end
    endtask

    // Task: Hard reset between scenarios
    task trigger_reset;
        begin
            rst = 1; case_open_raw = 0; admin_clear_tamper = 0;
            nvm_read_data = 0; nvm_read_done = 0; nvm_error = 0;
            #20 rst = 0;
        end
    endtask

    initial begin
        // SCENARIO 1: Normal Boot (State CLOSED, Shutdown marker ignored)
        trigger_reset();
        respond_nvm(32'hA5A5_0002, 0); // Read State: CLOSED
        respond_nvm(32'hDEAD_BEEF, 0); // Read Shutdown: VALID
        wait(boot_check_done);
        #30; 

        // SCENARIO 2: Open Election Power Cut (Missing Marker) + Valid Clear
        trigger_reset();
        respond_nvm(32'hA5A5_0001, 0); // Read State: OPEN
        respond_nvm(32'h0000_0000, 0); // Read Shutdown: MISSING
        wait(boot_check_done);
        #30 admin_clear_tamper = 1; #10 admin_clear_tamper = 0;
        #30;

        // SCENARIO 3: NVM Read Error + Blocked Clear
        trigger_reset();
        respond_nvm(32'h0000_0000, 1); // Trigger NVM timeout/error
        wait(boot_check_done);
        #30 admin_clear_tamper = 1; #10 admin_clear_tamper = 0;
        #30;

        // SCENARIO 4: Invalid Saved State + Blocked Clear
        trigger_reset();
        respond_nvm(32'hBAD_C0DE, 0);  // Unrecognized state magic number
        wait(boot_check_done);
        #30 admin_clear_tamper = 1; #10 admin_clear_tamper = 0;
        #30;

        // SCENARIO 5: Physical Case Open & Administrative Clear
        trigger_reset();
        respond_nvm(32'hA5A5_0002, 0); 
        respond_nvm(32'hDEAD_BEEF, 0);
        wait(boot_check_done);
        #30;
        case_open_raw = 1; #20 case_open_raw = 0; // Rip case open, then close it
        #30 admin_clear_tamper = 1; #10 admin_clear_tamper = 0; // Authorized clear
        
        #50 $stop;
    end
endmodule