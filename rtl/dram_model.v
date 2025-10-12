`timescale 1ns / 1ps
`include "cache_params.vh"

// DRAM Memory Model
// Simulates main memory with configurable latency
// Supports read and write operations with realistic timing

module dram #(
    parameter LINE_SIZE = `L2_LINE_SIZE,           // 64 bytes
    parameter LATENCY = 10,                         // Read/Write latency in cycles
    parameter DEPTH = 65536                         // Number of cache lines (4MB / 64B)
)(
    input wire clk,
    input wire rst_n,
    
    // Memory Interface
    input wire [31:0] mem_addr,
    input wire [LINE_SIZE*8-1:0] mem_wdata,
    input wire mem_rd,
    input wire mem_wr,
    output reg [LINE_SIZE*8-1:0] mem_rdata,
    output reg mem_ready
);

    // Memory storage array
    reg [LINE_SIZE*8-1:0] storage [0:DEPTH-1];
    
    // Address calculation (cache line aligned)
    wire [15:0] line_addr = mem_addr[21:6];  // Bits [21:6] for 64-byte aligned address
    
    // Latency counter
    reg [7:0] latency_counter;
    reg operation_active;
    reg is_read;
    reg [15:0] saved_addr;
    
    // Statistics
    integer total_reads;
    integer total_writes;
    integer total_read_cycles;
    integer total_write_cycles;
    
    integer i;
    
    // Initialize memory with test patterns
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) begin
            // Create a recognizable pattern based on address
            storage[i] = {8{64'hDEADBEEFCAFEBABE}} ^ {8{i[15:0], i[15:0], i[15:0], i[15:0]}};
        end
        $display("[DRAM] Initialized %0d cache lines (%0d KB) with test patterns", 
                 DEPTH, (DEPTH * LINE_SIZE) / 1024);
        
        total_reads = 0;
        total_writes = 0;
        total_read_cycles = 0;
        total_write_cycles = 0;
    end
    
    // Main DRAM logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_ready <= 1'b0;
            mem_rdata <= {LINE_SIZE*8{1'b0}};
            latency_counter <= 8'b0;
            operation_active <= 1'b0;
            is_read <= 1'b0;
            saved_addr <= 16'b0;
        end else begin
            mem_ready <= 1'b0;  // Default: not ready
            
            // Start new operation
            if ((mem_rd || mem_wr) && !operation_active) begin
                operation_active <= 1'b1;
                is_read <= mem_rd;
                saved_addr <= line_addr;
                latency_counter <= 8'b0;
                
                if (mem_rd) begin
                    $display("[DRAM %0t] Read request: addr=0x%h (line %0d)", 
                             $time, mem_addr, line_addr);
                end else begin
                    $display("[DRAM %0t] Write request: addr=0x%h (line %0d), data=0x%h", 
                             $time, mem_addr, line_addr, mem_wdata[63:0]);
                end
            end
            
            // Count down latency
            if (operation_active) begin
                if (latency_counter < LATENCY - 1) begin
                    latency_counter <= latency_counter + 1;
                end else begin
                    // Operation complete
                    mem_ready <= 1'b1;
                    operation_active <= 1'b0;
                    latency_counter <= 8'b0;
                    
                    if (is_read) begin
                        // Complete read operation
                        mem_rdata <= storage[saved_addr];
                        total_reads <= total_reads + 1;
                        total_read_cycles <= total_read_cycles + LATENCY;
                        $display("[DRAM %0t] Read complete: addr=0x%h, data=0x%h", 
                                 $time, {saved_addr, 6'b0}, storage[saved_addr][63:0]);
                    end else begin
                        // Complete write operation
                        storage[saved_addr] <= mem_wdata;
                        total_writes <= total_writes + 1;
                        total_write_cycles <= total_write_cycles + LATENCY;
                        $display("[DRAM %0t] Write complete: addr=0x%h", 
                                 $time, {saved_addr, 6'b0});
                    end
                end
            end
        end
    end
    
    // Display statistics at end of simulation
    final begin
        $display("\n[DRAM] Performance Statistics:");
        if (total_reads > 0)
            $display("  Total Reads:  %0d (avg latency: %0d cycles)", 
                     total_reads, total_read_cycles / total_reads);
        else
            $display("  Total Reads:  0 (avg latency: 0 cycles)");
            
        if (total_writes > 0)
            $display("  Total Writes: %0d (avg latency: %0d cycles)", 
                     total_writes, total_write_cycles / total_writes);
        else
            $display("  Total Writes: 0 (avg latency: 0 cycles)");
    end

endmodule