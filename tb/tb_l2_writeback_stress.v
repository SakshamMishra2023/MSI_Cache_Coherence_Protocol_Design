`timescale 1ns / 1ps
`include "cache_params.vh"

// Stress test specifically designed to trigger L2 writeback to DRAM
module tb_l2_writeback_stress;

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
        forever #5 clk = ~clk;
    end

    // ===== Waveform Dump =====
    initial begin
        $dumpfile("l2_writeback_stress.vcd");
        $dumpvars(0, tb_l2_writeback_stress);
    end

    // ===== Monitor DRAM Writes =====
    integer dram_write_count;
    always @(posedge clk) begin
        if (mem_wr && mem_ready) begin
            dram_write_count = dram_write_count + 1;
            $display("\n*** DRAM WRITEBACK #%0d DETECTED! ***", dram_write_count);
            $display("    Time: %0t", $time);
            $display("    Address: 0x%h", mem_addr);
            $display("    Data: 0x%h", mem_wdata[63:0]);
            $display("    L2 evicting dirty victim\n");
        end
    end

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
        end
    endtask

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
        end
    endtask

    // ===== Main Test =====
    integer i, set_num, way_num;
    reg [31:0] test_addr;

    initial begin
        // Initialize
        rst_n = 0;
        cpu_rd = 0;
        cpu_wr = 0;
        cpu_addr = 32'b0;
        cpu_wdata = 32'b0;
        cpu_byte_en = 4'b0000;
        dram_write_count = 0;

        #20;
        rst_n = 1;
        #20;

        $display("\n========================================");
        $display("L2 WRITEBACK STRESS TEST");
        $display("========================================");
        $display("L2 Config: 8-way, 256 sets");
        $display("Strategy: Fill all 8 ways of one set with dirty data");
        $display("          Then access 9th line to force eviction");
        $display("========================================\n");

        // Choose a specific set (e.g., set 0x10 = 16)
        set_num = 16;
        
        $display("PHASE 1: Fill all 8 ways of set %0d with dirty data", set_num);
        $display("--------------------------------------------------------");
        
        // Fill all 8 ways of the chosen set
        // L2 address breakdown: [tag][index][offset]
        // index = bits [13:6] for L2
        // To hit the same set, keep bits [13:6] constant, vary tag
        
        for (way_num = 0; way_num < 8; way_num = way_num + 1) begin
            // Address format: [tag (18 bits)][index (8 bits)][offset (6 bits)]
            // Keep index = set_num (16), vary tag
            test_addr = {way_num[17:0], set_num[7:0], 6'b0};
            
            $display("  Way %0d: Writing to addr 0x%h (tag=0x%h, set=%0d)", 
                     way_num, test_addr, way_num[17:0], set_num);
            
            cpu_write(test_addr, 32'hBEEF_0000 + way_num);
            repeat (3) @(posedge clk);
        end

        $display("\n✓ All 8 ways filled with dirty data");
        $display("  Each way contains unique data (0xBEEF000X)\n");

        repeat (10) @(posedge clk);

        $display("PHASE 2: Access 9th line (same set, new tag)");
        $display("--------------------------------------------------------");
        $display("This should evict the LRU way and writeback to DRAM\n");

        // Access 9th line with same set but different tag
        test_addr = {18'd8, set_num[7:0], 6'b0};  // tag=8, set=16
        
        $display("  Accessing addr 0x%h (tag=0x%h, set=%0d)", 
                 test_addr, 18'd8, set_num);
        $display("  Expecting: L2 miss -> Writeback of LRU victim -> Allocate new line\n");
        
        cpu_write(test_addr, 32'hDEAD_BEEF);
        
        repeat (20) @(posedge clk);

        if (dram_write_count > 0) begin
            $display("\n========================================");
            $display("✓✓✓ SUCCESS! ✓✓✓");
            $display("========================================");
            $display("L2 writeback to DRAM verified!");
            $display("Total DRAM writebacks: %0d", dram_write_count);
        end else begin
            $display("\n========================================");
            $display("⚠ WARNING");
            $display("========================================");
            $display("No DRAM writeback detected.");
            $display("Possible issues:");
            $display("  - L2 write-back logic not working");
            $display("  - LRU victim not dirty");
            $display("  - State machine issue");
        end

        $display("\n========================================");
        $display("PHASE 3: Additional stress (fill more sets)");
        $display("========================================\n");

        // Fill multiple sets to increase writeback chances
        for (set_num = 20; set_num < 24; set_num = set_num + 1) begin
            $display("Filling set %0d...", set_num);
            
            for (way_num = 0; way_num < 9; way_num = way_num + 1) begin
                test_addr = {way_num[17:0], set_num[7:0], 6'b0};
                cpu_write(test_addr, 32'hCAFE_0000 + (set_num << 8) + way_num);
                repeat (2) @(posedge clk);
            end
            
            repeat (5) @(posedge clk);
        end

        repeat (20) @(posedge clk);

        $display("\n========================================");
        $display("TEST COMPLETE");
        $display("========================================");
        $display("Total DRAM Writebacks: %0d", dram_write_count);
        $display("========================================\n");

        #100;
        $finish;
    end

    // ===== Timeout =====
    initial begin
        #500000;
        $display("\n[ERROR] Simulation timeout!");
        $display("DRAM writebacks detected: %0d", dram_write_count);
        $finish;
    end

endmodule