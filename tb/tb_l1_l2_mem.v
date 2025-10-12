`timescale 1ns / 1ps
`include "cache_params.vh"

module tb_l1_l2_full;

    // ===== Clock & Reset =====
    reg clk;
    reg rst_n;

    // ===== CPU <-> L1 interface =====
    reg  [31:0] cpu_addr;
    reg  [31:0] cpu_wdata;
    reg  [3:0]  cpu_byte_en;
    reg  cpu_rd;
    reg  cpu_wr;
    wire [31:0] cpu_rdata;
    wire cpu_ready;

    // ===== L1 <-> L2 interface =====
    wire [31:0] l2_addr;
    wire [`L1_LINE_WIDTH-1:0] l2_wdata;
    wire l2_rd;
    wire l2_wr;
    wire [`L1_LINE_WIDTH-1:0] l2_rdata;
    wire l2_ready;

    // ===== L2 <-> Memory interface =====
    wire [31:0] mem_addr;
    wire [`L2_LINE_WIDTH-1:0] mem_wdata;
    wire mem_rd;
    wire mem_wr;
    wire [`L2_LINE_WIDTH-1:0] mem_rdata;
    wire mem_ready;

    // ===== Instantiate L1 Cache =====
    l1_cache l1_inst (
        .clk(clk),
        .rst_n(rst_n),
        .cpu_addr(cpu_addr),
        .cpu_wdata(cpu_wdata),
        .cpu_byte_en(cpu_byte_en),
        .cpu_rd(cpu_rd),
        .cpu_wr(cpu_wr),
        .cpu_rdata(cpu_rdata),
        .cpu_ready(cpu_ready),
        .l2_addr(l2_addr),
        .l2_wdata(l2_wdata),
        .l2_rd(l2_rd),
        .l2_wr(l2_wr),
        .l2_rdata(l2_rdata),
        .l2_ready(l2_ready)
    );

    // ===== Instantiate L2 Cache =====
    new_l2_cache l2_inst (
        .clk(clk),
        .rst_n(rst_n),
        .l1_addr(l2_addr),
        .l1_wdata(l2_wdata),
        .l1_rd(l2_rd),
        .l1_wr(l2_wr),
        .l1_rdata(l2_rdata),
        .l1_ready(l2_ready),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_rd(mem_rd),
        .mem_wr(mem_wr),
        .mem_rdata(mem_rdata),
        .mem_ready(mem_ready)
    );

    // ===== Instantiate DRAM Model =====
    dram #(
        .LINE_SIZE(`L2_LINE_SIZE),
        .LATENCY(10),
        .DEPTH(65536)
    ) dram_inst (
        .clk(clk),
        .rst_n(rst_n),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_rd(mem_rd),
        .mem_wr(mem_wr),
        .mem_rdata(mem_rdata),
        .mem_ready(mem_ready)
    );

    // ===== Clock Generation =====
    initial begin
        clk = 0;
        forever #5 clk = ~clk;  // 10 ns clock period (100 MHz)
    end

    // ===== Waveform Dump =====
    initial begin
        $dumpfile("l1_l2_full_test.vcd");
        $dumpvars(0, tb_l1_l2_full);
    end

    // ===== Monitor Cache States =====
    always @(posedge clk) begin
        if (l1_inst.state != l1_inst.next_state) begin
            $display("[%0t] L1 State: %0d -> %0d", $time, l1_inst.state, l1_inst.next_state);
        end
        
        if (l2_inst.state != l2_inst.next_state) begin
            case (l2_inst.next_state)
                3'd0: $display("[%0t] L2 State: -> IDLE", $time);
                3'd1: $display("[%0t] L2 State: -> CHECK_HIT", $time);
                3'd2: $display("[%0t] L2 State: -> WRITEBACK", $time);
                3'd3: $display("[%0t] L2 State: -> ALLOCATE", $time);
                3'd4: $display("[%0t] L2 State: -> RESPOND", $time);
            endcase
        end
    end

    // ===== Task: CPU Read =====
    task cpu_read;
        input [31:0] addr;
        begin
            @(posedge clk);
            cpu_addr = addr;
            cpu_rd = 1;
            cpu_byte_en = 4'b1111;
            @(posedge clk);
            cpu_rd = 0;
            wait (cpu_ready == 1);
            @(posedge clk);
            $display("[%0t] CPU Read: addr=0x%h, data=0x%h", $time, addr, cpu_rdata);
        end
    endtask

    // ===== Task: CPU Write =====
    task cpu_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            cpu_addr = addr;
            cpu_wdata = data;
            cpu_wr = 1;
            cpu_byte_en = 4'b1111;
            @(posedge clk);
            cpu_wr = 0;
            wait (cpu_ready == 1);
            @(posedge clk);
            $display("[%0t] CPU Write: addr=0x%h, data=0x%h", $time, addr, data);
        end
    endtask

    // ===== Main Test Stimulus =====
    integer i;
    integer test_num;

    initial begin
        // Initialize
        rst_n      = 0;
        cpu_rd     = 0;
        cpu_wr     = 0;
        cpu_addr   = 32'b0;
        cpu_wdata  = 32'b0;
        cpu_byte_en = 4'b0000;
        test_num   = 0;

        // ===== Reset Phase =====
        #20;
        rst_n = 1;
        #20;

        // ========================================
        // TEST 1: CPU Read Miss (L1 miss, L2 miss)
        // ========================================
        test_num = 1;
        $display("\n========================================");
        $display("TEST %0d: CPU READ MISS (COLD START)", test_num);
        $display("  Expected: L1 miss -> L2 miss -> DRAM fetch");
        $display("========================================");
        cpu_read(32'h0000_1000);
        repeat (5) @(posedge clk);

        // ========================================
        // TEST 2: CPU Read Hit (L1 hit)
        // ========================================
        test_num = 2;
        $display("\n========================================");
        $display("TEST %0d: CPU READ HIT (L1 CACHE)", test_num);
        $display("  Expected: L1 hit -> immediate response");
        $display("========================================");
        cpu_read(32'h0000_1000);
        repeat (5) @(posedge clk);

        // ========================================
        // TEST 3: CPU Write Hit (L1 hit)
        // ========================================
        test_num = 3;
        $display("\n========================================");
        $display("TEST %0d: CPU WRITE HIT (L1 CACHE)", test_num);
        $display("  Expected: L1 hit -> write, mark dirty");
        $display("========================================");
        cpu_write(32'h0000_1000, 32'hDEADBEEF);
        repeat (5) @(posedge clk);

        // ========================================
        // TEST 4: CPU Read to Verify Write
        // ========================================
        test_num = 4;
        $display("\n========================================");
        $display("TEST %0d: CPU READ AFTER WRITE", test_num);
        $display("  Expected: L1 hit -> return 0xDEADBEEF");
        $display("========================================");
        cpu_read(32'h0000_1000);
        if (cpu_rdata == 32'hDEADBEEF) begin
            $display("  PASS: Data matches!");
        end else begin
            $display("  FAIL: Expected 0xDEADBEEF, got 0x%h", cpu_rdata);
        end
        repeat (5) @(posedge clk);

        // ========================================
        // TEST 5: Read Different Line (L1 miss, L2 miss)
        // ========================================
        test_num = 5;
        $display("\n========================================");
        $display("TEST %0d: READ DIFFERENT ADDRESS", test_num);
        $display("  Expected: L1 miss -> L2 miss -> DRAM");
        $display("========================================");
        cpu_read(32'h0000_2000);
        repeat (5) @(posedge clk);

        // ========================================
        // TEST 6: Write to New Address
        // ========================================
        test_num = 6;
        $display("\n========================================");
        $display("TEST %0d: WRITE TO NEW ADDRESS", test_num);
        $display("  Expected: L1 miss -> allocate -> write");
        $display("========================================");
        cpu_write(32'h0000_3000, 32'hCAFEBABE);
        repeat (5) @(posedge clk);

        // ========================================
        // TEST 7: Sequential Reads (Fill L1 cache)
        // ========================================
        test_num = 7;
        $display("\n========================================");
        $display("TEST %0d: SEQUENTIAL READS (FILL CACHE)", test_num);
        $display("========================================");
        for (i = 0; i < 8; i = i + 1) begin
            cpu_read(32'h0001_0000 + (i << 6));  // Different cache lines
            repeat (3) @(posedge clk);
        end
        repeat (5) @(posedge clk);

        // ========================================
        // TEST 8: Access Pattern to Trigger Eviction
        // ========================================
        test_num = 8;
        $display("\n========================================");
        $display("TEST %0d: TRIGGER CACHE EVICTION", test_num);
        $display("  Fill all ways, then access new line");
        $display("========================================");
        
        // Fill all 4 ways of a set with dirty data
        for (i = 0; i < 4; i = i + 1) begin
            cpu_write(32'h0002_0000 + (i << 13), 32'h1000_0000 + i);
            repeat (3) @(posedge clk);
        end
        
        // Access 5th line - should evict LRU
        cpu_write(32'h0002_0000 + (4 << 13), 32'h1000_0004);
        repeat (5) @(posedge clk);

        // ========================================
        // TEST 9: Read Back Evicted Data
        // ========================================
        test_num = 9;
        $display("\n========================================");
        $display("TEST %0d: READ BACK EVICTED DATA", test_num);
        $display("  Should fetch from L2 or memory");
        $display("========================================");
        cpu_read(32'h0002_0000);  // First address that was written
        repeat (5) @(posedge clk);

        // ========================================
        // TEST 10: Stress Test - Random Accesses
        // ========================================
        test_num = 10;
        $display("\n========================================");
        $display("TEST %0d: STRESS TEST - MIXED OPS", test_num);
        $display("========================================");
        
        cpu_write(32'h0000_5000, 32'hAAAAAAAA);
        repeat (2) @(posedge clk);
        cpu_read(32'h0000_5000);
        repeat (2) @(posedge clk);
        cpu_write(32'h0000_5004, 32'hBBBBBBBB);
        repeat (2) @(posedge clk);
        cpu_read(32'h0000_5004);
        repeat (2) @(posedge clk);
        cpu_write(32'h0000_6000, 32'hCCCCCCCC);
        repeat (2) @(posedge clk);
        cpu_read(32'h0000_1000);  // Go back to first address
        repeat (5) @(posedge clk);

        // ========================================
        // End of Tests
        // ========================================
        $display("\n========================================");
        $display("ALL TESTS COMPLETE");
        $display("========================================\n");
        
        #100;
        $finish;
    end
    
    // ===== Timeout Watchdog =====
    initial begin
        #200000;  // 200 microseconds
        $display("\n[ERROR] Simulation timeout!");
        $finish;
    end

endmodule