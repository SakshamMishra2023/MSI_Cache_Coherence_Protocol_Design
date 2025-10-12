
// Common parameters for cache system
// All modules should include this file

`ifndef CACHE_PARAMS_VH
`define CACHE_PARAMS_VH


// L1 Cache Parameters

`define L1_CACHE_SIZE    32768    // 32KB
`define L1_LINE_SIZE     64       // 64 bytes per line
`define L1_NUM_WAYS      4        // 4-way set associative
`define L1_NUM_SETS      128      // 32KB / 64B / 4 ways = 128 sets
`define L1_TAG_WIDTH     19       // Tag bits
`define L1_INDEX_WIDTH   7        // Index bits (log2(128))
`define L1_OFFSET_WIDTH  6        // Offset bits (log2(64))


// L2 Cache Parameters

`define L2_CACHE_SIZE    131072   // 128KB
`define L2_LINE_SIZE     64       // 64 bytes
`define L2_NUM_WAYS      8        // 8-way set associative
`define L2_NUM_SETS      256      // 128KB / 64B / 8 ways = 256 sets
`define L2_TAG_WIDTH     18       // Tag bits
`define L2_INDEX_WIDTH   8        // Index bits (log2(256))
`define L2_OFFSET_WIDTH  6        // Offset bits (log2(64))


// Memory Parameters

`define MEM_SIZE         4194304  // 4MB
`define MEM_LATENCY      100      // DRAM access latency in cycles


// General Parameters

`define ADDR_WIDTH       32       // 32-bit addressing
`define DATA_WIDTH       32       // 32-bit data bus (word)
`define BYTE_WIDTH       8        // 8 bits per byte


// Derived Parameters

`define L1_LINE_WIDTH    (`L1_LINE_SIZE * `BYTE_WIDTH)  // 512 bits
`define L2_LINE_WIDTH    (`L2_LINE_SIZE * `BYTE_WIDTH)  // 512 bits
`define WORDS_PER_LINE   (`L1_LINE_SIZE / (`DATA_WIDTH/`BYTE_WIDTH))  // 16 words per line

`endif // CACHE_PARAMS_VH