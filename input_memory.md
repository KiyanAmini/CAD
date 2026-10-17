# `input_memory` blueprint

## Responsibility

`input_memory` stores the 784 normalized FP16 image pixels in row-major order
and supplies one consecutive seven-pixel group to the multiplier. The image is
partitioned into 112 groups of seven values, so every group is full.

It does not perform arithmetic, choose the active layer, or sequence group
requests. Group sequencing belongs to `controller_fsm`.

## Official module header

```systemverilog
module input_memory (
    input  logic        clk,
    input  logic        rst,
    input  logic        read_req,
    input  logic [6:0]  group_addr,
    output logic        group_valid,
    output logic [15:0] input0_out,
    output logic [15:0] input1_out,
    output logic [15:0] input2_out,
    output logic [15:0] input3_out,
    output logic [15:0] input4_out,
    output logic [15:0] input5_out,
    output logic [15:0] input6_out,
    output logic [6:0]  lane_valid
);
```

## Port contract

| Port | Direction | Width | Meaning |
|---|---:|---:|---|
| `clk` | input | 1 | Positive-edge clock. |
| `rst` | input | 1 | Synchronous, active-high reset. Clears the read-valid output. |
| `read_req` | input | 1 | Accepts the group at `group_addr` on a rising edge. |
| `group_addr` | input | 7 | Group number 0 through 111. Pixel index is `7 * group_addr + lane`. |
| `group_valid` | output | 1 | Indicates that the seven registered pixel outputs are valid. |
| `input0_out` ... `input6_out` | output | 16 each | Consecutive FP16 pixels in increasing image index order. |
| `lane_valid` | output | 7 | Always `7'b1111111` for a valid image group. |

## Timing and reset

This blueprint uses a one-cycle synchronous read: a request accepted at cycle
`t` produces `group_valid` and the seven pixel outputs at cycle `t + 1`.
Requests are returned in order. While reset is sampled high, `group_valid` and
`lane_valid` are cleared and all pixel outputs are set to zero.

## Connections

```text
controller_fsm
    ├── read_req, group_addr ───► input_memory
    └── group_valid ◄──────────── input_memory

input_memory
    └── input0_out ... input6_out ───► fp16_multiplier
```

