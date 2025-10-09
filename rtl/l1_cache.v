// l1_cache.v - FIXED VERSION
// L1 Cache: 32KB, 4-way set associative, 64B lines, LRU replacement
// Write-back, write-allocate policy

`include "cache_params.vh"

module l1_cache #(
    parameter CACHE_SIZE = `L1_CACHE_SIZE,
    parameter LINE_SIZE = `L1_LINE_SIZE,
    parameter NUM_WAYS = `L1_NUM_WAYS,
    parameter NUM_SETS = `L1_NUM_SETS,
    parameter TAG_WIDTH = `L1_TAG_WIDTH,
    parameter INDEX_WIDTH = `L1_INDEX_WIDTH,
    parameter OFFSET_WIDTH = `L1_OFFSET_WIDTH
)(
    input wire clk,
    input wire rst_n,
    
    // CPU Interface
    input wire [31:0] cpu_addr,
    input wire [31:0] cpu_wdata,
    input wire [3:0] cpu_byte_en,
    input wire cpu_rd,
    input wire cpu_wr,
    output reg [31:0] cpu_rdata,
    output reg cpu_ready,
    
    // L2 Interface
    output reg [31:0] l2_addr,
    output reg [LINE_SIZE*8-1:0] l2_wdata,
    output reg l2_rd,
    output reg l2_wr,
    input wire [LINE_SIZE*8-1:0] l2_rdata,
    input wire l2_ready
);

    // Saved request parameters
    reg [31:0] saved_addr;
    reg [31:0] saved_wdata;
    reg [3:0] saved_byte_en;
    reg saved_is_write;
    reg saved_is_read;

    // Address Parsing (using saved address)
    wire [TAG_WIDTH-1:0] addr_tag;
    wire [INDEX_WIDTH-1:0] addr_index;
    wire [OFFSET_WIDTH-1:0] addr_offset;
    wire [OFFSET_WIDTH-3:0] word_offset;
    
    assign addr_tag = saved_addr[31:31-TAG_WIDTH+1];
    assign addr_index = saved_addr[INDEX_WIDTH+OFFSET_WIDTH-1:OFFSET_WIDTH];
    assign addr_offset = saved_addr[OFFSET_WIDTH-1:0];
    assign word_offset = addr_offset[OFFSET_WIDTH-1:2];
    
    // Cache Storage Arrays
    reg valid [0:NUM_WAYS-1][0:NUM_SETS-1];
    reg dirty [0:NUM_WAYS-1][0:NUM_SETS-1];
    reg [TAG_WIDTH-1:0] tag [0:NUM_WAYS-1][0:NUM_SETS-1];
    reg [LINE_SIZE*8-1:0] data [0:NUM_WAYS-1][0:NUM_SETS-1];
    
    // LRU Tracking
    reg [1:0] lru_way [0:NUM_SETS-1];
    reg [NUM_WAYS-1:0] lru_access_way;
    reg lru_access_valid;
    wire [1:0] lru_replace_way;
    
    lru_controller lru_ctrl (
        .clk(clk),
        .rst_n(rst_n),
        .access_valid(lru_access_valid),
        .access_way(lru_access_way),
        .lru_way(lru_replace_way)
    );
    
    // Store LRU info per set
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            integer s;
            for (s = 0; s < NUM_SETS; s = s + 1) begin
                lru_way[s] <= 2'd0;
            end
        end else if (lru_access_valid) begin
            lru_way[addr_index] <= lru_replace_way;
        end
    end
    
    // Hit/Miss Detection
    reg [NUM_WAYS-1:0] way_hit;
    reg cache_hit;
    reg [1:0] hit_way;
    
    integer w;
    always @(*) begin
        way_hit = 4'b0000;
        cache_hit = 1'b0;
        hit_way = 2'd0;
        
        for (w = 0; w < NUM_WAYS; w = w + 1) begin
            if (valid[w][addr_index] && (tag[w][addr_index] == addr_tag)) begin
                way_hit[w] = 1'b1;
                cache_hit = 1'b1;
                hit_way = w[1:0];
            end
        end
    end
    
    // Cache Controller FSM
    localparam STATE_IDLE        = 3'd0;
    localparam STATE_CAPTURE     = 3'd1;
    localparam STATE_CHECK_HIT   = 3'd2;
    localparam STATE_WRITEBACK   = 3'd3;
    localparam STATE_ALLOCATE    = 3'd4;
    localparam STATE_RESPOND     = 3'd5;
    
    reg [2:0] state, next_state;
    reg [1:0] replace_way;
    reg [LINE_SIZE*8-1:0] temp_line;
    reg l2_req_sent;
    
    // State register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= STATE_IDLE;
        else
            state <= next_state;
    end
    
    // Next state logic
    always @(*) begin
        next_state = state;
        
        case (state)
            STATE_IDLE: begin
                if (cpu_rd || cpu_wr)
                    next_state = STATE_CAPTURE;
            end
            
            STATE_CAPTURE: begin
                next_state = STATE_CHECK_HIT;
            end
            
            STATE_CHECK_HIT: begin
                if (cache_hit) begin
                    next_state = STATE_RESPOND;
                end else begin
                    // Cache miss - check if need writeback
                    if (valid[lru_way[addr_index]][addr_index] && 
                        dirty[lru_way[addr_index]][addr_index])
                        next_state = STATE_WRITEBACK;
                    else
                        next_state = STATE_ALLOCATE;
                end
            end
            
            STATE_WRITEBACK: begin
                if (l2_req_sent && l2_ready)
                    next_state = STATE_ALLOCATE;
            end
            
            STATE_ALLOCATE: begin
                if (l2_req_sent && l2_ready)
                    next_state = STATE_RESPOND;
            end
            
            STATE_RESPOND: begin
                next_state = STATE_IDLE;
            end
            
            default: next_state = STATE_IDLE;
        endcase
    end
    
    // Output Logic & Cache Operations
    integer i, j, b;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset all cache lines
            for (i = 0; i < NUM_WAYS; i = i + 1) begin
                for (j = 0; j < NUM_SETS; j = j + 1) begin
                    valid[i][j] <= 1'b0;
                    dirty[i][j] <= 1'b0;
                    tag[i][j] <= {TAG_WIDTH{1'b0}};
                    data[i][j] <= {LINE_SIZE*8{1'b0}};
                end
            end
            
            cpu_rdata <= 32'b0;
            cpu_ready <= 1'b0;
            l2_addr <= 32'b0;
            l2_wdata <= {LINE_SIZE*8{1'b0}};
            l2_rd <= 1'b0;
            l2_wr <= 1'b0;
            lru_access_valid <= 1'b0;
            lru_access_way <= 4'b0000;
            replace_way <= 2'd0;
            temp_line <= {LINE_SIZE*8{1'b0}};
            saved_addr <= 32'b0;
            saved_wdata <= 32'b0;
            saved_byte_en <= 4'b0;
            saved_is_write <= 1'b0;
            saved_is_read <= 1'b0;
            l2_req_sent <= 1'b0;
            
        end else begin
            // Default values
            cpu_ready <= 1'b0;
            lru_access_valid <= 1'b0;
            
            case (state)
                STATE_IDLE: begin
                    l2_rd <= 1'b0;
                    l2_wr <= 1'b0;
                    l2_req_sent <= 1'b0;
                    
                    // Capture request in IDLE when it arrives
                    if (cpu_rd || cpu_wr) begin
                        saved_addr <= cpu_addr;
                        saved_wdata <= cpu_wdata;
                        saved_byte_en <= cpu_byte_en;
                        saved_is_write <= cpu_wr;
                        saved_is_read <= cpu_rd;
                    end
                end
                
                STATE_CAPTURE: begin
                    // Request already captured, just transition
                end
                
                STATE_CHECK_HIT: begin
                    if (cache_hit) begin
                        // Hit - update LRU
                        lru_access_valid <= 1'b1;
                        lru_access_way <= way_hit;
                        
                        // Read hit - return data
                        if (saved_is_read) begin
                            cpu_rdata <= data[hit_way][addr_index][word_offset*32 +: 32];
                        end
                        
                        // Write hit - update data and mark dirty
                        if (saved_is_write) begin
                            // Read-modify-write using temp variable
                            temp_line = data[hit_way][addr_index];
                            for (b = 0; b < 4; b = b + 1) begin
                                if (saved_byte_en[b]) begin
                                    temp_line[(word_offset*32) + (b*8) +: 8] = saved_wdata[b*8 +: 8];
                                end
                            end
                            data[hit_way][addr_index] <= temp_line;
                            dirty[hit_way][addr_index] <= 1'b1;
                        end
                    end else begin
                        // Miss - prepare for replacement
                        replace_way <= lru_way[addr_index];
                        l2_req_sent <= 1'b0;
                    end
                end
                
                STATE_WRITEBACK: begin
                    if (!l2_req_sent) begin
                        // Issue writeback request
                        l2_addr <= {tag[replace_way][addr_index], addr_index, {OFFSET_WIDTH{1'b0}}};
                        l2_wdata <= data[replace_way][addr_index];
                        l2_wr <= 1'b1;
                        l2_req_sent <= 1'b1;
                    end else begin
                        // Keep request active until acknowledged
                        if (l2_ready) begin
                            l2_wr <= 1'b0;
                        end
                    end
                end
                
                STATE_ALLOCATE: begin
                    if (!l2_req_sent) begin
                        // Issue read request
                        l2_addr <= {addr_tag, addr_index, {OFFSET_WIDTH{1'b0}}};
                        l2_rd <= 1'b1;
                        l2_req_sent <= 1'b1;
                    end else begin
                        // Keep request active until data arrives
                        if (l2_ready) begin
                            l2_rd <= 1'b0;
                            
                            // Install new line
                            valid[replace_way][addr_index] <= 1'b1;
                            tag[replace_way][addr_index] <= addr_tag;
                            
                            // Handle write-allocate
                            if (saved_is_write) begin
                                temp_line = l2_rdata;
                                for (b = 0; b < 4; b = b + 1) begin
                                    if (saved_byte_en[b]) begin
                                        temp_line[(word_offset*32) + (b*8) +: 8] = saved_wdata[b*8 +: 8];
                                    end
                                end
                                data[replace_way][addr_index] <= temp_line;
                                dirty[replace_way][addr_index] <= 1'b1;
                            end else begin
                                data[replace_way][addr_index] <= l2_rdata;
                                dirty[replace_way][addr_index] <= 1'b0;
                            end
                            
                            // Update LRU
                            lru_access_valid <= 1'b1;
                            lru_access_way <= (4'b0001 << replace_way);
                            
                            // Return data for read
                            if (saved_is_read) begin
                                cpu_rdata <= l2_rdata[word_offset*32 +: 32];
                            end
                        end
                    end
                end
                
                STATE_RESPOND: begin
                    cpu_ready <= 1'b1;
                    l2_rd <= 1'b0;
                    l2_wr <= 1'b0;
                end
                
            endcase
        end
    end

endmodule