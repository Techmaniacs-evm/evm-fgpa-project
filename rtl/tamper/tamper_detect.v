`timescale 1ns / 1ps

/*
 * MODULE 4.5: TAMPER DETECT
 *
 * ASSUMPTIONS AND INTEGRATION REQUIREMENTS
 *
 * 1. CLOCK AND RESET
 *    - clk is assumed to be the system clock running at 100 MHz.
 *    - rst is an active-high asynchronous reset.
 *
 * 2. PHYSICAL TAMPER INPUT
 *    - case_open_raw is active-high: 1 indicates that the case is open.
 *    - Assumes the input is synchronized and debounced before reaching this module. Synchronization and debouncing are not implemented here.
 *    - Once detected, physical tamper remains latched until an administrative clear request occurs while the case is closed.
 *
 * 3. ADMINISTRATIVE CLEAR INPUT
 *    - admin_clear_tamper is assumed to be a valid control pulse from the administrative input logic.
 *    - Administrator authentication is handled outside this module.
 *    - The physical tamper latch and boot tamper latch have separate clearing conditions.
 *    - A physical tamper can be cleared while a boot fault remains active. tamper_flag remains high while either latch is set.
 *
 * 4. NON-VOLATILE MEMORY (NVM) INTERFACE
 *    - nvm_read_data must contain valid read data when nvm_read_done is high.
 *    - nvm_read_done is assumed to be a one-clock-cycle completion pulse.
 *    - nvm_error indicates that the requested read failed.
 *    - The NVM controller must accept read requests and support the
 *      sequential reads requested by this module.
 *    - nvm_read_req and nvm_read_addr are the request and address outputs.
 *    - This module reads NVM markers but does not write or invalidate them.
 *
 * 5. NVM MEMORY MAP AND MARKER POLICY
 *    - ADDR_STATE identifies the stored EVM state.
 *    - ADDR_SHUTDOWN identifies the stored shutdown marker.
 *    - STATE_OPEN_MAGIC identifies an open election.
 *    - STATE_CLOSED_MAGIC identifies a closed election.
 *    - CLEAN_SHUT_MAGIC identifies a clean shutdown.
 *    - These parameter values must match the system's NVM format.
 *    - The surrounding FSM/controller must invalidate the clean-shutdown marker when an election opens and write it only after a verified,
 *      safe shutdown.
 *    - If the saved state is CLOSED, a missing clean-shutdown marker is ignored by the current implementation.
 *
 * 6. BOOT CHECK AND MAIN FSM
 *    - The main FSM must wait for boot_check_done before proceeding beyond its initialization phase.
 *    - boot_check_done indicates that the boot check has terminated;
 *      it does not indicate that the system is safe to operate.
 *    - The main FSM must independently check tamper_flag before enabling voting.
 *
 * 7. BOOT FAULT RECOVERY
 *    - Invalid saved state or an NVM read error causes the boot FSM to enter BOOT_HALT_FAIL and latch a boot fault.
 *    - The admin clear input cannot clear a fault while in BOOT_HALT_FAIL.
 *    - A missing clean-shutdown marker for an OPEN state creates a recoverable boot fault that can be cleared after boot completion.
 *    - Reset clears the boot latch and restarts validation from NVM. Fault persistence across reset is not implemented in this module.
 *
 * INTERNAL REGISTERS AND THEIR ROLES
 *    boot_state
 *      Tracks the boot-validation FSM stages, including NVM requests,
 *      waiting for responses, successful completion, and failure.
 *
 *    saved_evm_state
 *      Stores the state marker read from NVM so it can be checked
 *      against the shutdown marker returned by the second read.
 *
 *    physical_tamper_latched
 *      Remembers a detected case-opening event until a valid physical
 *      tamper-clear condition occurs.
 *
 *    boot_tamper_latched
 *      Remembers a boot-validation fault. Contributes to tamper_flag.
 *
 *    recoverable_power_cut
 *      Tracks the recoverable boot-fault condition caused by an OPEN
 *      saved state without a clean-shutdown marker. It does not prove
 *      that a power cut occurred.
 *
 *    tamper_flag
 *      Combinational OR of physical_tamper_latched and boot_tamper_latched.
 *
 *    boot_check_done
 *      Indicates that the boot-validation FSM has reached a terminal
 *      state, either BOOT_COMPLETE or BOOT_HALT_FAIL.
 *
 * NO ADDITIONAL EXTERNAL SIGNALS
 *    The internal registers listed above are implementation details.
 *    This documentation does not introduce new ports or change the RTL interface.
 */

module tamper_detect #(
    parameter [31:0] ADDR_STATE         = 32'h0000_1000,
    parameter [31:0] ADDR_SHUTDOWN      = 32'h0000_1004,
    parameter [31:0] STATE_OPEN_MAGIC   = 32'hA5A5_0001,
    parameter [31:0] STATE_CLOSED_MAGIC = 32'hA5A5_0002, 
    parameter [31:0] CLEAN_SHUT_MAGIC   = 32'hDEAD_BEEF
)(
    input  wire clk,
    input  wire rst,
    
    // Physical Security
    input  wire case_open_raw,      
    input  wire admin_clear_tamper, 
    
    // NVM Interface
    input  wire [31:0] nvm_read_data,
    input  wire nvm_read_done,
    input  wire nvm_error,          
    output reg  nvm_read_req,
    output reg  [31:0] nvm_read_addr,
    
    // Module Outputs
    output wire tamper_flag,        
    output reg  boot_check_done     
);

    localparam BOOT_INIT      = 3'd0;
    localparam WAIT_STATE     = 3'd1;
    localparam REQ_SHUTDOWN   = 3'd2;
    localparam WAIT_SHUTDOWN  = 3'd3;
    localparam BOOT_COMPLETE  = 3'd4;
    localparam BOOT_HALT_FAIL = 3'd5; 

    reg [2:0] boot_state;
    reg [31:0] saved_evm_state;
    
    reg physical_tamper_latched;
    reg boot_tamper_latched;
    reg recoverable_power_cut; 

    assign tamper_flag = physical_tamper_latched | boot_tamper_latched;

    // Process 1: The Boot-Up Detective (Unexpected Restart)
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            boot_state <= BOOT_INIT;
            nvm_read_req <= 1'b0;
            nvm_read_addr <= 32'd0;
            boot_check_done <= 1'b0;
            boot_tamper_latched <= 1'b0;
            recoverable_power_cut <= 1'b0;
            saved_evm_state <= 32'd0;
        end else begin
            
            // STRICT CLEARING: Mandates boot completion AND a confirmed recoverable fault
            if (admin_clear_tamper && (boot_state == BOOT_COMPLETE) && recoverable_power_cut) begin
                boot_tamper_latched <= 1'b0;
                recoverable_power_cut <= 1'b0; // Reset the fault tracker
            end

            case (boot_state)
                BOOT_INIT: begin
                    nvm_read_addr <= ADDR_STATE;
                    nvm_read_req  <= 1'b1;
                    boot_state    <= WAIT_STATE;
                end
                
                WAIT_STATE: begin
                    if (nvm_error) begin
                        nvm_read_req <= 1'b0;
                        boot_tamper_latched <= 1'b1; 
                        boot_state <= BOOT_HALT_FAIL;
                    end else if (nvm_read_done) begin
                        nvm_read_req <= 1'b0;
                        saved_evm_state <= nvm_read_data;
                        
                        if ((nvm_read_data != STATE_OPEN_MAGIC) && 
                            (nvm_read_data != STATE_CLOSED_MAGIC)) begin
                            boot_tamper_latched <= 1'b1;
                            boot_state <= BOOT_HALT_FAIL;
                        end else begin
                            boot_state <= REQ_SHUTDOWN;
                        end
                    end
                end
                
                REQ_SHUTDOWN: begin
                    nvm_read_addr <= ADDR_SHUTDOWN;
                    nvm_read_req  <= 1'b1;
                    boot_state    <= WAIT_SHUTDOWN;
                end
                
                WAIT_SHUTDOWN: begin
                    if (nvm_error) begin
                        nvm_read_req <= 1'b0;
                        boot_tamper_latched <= 1'b1; 
                        boot_state <= BOOT_HALT_FAIL;
                    end else if (nvm_read_done) begin
                        nvm_read_req <= 1'b0;
                        
                        if ((saved_evm_state == STATE_OPEN_MAGIC) && 
                            (nvm_read_data != CLEAN_SHUT_MAGIC)) begin
                            boot_tamper_latched <= 1'b1;
                            recoverable_power_cut <= 1'b1; 
                        end
                        boot_state <= BOOT_COMPLETE;
                    end
                end
                
                BOOT_COMPLETE: begin
                    boot_check_done <= 1'b1; 
                end

                BOOT_HALT_FAIL: begin
                    boot_check_done <= 1'b1; 
                end
            endcase
        end
    end

    // Process 2: Live Physical Monitor (Case Open)
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            physical_tamper_latched <= 1'b0;
        end else begin
            if (case_open_raw) begin
                physical_tamper_latched <= 1'b1;
            end else if (admin_clear_tamper && !case_open_raw) begin
                physical_tamper_latched <= 1'b0;
            end
        end
    end

endmodule