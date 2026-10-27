`timescale 1ns / 1ps

module tb_debounce;
    reg clk;
    reg rst;
    reg raw_signal;
    wire clean_pulse;

    debounce #(.DEBOUNCE_LIMIT(10)) uut (
        .clk(clk),
        .rst(rst),
        .raw_signal(raw_signal),
        .clean_pulse(clean_pulse)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        rst = 1;
        raw_signal = 0;
        #100;
        rst = 0;
        #50;

        raw_signal = 1; #12;
        raw_signal = 0; #8;
        raw_signal = 1; #15;
        raw_signal = 0; #10;
        raw_signal = 1;
        #150;
        
        raw_signal = 0; #14;
        raw_signal = 1; #7;
        raw_signal = 0; #18;
        raw_signal = 1; #9;
        raw_signal = 0;
        #150;

        raw_signal = 1; #40; raw_signal = 0;
        #100;
        
        $stop;
    end
endmodule