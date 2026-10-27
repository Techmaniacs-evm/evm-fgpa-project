`timescale 1ns / 1ps

module tb_admin_input_decode;
    reg clk;
    reg rst;
    reg admin_raw;
    reg [2:0] current_state;
    wire admin_close;
    wire admin_clear_tamper;

    admin_input_decode uut (
        .clk(clk),
        .rst(rst),
        .admin_raw(admin_raw),
        .current_state(current_state),
        .admin_close(admin_close),
        .admin_clear_tamper(admin_clear_tamper)
    );

    // 100MHz clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        // System Reset
        rst = 1;
        admin_raw = 0;
        current_state = 3'b000;
        #20;
        
        rst = 0;
        #20;

        // SCENARIO 1: Button pressed during active election
        current_state = 3'b001; // POLLING_OPEN
        #10;
        admin_raw = 1; #10; admin_raw = 0;
        #30;

        // SCENARIO 2: Button pressed when machine is bricked
        current_state = 3'b100; // TAMPER_LOCKED
        #10;
        admin_raw = 1; #10; admin_raw = 0;
        #30;

        // SCENARIO 3: Button pressed when election is already over
        current_state = 3'b010; // POLLING_CLOSED
        #10;
        admin_raw = 1; #10; admin_raw = 0;
        #30;
        
        $stop;
    end
endmodule