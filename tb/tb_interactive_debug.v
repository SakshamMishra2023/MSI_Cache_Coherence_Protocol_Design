`timescale 1ns / 1ps
`include "cache_params.vh"



//used with help from ai

module tb_interactive_debug;

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
    l1_cache_fixed l1_inst (
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
    new_l2_cache_fixed l2_inst (
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
        $dumpfile("interactive_debug.vcd");
        $dumpvars(0, tb_interactive_debug);
    end

    // ========================================
    // HELPER TASKS
    // ========================================
    
    // Task: CPU Read
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
            $display("\n[CPU READ] Addr=0x%h → Data=0x%h", addr, cpu_rdata);
        end
    endtask

    // Task: CPU Write
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
            $display("\n[CPU WRITE] Addr=0x%h ← Data=0x%h", addr, data);
        end
    endtask

    // ========================================
    // CACHE DISPLAY TASKS
    // ========================================
    
    // Display L1 Cache Contents
    task display_l1_cache;
        input [31:0] target_addr;  // Show set containing this address
        reg [6:0] set_idx;
        integer way;
        begin
            set_idx = target_addr[12:6];
            
            $display("\n========================================");
            $display("L1 CACHE - Set %0d (addr 0x%h)", set_idx, target_addr);
            $display("========================================");
            $display("Way | Valid | Dirty |    Tag    | Data (first 4 words)");
            $display("----|-------|-------|-----------|----------------------");
            
            for (way = 0; way < 4; way = way + 1) begin
                $write(" %0d  |", way);
                $write("   %0d   |", l1_inst.valid[way][set_idx]);
                $write("   %0d   |", l1_inst.dirty[way][set_idx]);
                $write(" 0x%h |", l1_inst.tag[way][set_idx]);
                $write(" 0x%h", l1_inst.data[way][set_idx][31:0]);
                $write(" 0x%h", l1_inst.data[way][set_idx][63:32]);
                $write(" 0x%h", l1_inst.data[way][set_idx][95:64]);
                $write(" 0x%h", l1_inst.data[way][set_idx][127:96]);
                $display("");
            end
            $display("========================================\n");
        end
    endtask

    // Display L2 Cache Contents
    task display_l2_cache;
        input [31:0] target_addr;  // Show set containing this address
        reg [7:0] set_idx;
        integer way;
        begin
            set_idx = target_addr[13:6];
            
            $display("\n========================================");
            $display("L2 CACHE - Set %0d (addr 0x%h)", set_idx, target_addr);
            $display("========================================");
            $display("Way | Valid | Dirty |    Tag    | Data (first 4 words)");
            $display("----|-------|-------|-----------|----------------------");
            
            for (way = 0; way < 8; way = way + 1) begin
                $write(" %0d  |", way);
                $write("   %0d   |", l2_inst.valid[way][set_idx]);
                $write("   %0d   |", l2_inst.dirty[way][set_idx]);
                $write(" 0x%h |", l2_inst.tag[way][set_idx]);
                $write(" 0x%h", l2_inst.data[way][set_idx][31:0]);
                $write(" 0x%h", l2_inst.data[way][set_idx][63:32]);
                $write(" 0x%h", l2_inst.data[way][set_idx][95:64]);
                $write(" 0x%h", l2_inst.data[way][set_idx][127:96]);
                $display("");
            end
            $display("========================================\n");
        end
    endtask

    // Display DRAM Contents
    task display_dram;
        input [31:0] start_addr;
        input integer num_lines;
        reg [15:0] line_addr;
        integer i;
        begin
            line_addr = start_addr[21:6];  // Cache line address
            
            $display("\n========================================");
            $display("DRAM CONTENTS - Starting at 0x%h", start_addr);
            $display("========================================");
            $display("Line Addr |           Data (first 8 words)");
            $display("----------|----------------------------------");
            
            for (i = 0; i < num_lines; i = i + 1) begin
                $write("  0x%h  |", (line_addr + i) << 6);
                $write(" 0x%h", dram_inst.storage[line_addr + i][31:0]);
                $write(" 0x%h", dram_inst.storage[line_addr + i][63:32]);
                $write(" 0x%h", dram_inst.storage[line_addr + i][95:64]);
                $write(" 0x%h", dram_inst.storage[line_addr + i][127:96]);
                $write(" 0x%h", dram_inst.storage[line_addr + i][159:128]);
                $write(" 0x%h", dram_inst.storage[line_addr + i][191:160]);
                $write(" 0x%h", dram_inst.storage[line_addr + i][223:192]);
                $write(" 0x%h", dram_inst.storage[line_addr + i][255:224]);
                $display("");
            end
            $display("========================================\n");
        end
    endtask

    // Display all cache hierarchy for a specific address
    task display_full_hierarchy;
        input [31:0] addr;
        begin
            $display("\n╔════════════════════════════════════════╗");
            $display("║   FULL HIERARCHY VIEW FOR 0x%h   ║", addr);
            $display("╚════════════════════════════════════════╝");
            
            display_l1_cache(addr);
            display_l2_cache(addr);
            display_dram(addr & 32'hFFFFFFC0, 4);  // Show 4 lines starting at aligned address
        end
    endtask

    // Decode address and show where it maps
    task decode_address;
        input [31:0] addr;
        reg [18:0] l1_tag;
        reg [6:0] l1_set;
        reg [5:0] l1_offset;
        reg [17:0] l2_tag;
        reg [7:0] l2_set;
        reg [5:0] l2_offset;
        begin
            // L1 breakdown
            l1_tag = addr[31:13];
            l1_set = addr[12:6];
            l1_offset = addr[5:0];
            
            // L2 breakdown
            l2_tag = addr[31:14];
            l2_set = addr[13:6];
            l2_offset = addr[5:0];
            
            $display("\n========================================");
            $display("ADDRESS DECODE: 0x%h", addr);
            $display("========================================");
            $display("Binary: %b", addr);
            $display("");
            $display("L1 Cache Mapping:");
            $display("  Tag:    0x%h (%0d bits)", l1_tag, 19);
            $display("  Set:    %0d (0x%h)", l1_set, l1_set);
            $display("  Offset: %0d bytes", l1_offset);
            $display("");
            $display("L2 Cache Mapping:");
            $display("  Tag:    0x%h (%0d bits)", l2_tag, 18);
            $display("  Set:    %0d (0x%h)", l2_set, l2_set);
            $display("  Offset: %0d bytes", l2_offset);
            $display("");
            $display("DRAM Line: %0d (0x%h)", addr[21:6], addr[21:6]);
            $display("========================================\n");
        end
    endtask


    // MAIN TEST SEQUENCE

    
    initial begin
        // Initialize
        rst_n      = 0;
        cpu_rd     = 0;
        cpu_wr     = 0;
        cpu_addr   = 32'b0;
        cpu_wdata  = 32'b0;
        cpu_byte_en = 4'b0000;

        #20;
        rst_n = 1;
        #20;

        $display("\n╔════════════════════════════════════════════════════╗");
        $display("║     INTERACTIVE CACHE DEBUG TESTBENCH              ║");
        $display("║                                                    ║");
        $display("║  This testbench allows you to easily test cache   ║");
        $display("║  operations and view the state of L1, L2, DRAM    ║");
        $display("╚════════════════════════════════════════════════════╝\n");

        // ====================================================================
        // YOUR MANUAL TEST OPERATIONS START HERE
        // ====================================================================
        // 
        // Available tasks:
        //   cpu_write(address, data)       - Write data to address
        //   cpu_read(address)              - Read data from address
        //   decode_address(address)        - Show how address maps to caches
        //   display_l1_cache(address)      - Show L1 set containing address
        //   display_l2_cache(address)      - Show L2 set containing address
        //   display_dram(address, num_lines) - Show DRAM contents
        //   display_full_hierarchy(address)  - Show L1, L2, DRAM for address
        //
        // EXAMPLES:
        // ====================================================================

        $display("\n>>> EXAMPLE 1: Basic Write and Read");
        $display("═══════════════════════════════════════\n");
        
        decode_address(32'h0000_1000);
        
        cpu_write(32'h0000_1000, 32'hDEADBEEF);
        repeat (5) @(posedge clk);
        
        display_full_hierarchy(32'h0000_1000);
        
        cpu_read(32'h0000_1000);
        repeat (5) @(posedge clk);

        // ====================================================================
        
        $display("\n>>> EXAMPLE 2: Test Cache Aliasing (Same Set, Different Tags)");
        $display("═══════════════════════════════════════════════════════════════\n");
        
        cpu_write(32'h0000_0000, 32'h11111111);  // Tag=0, Set=0
        repeat (3) @(posedge clk);
        
        cpu_write(32'h0000_2000, 32'h22222222);  // Tag=1, Set=0
        repeat (3) @(posedge clk);
        
        cpu_write(32'h0000_4000, 32'h33333333);  // Tag=2, Set=0
        repeat (3) @(posedge clk);
        
        display_l1_cache(32'h0000_0000);  // Show set 0


        
        $display("\n>>> EXAMPLE 3: Force L1 Eviction");
        $display("══════════════════════════════════════\n");
        
        cpu_write(32'h0000_6000, 32'h44444444);  // 4th way in set 0
        repeat (3) @(posedge clk);
        
        cpu_write(32'h0000_8000, 32'h55555555);  // 5th - forces eviction!
        repeat (10) @(posedge clk);
        
        display_l1_cache(32'h0000_0000);
        display_l2_cache(32'h0000_0000);


        
        $display("\n>>> EXAMPLE 4: Sequential Access Pattern");
        $display("═════════════════════════════════════════\n");
        
        cpu_write(32'h0001_0000, 32'hAAAA0000);
        repeat (2) @(posedge clk);
        
        cpu_write(32'h0001_0004, 32'hAAAA0001);
        repeat (2) @(posedge clk);
        
        cpu_write(32'h0001_0008, 32'hAAAA0002);
        repeat (2) @(posedge clk);
        
        display_l1_cache(32'h0001_0000);

        // ====================================================================
        // ADD YOUR OWN TESTS HERE!
        // ====================================================================
        
        $display("\n>>> YOUR CUSTOM TESTS");
        $display("═════════════════════════\n");
        
        // Example template - uncomment and modify:
        
        // Test 1: Your first test
        // cpu_write(32'h0000_XXXX, 32'hYYYYYYYY);
        // repeat (5) @(posedge clk);
        // display_full_hierarchy(32'h0000_XXXX);
        
        // Test 2: Your second test
        // cpu_read(32'h0000_XXXX);
        // repeat (5) @(posedge clk);
        
        // Test 3: Check specific cache state
        // display_l1_cache(32'h0000_XXXX);
        // display_l2_cache(32'h0000_XXXX);

        
        $display("\n>>> FINAL HIERARCHY SNAPSHOT");
        $display("═════════════════════════════════\n");
        
        display_full_hierarchy(32'h0000_0000);
        display_full_hierarchy(32'h0001_0000);

       
        
        $display("\n╔════════════════════════════════════════╗");
        $display("║       INTERACTIVE TEST COMPLETE        ║");
        $display("╚════════════════════════════════════════╝\n");
        
        #100;
        $finish;
    end
    
    // Timeout watchdog
    initial begin
        #500000;
        $display("\n[WARNING] Simulation timeout - stopping");
        $finish;
    end

endmodule