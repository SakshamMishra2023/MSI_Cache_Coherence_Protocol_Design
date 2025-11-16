// l1_cache_msi.v - L1 Cache with MSI Coherence Protocol
// Modified to include state output port for waveform viewing
// L1 Cache: 32KB, 4-way set associative, 64B lines, LRU replacement
// Write-back, write-allocate policy with MSI coherence

`include "cache_params.vh"

module l1_cache #(
    parameter CACHE_SIZE = `L1_CACHE_SIZE,
    parameter LINE_SIZE = `L1_LINE_SIZE,
    parameter NUM_WAYS = `L1_NUM_WAYS,
    parameter NUM_SETS = `L1_NUM_SETS,
    parameter TAG_WIDTH = `L1_TAG_WIDTH,
    parameter INDEX_WIDTH = `L1_INDEX_WIDTH,
    parameter OFFSET_WIDTH = `L1_OFFSET_WIDTH,
    parameter CACHE_ID = 0  // 0 or 1 for the two caches
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
    
    // Bus Interface - Shared between both L1 caches
    output reg bus_req,              // Request bus access
    input wire bus_grant,            // Bus granted to this cache
    output reg [2:0] bus_cmd,        // Bus command type
    output reg [31:0] bus_addr,      // Address on bus
    output reg [LINE_SIZE*8-1:0] bus_data_out,  // Data to bus
    input wire [LINE_SIZE*8-1:0] bus_data_in,   // Data from bus
    input wire bus_valid,            // Valid data/response on bus
    
    // Snoop Interface - Monitor other cache's bus transactions
    input wire snoop_valid,          // Snoop request valid
    input wire [2:0] snoop_cmd,      // Snooped command
    input wire [31:0] snoop_addr,    // Snooped address
    output reg snoop_hit,            // This cache has the line
    output reg [LINE_SIZE*8-1:0] snoop_data,  // Data for snoop response
    
    // L2 Interface
    output reg [31:0] l2_addr,
    output reg [LINE_SIZE*8-1:0] l2_wdata,
    output reg l2_rd,
    output reg l2_wr,
    input wire [LINE_SIZE*8-1:0] l2_rdata,
    input wire l2_ready,
    
    // State visibility outputs
    output reg [1:0] cpu_line_state,  // Coherence state of current CPU access line
    output reg [3:0] fsm_state        // Current FSM state for debugging
);

    // Bus Command Encoding
    localparam BUS_RD = 3'b001;      // Read (requesting Shared)
    localparam BUS_RDX = 3'b010;     // Read Exclusive (requesting Modified)
    localparam BUS_UPGR = 3'b011;    // Upgrade S->M
    localparam BUS_FLUSH = 3'b100;   // Flush dirty data
    localparam BUS_IDLE = 3'b000;    // No transaction

    // MSI Coherence States
    localparam COHERENCE_I = 2'b00;  // Invalid
    localparam COHERENCE_S = 2'b01;  // Shared
    localparam COHERENCE_M = 2'b10;  // Modified

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
    
    assign addr_tag    = saved_addr[31 : 32-TAG_WIDTH];
    assign addr_index  = saved_addr[32-TAG_WIDTH-1 : 32-TAG_WIDTH-INDEX_WIDTH];
    assign addr_offset = saved_addr[OFFSET_WIDTH-1 : 0];
    assign word_offset = addr_offset[OFFSET_WIDTH-1 : 2];

    
    // Snoop Address Parsing
    wire [TAG_WIDTH-1:0] snoop_tag;
    wire [INDEX_WIDTH-1:0] snoop_index;
    assign snoop_tag   = snoop_addr[31 : 32-TAG_WIDTH];
    assign snoop_index = snoop_addr[32-TAG_WIDTH-1 : 32-TAG_WIDTH-INDEX_WIDTH];

    
    // Cache Storage Arrays
    reg valid [0:NUM_WAYS-1][0:NUM_SETS-1];
    reg [1:0] coherence_state [0:NUM_WAYS-1][0:NUM_SETS-1];  // MSI state
    reg [TAG_WIDTH-1:0] tag [0:NUM_WAYS-1][0:NUM_SETS-1];
    reg [LINE_SIZE*8-1:0] data [0:NUM_WAYS-1][0:NUM_SETS-1];
    
    // LRU Tracking - Per-Set Counters
    reg [1:0] lru_counter [0:NUM_SETS-1][0:NUM_WAYS-1];
    
    // Find LRU way for current set
    reg [1:0] lru_replace_way;
    integer lru_i;
    always @(*) begin
        lru_replace_way = 2'd0;
        for (lru_i = 1; lru_i < NUM_WAYS; lru_i = lru_i + 1) begin
            if (lru_counter[addr_index][lru_i] > lru_counter[addr_index][lru_replace_way]) begin
                lru_replace_way = lru_i[1:0];
            end
        end
    end
    
    // Update LRU counters on access
    reg [NUM_WAYS-1:0] lru_access_way;
    reg lru_access_valid;
    integer lru_j;
    integer s, w;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (s = 0; s < NUM_SETS; s = s + 1) begin
                for (w = 0; w < NUM_WAYS; w = w + 1) begin
                    lru_counter[s][w] <= w[1:0];
                end
            end
        end else if (lru_access_valid) begin
            case (lru_access_way)
                4'b0001: begin
                    lru_counter[addr_index][0] <= 2'd0;
                    for (lru_j = 1; lru_j < NUM_WAYS; lru_j = lru_j + 1) begin
                        if (lru_counter[addr_index][lru_j] < 2'd3) 
                            lru_counter[addr_index][lru_j] <= lru_counter[addr_index][lru_j] + 1;
                    end
                end
                4'b0010: begin
                    lru_counter[addr_index][1] <= 2'd0;
                    if (lru_counter[addr_index][0] < 2'd3) 
                        lru_counter[addr_index][0] <= lru_counter[addr_index][0] + 1;
                    if (lru_counter[addr_index][2] < 2'd3) 
                        lru_counter[addr_index][2] <= lru_counter[addr_index][2] + 1;
                    if (lru_counter[addr_index][3] < 2'd3) 
                        lru_counter[addr_index][3] <= lru_counter[addr_index][3] + 1;
                end
                4'b0100: begin
                    lru_counter[addr_index][2] <= 2'd0;
                    if (lru_counter[addr_index][0] < 2'd3) 
                        lru_counter[addr_index][0] <= lru_counter[addr_index][0] + 1;
                    if (lru_counter[addr_index][1] < 2'd3) 
                        lru_counter[addr_index][1] <= lru_counter[addr_index][1] + 1;
                    if (lru_counter[addr_index][3] < 2'd3) 
                        lru_counter[addr_index][3] <= lru_counter[addr_index][3] + 1;
                end
                4'b1000: begin
                    lru_counter[addr_index][3] <= 2'd0;
                    if (lru_counter[addr_index][0] < 2'd3) 
                        lru_counter[addr_index][0] <= lru_counter[addr_index][0] + 1;
                    if (lru_counter[addr_index][1] < 2'd3) 
                        lru_counter[addr_index][1] <= lru_counter[addr_index][1] + 1;
                    if (lru_counter[addr_index][2] < 2'd3) 
                        lru_counter[addr_index][2] <= lru_counter[addr_index][2] + 1;
                end
            endcase
        end
    end
    
    // Hit/Miss Detection
    reg [NUM_WAYS-1:0] way_hit;
    reg cache_hit;
    reg [1:0] hit_way;
    reg [1:0] hit_coherence_state;
    
    always @(*) begin
        way_hit = 4'b0000;
        cache_hit = 1'b0;
        hit_way = 2'd0;
        hit_coherence_state = COHERENCE_I;
        
        for (w = 0; w < NUM_WAYS; w = w + 1) begin
            if (valid[w][addr_index] && (tag[w][addr_index] == addr_tag)) begin
                way_hit[w] = 1'b1;
                cache_hit = 1'b1;
                hit_way = w[1:0];
                hit_coherence_state = coherence_state[w][addr_index];
            end
        end
    end
    
    // Snoop Hit Detection
    reg [NUM_WAYS-1:0] snoop_way_hit;
    reg snoop_cache_hit;
    reg [1:0] snoop_hit_way;
    reg [1:0] snoop_hit_state;
    
    always @(*) begin
        snoop_way_hit = 4'b0000;
        snoop_cache_hit = 1'b0;
        snoop_hit_way = 2'd0;
        snoop_hit_state = COHERENCE_I;
        
        for (w = 0; w < NUM_WAYS; w = w + 1) begin
            if (valid[w][snoop_index] && (tag[w][snoop_index] == snoop_tag)) begin
                snoop_way_hit[w] = 1'b1;
                snoop_cache_hit = 1'b1;
                snoop_hit_way = w[1:0];
                snoop_hit_state = coherence_state[w][snoop_index];
            end
        end
    end
    
    // Cache Controller FSM with MSI Buffer States
    localparam STATE_IDLE           = 4'd0;
    localparam STATE_CAPTURE        = 4'd1;
    localparam STATE_CHECK_HIT      = 4'd2;
    
    // Buffer states for coherence transitions
    localparam STATE_BUF_M_TO_S     = 4'd3;  // M->S buffer (flush to bus)
    localparam STATE_BUF_M_TO_I     = 4'd4;  // M->I buffer (flush and invalidate)
    localparam STATE_BUF_S_TO_M     = 4'd5;  // S->M buffer (upgrade)
    localparam STATE_BUF_S_TO_I     = 4'd6;  // S->I buffer (invalidate)
    localparam STATE_BUF_I_TO_S     = 4'd7;  // I->S buffer (fetch shared)
    localparam STATE_BUF_I_TO_M     = 4'd8;  // I->M buffer (fetch exclusive)
    
    localparam STATE_WRITEBACK      = 4'd9;
    localparam STATE_ALLOCATE       = 4'd10;
    localparam STATE_RESPOND        = 4'd11;
    
    reg [3:0] state, next_state;
    reg [1:0] replace_way;
    reg [LINE_SIZE*8-1:0] temp_line;
    reg l2_req_sent;
    reg bus_transaction_done;
    
    // State register - also update fsm_state output
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
            fsm_state <= STATE_IDLE;
        end else begin
            state <= next_state;
            fsm_state <= next_state;  // Mirror state to output port
        end
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
                    // Hit - check coherence state and required action
                    
                    if (saved_is_read) begin
                        // Read: Valid in S or M is OK
                        if (hit_coherence_state == COHERENCE_S || hit_coherence_state == COHERENCE_M)
                            next_state = STATE_RESPOND;
                        else
                            next_state = STATE_BUF_I_TO_S; // Invalid, need to fetch
                    end else if (saved_is_write) begin
                        // Write: Need Modified state
                        if (hit_coherence_state == COHERENCE_M)
                            next_state = STATE_RESPOND;
                        else if (hit_coherence_state == COHERENCE_S)
                            next_state = STATE_BUF_S_TO_M; // Upgrade needed
                        else
                            next_state = STATE_BUF_I_TO_M; // Invalid, need exclusive
                    end
                end else begin
                    // Cache miss - check if need writeback
                    
                    if (saved_is_write) begin
                        // WRITE MISS must ALWAYS do BUS_RDX
                        if (valid[lru_replace_way][addr_index] &&
                            coherence_state[lru_replace_way][addr_index] == COHERENCE_M)
                            next_state = STATE_WRITEBACK;
                        else
                            next_state = STATE_BUF_I_TO_M;
                    end else begin
                        // READ MISS - use BUS_RD to fetch in Shared state
                        if (valid[lru_replace_way][addr_index] &&
                            coherence_state[lru_replace_way][addr_index] == COHERENCE_M)
                            next_state = STATE_WRITEBACK;
                        else
                            next_state = STATE_BUF_I_TO_S;
                    end
                end
            end
            
            // Buffer state transitions
            STATE_BUF_S_TO_M: begin
                if (bus_transaction_done)
                    next_state = STATE_RESPOND;
            end
            
            STATE_BUF_I_TO_S: begin
                if (bus_transaction_done)
                    next_state = STATE_RESPOND;
            end
            
            STATE_BUF_I_TO_M: begin
                if (bus_transaction_done)
                    next_state = STATE_RESPOND;
            end
            
            STATE_BUF_M_TO_S: begin
                if (bus_transaction_done)
                    next_state = STATE_RESPOND;
            end
            
            STATE_BUF_M_TO_I: begin
                if (bus_transaction_done)
                    next_state = STATE_ALLOCATE;
            end
            
            STATE_WRITEBACK: begin
                if (l2_req_sent && l2_ready)
                    next_state = (saved_is_read ? STATE_BUF_I_TO_S : STATE_BUF_I_TO_M);
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
    
    // Snoop Logic - Runs in parallel with main FSM
    integer snoop_w;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            snoop_hit <= 1'b0;
            snoop_data <= {LINE_SIZE*8{1'b0}};
        end else begin
            snoop_hit <= 1'b0;
            snoop_data <= {LINE_SIZE*8{1'b0}};
            
            if (snoop_valid && snoop_cache_hit) begin
                snoop_hit <= 1'b1;
                
                case (snoop_cmd)
                    BUS_RD: begin
                        // Other cache reading - provide data if Modified
                        if (snoop_hit_state == COHERENCE_M) begin
                            snoop_data <= data[snoop_hit_way][snoop_index];
                            // Transition M->S
                            coherence_state[snoop_hit_way][snoop_index] <= COHERENCE_S;
                            $display("[L1-%0d %0t] SNOOP: M->S transition on BUS_RD, providing data", 
                                     CACHE_ID, $time);
                        end else if (snoop_hit_state == COHERENCE_S) begin
                            // Already shared, stay shared
                            snoop_data <= data[snoop_hit_way][snoop_index];
                        end
                    end
                    
                    BUS_RDX: begin
                        // Other cache wants exclusive - invalidate our copy
                        if (snoop_hit_state == COHERENCE_M) begin
                            snoop_data <= data[snoop_hit_way][snoop_index];
                            $display("[L1-%0d %0t] SNOOP: M->I transition on BUS_RDX, providing data", 
                                     CACHE_ID, $time);
                        end
                        coherence_state[snoop_hit_way][snoop_index] <= COHERENCE_I;
                        valid[snoop_hit_way][snoop_index] <= 1'b0;
                    end
                    
                    BUS_UPGR: begin
                        // Other cache upgrading S->M - invalidate our copy
                        coherence_state[snoop_hit_way][snoop_index] <= COHERENCE_I;
                        valid[snoop_hit_way][snoop_index] <= 1'b0;
                        $display("[L1-%0d %0t] SNOOP: S->I transition on BUS_UPGR", 
                                 CACHE_ID, $time);
                    end
                endcase
            end
        end
    end
    
    // Main FSM Output Logic & Cache Operations
    integer i, j, b;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset all cache lines
            cpu_line_state <= COHERENCE_I;

            for (i = 0; i < NUM_WAYS; i = i + 1) begin
                for (j = 0; j < NUM_SETS; j = j + 1) begin
                    valid[i][j] <= 1'b0;
                    coherence_state[i][j] <= COHERENCE_I;
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
            
            // Bus interface
            bus_req <= 1'b0;
            bus_cmd <= BUS_IDLE;
            bus_addr <= 32'b0;
            bus_data_out <= {LINE_SIZE*8{1'b0}};
            bus_transaction_done <= 1'b0;
            
        end else begin
            // Default values
            cpu_ready <= 1'b0;
            lru_access_valid <= 1'b0;
            bus_transaction_done <= 1'b0;
            
            case (state)
                STATE_IDLE: begin
                    l2_rd <= 1'b0;
                    l2_wr <= 1'b0;
                    l2_req_sent <= 1'b0;
                    bus_req <= 1'b0;
                    bus_cmd <= BUS_IDLE;
                    
                    if (cpu_rd || cpu_wr) begin
                        saved_addr <= cpu_addr;
                        saved_wdata <= cpu_wdata;
                        saved_byte_en <= cpu_byte_en;
                        saved_is_write <= cpu_wr;
                        saved_is_read <= cpu_rd;
                    end
                end
                
                STATE_CAPTURE: begin
                    // Request already captured
                end
                
                STATE_CHECK_HIT: begin
                    cpu_line_state <= hit_coherence_state;
                    if (cache_hit) begin
                        if (saved_is_read && (hit_coherence_state == COHERENCE_S || hit_coherence_state == COHERENCE_M)) begin
                            
                            // Read hit in S or M
                            lru_access_valid <= 1'b1;
                            lru_access_way <= way_hit;
                            cpu_rdata <= data[hit_way][addr_index][word_offset*32 +: 32];
                        end else if (saved_is_write && hit_coherence_state == COHERENCE_M) begin
                            
                            // Write hit in M
                            lru_access_valid <= 1'b1;
                            lru_access_way <= way_hit;
                            temp_line = data[hit_way][addr_index];
                            for (b = 0; b < 4; b = b + 1) begin
                                if (saved_byte_en[b]) begin
                                    temp_line[(word_offset*32) + (b*8) +: 8] = saved_wdata[b*8 +: 8];
                                end
                            end
                            data[hit_way][addr_index] <= temp_line;
                        end
                    end else begin
                        replace_way <= lru_replace_way;
                        l2_req_sent <= 1'b0;
                    end
                end
                
                // S->M Transition Buffer State
                STATE_BUF_S_TO_M: begin
                    cpu_line_state <= COHERENCE_S;  // Still in S until upgrade completes
                    if (!bus_req) begin
                        // Request bus for upgrade
                        bus_req <= 1'b1;
                        bus_cmd <= BUS_UPGR;
                        bus_addr <= saved_addr;
                    end else if (bus_grant) begin
                        // Bus granted, wait for acknowledgment
                        if (bus_valid) begin
                            // Upgrade complete, transition to M
                            coherence_state[hit_way][addr_index] <= COHERENCE_M;
                            cpu_line_state <= COHERENCE_M;
                            
                            // Perform the write
                            temp_line = data[hit_way][addr_index];
                            for (b = 0; b < 4; b = b + 1) begin
                                if (saved_byte_en[b]) begin
                                    temp_line[(word_offset*32) + (b*8) +: 8] = saved_wdata[b*8 +: 8];
                                end
                            end
                            data[hit_way][addr_index] <= temp_line;
                            
                            bus_req <= 1'b0;
                            bus_cmd <= BUS_IDLE;
                            bus_transaction_done <= 1'b1;
                        end
                    end
                end
                
                // I->S Transition Buffer State (READ MISS)
                STATE_BUF_I_TO_S: begin
                    cpu_line_state <= COHERENCE_I;  // Still invalid until data arrives
                    if (!bus_req) begin
                        bus_req <= 1'b1;
                        bus_cmd <= BUS_RD;
                        bus_addr <= saved_addr;
                        $display("[L1-%0d %0t] BUS_RD request for addr=0x%h", CACHE_ID, $time, saved_addr);
                    end else if (bus_grant && bus_valid) begin
                        // Data received from bus (could be from L2 or snoop response)
                        // Install in the selected way (for miss: use replace_way, for hit in I: use hit_way)
                        if (cache_hit) begin
                            // Had a hit but was Invalid - use hit_way
                            data[hit_way][addr_index] <= bus_data_in;
                            coherence_state[hit_way][addr_index] <= COHERENCE_S;
                            cpu_line_state <= COHERENCE_S;
                            valid[hit_way][addr_index] <= 1'b1;
                            tag[hit_way][addr_index] <= addr_tag;
                            cpu_rdata <= bus_data_in[word_offset*32 +: 32];
                            lru_access_valid <= 1'b1;
                            lru_access_way <= way_hit;
                            $display("[L1-%0d %0t] BUS_RD complete: installed in way=%0d (hit), data=0x%h", 
                                     CACHE_ID, $time, hit_way, bus_data_in[31:0]);
                        end else begin
                            // True miss - use replace_way
                            data[replace_way][addr_index] <= bus_data_in;
                            coherence_state[replace_way][addr_index] <= COHERENCE_S;
                            cpu_line_state <= COHERENCE_S;
                            valid[replace_way][addr_index] <= 1'b1;
                            tag[replace_way][addr_index] <= addr_tag;
                            cpu_rdata <= bus_data_in[word_offset*32 +: 32];
                            lru_access_valid <= 1'b1;
                            lru_access_way <= (4'b0001 << replace_way);
                            $display("[L1-%0d %0t] BUS_RD complete: installed in way=%0d (miss), data=0x%h", 
                                     CACHE_ID, $time, replace_way, bus_data_in[31:0]);
                        end
                        
                        bus_req <= 1'b0;
                        bus_cmd <= BUS_IDLE;
                        bus_transaction_done <= 1'b1;
                    end
                end
                
                // I->M Transition Buffer State (WRITE MISS)
                STATE_BUF_I_TO_M: begin
                    cpu_line_state <= COHERENCE_I;  // Still invalid until data arrives
                    if (!bus_req) begin
                        bus_req <= 1'b1;
                        bus_cmd <= BUS_RDX;
                        bus_addr <= saved_addr;
                        $display("[L1-%0d %0t] BUS_RDX request for addr=0x%h", CACHE_ID, $time, saved_addr);
                    end else if (bus_grant && bus_valid) begin
                        // Data received, install in Modified state with write
                        temp_line = bus_data_in;
                        for (b = 0; b < 4; b = b + 1) begin
                            if (saved_byte_en[b]) begin
                                temp_line[(word_offset*32) + (b*8) +: 8] = saved_wdata[b*8 +: 8];
                            end
                        end
                        
                        if (cache_hit) begin
                            data[hit_way][addr_index] <= temp_line;
                            coherence_state[hit_way][addr_index] <= COHERENCE_M;
                            cpu_line_state <= COHERENCE_M;
                            valid[hit_way][addr_index] <= 1'b1;
                            tag[hit_way][addr_index] <= addr_tag;
                            lru_access_valid <= 1'b1;
                            lru_access_way <= way_hit;
                            $display("[L1-%0d %0t] BUS_RDX complete: installed in way=%0d (hit)", 
                                     CACHE_ID, $time, hit_way);
                        end else begin
                            data[replace_way][addr_index] <= temp_line;
                            coherence_state[replace_way][addr_index] <= COHERENCE_M;
                            cpu_line_state <= COHERENCE_M;
                            valid[replace_way][addr_index] <= 1'b1;
                            tag[replace_way][addr_index] <= addr_tag;
                            lru_access_valid <= 1'b1;
                            lru_access_way <= (4'b0001 << replace_way);
                            $display("[L1-%0d %0t] BUS_RDX complete: installed in way=%0d (miss)", 
                                     CACHE_ID, $time, replace_way);
                        end
                        
                        bus_req <= 1'b0;
                        bus_cmd <= BUS_IDLE;
                        bus_transaction_done <= 1'b1;
                        end
                end
                
                STATE_WRITEBACK: begin
                    if (!l2_req_sent) begin
                        l2_addr <= {tag[replace_way][addr_index], addr_index, {OFFSET_WIDTH{1'b0}}};
                        l2_wdata <= data[replace_way][addr_index];
                        l2_wr <= 1'b1;
                        l2_req_sent <= 1'b1;
                        $display("[L1-%0d %0t] Writeback to L2: addr=0x%h", 
                                 CACHE_ID, $time, {tag[replace_way][addr_index], addr_index, {OFFSET_WIDTH{1'b0}}});
                    end else begin
                        if (l2_ready) begin
                            l2_wr <= 1'b0;
                            l2_req_sent <= 1'b0;
                            // Invalidate the victim line
                            valid[replace_way][addr_index] <= 1'b0;
                            coherence_state[replace_way][addr_index] <= COHERENCE_I;
                        end
                    end
                end
                
                STATE_ALLOCATE: begin
                    if (!l2_req_sent) begin
                        l2_addr <= {addr_tag, addr_index, {OFFSET_WIDTH{1'b0}}};
                        l2_rd <= 1'b1;
                        l2_req_sent <= 1'b1;
                    end else begin
                        if (l2_ready) begin
                            l2_rd <= 1'b0;
                            
                            valid[replace_way][addr_index] <= 1'b1;
                            tag[replace_way][addr_index] <= addr_tag;
                            
                            if (saved_is_write) begin
                                temp_line = l2_rdata;
                                for (b = 0; b < 4; b = b + 1) begin
                                    if (saved_byte_en[b]) begin
                                        temp_line[(word_offset*32) + (b*8) +: 8] = saved_wdata[b*8 +: 8];
                                    end
                                end
                                data[replace_way][addr_index] <= temp_line;
                                coherence_state[replace_way][addr_index] <= COHERENCE_M;
                                cpu_line_state <= COHERENCE_M;
                            end else begin
                                data[replace_way][addr_index] <= l2_rdata;
                                coherence_state[replace_way][addr_index] <= COHERENCE_S;
                                cpu_line_state <= COHERENCE_S;
                            end
                            
                            lru_access_valid <= 1'b1;
                            lru_access_way <= (4'b0001 << replace_way);
                            
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
                    bus_req <= 1'b0;
                    bus_cmd <= BUS_IDLE;
                end
                
            endcase
        end
    end

endmodule
