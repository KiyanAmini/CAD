# `layer2_register_file` blueprint

## Responsibility

`layer2_register_file` preserves the eight ReLU activations while all ten
second-layer neurons are evaluated. Entries 0 through 7 hold hidden
activations; entries 8 and 9 remain reserved. It supplies the hidden values as
seven-value groups to `fp16_multiplier`:

- group 0 contains hidden values 0 through 6;
- group 1 contains hidden value 7 in lane 0 and invalid lanes 1 through 6.

Final logits are not written over hidden values. They are streamed to
`argmax`, which stores the ten final outputs.

## Official module header

```systemverilog
module layer2_register_file (
    input  logic        clk,
    input  logic        rst,
    input  logic        hidden_write_en,
    input  logic [2:0]  hidden_write_addr,
    input  logic [15:0] hidden_write_data,
    input  logic        group_read_req,
    input  logic        group_addr,
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
| `rst` | input | 1 | Synchronous, active-high reset. Clears all ten entries. |
| `hidden_write_en` | input | 1 | Writes one hidden activation when high. |
| `hidden_write_addr` | input | 3 | Destination entry 0 through 7. |
| `hidden_write_data` | input | 16 | FP16 ReLU result to store. |
| `group_read_req` | input | 1 | Requests one seven-lane hidden group. |
| `group_addr` | input | 1 | `0` selects hidden values 0..6; `1` selects hidden value 7 plus invalid lanes. |
| `group_valid` | output | 1 | Indicates that the registered read group is valid. |
| `input0_out` ... `input6_out` | output | 16 each | Seven FP16 multiplier operands. |
| `lane_valid` | output | 7 | `1111111` for group 0; `0000001` for group 1. |

## Timing and reset

A group request is registered and produces `group_valid` and the seven output
lanes one cycle later. Hidden writes take effect on the accepting rising edge.
Reset clears every register and deasserts `group_valid` and `lane_valid`.

## Connections

```text
relu
    └── data_out, valid_out ───► layer2_register_file

controller_fsm
    ├── hidden_write_en/address ─► layer2_register_file
    └── group_read_req/address ───► layer2_register_file

layer2_register_file
    └── input0_out ... input6_out ───► fp16_multiplier
```

