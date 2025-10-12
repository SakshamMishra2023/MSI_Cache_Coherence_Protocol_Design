
`include "cache_params.vh"

module new_l2_cache #(
    parameter CACHE_SIZE   = `L2_CACHE_SIZE,
    parameter LINE_SIZE    = `L2_LINE_SIZE,
    parameter NUM_WAYS     = `L2_NUM_WAYS,
    parameter NUM_SETS     = `L2_NUM_SETS,
    parameter TAG_WIDTH    = `L2_TAG_WIDTH,
    parameter INDEX_WIDTH  = `L2_INDEX_WIDTH,
    parameter OFFSET_WIDTH = `L2_OFFSET_WIDTH
)(
    input  wire clk,
    input  wire rst_n,

    // From L1 (line-based)
    input  wire [31:0] l1_addr,
    input  wire [LINE_SIZE*8-1:0] l1_wdata,
    input  wire l1_rd,
    input  wire l1_wr,
    output reg [LINE_SIZE*8-1:0] l1_rdata,
    output reg l1_ready,

    // To Main Memory (line-based)
    output reg [31:0] mem_addr,
    output reg [LINE_SIZE*8-1:0] mem_wdata,
    output reg mem_rd,
    output reg mem_wr,
    input  wire [LINE_SIZE*8-1:0] mem_rdata,
    input  wire  mem_ready
);

    // ========= Saved request (critical) =========
    reg [31:0] saved_addr;
    reg [LINE_SIZE*8-1:0] saved_wdata;
    reg saved_is_rd, saved_is_wr;

    // Address fields from saved_addr
    wire [TAG_WIDTH-1:0]   addr_tag   = saved_addr[31:31-TAG_WIDTH+1];
    wire [INDEX_WIDTH-1:0] addr_index = saved_addr[INDEX_WIDTH+OFFSET_WIDTH-1:OFFSET_WIDTH];

    // ========= Arrays =========
    reg valid [0:NUM_WAYS-1][0:NUM_SETS-1];
    reg dirty [0:NUM_WAYS-1][0:NUM_SETS-1];
    reg [TAG_WIDTH-1:0] tag [0:NUM_WAYS-1][0:NUM_SETS-1];
    reg [LINE_SIZE*8-1:0] data [0:NUM_WAYS-1][0:NUM_SETS-1];
    reg [2:0] lru_counter [0:NUM_SETS-1][0:NUM_WAYS-1]; // 0=MRU..7=LRU

    // ========= Tag match =========
    reg cache_hit;
    reg [7:0] way_hit;
    reg [2:0] hit_way;
    integer w;
    always @(*) begin
        cache_hit = 1'b0;
        way_hit   = 8'b0;
        hit_way   = 3'd0;
        for (w = 0; w < NUM_WAYS; w = w + 1) begin
            if (valid[w][addr_index] && (tag[w][addr_index] == addr_tag)) begin
                cache_hit   = 1'b1;
                way_hit[w]  = 1'b1;
                hit_way     = w[2:0];
            end
        end
    end

    // ========= LRU select =========
    reg [2:0] lru_replace_way;
    integer lw;
    always @(*) begin
        lru_replace_way = 3'd0;
        for (lw = 1; lw < NUM_WAYS; lw = lw + 1)
            if (lru_counter[addr_index][lw] > lru_counter[addr_index][lru_replace_way])
                lru_replace_way = lw[2:0];
    end

    // ========= FSM =========
    localparam IDLE=3'd0, CHECK_HIT=3'd1, WRITEBACK=3'd2, ALLOCATE=3'd3, RESPOND=3'd4;
    reg [2:0] state, next_state;
    reg [2:0] replace_way;
    reg req_sent;              // mem request in-flight

    // LRU update pulse
    reg lru_update_en;
    reg [2:0] lru_update_way;

    // State reg
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= IDLE;
        else        state <= next_state;
    end

    // Next state
    always @(*) begin
        next_state = state;
    
        if (state == IDLE) begin
            if (l1_rd || l1_wr)
                next_state = CHECK_HIT;
            else
                next_state = IDLE;
    
        end else if (state == CHECK_HIT) begin
            if (cache_hit)
                next_state = RESPOND;
            else if (valid[lru_replace_way][addr_index] && dirty[lru_replace_way][addr_index])
                next_state = WRITEBACK;
            else
                next_state = ALLOCATE;
    
        end else if (state == WRITEBACK) begin
            if (mem_ready)
                next_state = ALLOCATE;
            else
                next_state = WRITEBACK;
    
        end else if (state == ALLOCATE) begin
            if (mem_ready)
                next_state = RESPOND;
            else
                next_state = ALLOCATE;
    
        end else if (state == RESPOND) begin
            next_state = IDLE;
    
        end else begin
            next_state = IDLE;
        end
    end


    // Body
    integer i,j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i=0;i<NUM_WAYS;i=i+1)
                for (j=0;j<NUM_SETS;j=j+1) begin
                    valid[i][j] <= 1'b0;
                    dirty[i][j] <= 1'b0;
                    tag[i][j]   <= {TAG_WIDTH{1'b0}};
                    data[i][j]  <= {LINE_SIZE*8{1'b0}};
                    lru_counter[j][i] <= i[2:0]; // 0..7
                end
            l1_ready <= 1'b0;
            l1_rdata <= {LINE_SIZE*8{1'b0}};
            mem_rd   <= 1'b0;
            mem_wr   <= 1'b0;
            mem_addr <= 32'b0;
            mem_wdata<= {LINE_SIZE*8{1'b0}};
            req_sent <= 1'b0;

            saved_addr   <= 32'b0;
            saved_wdata  <= {LINE_SIZE*8{1'b0}};
            saved_is_rd  <= 1'b0;
            saved_is_wr  <= 1'b0;

            lru_update_en <= 1'b0;
            lru_update_way<= 3'd0;
            replace_way   <= 3'd0;
        end
        else begin
            // defaults each cycle
            l1_ready      <= 1'b0;
            lru_update_en <= 1'b0;

            case (state)
                IDLE: begin
                    mem_rd   <= 1'b0;
                    mem_wr   <= 1'b0;
                    req_sent <= 1'b0;
                    // latch request only here
                    if (l1_rd || l1_wr) begin
                        saved_addr  <= l1_addr;
                        saved_wdata <= l1_wdata;
                        saved_is_rd <= l1_rd;
                        saved_is_wr <= l1_wr;
                    end
                end

                CHECK_HIT: begin
                    if (cache_hit) begin
                        // read hit: return whole line
                        if (saved_is_rd) begin
                            l1_rdata <= data[hit_way][addr_index];
                        end
                        // write hit: full-line write
                        if (saved_is_wr) begin
                            data[hit_way][addr_index]  <= saved_wdata;
                            dirty[hit_way][addr_index] <= 1'b1;
                        end
                        // LRU: mark hit_way as MRU
                        lru_update_en  <= 1'b1;
                        lru_update_way <= hit_way;
                    end
                    else begin
                        replace_way <= lru_replace_way;
                    end
                end

                WRITEBACK: begin
                    if (!req_sent) begin
                        mem_addr  <= {tag[replace_way][addr_index], addr_index, {OFFSET_WIDTH{1'b0}}};
                        mem_wdata <= data[replace_way][addr_index];
                        mem_wr    <= 1'b1;
                        req_sent  <= 1'b1;
                    end else if (mem_ready) begin
                        mem_wr    <= 1'b0;
                        req_sent  <= 1'b0;
                        // after successful WB, clear dirty
                        dirty[replace_way][addr_index] <= 1'b0;
                    end
                end

                ALLOCATE: begin
                    if (!req_sent) begin
                        mem_addr <= {addr_tag, addr_index, {OFFSET_WIDTH{1'b0}}};
                        mem_rd   <= 1'b1;
                        req_sent <= 1'b1;
                    end else if (mem_ready) begin
                        mem_rd   <= 1'b0;
                        req_sent <= 1'b0;
                        // install line
                        data[replace_way][addr_index]  <= saved_is_wr ? saved_wdata : mem_rdata;
                        tag[replace_way][addr_index]   <= addr_tag;
                        valid[replace_way][addr_index] <= 1'b1;
                        dirty[replace_way][addr_index] <= saved_is_wr; // write-allocate
                        // prepare read response
                        if (saved_is_rd) l1_rdata <= mem_rdata;
                        // LRU: mark installed way as MRU
                        lru_update_en  <= 1'b1;
                        lru_update_way <= replace_way;
                    end
                end

                RESPOND: begin
                    l1_ready <= 1'b1; // 1-cycle ack
                end
            endcase

            // ===== LRU counter update for one set =====
            if (lru_update_en) begin : LRU_UPD
                integer k;
                for (k=0; k<NUM_WAYS; k=k+1) begin
                    if (k == lru_update_way) begin
                        lru_counter[addr_index][k] <= 3'd0; // MRU
                    end else begin
                        if (lru_counter[addr_index][k] < 3'd7)
                            lru_counter[addr_index][k] <= lru_counter[addr_index][k] + 3'd1;
                    end
                end
            end
        end
    end
    
endmodule
