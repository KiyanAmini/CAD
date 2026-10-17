# `weight_sram` blueprint

## Responsibility

`weight_sram` stores the flattened first-layer and second-layer FP16 weights
and provides one seven-FP16 row at a time. It models the required synchronous
SRAM latency:

- A read request sampled on a rising edge produces its row exactly seven
  rising edges later.
- Requests are returned in acceptance order.
- The seven output lanes are held in registers so the multiplier can consume
  one lane per cycle.
- The final second-layer row exposes three valid lanes; its four padding lanes
  must not be consumed by the MAC datapath. This follows the 80 values in
  `fc2_weights.mem`: 11 complete rows plus 3 values.

The SRAM does not perform multiplication, accumulation, address sequencing,
or layer control. Those functions belong to `fp16_multiplier`,
`fp16_accumulator`, and `controller_fsm` respectively.

## Official module header

```systemverilog
module weight_sram (
    input  logic        clk,
    input  logic        rst,
    input  logic        read_req,
    input  logic [9:0]  row_addr,
    output logic        row_valid,
    output logic [15:0] weight0_out,
    output logic [15:0] weight1_out,
    output logic [15:0] weight2_out,
    output logic [15:0] weight3_out,
    output logic [15:0] weight4_out,
    output logic [15:0] weight5_out,
    output logic [15:0] weight6_out,
    output logic [6:0]  lane_valid
);
```

## Port contract

| Port | Direction | Width | Meaning |
|---|---:|---:|---|
| `clk` | input | 1 | Positive-edge clock. |
| `rst` | input | 1 | Synchronous, active-high reset. It flushes pending requests and clears outputs. |
| `read_req` | input | 1 | When high on a rising edge, accepts the request at `row_addr`. |
| `row_addr` | input | 10 | Address of one 112-bit row. Addresses 0 through 907 are defined. |
| `row_valid` | output | 1 | One-cycle indication that the seven output registers contain the requested row. |
| `weight0_out` ... `weight6_out` | output | 16 each | Seven registered FP16 weights in ascending logical order. |
| `lane_valid` | output | 7 | Validity mask for the seven output lanes. Bit 0 refers to `weight0_out`; bit 6 refers to `weight6_out`. |

## Address map

The two weight files share one logical address space:

| Address range | Contents | Number of rows |
|---:|---|---:|
| `0` ... `895` | `fc1_weights.mem`, flattened as `W1[n][p]` | 896 |
| `896` ... `907` | `fc2_weights.mem`, flattened as `W2[d][h]` | 12 |

Within each physical row, lane 0 is the first stored weight in logical order
and lane 6 is the seventh. Address `907` is the final second-layer row: lanes
0 through 2 are valid and lanes 3 through 6 are padding. Therefore:

```text
lane_valid = 7'b1111111 for every complete row
lane_valid = 7'b0000111 for row_addr == 10'd907
```

For second-layer digit `d` and hidden index `h`, the physical location is:

```text
flat_index = 8 * d + h
row_addr   = 896 + floor(flat_index / 7)
row_lane   = flat_index % 7
```

The controller gathers the selected physical lanes into a logical seven-value
group before starting the multiplier. Consequently, a physical row is not
assumed to be one complete second-layer neuron.

## Timing and reset

If `read_req` is high when a rising edge accepts address `A` at cycle `t`,
then `row_valid` is asserted for the corresponding result at cycle `t + 7`.
The seven `weight*_out` values and `lane_valid` are valid in that same cycle.
Multiple requests may be accepted on consecutive cycles; their responses
appear seven cycles later in the same order.

While `rst` is high on a rising edge, pending requests are discarded,
`row_valid` is cleared, all weight outputs are set to `16'h0000`, and
`lane_valid` is cleared. After reset, no row is considered available until a
new `read_req` is accepted.

## Connections

```text
controller_fsm
    ├── read_req, row_addr ───────► weight_sram
    ├── row_valid, lane_valid ◄─── weight_sram
    └── physical row data ◄─────── weight_sram

weight_sram
    └── physical weight row ──────► controller_fsm staging registers

controller_fsm
    └── logical weight group ─────► fp16_multiplier
```

For first-layer groups, the controller may forward the physical row directly.
For second-layer groups, it selects the required lanes using the formula
above, fills its seven logical weight registers, and asserts the corresponding
logical `lane_valid` mask. The multiplier captures/consumes weights only after
that logical group is complete.
