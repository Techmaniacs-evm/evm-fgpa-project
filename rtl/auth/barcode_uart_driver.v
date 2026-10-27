
`timescale 1ns / 1ps

/*
ASSUMPTIONS AND INTEGRATION NOTES

1. rst is active-high and resets the receiver and UID assembler.
2. UART uses 9600 baud, 8 data bits, no parity and 1 stop bit.
3. The system clock is assumed to be 50 MHz.
4. rx is the UART input from the barcode scanner.
5. A scan contains exactly 8 ASCII characters.
6. The roll number format is 2 uppercase letters, 2 digits,
   1 uppercase letter and 3 digits.
7. The scanner sends the characters in order, least significant
   UART data bit first, followed by a stop bit.
8. uid_valid is a one-clock-cycle pulse for a correctly formatted UID.
9. tx_enb is generated but is unused because this module only receives data.
*/

module baudrate_generator(input clk, output rx_enb, output tx_enb);

reg [12:0] rx_cnt = 13'd0;
reg [12:0] tx_cnt = 13'd0;

always @(posedge clk) begin
    if (rx_cnt == 13'd324)
        rx_cnt <= 13'd0;
    else
        rx_cnt <= rx_cnt + 13'd1;
end

always @(posedge clk) begin
    if (tx_cnt == 13'd5207)
        tx_cnt <= 13'd0;
    else
        tx_cnt <= tx_cnt + 13'd1;
end

assign rx_enb = (rx_cnt == 13'd0);
assign tx_enb = (tx_cnt == 13'd0);

endmodule


module reciever(input clk, input rx_enb, input rx, input rx_rst,
                output reg [7:0] data_out, output reg data_valid);

localparam IDLE_STATE    = 2'b00;
localparam START_STATE   = 2'b01;
localparam DATAOUT_STATE = 2'b10;
localparam STOP_STATE    = 2'b11;

reg [1:0] state;
reg [3:0] index;
reg [3:0] sample;

always @(posedge clk) begin
    data_valid <= 1'b0;

    if (rx_rst) begin
        data_out <= 8'b0;
        index    <= 4'h0;
        sample   <= 4'h0;
        state    <= IDLE_STATE;
    end
    else if (rx_enb) begin
        case (state)

            // Wait for the UART start bit
            IDLE_STATE: begin
                if (rx == 1'b0) begin
                    sample <= 4'h0;
                    state  <= START_STATE;
                end
            end

            // Check the start bit near its middle
            START_STATE: begin
                if (sample == 4'h7) begin
                    if (rx == 1'b1) begin
                        state  <= IDLE_STATE;
                        sample <= 4'h0;
                    end
                    else begin
                        state  <= DATAOUT_STATE;
                        sample <= 4'h0;
                        index  <= 4'h0;
                    end
                end
                else
                    sample <= sample + 4'h1;
            end

            // Receive the 8 data bits
            DATAOUT_STATE: begin
                if (sample == 4'h7)
                    data_out[index] <= rx;

                if (sample == 4'hF) begin
                    sample <= 4'h0;

                    if (index == 4'h7)
                        state <= STOP_STATE;
                    else
                        index <= index + 4'h1;
                end
                else
                    sample <= sample + 4'h1;
            end

            // Check the stop bit and indicate received data
            STOP_STATE: begin
                if (sample == 4'h7) begin
                    data_valid <= (rx == 1'b1);
                    state      <= IDLE_STATE;
                    sample     <= 4'h0;
                end
                else
                    sample <= sample + 4'h1;
            end

            default: state <= IDLE_STATE;

        endcase
    end
end

endmodule


module uid_assembler(input clk, input rst, input [7:0] data, input data_valid,
                     output reg [63:0] uid, output reg uid_check);

reg [2:0] i;

always @(posedge clk) begin
    uid_check <= 1'b0;

    if (rst) begin
        i   <= 3'h0;
        uid <= 64'd0;
    end
    else if (data_valid) begin
        // Store each received character in the UID register
        uid[8*i +: 8] <= data;
        i <= i + 3'h1;

        // Indicate that all 8 characters have arrived
        if (i == 3'h7) begin
            uid_check <= 1'b1;
            i <= 3'h0;
        end
    end
end

endmodule


module uid_validator(input clk, input rst, input [63:0] uid, input uid_check,
                     output reg uid_valid);

wire format_ok =
    (uid[7:0]   >= 8'h41 && uid[7:0]   <= 8'h5A) &&
    (uid[15:8]  >= 8'h41 && uid[15:8]  <= 8'h5A) &&
    (uid[23:16] >= 8'h30 && uid[23:16] <= 8'h39) &&
    (uid[31:24] >= 8'h30 && uid[31:24] <= 8'h39) &&
    (uid[39:32] >= 8'h41 && uid[39:32] <= 8'h5A) &&
    (uid[47:40] >= 8'h30 && uid[47:40] <= 8'h39) &&
    (uid[55:48] >= 8'h30 && uid[55:48] <= 8'h39) &&
    (uid[63:56] >= 8'h30 && uid[63:56] <= 8'h39);

always @(posedge clk) begin
    uid_valid <= 1'b0;

    // Accept only a complete, correctly formatted UID
    if (!rst && uid_check && format_ok)
        uid_valid <= 1'b1;
end

endmodule


module barcode_uart_driver(input clk, input rst, input rx,
                           output [63:0] uid, output uid_valid);

wire rx_enb, tx_enb;
wire [7:0] data;
wire data_valid;
wire uid_check;

baudrate_generator u_baud(clk, rx_enb, tx_enb);
reciever           u_rx(clk, rx_enb, rx, rst, data, data_valid);
uid_assembler      u_asm(clk, rst, data, data_valid, uid, uid_check);
uid_validator      u_val(clk, rst, uid, uid_check, uid_valid);

endmodule

