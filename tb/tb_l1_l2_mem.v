`timescale 1ns / 1ps
`include "cache_params.vh"

module tb_l2_cache_simple;

    // ===== Clock & Reset =====
    reg clk;
    reg rst_n;

    // ===== L1 <-> L2 interface =====
    reg  [31:0] l1_addr;
    reg  [`L2_LINE_WIDTH-1:0] l1_wdata;
    reg  l1_rd;
    reg  l1_wr;
    wire [`L2_LINE_WIDTH-1:0] l1_rdata;
    wire l1_ready;

    // ===== L2 <-> Memory interface =====
    wire [31:0] mem_addr;
    wire [`L2_LINE_WIDTH-1:0] mem_wdata;
    wire mem_rd;
    wire mem_wr;
    reg  [`L2_LINE_WIDTH-1:0] mem_rdata;
    reg  mem_ready;

    // ===== Instantiate the L2 Cache =====
    new_l2_cache uut (  // use your fixed new_l2_cache.v
        .clk(clk),
        .rst_n(rst_n),
        .l1_addr(l1_addr),
        .l1_wdata(l1_wdata),
        .l1_rd(l1_rd),
        .l1_wr(l1_wr),
        .l1_rdata(l1_rdata),
        .l1_ready(l1_ready),
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
        forever #5 clk = ~clk;  // 10 ns clock period
    end

    // ===== Main Test Stimulus =====
    integer i;
    reg [31:0] base_addr;

    initial begin
        // Initialize
        rst_n      = 0;
        l1_rd      = 0;
        l1_wr      = 0;
        l1_addr    = 32'b0;
        l1_wdata   = {`L2_LINE_WIDTH{1'b0}};
        mem_ready  = 0;
        mem_rdata  = {`L2_LINE_WIDTH{1'b0}};

        // ===== Reset Phase =====
        #20;
        rst_n = 1;
        #20;

        $display("=== TEST 1: L1 READ MISS (FETCH FROM MEMORY) ===");
        @(posedge clk);
        l1_addr = 32'h0000_1000;
        l1_rd   = 1;
        @(posedge clk);
        l1_rd   = 0;

        repeat (10) @(posedge clk);

        mem_rdata = {8{64'hDEADBEEFCAFEBABE}};
        @(posedge clk);
        mem_ready = 1;
        @(posedge clk);
        mem_ready = 0;

        wait (l1_ready == 1);
        $display("[%0t] L2 responded to L1. Data = %h", $time, l1_rdata);
        repeat (5) @(posedge clk);

        $display("=== TEST 2: L1 READ HIT (NO MEMORY ACCESS) ===");
        @(posedge clk);
        l1_addr = 32'h0000_1000;
        l1_rd   = 1;
        @(posedge clk);
        l1_rd   = 0;

        wait (l1_ready == 1);
        $display("[%0t] L2 HIT confirmed. Data = %h", $time, l1_rdata);
        repeat (5) @(posedge clk);

        $display("=== TEST 3: L1 WRITE HIT (NO MEMORY ACCESS, DIRTY BIT SET) ===");
        @(posedge clk);
        l1_addr  = 32'h0000_1000;
        l1_wdata = {8{64'hCAFEBABECAFEBABE}};
        l1_wr    = 1;
        @(posedge clk);
        l1_wr    = 0;
        wait (l1_ready == 1);
        $display("[%0t] L2 WRITE HIT confirmed. No mem access expected.", $time);
        repeat (10) @(posedge clk);

        // =====================================================
        // TEST 4: LRU REPLACEMENT AND WRITEBACK OF DIRTY LINE
        // =====================================================
        $display("=== TEST 4: WRITE MISS WITH DIRTY VICTIM (LRU REPLACEMENT) ===");

        // Fill more lines in same index but different tags
        for (i = 0; i < 8; i = i + 1) begin
            @(posedge clk);
            l1_addr  = 32'h0000_1000 + (i << 12);  // different tags, same index pattern
            l1_wdata = {8{64'h1111_0000 + i}};
            l1_wr    = 1;
            @(posedge clk);
            l1_wr    = 0;

            // On miss, memory will need to respond
            if (i > 0) begin
                repeat (10) @(posedge clk);
                mem_rdata = {8{64'hAABBCCDD_0000_0000 + i}};
                mem_ready = 1;
                @(posedge clk);
                mem_ready = 0;
            end
            wait (l1_ready == 1);
            $display("[%0t] Line %0d written to cache (tag=%h).", $time, i, l1_addr[31:12]);
            repeat (3) @(posedge clk);
        end

        // Now access a 9th address mapping to same index (forces LRU eviction)
        @(posedge clk);
        l1_addr  = 32'h0000_9000;
        l1_wdata = {8{64'hFACEFACEFACEFACE}};
        l1_wr    = 1;
        @(posedge clk);
        l1_wr    = 0;

        // Memory should first see a WRITEBACK of dirty victim
        repeat (10) @(posedge clk);
        mem_ready = 1;
        @(posedge clk);
        mem_ready = 0;

        wait (l1_ready == 1);
        $display("[%0t] Replacement done, dirty victim written back, new line allocated.", $time);

        repeat (10) @(posedge clk);
        $display("=== SIMULATION COMPLETE ===");
        $finish;
    end

    // ===== Simple Trace Monitor =====
    always @(posedge clk) begin
        $display("%0t | mem_rd=%0b mem_wr=%0b mem_ready=%0b l1_ready=%0b state=%0d", 
                 $time, mem_rd, mem_wr, mem_ready, l1_ready, uut.state);
    end

endmodule
