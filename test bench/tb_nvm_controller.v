
//   T0 boot on blank flash        T5 double-buffered writes
//   T1 write / read back          T6 reboot restores active slot
//   T2 verify mismatch            T7 boot snapshot, clean marker
//   T3 multi-byte alignment       T8 boot with both / partial markers
//   T4 rejected requests          T9 power cut at 55 points in one write
`timescale 1ns/1ps
module tb_nvm_controller;
    localparam [23:0] SLOT_A  = 24'h300000, SLOT_B  = 24'h301000;
    localparam [23:0] VALID_A = 24'h302000, VALID_B = 24'h303000;
    localparam [23:0] STATE_M = 24'h304000, CLEAN_M = 24'h305000;

    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;

    reg         write_req = 0, read_req = 0, double_buffered = 0, erase_en = 0;
    reg  [23:0] address = 0;
    reg  [63:0] write_data = 0;
    reg  [3:0]  byte_count = 0;
    wire [63:0] read_data;
    wire        read_done, read_error, write_done, write_error, busy;
    wire [7:0]  boot_state_byte, boot_clean_byte;
    wire        boot_done;

    wire        qm_start, qm_byte_req, qm_byte_valid, qm_busy, qm_done;
    wire [2:0]  qm_op;
    wire [23:0] qm_addr;
    wire [15:0] qm_len;
    wire [7:0]  qm_byte_in, qm_byte_out;
    wire        sck, cs_n, mosi, miso;

    nvm_controller #(.POWERUP_DELAY(24'd50)) dut (
        .clk(clk), .rst(rst),
        .write_req(write_req), .read_req(read_req), .address(address), .write_data(write_data),
        .byte_count(byte_count), .double_buffered(double_buffered), .erase_en(erase_en),
        .read_data(read_data), .read_done(read_done), .read_error(read_error),
        .write_done(write_done), .write_error(write_error), .busy(busy),
        .boot_state_byte(boot_state_byte), .boot_clean_byte(boot_clean_byte), .boot_done(boot_done),
        .qm_start(qm_start), .qm_op(qm_op), .qm_addr(qm_addr), .qm_len(qm_len),
        .qm_byte_req(qm_byte_req), .qm_byte_in(qm_byte_in),
        .qm_byte_valid(qm_byte_valid), .qm_byte_out(qm_byte_out),
        .qm_busy(qm_busy), .qm_done(qm_done));

    qspi_master #(.CLK_DIV(4)) qm (
        .clk(clk), .rst(rst), .start(qm_start), .op(qm_op), .addr(qm_addr), .xfer_len(qm_len),
        .byte_req(qm_byte_req), .byte_in(qm_byte_in), .byte_valid(qm_byte_valid), .byte_out(qm_byte_out),
        .busy(qm_busy), .done(qm_done), .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso));

    spi_flash_model #(.ERASE_NS(30000), .PROG_NS(5000)) fl (
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso));

    // ---- checking ----
    integer checks = 0, fails = 0;
    task check(input cond, input [8*70-1:0] msg);
        begin
            checks = checks + 1;
            if (!cond) begin fails = fails + 1; $display("FAIL: %0s", msg); end
        end
    endtask

    integer grp_fails = 0;
    task group_end(input [8*50-1:0] name);
        begin
            if (fails == grp_fails) $display("PASS: %0s", name);
            else                    $display("FAIL: %0s", name);
            grp_fails = fails;
        end
    endtask

    reg got_done, got_err;
    reg [63:0] rd;
    reg seen_done = 0;
    always @(posedge clk) if (write_done) seen_done <= 1;

    // ---- helpers ----
    task wait_idle;
        begin while (busy) @(posedge clk); @(posedge clk); end
    endtask

    task do_reset;                       // power-cycle the controller (flash keeps its contents)
        begin
            fl.reset_state;
            rst <= 1; repeat (3) @(posedge clk);
            rst <= 0; @(posedge clk);
            while (!boot_done) @(posedge clk);
            @(posedge clk);
        end
    endtask

    task pulse_write(input [23:0] a, input [63:0] d, input [3:0] n, input dbuf, input er);
        begin
            wait_idle;
            @(posedge clk); address <= a; write_data <= d; byte_count <= n;
            double_buffered <= dbuf; erase_en <= er; write_req <= 1;
            @(posedge clk); write_req <= 0;
        end
    endtask

    task do_write(input [23:0] a, input [63:0] d, input [3:0] n, input dbuf, input er);
        begin
            pulse_write(a, d, n, dbuf, er);
            got_done = 0; got_err = 0;
            while (!got_done && !got_err) begin @(posedge clk); got_done = write_done; got_err = write_error; end
        end
    endtask

    task do_read(input [23:0] a, input [3:0] n, input dbuf);
        begin
            wait_idle;
            @(posedge clk); address <= a; byte_count <= n; double_buffered <= dbuf; read_req <= 1;
            @(posedge clk); read_req <= 0;
            got_done = 0; got_err = 0;
            while (!got_done && !got_err) begin @(posedge clk); got_done = read_done; got_err = read_error; end
            rd = read_data;
        end
    endtask

    function [31:0] flash_hash(input dummy);
        integer i;
        begin flash_hash = 32'd17; for (i = 0; i < 65536; i = i + 1) flash_hash = flash_hash * 31 + fl.mem[i]; end
    endfunction

    reg [31:0] h0;
    task bad_write(input [23:0] a, input [3:0] n, input dbuf, input er, input [8*70-1:0] msg);
        begin
            h0 = flash_hash(0);
            do_write(a, 64'h0123456789ABCDEF, n, dbuf, er);
            check(got_err && !got_done && flash_hash(0) == h0, msg);
        end
    endtask
    task bad_read(input [23:0] a, input [3:0] n, input dbuf, input [8*70-1:0] msg);
        begin do_read(a, n, dbuf); check(got_err && !got_done, msg); end
    endtask

    task set_marker(input [23:0] a, input [7:0] b0, input [7:0] b1);   // write marker bytes straight into the flash model
        begin fl.mem[a[15:0]] = b0; fl.mem[a[15:0] + 1] = b1; end
    endtask

    // ---- test data ----
    localparam [63:0] V1 = 64'hDEADBEEF_00000001;
    localparam [63:0] V2 = 64'hCAFEBABE_00000002;
    localparam [63:0] V3 = 64'h0BADF00D_00000003;

    reg [7:0] snap [0:65535];
    integer i, k, t_start, t_full, cut_at, n_cuts;
    integer n_old, n_new, n_bad, n_lost, n_recov_fail;

    initial begin
        #200_000_000; $display("FAIL: timeout (a request never completed)"); $finish(0);
    end

    initial begin
        repeat (3) @(posedge clk); rst <= 0; @(posedge clk);
        while (!boot_done) @(posedge clk); @(posedge clk);

        // ============================================================== T0
        check(boot_state_byte == 8'hFF && boot_clean_byte == 8'hFF, "snapshot = FF/FF on blank flash");
        check(dut.active_slot == 0 && dut.cur_seq == 0,             "no valid copy: slot A, seq 0");
        check(!busy,                                                 "idle after boot");

        // ============================================================== T1
        group_end("T0 boot on blank flash");
        do_write(STATE_M, 64'h01, 1, 0, 1);
        check(got_done && !got_err,         "write_done, no error");
        check(fl.mem[16'h4000] == 8'h01,    "flash holds 01");
        do_read(STATE_M, 1, 0);
        check(got_done && rd == 64'h01,     "read_data = 01 (upper bits 0)");

        // ============================================================== T2
        group_end("T1 write and read back");
        do_write(STATE_M, 64'hFF, 1, 0, 0);          // programming FF over 01 cannot set bits
        check(got_err && !got_done,         "write_error raised");
        check(fl.mem[16'h4000] == 8'h01,    "old value untouched");

        // ============================================================== T3
        group_end("T2 verify mismatch");
        do_write(24'h306000, 64'h00000000_00AABBCC, 3, 0, 1);
        check(got_done && fl.mem[16'h6000] == 8'hAA && fl.mem[16'h6001] == 8'hBB && fl.mem[16'h6002] == 8'hCC,
              "3-byte write lands as AA BB CC");
        do_write(24'h306100, 64'h1122334455667788, 8, 0, 1);
        check(got_done && fl.mem[16'h6100] == 8'h11 && fl.mem[16'h6107] == 8'h88, "8-byte write lands 11..88");
        do_read(24'h306100, 8, 0); check(rd == 64'h1122334455667788, "read 8 bytes");
        do_read(24'h306100, 3, 0); check(rd == 64'h0000000000112233, "read 3 bytes (right-aligned)");
        do_read(24'h306100, 5, 0); check(rd == 64'h0000001122334455, "read 5 bytes (right-aligned)");

        // ============================================================== T4
        group_end("T3 multi-byte alignment");
        bad_write(24'h306000, 0, 0, 1, "write: byte_count = 0");
        bad_write(24'h306000, 9, 0, 1, "write: byte_count = 9");
        bad_write(24'h100000, 1, 0, 1, "write: below data region");
        bad_write(24'h400000, 1, 0, 1, "write: above data region");
        bad_write(24'h3060FE, 4, 0, 1, "write: crosses 256-byte page");
        bad_write(24'h300000, 1, 0, 1, "write: plain write into tally region");
        bad_write(24'h001000, 1, 1, 1, "write: double-buffer offset beyond 4 KB");
        bad_read (24'h306000, 0, 0,    "read: byte_count = 0");
        bad_read (24'h306000, 9, 0,    "read: byte_count = 9");
        bad_read (24'h001000, 1, 1,    "read: double-buffer offset beyond 4 KB");

        // ============================================================== T5
        group_end("T4 rejected requests");
        do_write(24'h0, V1, 8, 1, 0);
        check(got_done,                                  "V1 written");
        check(dut.active_slot == 1 && dut.cur_seq == 1,  "committed: slot B, seq 1");
        check(fl.mem[16'h1000] == 8'hDE && fl.mem[16'h1007] == 8'h01, "V1 sits in slot B");
        check(fl.mem[16'h3000] == 8'h01 && fl.mem[16'h3001] == 8'hFE, "marker B = {01,FE}");
        check(fl.mem[16'h2000] == 8'hFF && fl.mem[16'h2001] == 8'hFF, "marker A blank");
        do_read(24'h0, 8, 1); check(rd == V1, "read returns V1");
        do_write(24'h0, V2, 8, 1, 0);
        check(got_done,                                  "V2 written");
        check(dut.active_slot == 0 && dut.cur_seq == 2,  "committed: slot A, seq 2");
        check(fl.mem[16'h0000] == 8'hCA && fl.mem[16'h0007] == 8'h02, "V2 sits in slot A");
        check(fl.mem[16'h1000] == 8'hDE && fl.mem[16'h1007] == 8'h01, "V1 still in slot B (old copy kept)");
        check(fl.mem[16'h2000] == 8'h02 && fl.mem[16'h2001] == 8'hFD, "marker A = {02,FD}");
        check(fl.mem[16'h3000] == 8'hFF && fl.mem[16'h3001] == 8'hFF, "marker B erased");
        do_read(24'h0, 8, 1); check(rd == V2, "read returns V2");
        check(dut.nseq(8'h00) == 8'h01 && dut.nseq(8'hFD) == 8'hFE && dut.nseq(8'hFE) == 8'h01 && dut.nseq(8'hFF) == 8'h01,
              "sequence number wraps 0xFE -> 0x01");

        // ============================================================== T6
        group_end("T5 double-buffered writes");
        do_reset;
        check(dut.active_slot == 0 && dut.cur_seq == 2, "slot A, seq 2 restored");
        do_read(24'h0, 8, 1); check(rd == V2,           "tally still V2");

        // ============================================================== T7
        group_end("T6 reboot restores active slot");
        do_write(CLEAN_M, 64'hA5, 1, 0, 1);
        check(got_done && fl.mem[16'h5000] == 8'hA5, "clean marker written");
        do_reset;
        check(boot_state_byte == 8'h01 && boot_clean_byte == 8'hA5, "snapshot = state 01, clean A5");
        check(fl.mem[16'h5000] == 8'hFF,                            "clean marker reset to not-clean after being read");
        do_reset;
        check(boot_clean_byte == 8'hFF,                             "next boot sees not-clean");

        // ============================================================== T8
        group_end("T7 boot snapshot and clean marker");
        set_marker(VALID_B, 8'h01, 8'hFE);            // A = {02,FD} still valid -> power died before old marker erase
        do_reset;
        check(dut.active_slot == 0 && dut.cur_seq == 2, "A newer -> slot A");
        check(fl.mem[16'h3000] == 8'hFF,                "older marker B erased");
        set_marker(VALID_A, 8'h01, 8'hFE); set_marker(VALID_B, 8'h02, 8'hFD);
        do_reset;
        check(dut.active_slot == 1 && dut.cur_seq == 2, "B newer -> slot B");
        check(fl.mem[16'h2000] == 8'hFF,                "older marker A erased");
        set_marker(VALID_A, 8'h01, 8'hFE); set_marker(VALID_B, 8'hFE, 8'h01);
        do_reset;
        check(dut.active_slot == 0 && dut.cur_seq == 1, "wrap: seq 01 is newer than FE");
        fl.mem[16'h3000] = 8'hFF; fl.mem[16'h3001] = 8'hFF;
        set_marker(VALID_A, 8'h02, 8'hFF);            // half-programmed marker
        set_marker(VALID_B, 8'h05, 8'hFA);
        do_reset;
        check(dut.active_slot == 1 && dut.cur_seq == 5, "partial marker ignored");

        check(fl.n_midbyte == 0 && fl.n_busy_cmd == 0 && fl.n_nowel == 0, "flash saw no protocol violations (T0-T8)");

        // ============================================================== T9
        group_end("T8 boot with both/partial markers");
        fl.erase_all;  do_reset;
        do_write(24'h0, V1, 8, 1, 0);                 // committed baseline
        for (i = 0; i < 65536; i = i + 1) snap[i] = fl.mem[i];
        t_start = $time; do_write(24'h0, V2, 8, 1, 0); t_full = $time - t_start;
        fl.quiet = 1;
        n_cuts = 55; n_old = 0; n_new = 0; n_bad = 0; n_lost = 0; n_recov_fail = 0;
        for (k = 1; k <= n_cuts; k = k + 1) begin
            for (i = 0; i < 65536; i = i + 1) fl.mem[i] = snap[i];
            do_reset;
            seen_done = 0;
            pulse_write(24'h0, V2, 8, 1, 0);
            cut_at = (t_full * k) / 50;
            #(cut_at);
            fl.power_cut; rst <= 1; repeat (3) @(posedge clk); fl.power_on; rst <= 0; @(posedge clk);
            while (!boot_done) @(posedge clk); @(posedge clk);
            do_read(24'h0, 8, 1);
            if (rd == V2)      n_new = n_new + 1;
            else if (rd == V1) n_old = n_old + 1;
            else begin n_bad = n_bad + 1; $display("  FAIL: cut at %0d ns left tally = %h", cut_at, rd); end
            if (seen_done && rd != V2) begin n_lost = n_lost + 1; $display("  FAIL: write_done had fired but cut at %0d ns lost V2", cut_at); end
            do_write(24'h0, V3, 8, 1, 0);             // can the system carry on after the crash?
            do_read(24'h0, 8, 1);
            if (rd != V3) begin n_recov_fail = n_recov_fail + 1; $display("  FAIL: after crash at %0d ns next write gave %h", cut_at, rd); end
        end
        fl.quiet = 0;
        check(n_bad == 0,                  "never a corrupted tally");
        check(n_lost == 0,                 "an acknowledged write is never lost");
        check(n_recov_fail == 0,           "next write after every crash works");
        check(n_old > 0 && n_new > 0,      "sweep hit both outcomes (old kept / new committed)");
        check(fl.n_busy_cmd == 0 && fl.n_nowel == 0, "no commands sent while flash busy / without WEL");

        group_end("T9 power-cut sweep");
        $display("PASSED: %0d", checks - fails);
        $display("FAILED: %0d", fails);
        $finish(0);
    end
endmodule
