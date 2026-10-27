
// ============================================================================
// 1. Single-Line SPI    : Operates in standard SPI Mode 0 (CPOL=0, CPHA=0).
// 2. byte_req / byte_in : Handshake signals that pull multi-byte write data
//                         from the nvm_controller.
// 3. byte_valid /       : Output interface sending received data back to
//    byte_out             nvm_controller as parallel bytes.
// 4. CLK_DIV            : Prescaler parameter (default=4) to divide the system
//                         clock to match the target SPI Flash speed.
// 5. Standard Opcodes   : Uses standard SPI Flash commands: Read (0x03),
//                         Page Program (0x02), 4KB Sector Erase (0x20),
//                         Read Status (0x05), and Write Enable (0x06).
// ============================================================================

module qspi_master #(
    parameter CLK_DIV = 4
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [2:0]  op,
    input  wire [23:0] addr,
    input  wire [15:0] xfer_len,
    output reg         byte_req,
    input  wire [7:0]  byte_in,
    output reg         byte_valid,
    output reg  [7:0]  byte_out,
    output reg         busy,
    output reg         done,
    output reg         sck,
    output reg         cs_n,
    output reg         mosi,
    input  wire        miso
);

    localparam OP_READ         = 3'd0;
    localparam OP_PAGE_PROG    = 3'd1;
    localparam OP_SECTOR_ERASE = 3'd2;
    localparam OP_READ_STATUS  = 3'd3;
    localparam OP_WRITE_ENABLE = 3'd4;

    localparam [7:0] CMD_READ         = 8'h03;
    localparam [7:0] CMD_PAGE_PROGRAM  = 8'h02;
    localparam [7:0] CMD_SECTOR_ERASE  = 8'h20;
    localparam [7:0] CMD_READ_STATUS   = 8'h05;
    localparam [7:0] CMD_WRITE_ENABLE  = 8'h06;

    localparam S_IDLE        = 4'd0;
    localparam S_CS_LOW      = 4'd1;
    localparam S_SEND_OP     = 4'd2;
    localparam S_SEND_ADDR   = 4'd3;
    localparam S_DATA_WR_REQ = 4'd4;
    localparam S_DATA_WR_WAIT= 4'd5;
    localparam S_DATA_WR     = 4'd6;
    localparam S_DATA_RD     = 4'd7;
    localparam S_CS_HOLD     = 4'd8;
    localparam S_CS_HIGH     = 4'd9;
    localparam S_DONE        = 4'd10;

    reg [3:0]  state;
    reg [7:0]  shift_reg;
    reg [2:0]  bit_cnt;
    reg [1:0]  addr_byte_idx;
    reg [15:0] data_byte_cnt;
    reg [23:0] addr_latched;
    reg        has_addr_phase;
    reg        is_write_op;

    reg [$clog2(CLK_DIV+1)-1:0] clk_div_cnt;
    reg                         sck_en;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            clk_div_cnt <= 0;
            sck_en      <= 1'b0;
        end else if (busy) begin
            if (clk_div_cnt == CLK_DIV - 1) begin
                clk_div_cnt <= 0;
                sck_en      <= 1'b1;
            end else begin
                clk_div_cnt <= clk_div_cnt + 1'b1;
                sck_en      <= 1'b0;
            end
        end else begin
            clk_div_cnt <= 0;
            sck_en      <= 1'b0;
        end
    end

    function [7:0] op_to_cmd(input [2:0] op_sel);
        case (op_sel)
            OP_READ:         op_to_cmd = CMD_READ;
            OP_PAGE_PROG:    op_to_cmd = CMD_PAGE_PROGRAM;
            OP_SECTOR_ERASE: op_to_cmd = CMD_SECTOR_ERASE;
            OP_READ_STATUS:  op_to_cmd = CMD_READ_STATUS;
            OP_WRITE_ENABLE: op_to_cmd = CMD_WRITE_ENABLE;
            default:         op_to_cmd = 8'h00;
        endcase
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state         <= S_IDLE;
            busy          <= 1'b0;
            done          <= 1'b0;
            cs_n          <= 1'b1;
            sck           <= 1'b0;
            mosi          <= 1'b0;
            byte_req      <= 1'b0;
            byte_valid    <= 1'b0;
            byte_out      <= 8'h00;
            bit_cnt       <= 3'd7;
            addr_byte_idx <= 2'd0;
            data_byte_cnt <= 16'd0;
        end else begin
            byte_req   <= 1'b0;
            byte_valid <= 1'b0;
            done       <= 1'b0;

            case (state)
                S_IDLE: begin
                    cs_n <= 1'b1;
                    sck  <= 1'b0;
                    if (start) begin
                        busy           <= 1'b1;
                        addr_latched   <= addr;
                        has_addr_phase <= (op != OP_READ_STATUS) && (op != OP_WRITE_ENABLE);
                        is_write_op    <= (op == OP_PAGE_PROG);
                        data_byte_cnt  <= xfer_len;
                        addr_byte_idx  <= 2'd0;
                        bit_cnt        <= 3'd7;
                        shift_reg      <= op_to_cmd(op);
                        state          <= S_CS_LOW;
                    end
                end

                S_CS_LOW: begin
                    cs_n      <= 1'b0;
                    mosi      <= shift_reg[7];
                    shift_reg <= {shift_reg[6:0], 1'b0};
                    state     <= S_SEND_OP;
                end

                S_SEND_OP: if (sck_en) begin
                    sck <= ~sck;
                    if (~sck) begin
                        if (bit_cnt == 0) begin
                            bit_cnt <= 3'd7;
                            if (has_addr_phase) begin
                                shift_reg <= addr_latched[23:16];
                                state     <= S_SEND_ADDR;
                            end else if (data_byte_cnt > 0) begin
                                state     <= is_write_op ? S_DATA_WR_REQ : S_DATA_RD;
                            end else begin
                                state     <= S_CS_HOLD;
                            end
                        end else begin
                            bit_cnt <= bit_cnt - 1'b1;
                        end
                    end else begin
                        mosi      <= shift_reg[7];
                        shift_reg <= {shift_reg[6:0], 1'b0};
                    end
                end

                S_SEND_ADDR: if (sck_en) begin
                    sck <= ~sck;
                    if (~sck) begin
                        if (bit_cnt == 0) begin
                            bit_cnt <= 3'd7;
                            if (addr_byte_idx == 2'd2) begin
                                state <= (data_byte_cnt == 0) ? S_CS_HOLD :
                                          (is_write_op ? S_DATA_WR_REQ : S_DATA_RD);
                            end else begin
                                addr_byte_idx <= addr_byte_idx + 1'b1;
                                shift_reg <= (addr_byte_idx == 2'd0) ? addr_latched[15:8] : addr_latched[7:0];
                            end
                        end else
                            bit_cnt <= bit_cnt - 1'b1;
                    end else begin
                        mosi      <= shift_reg[7];
                        shift_reg <= {shift_reg[6:0], 1'b0};
                    end
                end

                S_DATA_WR_REQ: begin
                    byte_req  <= 1'b1;
                    shift_reg <= byte_in;
                    state     <= S_DATA_WR;
                end

                S_DATA_WR: if (sck_en) begin
                    sck <= ~sck;
                    if (~sck) begin
                        if (bit_cnt == 0) begin
                            bit_cnt <= 3'd7;
                            if (data_byte_cnt == 1)
                                state <= S_CS_HOLD;
                            else begin
                                data_byte_cnt <= data_byte_cnt - 1'b1;
                                state         <= S_DATA_WR_REQ;
                            end
                        end else
                            bit_cnt <= bit_cnt - 1'b1;
                    end else begin
                        mosi      <= shift_reg[7];
                        shift_reg <= {shift_reg[6:0], 1'b0};
                    end
                end

                S_DATA_RD: if (sck_en) begin
                    sck <= ~sck;
                    if (~sck) begin
                        if (bit_cnt == 0) begin
                            byte_out   <= {shift_reg[6:0], miso};
                            byte_valid <= 1'b1;
                            bit_cnt    <= 3'd7;
                            if (data_byte_cnt == 1)
                                state <= S_CS_HOLD;
                            else
                                data_byte_cnt <= data_byte_cnt - 1'b1;
                        end else begin
                            shift_reg <= {shift_reg[6:0], miso};
                            bit_cnt   <= bit_cnt - 1'b1;
                        end
                    end
                end

                S_CS_HOLD: if (sck_en) begin
                    sck   <= 1'b0;
                    state <= S_CS_HIGH;
                end

                S_CS_HIGH: begin
                    cs_n  <= 1'b1;
                    state <= S_DONE;
                end

                S_DONE: begin
                    busy  <= 1'b0;
                    done  <= 1 meb0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
