// cache_line.v
// Single cache line with tag, valid, dirty, and data storage
// Used as building block for cache sets

`include "cache_params.vh"

module cache_line #(
    parameter LINE_SIZE = `L1_LINE_SIZE,      // 64 bytes
    parameter TAG_WIDTH = `L1_TAG_WIDTH       // 19 bits
)(
    input wire clk,
    input wire rst_n,
    
    // Control signals
    input wire write_enable,      // Write new data to this line
    input wire valid_in,          // Valid bit to write
    input wire dirty_in,          // Dirty bit to write
    input wire [TAG_WIDTH-1:0] tag_in,
    input wire [LINE_SIZE*8-1:0] data_in,
    
    // Output state
    output reg valid_out,
    output reg dirty_out,
    output reg [TAG_WIDTH-1:0] tag_out,
    output reg [LINE_SIZE*8-1:0] data_out
);

    // State storage
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            dirty_out <= 1'b0;
            tag_out <= {TAG_WIDTH{1'b0}};
            data_out <= {LINE_SIZE*8{1'b0}};
        end else if (write_enable) begin
            valid_out <= valid_in;
            dirty_out <= dirty_in;
            tag_out <= tag_in;
            data_out <= data_in;
        end
    end

endmodule