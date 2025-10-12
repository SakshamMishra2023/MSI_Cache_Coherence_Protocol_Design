

`include "cache_params.vh"
`timescale 1ns/1ps

module l1_cache_tb;

    reg clk;
    reg rst_n;
    
    // CPU Interface
    reg [31:0] cpu_addr;
    reg [31:0] cpu_wdata;
    reg [3:0] cpu_byte_en;
    reg cpu_rd;
    reg cpu_wr;
    wire [31:0] cpu_rdata;
    wire cpu_ready;
    
    // L2 Interface
    wire [31:0] l2_addr;
    wire [511:0] l2_wdata;
    wire l2_rd;
    wire l2_wr;
    reg [511:0] l2_rdata;
    reg l2_ready;
    
    // Instantiate L1 cache
    l1_cache dut (
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
    
    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;  // 100MHz clock
    end
    
    // Monitor cache state changes
    always @(posedge clk) begin
        if (dut.state != dut.next_state) begin
            $display("  [%0t] State: %0d -> %0d", $time, dut.state, dut.next_state);
        end
        if (dut.state == 2) begin  // CHECK_HIT state
            $display("  [%0t] CHECK_HIT: hit=%b, way=%d, index=%d, word_offset=%d", 
                     $time, dut.cache_hit, dut.hit_way, dut.addr_index, dut.word_offset);
            if (dut.saved_is_write) begin
                $display("  [%0t] Writing data=0x%h to way %d, index %d", 
                         $time, dut.saved_wdata, dut.hit_way, dut.addr_index);
            end
        end
    end
    
    // Mock L2 memory
    reg [511:0] mock_l2_mem [0:1023];
    integer l2_latency_counter;
    
    // L2 response logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l2_ready <= 0;
            l2_rdata <= 512'b0;
            l2_latency_counter <= 0;
        end else begin
            l2_ready <= 0;  // Default to not ready
            
            if ((l2_rd || l2_wr) && !l2_ready) begin
                if (l2_latency_counter < 9) begin  // Count 0-9 = 10 cycles
                    l2_latency_counter <= l2_latency_counter + 1;
                end else begin
                    l2_ready <= 1;  // Assert ready on cycle 10
                    l2_latency_counter <= 0;
                    
                    if (l2_rd) begin
                        // Return data based on address
                        l2_rdata <= {16{l2_addr[31:0]}};  // Simple pattern
                        $display("  [%0t] L2 returning data for addr=0x%h", $time, l2_addr);
                    end
                    
                    if (l2_wr) begin
                        $display("  [%0t] L2 accepting writeback from addr=0x%h", $time, l2_addr);
                    end
                end
            end else if (!l2_rd && !l2_wr) begin
                l2_latency_counter <= 0;
            end
        end
    end
    
    // Test sequence
    initial begin
        $dumpfile("l1_cache_test.vcd");
        $dumpvars(0, l1_cache_tb);
        
        // Initialize
        rst_n = 0;
        cpu_addr = 0;
        cpu_wdata = 0;
        cpu_byte_en = 4'b0000;
        cpu_rd = 0;
        cpu_wr = 0;
        
        #20;
        rst_n = 1;
        #20;
        
        $display("\n========================================");
        $display("Test 1: Read Miss (Cold Start)");
        $display("========================================");
        cpu_addr = 32'h0000_1000;
        cpu_rd = 1;
        cpu_byte_en = 4'b1111;
        #10;
        cpu_rd = 0;
        
        wait(cpu_ready);
        $display("Read complete: addr=0x%h, data=0x%h", cpu_addr, cpu_rdata);
        #20;
        
        $display("\n========================================");
        $display("Test 2: Read Hit (Same Address)");
        $display("========================================");
        cpu_addr = 32'h0000_1000;
        cpu_rd = 1;
        #10;
        cpu_rd = 0;
        
        wait(cpu_ready);
        $display("Read complete: addr=0x%h, data=0x%h", cpu_addr, cpu_rdata);
        #20;
        
        $display("\n========================================");
        $display("Test 3: Write Hit");
        $display("========================================");
        cpu_addr = 32'h0000_1000;
        cpu_wdata = 32'hDEAD_BEEF;
        cpu_wr = 1;
        cpu_byte_en = 4'b1111;
        #10;
        cpu_wr = 0;
        
        wait(cpu_ready);
        $display("Write complete: addr=0x%h, data=0x%h", cpu_addr, cpu_wdata);
        
        // Check what's actually in the cache
        #10;
        $display("  Cache contents after write:");
        $display("    way 0, set 0x10, word 0: 0x%h", dut.data[0][16][31:0]);
        $display("    way 1, set 0x10, word 0: 0x%h", dut.data[1][16][31:0]);
        $display("    way 2, set 0x10, word 0: 0x%h", dut.data[2][16][31:0]);
        $display("    way 3, set 0x10, word 0: 0x%h", dut.data[3][16][31:0]);
        #10;
        
        $display("\n========================================");
        $display("Test 4: Read After Write (Verify)");
        $display("========================================");
        cpu_addr = 32'h0000_1000;
        cpu_rd = 1;
        #10;
        cpu_rd = 0;
        
        wait(cpu_ready);
        $display("Read complete: addr=0x%h, data=0x%h", cpu_addr, cpu_rdata);
        if (cpu_rdata == 32'hDEAD_BEEF)
            $display("PASS: Data matches written value");
        else
            $display("FAIL: Data mismatch! Expected 0xDEADBEEF, got 0x%h", cpu_rdata);
        #20;
        
        $display("\n========================================");
        $display("Test 5: Write Miss (Allocate)");
        $display("========================================");
        cpu_addr = 32'h0000_2000;
        cpu_wdata = 32'hCAFE_BABE;
        cpu_wr = 1;
        cpu_byte_en = 4'b1111;
        #10;
        cpu_wr = 0;
        
        wait(cpu_ready);
        $display("Write complete: addr=0x%h, data=0x%h", cpu_addr, cpu_wdata);
        #20;
        
        $display("\n========================================");
        $display("Test Complete!");
        $display("========================================");
        
        #100;
        $finish;
    end
    
    // Timeout watchdog
    initial begin
        #10000;
        $display("ERROR: Simulation timeout!");
        $finish;
    end

endmodule