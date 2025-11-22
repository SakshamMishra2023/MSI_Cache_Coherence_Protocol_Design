
module lru_controller #(
    parameter NUM_WAYS = 4
)(
    input wire clk,
    input wire rst_n,
    
    // Access interface
    input wire access_valid,              // An access occurred
    input wire [NUM_WAYS-1:0] access_way, // One-hot: which way was accessed
    
    // Replacement interface
    output reg [1:0] lru_way              // Which way to replace (0-3)
);

    // LRU counters for each way (2 bits each)
    reg [1:0] lru_counter [0:NUM_WAYS-1];
    
    integer i;
    
    // Find the LRU way (highest counter value)
    always @(*) begin
        lru_way = 2'd0;
        for (i = 1; i < NUM_WAYS; i = i + 1) begin
            if (lru_counter[i] > lru_counter[lru_way]) begin
                lru_way = i[1:0];
            end
        end
    end
    
    // Update LRU counters on access
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Initialize: way 0 is MRU, way 3 is LRU
            lru_counter[0] <= 2'd0;
            lru_counter[1] <= 2'd1;
            lru_counter[2] <= 2'd2;
            lru_counter[3] <= 2'd3;
        end else if (access_valid) begin
            // Determine which way was accessed
            case (access_way)
                4'b0001: begin  // Way 0 accessed
                    lru_counter[0] <= 2'd0;  // Make it MRU
                    // Increment others if they were more recent
                    if (lru_counter[1] < 2'd3) lru_counter[1] <= lru_counter[1] + 1;
                    if (lru_counter[2] < 2'd3) lru_counter[2] <= lru_counter[2] + 1;
                    if (lru_counter[3] < 2'd3) lru_counter[3] <= lru_counter[3] + 1;
                end
                4'b0010: begin  // Way 1 accessed
                    lru_counter[1] <= 2'd0;
                    if (lru_counter[0] < 2'd3) lru_counter[0] <= lru_counter[0] + 1;
                    if (lru_counter[2] < 2'd3) lru_counter[2] <= lru_counter[2] + 1;
                    if (lru_counter[3] < 2'd3) lru_counter[3] <= lru_counter[3] + 1;
                end
                4'b0100: begin  // Way 2 accessed
                    lru_counter[2] <= 2'd0;
                    if (lru_counter[0] < 2'd3) lru_counter[0] <= lru_counter[0] + 1;
                    if (lru_counter[1] < 2'd3) lru_counter[1] <= lru_counter[1] + 1;
                    if (lru_counter[3] < 2'd3) lru_counter[3] <= lru_counter[3] + 1;
                end
                4'b1000: begin  // Way 3 accessed
                    lru_counter[3] <= 2'd0;
                    if (lru_counter[0] < 2'd3) lru_counter[0] <= lru_counter[0] + 1;
                    if (lru_counter[1] < 2'd3) lru_counter[1] <= lru_counter[1] + 1;
                    if (lru_counter[2] < 2'd3) lru_counter[2] <= lru_counter[2] + 1;
                end
                default: begin
                    // No change if invalid access
                end
            endcase
        end
    end

endmodule
