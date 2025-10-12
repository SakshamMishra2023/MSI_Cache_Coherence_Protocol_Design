//debugging from claude and code snippets from https://github.com/midn8hustlr/MSI_cache_coherence/tree/master/RTL

`include "cache_params.vh"

module l1_cache #(
    parameter CACHE_SIZE   = `L1_CACHE_SIZE,
    parameter LINE_SIZE    = `L1_LINE_SIZE,
    parameter NUM_WAYS     = `L1_NUM_WAYS,
    parameter NUM_SETS     = `L1_NUM_SETS,
    parameter TAG_WIDTH    = `L1_TAG_WIDTH,
    parameter INDEX_WIDTH  = `L1_INDEX_WIDTH,
    parameter OFFSET_WIDTH = `L1_OFFSET_WIDTH
)(
    input  wire clk,
    input  wire rst_n,

    // CPU Interface (word-based)
    input  wire [31:0] cpu_addr,
    input  wire [31:0] cpu_wdata,
    input  wire [3:0]  cpu_byte_en,
    input  wire cpu_rd,
    input  wire cpu_wr,
    output reg  [31:0] cpu_rdata,
    output reg  cpu_ready,

    // L2 Interface (line-based)
    output reg  [31:0] l2_addr,
    output reg  [LINE_SIZE*8-1:0] l2_wdata,
    output reg  l2_rd,
    output reg  l2_wr,
    input  wire [LINE_SIZE*8-1:0] l2_rdata,
    input  wire l2_ready
);

    //Address Decomposition
    wire [TAG_WIDTH-1:0]   cpu_tag    = cpu_addr[31:31-TAG_WIDTH+1];
    wire [INDEX_WIDTH-1:0] cpu_index  = cpu_addr[INDEX_WIDTH+OFFSET_WIDTH-1:OFFSET_WIDTH];
    wire [OFFSET_WIDTH-3-1:0] cpu_word_offset = cpu_addr[OFFSET_WIDTH-1:2];

    //Saved Request
    reg [31:0] saved_addr;
    reg [31:0] saved_wdata;
    reg [3:0]  saved_byte_en;
    reg saved_is_read;
    reg saved_is_write;

    wire [TAG_WIDTH-1:0]   addr_tag   = saved_addr[31:31-TAG_WIDTH+1];
    wire [INDEX_WIDTH-1:0] addr_index = saved_addr[INDEX_WIDTH+OFFSET_WIDTH-1:OFFSET_WIDTH];
    wire [OFFSET_WIDTH-3-1:0] word_offset = saved_addr[OFFSET_WIDTH-1:2];

    //Cache Arrays
    reg valid [0:NUM_WAYS-1][0:NUM_SETS-1];
    reg dirty [0:NUM_WAYS-1][0:NUM_SETS-1];
    reg [TAG_WIDTH-1:0] tag [0:NUM_WAYS-1][0:NUM_SETS-1];
    reg [LINE_SIZE*8-1:0] data [0:NUM_WAYS-1][0:NUM_SETS-1];

    // LRU Tracking
    reg [1:0] lru_counter [0:NUM_SETS-1][0:NUM_WAYS-1];

    //Tag Comparison
    reg cache_hit;
    reg [NUM_WAYS-1:0] way_hit;
    reg [1:0] hit_way;
    integer w;
    
    always @(*) begin
        cache_hit = 1'b0;
        way_hit = 4'b0;
        hit_way = 2'd0;
        for (w = 0; w < NUM_WAYS; w = w + 1) begin
            if (valid[w][addr_index] && (tag[w][addr_index] == addr_tag)) begin
                cache_hit = 1'b1;
                way_hit[w] = 1'b1;
                hit_way = w[1:0];
            end
        end
    end

    //LRU Selection
    reg [1:0] lru_way;
    integer lw;
    
    always @(*) begin
        lru_way = 2'd0;
        for (lw = 1; lw < NUM_WAYS; lw = lw + 1) begin
            if (lru_counter[addr_index][lw] > lru_counter[addr_index][lru_way]) begin
                lru_way = lw[1:0];
            end
        end
    end

    //FSM States
    localparam IDLE         = 4'd0;
    localparam CHECK_HIT    = 4'd1;
    localparam WRITEBACK_L2 = 4'd2;  // NEW: Writeback victim to L2
    localparam ALLOCATE     = 4'd3;
    localparam WRITE_UPDATE = 4'd4;
    localparam RESPOND      = 4'd5;

    reg [3:0] state, next_state;
    reg [1:0] victim_way;
    reg victim_dirty;
    reg [TAG_WIDTH-1:0] victim_tag;
    reg [LINE_SIZE*8-1:0] victim_data;

    //State Register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= IDLE;
        else        state <= next_state;
    end

    //Next State Logic
    always @(*) begin
        next_state = state;
        
        case (state)
            IDLE: begin
                if (cpu_rd || cpu_wr)
                    next_state = CHECK_HIT;
            end

            CHECK_HIT: begin
                if (cache_hit) begin
                    if (saved_is_write)
                        next_state = WRITE_UPDATE;
                    else
                        next_state = RESPOND;
                end else begin
                    // Miss: check if victim needs writeback
                    if (valid[lru_way][addr_index] && dirty[lru_way][addr_index])
                        next_state = WRITEBACK_L2;  // Victim is dirty, write to L2 first
                    else
                        next_state = ALLOCATE;
                end
            end

            WRITEBACK_L2: begin
                if (l2_ready)
                    next_state = ALLOCATE;
            end

            ALLOCATE: begin
                if (l2_ready) begin
                    if (saved_is_write)
                        next_state = WRITE_UPDATE;
                    else
                        next_state = RESPOND;
                end
            end

            WRITE_UPDATE: begin
                next_state = RESPOND;
            end

            RESPOND: begin
                next_state = IDLE;
            end

            default: next_state = IDLE;
        endcase
    end

    // Datapath
    reg [LINE_SIZE*8-1:0] modified_line;
    reg req_sent;
    reg lru_update;
    reg [1:0] lru_update_way;

    integer i, j;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Initialize arrays
            for (i = 0; i < NUM_WAYS; i = i + 1) begin
                for (j = 0; j < NUM_SETS; j = j + 1) begin
                    valid[i][j] <= 1'b0;
                    dirty[i][j] <= 1'b0;
                    tag[i][j] <= {TAG_WIDTH{1'b0}};
                    data[i][j] <= {LINE_SIZE*8{1'b0}};
                    lru_counter[j][i] <= i[1:0];
                end
            end
            
            cpu_ready <= 1'b0;
            cpu_rdata <= 32'b0;
            l2_rd <= 1'b0;
            l2_wr <= 1'b0;
            l2_addr <= 32'b0;
            l2_wdata <= {LINE_SIZE*8{1'b0}};
            
            saved_addr <= 32'b0;
            saved_wdata <= 32'b0;
            saved_byte_en <= 4'b0;
            saved_is_read <= 1'b0;
            saved_is_write <= 1'b0;
            
            victim_way <= 2'd0;
            victim_dirty <= 1'b0;
            victim_tag <= {TAG_WIDTH{1'b0}};
            victim_data <= {LINE_SIZE*8{1'b0}};
            
            req_sent <= 1'b0;
            lru_update <= 1'b0;
            lru_update_way <= 2'd0;
            
        end else begin
            // Default outputs
            cpu_ready <= 1'b0;
            lru_update <= 1'b0;
            
            case (state)
                IDLE: begin
                    l2_rd <= 1'b0;
                    l2_wr <= 1'b0;
                    req_sent <= 1'b0;
                    
                    // Capture request
                    if (cpu_rd || cpu_wr) begin
                        saved_addr <= cpu_addr;
                        saved_wdata <= cpu_wdata;
                        saved_byte_en <= cpu_byte_en;
                        saved_is_read <= cpu_rd;
                        saved_is_write <= cpu_wr;
                    end
                end

                CHECK_HIT: begin
                    if (cache_hit) begin
                        // HIT: Read data for reads, prepare for write
                        if (saved_is_read) begin
                            cpu_rdata <= data[hit_way][addr_index][word_offset*32 +: 32];
                        end
                        
                        // Update LRU
                        lru_update <= 1'b1;
                        lru_update_way <= hit_way;
                        
                    end else begin
                        // MISS: Save victim info for potential writeback
                        victim_way <= lru_way;
                        victim_dirty <= dirty[lru_way][addr_index];
                        victim_tag <= tag[lru_way][addr_index];
                        victim_data <= data[lru_way][addr_index];
                    end
                end

                WRITEBACK_L2: begin
                    // Write dirty victim back to L2
                    if (!req_sent) begin
                        l2_addr <= {victim_tag, addr_index, {OFFSET_WIDTH{1'b0}}};
                        l2_wdata <= victim_data;
                        l2_wr <= 1'b1;
                        req_sent <= 1'b1;
                        
                        $display("[L1 %0t] Writeback dirty line to L2: addr=0x%h", 
                                 $time, {victim_tag, addr_index, {OFFSET_WIDTH{1'b0}}});
                    end else if (l2_ready) begin
                        l2_wr <= 1'b0;
                        req_sent <= 1'b0;
                        $display("[L1 %0t] Writeback to L2 complete", $time);
                    end
                end

                ALLOCATE: begin
                    // Fetch line from L2
                    if (!req_sent) begin
                        l2_addr <= {addr_tag, addr_index, {OFFSET_WIDTH{1'b0}}};
                        l2_rd <= 1'b1;
                        req_sent <= 1'b1;
                    end else if (l2_ready) begin
                        l2_rd <= 1'b0;
                        req_sent <= 1'b0;
                        
                        // Install new line
                        data[victim_way][addr_index] <= l2_rdata;
                        tag[victim_way][addr_index] <= addr_tag;
                        valid[victim_way][addr_index] <= 1'b1;
                        dirty[victim_way][addr_index] <= 1'b0;  // Clean from L2
                        
                        // Read response
                        if (saved_is_read) begin
                            cpu_rdata <= l2_rdata[word_offset*32 +: 32];
                        end
                        
                        // Update LRU
                        lru_update <= 1'b1;
                        lru_update_way <= victim_way;
                    end
                end

                WRITE_UPDATE: begin
                    // Apply write to cache line
                    modified_line = data[cache_hit ? hit_way : victim_way][addr_index];
                    
                    // Byte-enable write
                    if (saved_byte_en[0]) modified_line[word_offset*32 +: 8]  = saved_wdata[7:0];
                    if (saved_byte_en[1]) modified_line[word_offset*32+8 +: 8] = saved_wdata[15:8];
                    if (saved_byte_en[2]) modified_line[word_offset*32+16 +: 8] = saved_wdata[23:16];
                    if (saved_byte_en[3]) modified_line[word_offset*32+24 +: 8] = saved_wdata[31:24];
                    
                    data[cache_hit ? hit_way : victim_way][addr_index] <= modified_line;
                    dirty[cache_hit ? hit_way : victim_way][addr_index] <= 1'b1;
                end

                RESPOND: begin
                    cpu_ready <= 1'b1;
                end
            endcase

            // LRU Update
            if (lru_update) begin : LRU_UPDATE_BLOCK
                integer k;
                for (k = 0; k < NUM_WAYS; k = k + 1) begin
                    if (k == lru_update_way) begin
                        lru_counter[addr_index][k] <= 2'd0;  // MRU
                    end else begin
                        if (lru_counter[addr_index][k] < 2'd3)
                            lru_counter[addr_index][k] <= lru_counter[addr_index][k] + 2'd1;
                    end
                end
            end
        end
    end

endmodule