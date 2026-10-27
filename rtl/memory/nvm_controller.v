// ============================================================================
// 1. byte_count [3:0]    : Data length (1 to 8 bytes) to handle different
//                          data sizes like 64-bit counts or 8-bit markers.
// 2. double_buffered     : Flag to use logical offsets inside a 4 KB
//                          double-buffered slot (Slot A / Slot B).
// 3. erase_en            : Triggers a 4 KB sector erase before writing
//                          (automatically set when double_buffered = 1).
// 4. POWERUP_DELAY /     : Configuration parameters for the 10 ms Flash power-on
//    WIP_POLL_LIMIT        wait and status polling timeout limit.
// 5. boot_state_byte /   : Direct output ports sending Flash boot markers
//    boot_clean_byte       to the tamper_detect module.
// 6. qm_* Port Names     : Handshake interface designed to match qspi_master.
// 7. DATA_REGION_START/  : Reserved memory zone (0x300000 - 0x3FFFFF) to keep
//    END                   election data separate from the FPGA bitstream.
// ============================================================================
module nvm_controller #(
    parameter ADDR_WIDTH     = 24,
    parameter POWERUP_DELAY  = 24'd1_000_000,
    parameter WIP_POLL_LIMIT = 24'd4_000_000
)(
    input  wire                  clk,
    input  wire                  rst,

    // Requester Interface
    input  wire                  write_req,
    input  wire                  read_req,
    input  wire [ADDR_WIDTH-1:0] address,
    input  wire [63:0]           write_data,
    input  wire [3:0]            byte_count,
    input  wire                  double_buffered,
    input  wire                  erase_en,
    output reg  [63:0]           read_data,
    output reg                   read_done,
    output reg                   read_error,
    output reg                   write_done,
    output reg                   write_error,
    output reg                   busy,

    // Boot Snapshot Interface
    output reg  [7:0]            boot_state_byte,
    output reg  [7:0]            boot_clean_byte,
    output reg                   boot_done,

    // QSPI Master Interface
    output reg                   qm_start,
    output reg  [2:0]            qm_op,
    output reg  [23:0]           qm_addr,
    output reg  [15:0]           qm_len,
    input  wire                  qm_byte_req,
    output wire [7:0]            qm_byte_in,
    input  wire                  qm_byte_valid,
    input  wire [7:0]            qm_byte_out,
    input  wire                  qm_busy,
    input  wire                  qm_done
);

    localparam [23:0] DATA_REGION_START = 24'h300000;
    localparam [23:0] DATA_REGION_END   = 24'h3FFFFF;
    localparam [23:0] TALLY_SLOT_A_BASE = 24'h300000;
    localparam [23:0] TALLY_SLOT_B_BASE = 24'h301000;
    localparam [23:0] TALLY_VALID_A     = 24'h302000;
    localparam [23:0] TALLY_VALID_B     = 24'h303000;
    localparam [23:0] STATE_MARKER_ADDR = 24'h304000;
    localparam [23:0] CLEAN_MARKER_ADDR = 24'h305000;
    localparam [7:0]  CLEAN_VALUE       = 8'hA5;

    localparam OP_READ         = 3'd0;
    localparam OP_PAGE_PROG    = 3'd1;
    localparam OP_SECTOR_ERASE = 3'd2;
    localparam OP_READ_STATUS  = 3'd3;
    localparam OP_WRITE_ENABLE = 3'd4;

    localparam [4:0]
        S_PWRUP          = 5'd0,
        S_BOOT_ISSUE     = 5'd1,
        S_BOOT_WAIT      = 5'd2,
        S_BOOT_DECIDE    = 5'd3,
        S_BOOT_CLEAN     = 5'd4,
        S_BOOT_FIN       = 5'd5,
        S_IDLE           = 5'd6,
        S_RD_ISSUE       = 5'd7,
        S_RD_WAIT        = 5'd8,
        S_WR_ERASE       = 5'd9,
        S_WR_PROGRAM     = 5'd10,
        S_WR_VERIFY      = 5'd11,
        S_WR_VERIFY_WAIT = 5'd12,
        S_WR_MARK_ERASE  = 5'd13,
        S_WR_MARK        = 5'd14,
        S_WR_CLEAR_OLD   = 5'd15,
        S_DONE           = 5'd16,
        S_ERROR          = 5'd17,
        S_SUB_WE         = 5'd18,
        S_SUB_WE_W       = 5'd19,
        S_SUB_CMD        = 5'd20,
        S_SUB_CMD_W      = 5'd21,
        S_SUB_POLL       = 5'd22,
        S_SUB_POLL_W     = 5'd23;

    reg [4:0]  state;
    reg [23:0] pwr_cnt;

    reg [63:0] wdata_latched;
    reg [3:0]  bcount_latched;
    reg [23:0] target_addr;
    reg [63:0] readback_data;
    reg        is_double_buf;
    reg        do_erase;
    reg [63:0] wdata_shift;

    reg        active_slot;
    reg [7:0]  cur_seq;

    reg [2:0]  sub_op;
    reg [23:0] sub_addr;
    reg [15:0] sub_len;
    reg [4:0]  sub_ret;
    reg [7:0]  status_byte;
    reg [23:0] poll_cnt;

    reg [1:0]  boot_step;
    reg [15:0] boot_acc;
    reg [15:0] mark_a, mark_b;

    function [7:0] nseq;
        input [7:0] s;
        begin
            nseq = (s >= 8'hFE) ? 8'h01 : (s + 8'd1);
        end
    endfunction

    wire a_ok = (mark_a[15:8] == ~mark_a[7:0]) && (mark_a[15:8] != 8'h00) && (mark_a[15:8] != 8'hFF);
    wire b_ok = (mark_b[15:8] == ~mark_b[7:0]) && (mark_b[15:8] != 8'h00) && (mark_b[15:8] != 8'hFF);
    wire a_newer = (mark_a[15:8] == nseq(mark_b[15:8]));

    wire [23:0] new_marker_addr = active_slot ? TALLY_VALID_A : TALLY_VALID_B;
    wire [23:0] old_marker_addr = active_slot ? TALLY_VALID_B : TALLY_VALID_A;

    wire [23:0] addr24      = address[23:0];
    wire [23:0] rd_slot     = active_slot ? TALLY_SLOT_B_BASE : TALLY_SLOT_A_BASE;
    wire [23:0] wr_slot     = active_slot ? TALLY_SLOT_A_BASE : TALLY_SLOT_B_BASE;
    wire [23:0] rd_addr     = double_buffered ? (rd_slot + {12'd0, addr24[11:0]}) : addr24;
    wire [23:0] wr_addr     = double_buffered ? (wr_slot + {12'd0, addr24[11:0]}) : addr24;
    wire [8:0]  page_end    = {1'b0, wr_addr[7:0]} + {5'd0, byte_count};
    wire        in_tally_rg = (wr_addr >= TALLY_SLOT_A_BASE) && (wr_addr < STATE_MARKER_ADDR);

    wire rd_bad = (byte_count == 4'd0) || (byte_count > 4'd8) ||
                  (double_buffered && (addr24[23:12] != 12'd0));
    wire wr_bad = (byte_count == 4'd0) || (byte_count > 4'd8) ||
                  (wr_addr < DATA_REGION_START) || (wr_addr > DATA_REGION_END) ||
                  (page_end > 9'd256) ||
                  (double_buffered && (addr24[23:12] != 12'd0)) ||
                  (!double_buffered && in_tally_rg);

    wire [6:0]  pad_bits = {(4'd8 - bcount_latched), 3'b000};
    wire [63:0] rb_cmp   = readback_data  << pad_bits;
    wire [63:0] wd_cmp   = wdata_latched  << pad_bits;

    assign qm_byte_in = wdata_shift[63:56];

    always @(posedge clk or posedge rst) begin
        if (rst)
            wdata_shift <= 64'd0;
        else if (state == S_WR_PROGRAM)
            wdata_shift <= wdata_latched << pad_bits;
        else if (state == S_WR_MARK)
            wdata_shift <= {nseq(cur_seq), ~nseq(cur_seq), 48'd0};
        else if (qm_byte_req)
            wdata_shift <= {wdata_shift[55:0], 8'h00};
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state           <= S_PWRUP;
            pwr_cnt         <= 24'd0;
            busy            <= 1'b1;
            write_done      <= 1'b0;
            write_error     <= 1'b0;
            read_done       <= 1'b0;
            read_error      <= 1'b0;
            boot_done       <= 1'b0;
            boot_state_byte <= 8'hFF;
            boot_clean_byte <= 8'hFF;
            qm_start        <= 1'b0;
            qm_op           <= 3'd0;
            qm_addr         <= 24'd0;
            qm_len          <= 16'd0;
            read_data       <= 64'd0;
            readback_data   <= 64'd0;
            target_addr     <= 24'd0;
            wdata_latched   <= 64'd0;
            bcount_latched  <= 4'd0;
            is_double_buf   <= 1'b0;
            do_erase        <= 1'b0;
            active_slot     <= 1'b0;
            cur_seq         <= 8'd0;
            sub_op          <= 3'd0;
            sub_addr        <= 24'd0;
            sub_len         <= 16'd0;
            sub_ret         <= S_IDLE;
            status_byte     <= 8'h01;
            poll_cnt        <= 24'd0;
            boot_step       <= 2'd0;
            boot_acc        <= 16'd0;
            mark_a          <= 16'hFFFF;
            mark_b          <= 16'hFFFF;
        end else begin
            qm_start   <= 1'b0;
            write_done <= 1'b0;
            read_done  <= 1'b0;
            read_error <= 1'b0;

            case (state)

                S_PWRUP: begin
                    if (pwr_cnt == POWERUP_DELAY) begin
                        boot_step <= 2'd0;
                        state     <= S_BOOT_ISSUE;
                    end else
                        pwr_cnt <= pwr_cnt + 1'b1;
                end

                S_BOOT_ISSUE: begin
                    qm_op    <= OP_READ;
                    qm_start <= 1'b1;
                    boot_acc <= 16'd0;
                    case (boot_step)
                        2'd0: begin qm_addr <= TALLY_VALID_A;     qm_len <= 16'd2; end
                        2'd1: begin qm_addr <= TALLY_VALID_B;     qm_len <= 16'd2; end
                        2'd2: begin qm_addr <= STATE_MARKER_ADDR; qm_len <= 16'd1; end
                        default: begin qm_addr <= CLEAN_MARKER_ADDR; qm_len <= 16'd1; end
                    endcase
                    state <= S_BOOT_WAIT;
                end

                S_BOOT_WAIT: begin
                    if (qm_byte_valid)
                        boot_acc <= {boot_acc[7:0], qm_byte_out};
                    if (qm_done) begin
                        case (boot_step)
                            2'd0: mark_a          <= boot_acc;
                            2'd1: mark_b          <= boot_acc;
                            2'd2: boot_state_byte <= boot_acc[7:0];
                            default: boot_clean_byte <= boot_acc[7:0];
                        endcase
                        if (boot_step == 2'd3)
                            state <= S_BOOT_DECIDE;
                        else begin
                            boot_step <= boot_step + 1'b1;
                            state     <= S_BOOT_ISSUE;
                        end
                    end
                end

                S_BOOT_DECIDE: begin
                    case ({b_ok, a_ok})
                        2'b01: begin
                            active_slot <= 1'b0;
                            cur_seq     <= mark_a[15:8];
                            state       <= S_BOOT_CLEAN;
                        end
                        2'b10: begin
                            active_slot <= 1'b1;
                            cur_seq     <= mark_b[15:8];
                            state       <= S_BOOT_CLEAN;
                        end
                        2'b11: begin
                            sub_op   <= OP_SECTOR_ERASE;
                            sub_len  <= 16'd0;
                            sub_ret  <= S_BOOT_CLEAN;
                            if (a_newer) begin
                                active_slot <= 1'b0;
                                cur_seq     <= mark_a[15:8];
                                sub_addr    <= TALLY_VALID_B;
                            end else begin
                                active_slot <= 1'b1;
                                cur_seq     <= mark_b[15:8];
                                sub_addr    <= TALLY_VALID_A;
                            end
                            state <= S_SUB_WE;
                        end
                        default: begin
                            active_slot <= 1'b0;
                            cur_seq     <= 8'd0;
                            state       <= S_BOOT_CLEAN;
                        end
                    endcase
                end

                S_BOOT_CLEAN: begin
                    if (boot_clean_byte != 8'hFF) begin
                        sub_op   <= OP_SECTOR_ERASE;
                        sub_addr <= CLEAN_MARKER_ADDR;
                        sub_len  <= 16'd0;
                        sub_ret  <= S_BOOT_FIN;
                        state    <= S_SUB_WE;
                    end else
                        state <= S_BOOT_FIN;
                end

                S_BOOT_FIN: begin
                    boot_done <= 1'b1;
                    busy      <= 1'b0;
                    state     <= S_IDLE;
                end

                S_IDLE: begin
                    write_error <= 1'b0;
                    if (read_req) begin
                        if (rd_bad)
                            read_error <= 1'b1;
                        else begin
                            busy           <= 1'b1;
                            target_addr    <= rd_addr;
                            bcount_latched <= byte_count;
                            state          <= S_RD_ISSUE;
                        end
                    end else if (write_req) begin
                        busy           <= 1'b1;
                        wdata_latched  <= write_data;
                        bcount_latched <= byte_count;
                        is_double_buf  <= double_buffered;
                        do_erase       <= erase_en | double_buffered;
                        target_addr    <= wr_addr;
                        if (wr_bad)
                            state <= S_ERROR;
                        else
                            state <= (erase_en | double_buffered) ? S_WR_ERASE : S_WR_PROGRAM;
                    end
                end

                S_RD_ISSUE: begin
                    qm_op     <= OP_READ;
                    qm_addr   <= target_addr;
                    qm_len    <= {12'd0, bcount_latched};
                    qm_start  <= 1'b1;
                    read_data <= 64'd0;
                    state     <= S_RD_WAIT;
                end

                S_RD_WAIT: begin
                    if (qm_byte_valid)
                        read_data <= {read_data[55:0], qm_byte_out};
                    if (qm_done) begin
                        busy      <= 1'b0;
                        read_done <= 1'b1;
                        state     <= S_IDLE;
                    end
                end

                S_WR_ERASE: begin
                    sub_op   <= OP_SECTOR_ERASE;
                    sub_addr <= target_addr;
                    sub_len  <= 16'd0;
                    sub_ret  <= S_WR_PROGRAM;
                    state    <= S_SUB_WE;
                end

                S_WR_PROGRAM: begin
                    sub_op   <= OP_PAGE_PROG;
                    sub_addr <= target_addr;
                    sub_len  <= {12'd0, bcount_latched};
                    sub_ret  <= S_WR_VERIFY;
                    state    <= S_SUB_WE;
                end

                S_WR_VERIFY: begin
                    qm_op         <= OP_READ;
                    qm_addr       <= target_addr;
                    qm_len        <= {12'd0, bcount_latched};
                    qm_start      <= 1'b1;
                    readback_data <= 64'd0;
                    state         <= S_WR_VERIFY_WAIT;
                end

                S_WR_VERIFY_WAIT: begin
                    if (qm_byte_valid)
                        readback_data <= {readback_data[55:0], qm_byte_out};
                    if (qm_done) begin
                        if (rb_cmp == wd_cmp)
                            state <= is_double_buf ? S_WR_MARK_ERASE : S_DONE;
                        else
                            state <= S_ERROR;
                    end
                end

                S_WR_MARK_ERASE: begin
                    sub_op   <= OP_SECTOR_ERASE;
                    sub_addr <= new_marker_addr;
                    sub_len  <= 16'd0;
                    sub_ret  <= S_WR_MARK;
                    state    <= S_SUB_WE;
                end

                S_WR_MARK: begin
                    sub_op   <= OP_PAGE_PROG;
                    sub_addr <= new_marker_addr;
                    sub_len  <= 16'd2;
                    sub_ret  <= S_WR_CLEAR_OLD;
                    state    <= S_SUB_WE;
                end

                S_WR_CLEAR_OLD: begin
                    sub_op   <= OP_SECTOR_ERASE;
                    sub_addr <= old_marker_addr;
                    sub_len  <= 16'd0;
                    sub_ret  <= S_DONE;
                    state    <= S_SUB_WE;
                end

                S_SUB_WE: begin
                    qm_op    <= OP_WRITE_ENABLE;
                    qm_len   <= 16'd0;
                    qm_start <= 1'b1;
                    state    <= S_SUB_WE_W;
                end

                S_SUB_WE_W: if (qm_done) state <= S_SUB_CMD;

                S_SUB_CMD: begin
                    qm_op    <= sub_op;
                    qm_addr  <= sub_addr;
                    qm_len   <= sub_len;
                    qm_start <= 1'b1;
                    poll_cnt <= 24'd0;
                    state    <= S_SUB_CMD_W;
                end

                S_SUB_CMD_W: if (qm_done) state <= S_SUB_POLL;

                S_SUB_POLL: begin
                    qm_op       <= OP_READ_STATUS;
                    qm_len      <= 16'd1;
                    qm_start    <= 1'b1;
                    status_byte <= 8'h01;
                    state       <= S_SUB_POLL_W;
                end

                S_SUB_POLL_W: begin
                    if (qm_byte_valid)
                        status_byte <= qm_byte_out;
                    if (qm_done) begin
                        if (!status_byte[0])
                            state <= sub_ret;
                        else if (poll_cnt >= WIP_POLL_LIMIT)
                            state <= S_ERROR;
                        else begin
                            poll_cnt <= poll_cnt + 1'b1;
                            state    <= S_SUB_POLL;
                        end
                    end
                end

                S_DONE: begin
                    busy       <= 1'b0;
                    write_done <= 1'b1;
                    if (is_double_buf) begin
                        active_slot <= ~active_slot;
                        cur_seq     <= nseq(cur_seq);
                    end
                    state <= S_IDLE;
                end

                S_ERROR: begin
                    busy        <= 1'b0;
                    write_error <= 1'b1;
                    state       <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
