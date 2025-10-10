`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/07/2025 10:31:44 PM
// Design Name: 
// Module Name: l2_cache_design
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module l2_cache_design(
    input wire clk,
    input wire rst,
    //L1 Interface
    input wire readEn,
    input wire writeEn,
    input wire [31:0] addr,
    input wire [31:0] write_data,
    output wire [31:0] read_data,
    output reg hit,
    output reg miss,
    
    output reg ready,         // goes HIGH when L2 has finished the current operation
    output reg mem_req,       // tells memory that L2 wants to read/fetch data
    input  wire mem_ready,    // indicates that memory has completed the request
    
    //memory interface
    output reg [31:0]mem_addr,
    input wire [31:0] mem_read_data
    );
    localparam OFFSET_BITS = 6;
    localparam INDEX_BITS = 9;
    localparam TAG_BITS = 17;
    localparam NUM_WAYS    = 4;
    localparam WORDS_PER_LINE = 16; // 64B / 4B
    
    reg [31:0] data_array[0:3][0:511][0:15];
    reg [16:0] tag_array  [0:3][0:511];   // 17-bit tags
    reg valid_bit [0:3][0:511];
    reg dirty_bit [0:3][0:511];

    //extracting the information into specifics from the given address
    wire [16:0] addr_tag    = addr[31:15];
    wire [8:0]  addr_index  = addr[14:6];
    wire [5:0]  addr_offset = addr[5:0];
    
    //FSM STATES encoding
    localparam S_IDLE   = 3'd0;
    localparam S_CHECK  = 3'd1;
    localparam S_HIT    = 3'd2;
    localparam S_MISS   = 3'd3;
    localparam S_RESP   = 3'd4;
    localparam S_MEMWAIT = 3'd5;
    // FSM states registers
    reg [2:0] state, next_state;
    
    
    //adding lru handling registers
    reg [1:0] lru_counter [0:3][0:511]; // 4 ways × 512 sets


    always @(posedge clk or posedge rst) begin
        if (rst)
            state <= S_IDLE;
        else
            state <= next_state;
    end

    
    
    integer i, j;
    initial begin
        for (i = 0; i < 4; i = i + 1) begin
            for (j = 0; j < 512; j = j + 1) begin
                valid_bit[i][j] = 0;
                dirty_bit[i][j] = 0;
                tag_array[i][j] = 0;
            end
        end
    end
    
    
    //Checking for Hit or Miss combinational
    
    integer way;
    reg[3:0] hit_way;
    reg hit_found;
    always@(*) begin
        hit_found = 0;
        hit_way = 4'b0000;
        for(way = 0;way<4;way=way+1)begin
            if (valid_bit[way][addr_index] && (tag_array[way][addr_index] == addr_tag))begin
                hit_found = 1'b1;
                hit_way[way] = 1'b1; //marking which way hit one hot encoding
            end
        end
    end
    
    //updating the hit/miss tags
    always@(posedge clk or posedge rst) begin
        if (rst) begin
            hit<=1'b0;
            miss<=1'b0;
         end else begin
            if (readEn || writeEn)begin
                hit<=hit_found;
                miss <=~hit_found;
             end else begin
                hit<=1'b0;
                miss<=1'b0;
             end
           end
        end
       
       
       //updating the fsm block 
       
       // FSM next state logic
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE: begin
                if (readEn || writeEn)
                    next_state = S_CHECK;
            end
            
            S_CHECK: begin
                if (hit_found)
                    next_state = S_HIT;
                else
                    next_state = S_MISS;
            end
    
            S_HIT: begin
                // after handling hit, respond immediately
                next_state = S_RESP;
            end
    
            S_MISS: begin
                // directly transition to MEMWAIT after issuing request
                next_state = S_MEMWAIT;
            end

    
            S_MEMWAIT: begin
                if (mem_ready)
                    next_state = S_RESP;
            end
    
            S_RESP: begin
                // after ready signal, go back idle
                next_state = S_IDLE;
            end
        endcase
    end

       //reading the data 
       wire [3:0] word_index = addr_offset[5:2];
       reg[31:0] read_data_temp;
       
       
       //reading the data
       always @(*) begin
        if (state == S_HIT && hit_found && readEn) begin
            case (hit_way)
                4'b0001: read_data_temp = data_array[0][addr_index][word_index];
                4'b0010: read_data_temp = data_array[1][addr_index][word_index];
                4'b0100: read_data_temp = data_array[2][addr_index][word_index];
                4'b1000: read_data_temp = data_array[3][addr_index][word_index];
            endcase
        end else begin
            read_data_temp = 32'b0;
        end
    end

     assign read_data = read_data_temp;
     
     
     //writing data from l1 and declaring it as dirty
     integer w;
     always @(posedge clk) begin
        if (state == S_HIT && writeEn && hit_found) begin
            for (w = 0; w < NUM_WAYS; w = w + 1) begin
                if (hit_way[w]) begin
                    data_array[w][addr_index][word_index] <= write_data;
                    dirty_bit[w][addr_index] <= 1'b1;
                end
            end
        end
    end
    
    integer way2;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i = 0; i < NUM_WAYS; i = i + 1)
                for (j = 0; j < 512; j = j + 1)
                    lru_counter[i][j] <= 2'b00;
        end else if (state == S_HIT && hit_found) begin
            for (way2 = 0; way2 < NUM_WAYS; way2 = way2 + 1) begin
                if (hit_way[way2]) begin
                    lru_counter[way2][addr_index] <= 2'b11; // most recent
                end else if (lru_counter[way2][addr_index] > 0) begin
                    lru_counter[way2][addr_index] <= lru_counter[way2][addr_index] - 1;
                end
            end
        end
    end

    //Victim selection based on LRU 
    reg[1:0] victim_way;
    always@(*) begin
        victim_way = 2'b00;
        for (way = 0;way<NUM_WAYS;way=way+1)begin
            if (lru_counter[way][addr_index] == 2'b00)
                victim_way = way[1:0];
            end
        end
     
         
    //FSM OUTPUT 
    
    // FSM output & control logic
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ready    <= 1'b0;
            mem_req  <= 1'b0;
            mem_addr <= 32'b0;
        end else begin
            // Default outputs
            ready   <= 1'b0;
            mem_req <= 1'b0;
    
            case (state)
                S_IDLE: begin
                    // Wait for new request
                    ready   <= 1'b0;
                    mem_req <= 1'b0;
                end
    
                S_CHECK: begin
                    // No output - just check hit/miss (combinational)
                end
    
                S_HIT: begin
                    // Cache hit: ready to respond immediately
                    ready <= 1'b1;
                    mem_req <= 1'b0;
                end
    
                S_MISS: begin
                    // Cache miss: issue memory request
                    mem_addr <= addr;
                    mem_req  <= 1'b1;
                end
    
                S_MEMWAIT: begin
                    // Wait for memory to be ready
                    if (mem_ready) begin
                        // --- refill new cache line ---
                        data_array[victim_way][addr_index][word_index] <= mem_read_data;
                        tag_array[victim_way][addr_index] <= addr_tag;
                        valid_bit[victim_way][addr_index] <= 1'b1;
                        dirty_bit[victim_way][addr_index] <= 1'b0;
                        lru_counter[victim_way][addr_index] <= 2'b11;
                        mem_req <= 1'b0;
                    end
                end
    
                S_RESP: begin
                    // Signal completion
                    ready <= 1'b1;
                end
            endcase
        end
    end
    
//need to implement memory writeback for dirty lines     
endmodule
