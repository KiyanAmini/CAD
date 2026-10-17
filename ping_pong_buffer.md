# `ping_pong_buffer` blueprint

## Responsibility

`ping_pong_buffer` decouples the multiplier's product stream from the
accumulator's consumption stream. It contains two independent seven-entry
FP16 halves:

- one half is written by `fp16_multiplier`;
- the other half is read by `fp16_accumulator`; and
- the roles swap only after the write group is complete and the read group has
  been fully consumed.

The buffer tracks valid entries and prevents overwriting unread products or
reading unwritten products. Invalid multiplier lanes are not stored.

## Official module header

```systemverilog
module ping_pong_buffer (
    input  logic        clk,
    input  logic        rst,
    input  logic        product_valid,
    input  logic [15:0] product_in,
    input  logic        product_last,
    output logic        write_ready,
    input  logic        consume_start,
    input  logic        consume_ready,
    output logic        consume_valid,
    output logic [15:0] consume_data,
    output logic        consume_last,
    output logic        buffer_full,
    output logic        buffer_empty
);
```

## Port contract

| Port | Direction | Width | Meaning |
|---|---:|---:|---|
| `clk` | input | 1 | Positive-edge clock. |
| `rst` | input | 1 | Synchronous, active-high reset. Empties both halves. |
| `product_valid` | input | 1 | The multiplier presents a valid FP16 product this cycle. |
| `product_in` | input | 16 | Product to store when `product_valid` is high. |
| `product_last` | input | 1 | End of the seven-position multiplier group. The final position may be invalid. |
| `write_ready` | output | 1 | High when the selected write half can accept a product. |
| `consume_start` | input | 1 | Starts reading the oldest full half. Accepted only when data is available. |
| `consume_ready` | input | 1 | Accumulator is ready to accept `consume_data`. |
| `consume_valid` | output | 1 | A buffered product is presented this cycle. |
| `consume_data` | output | 16 | FP16 product in read order. |
| `consume_last` | output | 1 | High with the final valid product in the current group. |
| `buffer_full` | output | 1 | At least one half is full and available for reading. |
| `buffer_empty` | output | 1 | No stored product is available for reading. |

## Operation and timing

Products are written in arrival order. `product_last` closes the current
write group; the buffer records how many valid products were stored, so a
partially populated final group is read without fabricated padding values.
The accumulator sees products in the same order in which they were produced.

When `consume_start` is accepted, the selected full half presents its first
product. A product is removed only on a cycle where both `consume_valid` and
`consume_ready` are high. The selected half asserts `consume_last` with its
last valid product. A half is not reused for writing until its read side has
finished.

## Connections

```text
fp16_multiplier
    ├── product_valid, product_in, group_done ───► ping_pong_buffer
    └── write_ready ◄──────────────────────────── ping_pong_buffer

controller_fsm
    └── consume_start ──────────────────────────► ping_pong_buffer

ping_pong_buffer
    ├── consume_valid, consume_data, consume_last ─► fp16_accumulator
    └── consume_ready ◄──────────────────────────── fp16_accumulator
```
