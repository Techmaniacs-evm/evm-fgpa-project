`timescale 1ns / 1ps
/*
 * ASSUMPTIONS AND INTEGRATION NOTES
 *
 * 1. Clock: Assumes a 100 MHz system clock. DEBOUNCE_LIMIT = 2,000,000 corresponds to a 20 ms debounce interval at this frequency.
 * 2. Reset: rst is assumed to be active-high and asynchronous.
 * 3. Input: raw_signal is assumed to be an active-high physical button input asynchronous to clk. A two-stage synchronizer is implemented
 *    internally; external synchronization is not required.
 *
 * 4. Output: clean_pulse is asserted for one clock cycle on a recognized stable low-to-high transition. Button release does not generate a pulse.
 *
 * 5. Integration: Downstream logic must use clean_pulse as a one-cycle event signal. The clock frequency and debounce parameter must be
 *    appropriate for the target hardware.
 *
 * INTERNAL SIGNALS
 *    sync_0, sync_1       - Two-stage input synchronizer.
 *    counter              - Counts cycles while input differs from stable_state.
 *    stable_state         - Last accepted stable input state.
 *    prev_stable_state    - Previous stable_state value, used for rising-edge detection.
 *
 * No additional external signals are assumed beyond the declared module ports.
 */
module debounce #(
    // 20ms debounce at 100MHz clock = 2,000,000 clock cycles
    parameter integer DEBOUNCE_LIMIT = 2000000 
)(
    input  wire clk,
    input  wire rst,          // Assuming active-high reset
    input  wire raw_signal,   // Assuming active-high button hardware
    output reg  clean_pulse
);

    // Automatically calculate the required counter width based on the parameter
    localparam COUNTER_WIDTH = $clog2(DEBOUNCE_LIMIT);

    // 1. Two-Stage Synchronizer with Vivado synthesis attributes
    (* ASYNC_REG = "TRUE" *) reg sync_0;
    (* ASYNC_REG = "TRUE" *) reg sync_1;

    // Debounce state and counter
    reg [COUNTER_WIDTH-1:0] counter;
    reg stable_state;
    reg prev_stable_state;

    // Synchronizer logic
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sync_0 <= 1'b0;
            sync_1 <= 1'b0;
        end else begin
            sync_0 <= raw_signal;
            sync_1 <= sync_0;
        end
    end

    // Debounce Counter and State Update
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            counter <= 0;
            stable_state <= 1'b0;
            prev_stable_state <= 1'b0;
            clean_pulse <= 1'b0;
        end else begin
            // Track the previous stable state to detect the rising edge later
            prev_stable_state <= stable_state;

            // If the synchronized input differs from our currently recognized stable state
            if (sync_1 != stable_state) begin
                counter <= counter + 1;
                
                // Fixed: trigger state change one cycle earlier to account for nonblocking assignment
                if (counter == DEBOUNCE_LIMIT - 1) begin
                    stable_state <= sync_1; 
                    counter <= 0;       
                end
            end else begin
                // Signal bounced back or is stable, reset counter
                counter <= 0;
            end

            // 3. One-Cycle Pulse Generation (Rising Edge Only)
            if (stable_state == 1'b1 && prev_stable_state == 1'b0) begin
                clean_pulse <= 1'b1;
            end else begin
                clean_pulse <= 1'b0;
            end
        end
    end

endmodule