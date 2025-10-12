// memory.v
// Line-wide behavioral memory (64B = 512-bit per transaction)
// - Uses cache_params.vh defines for widths/sizes
// - One request at a time via mem_req/mem_ready
// - Read returns the whole line; Write stores the whole line
// - Applies configurable fixed initial latency before the burst completes
//
// Interface (B):
//   mem_req   : start transaction
//   mem_wr    : 1=write line, 0=read line
//   mem_addr  : byte address (can be unaligned; memory aligns to 64B boundary)
//   mem_wline : 512-bit write data (entire line)
//   mem_rline : 512-bit read data (entire line)
//   mem_ready : 1-cycle pulse when done
//
// Notes:
//   - Under the hood memory is 32-bit word-addressable. A line is 16 words.
//   - LATENCY adds wait cycles before mem_ready; burst itself is modeled inside.
//   - If a new mem_req arrives while busy, it is ignored (simple model).

`timescale 1ns/1ps
`include "cache_params.vh"

module memory #(
    parameter ADDR_WIDTH = `ADDR_WIDTH,        // 32
    parameter DATA_WIDTH = `DATA_WIDTH,        // 32
    parameter MEM_BYTES  = `MEM_SIZE,          // e.g., 4MB
    parameter LINE_BYTES = `L1_LINE_SIZE,      // 64
    parameter LINE_BITS  = `L1_LINE_WIDTH,     // 512
    parameter LATENCY    = `MEM_LATENCY        // cycles
)(
    input  wire                     clk,
    input  wire                     rst,         // active-high
    input  wire                     mem_req,     // start request
    input  wire                     mem_wr,      // 1=write line, 0=read line
    input  wire [ADDR_WIDTH-1:0]    mem_addr,    // byte address (unaligned ok)
    input  wire [LINE_BITS-1:0]     mem_wline,   // entire line to write
    output reg                      mem_ready,   // 1-cycle pulse when done
    output reg  [LINE_BITS-1:0]     mem_rline    // entire line read out
);

    localparam WORD_BYTES      = (DATA_WIDTH/8);              // 4
    localparam WORDS_PER_LINE  = LINE_BYTES / WORD_BYTES;     // 16
    localparam DEPTH_WORDS     = MEM_BYTES / WORD_BYTES;

    // Internal storage
    reg [DATA_WIDTH-1:0] mem_array [0:DEPTH_WORDS-1];

    // Align base address down to line boundary
    wire [ADDR_WIDTH-1:0] base_addr_aligned = {mem_addr[ADDR_WIDTH-1:`L1_OFFSET_WIDTH], {`L1_OFFSET_WIDTH{1'b0}}};
    wire [$clog2(DEPTH_WORDS)-1:0] base_word_addr = base_addr_aligned[ADDR_WIDTH-1:2];

    // Simple FSM
    typedef enum reg [1:0] {S_IDLE=2'd0, S_WAIT=2'd1, S_DO=2'd2, S_RESP=2'd3} state_t;
    state_t state;

    // Latched request & counters
    reg                      pend_wr;
    reg [$clog2(DEPTH_WORDS)-1:0] pend_base_word;
    reg [LINE_BITS-1:0]      pend_wline;
    integer                  wait_cnt;
    integer                  i;

    // Optional init
    initial begin
        for (i = 0; i < DEPTH_WORDS; i = i + 1) begin
            mem_array[i] = '0;
        end
        mem_rline = '0;
    end

    // Helper tasks (synth-safe behavioral style)
    task read_line_into(output [LINE_BITS-1:0] line_out, input [$clog2(DEPTH_WORDS)-1:0] base);
        integer w;
        reg [LINE_BITS-1:0] tmp;
        begin
            tmp = {LINE_BITS{1'b0}};
            for (w = 0; w < WORDS_PER_LINE; w = w + 1) begin
                tmp[w*DATA_WIDTH +: DATA_WIDTH] = mem_array[base + w];
            end
            line_out = tmp;
        end
    endtask

    task write_line_from(input [LINE_BITS-1:0] line_in, input [$clog2(DEPTH_WORDS)-1:0] base);
        integer w;
        begin
            for (w = 0; w < WORDS_PER_LINE; w = w + 1) begin
                mem_array[base + w] <= line_in[w*DATA_WIDTH +: DATA_WIDTH];
            end
        end
    endtask

    // Main FSM
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state           <= S_IDLE;
            mem_ready       <= 1'b0;
            pend_wr         <= 1'b0;
            pend_base_word  <= '0;
            pend_wline      <= '0;
            mem_rline       <= '0;
            wait_cnt        <= 0;
        end else begin
            mem_ready <= 1'b0; // default

            case (state)
                S_IDLE: begin
                    if (mem_req) begin
                        pend_wr        <= mem_wr;
                        pend_base_word <= base_word_addr;
                        pend_wline     <= mem_wline;
                        wait_cnt       <= (LATENCY>0) ? (LATENCY-1) : 0;
                        state          <= (LATENCY>0) ? S_WAIT : S_DO;
                    end
                end

                S_WAIT: begin
                    if (wait_cnt > 0) wait_cnt <= wait_cnt - 1;
                    else               state    <= S_DO;
                end

                S_DO: begin
                    if (pend_wr) begin
                        // Write full line
                        write_line_from(pend_wline, pend_base_word);
                    end else begin
                        // Read full line
                        read_line_into(mem_rline, pend_base_word);
                    end
                    state    <= S_RESP;
                end

                S_RESP: begin
                    mem_ready <= 1'b1;   // 1-cycle pulse
                    state     <= S_IDLE;
                end

            endcase
        end
    end

endmodule

