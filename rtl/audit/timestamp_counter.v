`timescale 1ns/1ps
// Section 4.6 timestamp source.
//
// ASSUMPTIONS:
// A1. Default clock is 100 MHz; DIVIDER=100000 yields one tick per millisecond.
// A2. This is elapsed time since reset, NOT wall-clock time/date.
// A3. Counter wraps naturally after 2**WIDTH ticks.
module timestamp_counter #(
    parameter integer WIDTH=32,
    parameter integer DIVIDER=100000
)(
    input wire clk, input wire rst,
    output reg [WIDTH-1:0] timestamp
);
    localparam integer DW=(DIVIDER<=2)?1:$clog2(DIVIDER);
    reg [DW-1:0] div_count;
    always @(posedge clk) begin
        if (rst) begin div_count<=0; timestamp<=0; end
        else if ((DIVIDER<=1) || (div_count==DIVIDER-1)) begin
            div_count<=0; timestamp<=timestamp+1'b1;
        end else div_count<=div_count+1'b1;
    end
endmodule
