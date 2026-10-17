# `fp16_multiplier` blueprint

## Responsibility

`fp16_multiplier` performs one reusable IEEE-754 binary16 multiplication
unit. It accepts one seven-value input group and emits the products as a
sequential stream, one product position per clock:

```text
product[k] = FP16(weight[k] * input[k])
```

The multiplication result is rounded to FP16 before it leaves the module.
The module does not add products, accumulate partial sums, access memory, or
decide which layer is active. Those functions belong to
`fp16_accumulator`, `weight_sram`, `input_memory`/`layer2_register_file`, and
`controller_fsm` respectively. In particular, `controller_fsm` presents
logical weight groups after any required second-layer lane gathering.

## Official module header

```systemverilog
module fp16_multiplier (
    input  logic        clk,
    input  logic        rst,
    input  logic        start_group,
    input  logic [15:0] input0,
    input  logic [15:0] input1,
    input  logic [15:0] input2,
    input  logic [15:0] input3,
    input  logic [15:0] input4,
    input  logic [15:0] input5,
    input  logic [15:0] input6,
    input  logic [15:0] weight0,
    input  logic [15:0] weight1,
    input  logic [15:0] weight2,
    input  logic [15:0] weight3,
    input  logic [15:0] weight4,
    input  logic [15:0] weight5,
    input  logic [15:0] weight6,
    input  logic [6:0]  lane_valid,
    output logic        busy,
    output logic        product_valid,
    output logic [15:0] product_out,
    output logic [2:0]  product_index,
    output logic        group_done
);
```

## Port contract

| Port | Direction | Width | Meaning |
|---|---:|---:|---|
| `clk` | input | 1 | Positive-edge clock. |
| `rst` | input | 1 | Synchronous, active-high reset. It aborts a group and clears outputs. |
| `start_group` | input | 1 | One-cycle request to capture a new seven-lane group. Accepted only while `busy` is low. |
| `input0` ... `input6` | input | 16 each | Seven FP16 operands from `input_memory` for layer one or `layer2_register_file` for layer two. |
| `weight0` ... `weight6` | input | 16 each | Seven FP16 weights for one logical group. For layer one these may be forwarded from one SRAM row; for layer two they are assembled by `controller_fsm` from the physical SRAM rows. |
| `lane_valid` | input | 7 | Validity mask for the captured logical group. Bit `k` corresponds to lane `k`. Invalid lanes do not produce a valid product. |
| `busy` | output | 1 | High while the captured group is being processed. |
| `product_valid` | output | 1 | High when `product_out` is a valid product for the current cycle. |
| `product_out` | output | 16 | FP16 product for `product_index`. It is zero when `product_valid` is low. |
| `product_index` | output | 3 | Lane number, 0 through 6, of the current product. |
| `group_done` | output | 1 | One-cycle pulse after the seventh lane position has been visited. It marks the end of the group, including invalid positions. |

## Operation and timing

When `start_group` is sampled high on a rising edge while `busy` is low, the
module captures all seven inputs, all seven weights, and `lane_valid`. It then
visits lane positions in increasing order:

```text
cycle 0: product_index = 0
cycle 1: product_index = 1
...
cycle 6: product_index = 6, group_done = 1
```

For a valid lane, `product_valid` is high for that cycle and `product_out`
contains the rounded FP16 product. For an invalid lane, `product_valid` is
low and the lane is skipped; no padding value may enter the MAC sequence.
`group_done` is asserted exactly once in the final lane cycle. `busy` remains
high during that cycle and clears on the following rising edge, so the
controller starts the next group only after the current group has completed.

The normal seven-lane path therefore produces at most one product per clock
for seven clocks. The downstream ping-pong buffer consumes products in
`product_index` order and writes only cycles where `product_valid` is high.

## Reset behavior

While `rst` is high on a rising edge:

- `busy`, `product_valid`, and `group_done` are cleared;
- `product_out` and `product_index` are cleared; and
- any partially processed group is discarded.

No product is valid until a later `start_group` request is accepted.

## Connections

```text
controller_fsm
    ├── selected weight0 ... weight6 ─► fp16_multiplier
    └── selected lane_valid ───────────► fp16_multiplier

input_memory / layer2_register_file
    └── input0 ... input6 ─────────► fp16_multiplier

controller_fsm
    └── start_group ───────────────► fp16_multiplier

fp16_multiplier
    ├── product_out
    ├── product_valid
    └── product_index ─────────────► ping_pong_buffer
```

The controller starts a group only after the corresponding SRAM row and input
group are aligned. The multiplier has exactly one FP16 multiplication datapath;
the seven operand registers provide time-multiplexed access to that unit.
