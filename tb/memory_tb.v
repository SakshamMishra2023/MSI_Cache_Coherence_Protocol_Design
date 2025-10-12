`timescale 1ns/1ps
`include "cache_params.vh"

module memory_tb;

    // Clock/reset
    reg clk;
    reg rst;

    // DUT I/F
    reg         mem_req;
    reg         mem_wr;
    reg  [31:0] mem_addr;
    reg  [`L1_LINE_WIDTH-1:0] mem_wline;
    wire        mem_ready;
    wire [`L1_LINE_WIDTH-1:0] mem_rline;

    // DUT
    memory dut (
        .clk(clk),
        .rst(rst),
        .mem_req(mem_req),
        .mem_wr(mem_wr),
        .mem_addr(mem_addr),
        .mem_wline(mem_wline),
        .mem_ready(mem_ready),
        .mem_rline(mem_rline)
    );

    // Wave dump
    initial begin
    $dumpfile("memory.vcd");    // Name of the VCD file
    $dumpvars(0, memory_tb);    // Dump all signals in this testbench
end


    // Clock
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk; // 100 MHz
    end

    // Utilities
    localparam WORDS_PER_LINE = `WORDS_PER_LINE; // 16
    localparam LINE_BITS      = `L1_LINE_WIDTH;  // 512

    // Build a line with pattern: word[i] = base + 4*i ^ CONST
    function [LINE_BITS-1:0] make_line(input [31:0] base_addr, input [31:0] xormask);
        integer i;
        reg [LINE_BITS-1:0] tmp;
        begin
            tmp = '0;
            for (i = 0; i < WORDS_PER_LINE; i = i + 1) begin
                tmp[i*32 +: 32] = (base_addr + (i*4)) ^ xormask;
            end
            make_line = tmp;
        end
    endfunction

    // Pretty print a line (first few words)
    task print_line(input [LINE_BITS-1:0] line, input [8*32-1:0] tag);
        integer i;
        begin
            $display("%s", tag);
            for (i = 0; i < WORDS_PER_LINE; i = i + 1) begin
                $display("  word[%0d] = 0x%08x", i, line[i*32 +: 32]);
            end
        end
    endtask

    // Simple line write
    task mem_write_line(input [31:0] addr, input [LINE_BITS-1:0] line);
        begin
            @(negedge clk);
            mem_addr  <= addr;
            mem_wline <= line;
            mem_wr    <= 1'b1;
            mem_req   <= 1'b1;
            @(posedge clk);
            mem_req   <= 1'b0;
            // wait for completion
            wait (mem_ready);
            @(posedge clk);
            $display("[%0t] WRITE_LINE done @ addr=0x%08x", $time, addr);
        end
    endtask

    // Simple line read (result in mem_rline)
    task mem_read_line(input [31:0] addr);
        begin
            @(negedge clk);
            mem_addr  <= addr;
            mem_wr    <= 1'b0;
            mem_req   <= 1'b1;
            @(posedge clk);
            mem_req   <= 1'b0;
            wait (mem_ready);
            @(posedge clk);
            $display("[%0t] READ_LINE  done @ addr=0x%08x", $time, addr);
        end
    endtask

    // Test sequence
    localparam [31:0] ADDR_A = 32'h0000_1004; // unaligned on purpose (module aligns internally)
    localparam [31:0] ADDR_B = 32'h0001_1008; // different tag, also unaligned

    reg [LINE_BITS-1:0] lineA_w;
    reg [LINE_BITS-1:0] lineA_r;
    reg [LINE_BITS-1:0] lineB_w;
    reg [LINE_BITS-1:0] lineB_r;

    initial begin
        // init inputs
        mem_req  = 1'b0;
        mem_wr   = 1'b0;
        mem_addr = 32'h0;
        mem_wline= '0;

        // reset
        rst = 1'b1;
        repeat (3) @(posedge clk);
        rst = 1'b0;
        $display("=== Reset done at %0t ===", $time);

        // 1) Read A initially (expect zeros)
        $display("\n--- Test 1: Cold Read A (expect zeros) ---");
        mem_read_line(ADDR_A);
        lineA_r = mem_rline;
        // Check a few words are zero
        if (lineA_r !== {LINE_BITS{1'b0}}) begin
            $display("INFO: Memory not zero-initialized (that is okay if you loaded init).");
        end
        // print_line(lineA_r, "Line A (cold):");

        // 2) Write a pattern to line A, then read back and compare
        $display("\n--- Test 2: Write A, then Read A (compare) ---");
        lineA_w = make_line(ADDR_A & 32'hFFFF_FFC0, 32'hDEAD_BEEF);
        mem_write_line(ADDR_A, lineA_w);
        mem_read_line(ADDR_A);
        lineA_r = mem_rline;
        // print_line(lineA_w, "Line A (written):");
        // print_line(lineA_r, "Line A (read back):");
        if (lineA_r !== lineA_w) begin
            $display("FAIL: Line A mismatch!");
            $finish;
        end else begin
            $display("PASS: Line A matches (write/read).");
        end

        // 3) Write a different pattern to B, read back and compare
        $display("\n--- Test 3: Write B, then Read B (compare) ---");
        lineB_w = make_line(ADDR_B & 32'hFFFF_FFC0, 32'hCAFE_BABE);
        mem_write_line(ADDR_B, lineB_w);
        mem_read_line(ADDR_B);
        lineB_r = mem_rline;
        if (lineB_r !== lineB_w) begin
            $display("FAIL: Line B mismatch!");
            $finish;
        end else begin
            $display("PASS: Line B matches (write/read).");
        end

        // 4) Re-read A to ensure lines don’t interfere
        $display("\n--- Test 4: Read A again (should still match) ---");
        mem_read_line(ADDR_A);
        lineA_r = mem_rline;
        if (lineA_r !== lineA_w) begin
            $display("FAIL: Line A changed unexpectedly!");
            $finish;
        end else begin
            $display("PASS: Line A still matches.");
        end

        $display("\n=== ALL TESTS PASSED ===");
        #50 $finish;
    end

endmodule

