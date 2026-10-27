`timescale 1ns / 1ps
/*
 * ASSUMPTIONS AND INTEGRATION NOTES
 *
 * 1. Reset: rst is active-high and asynchronous.
 * 2. Input: admin_raw is a one-clock-cycle pulse from debounce.v.
 * 3. FSM: current_state uses the one-hot encodings defined below, which must match the main EVM FSM.
 * 4. Authorization: Admin authentication and action eligibility are handled by other modules.
 * 5. Outputs: admin_close and admin_clear_tamper are one-cycle pulses. Invalid or unsupported states are ignored.
 * No additional external signals are assumed.
 */
module admin_input_decode (
    input  wire clk,
    input  wire rst,
    input  wire admin_raw,           // 1-cycle pulse from debounce
    input  wire [2:0] current_state, // 3-bit one-hot FSM state
    output reg  admin_close,
    output reg  admin_clear_tamper
);

    // One-hot state definitions
    localparam POLLING_OPEN   = 3'b001;
    localparam POLLING_CLOSED = 3'b010;
    localparam TAMPER_LOCKED  = 3'b100;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            admin_close <= 1'b0;
            admin_clear_tamper <= 1'b0;
        end else begin
            // 1. Default assignments guarantee outputs are 1-cycle pulses and structurally prevent them from being asserted simultaneously.
            admin_close <= 1'b0;
            admin_clear_tamper <= 1'b0;

            // 2. Route the pulse based on the active EVM state
            if (admin_raw) begin
                case (current_state)
                    POLLING_OPEN: begin
                        admin_close <= 1'b1;
                    end
                    TAMPER_LOCKED: begin
                        admin_clear_tamper <= 1'b1;
                    end
                    // In POLLING_CLOSED or any invalid state, the button press is completely ignored (outputs safely remain 0).
                    default: begin
                        admin_close <= 1'b0;
                        admin_clear_tamper <= 1'b0;
                    end
                endcase
            end
        end
    end

endmodule