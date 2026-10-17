# `fp16_accumulator` blueprint

## Responsibility

`fp16_accumulator` performs the ordered FP16 left-fold required for one
neuron. It initializes its accumulator from the selected bias and then adds
each valid product in arrival order:

```text
acc <- bias
acc <- FP16(acc + product[0])
acc <- FP16(acc + product[1])
...
```

There is one reusable FP16 adder. The accumulator is preserved across all
seven-product groups belonging to the same neuron and is cleared/reloaded
only at the start of the next neuron.

## Official module header

```systemverilog
module fp16_accumulator (
    input  logic        clk,
    input  logic        rst,
    input  logic        neuron_start,
    input  logic [15:0] bias_in,
    input  logic        product_valid,
    input  logic [15:0] product_in,
    input  logic        group_last,
    input  logic        neuron_last,
    output logic        product_ready,
    output logic        busy,
    output logic [15:0] result_out,
    output logic        result_valid
);
```

## Port contract

| Port | Direction | Width | Meaning |
|---|---:|---:|---|
| `clk` | input | 1 | Positive-edge clock. |
| `rst` | input | 1 | Synchronous, active-high reset. Clears the accumulator and status. |
| `neuron_start` | input | 1 | Loads `bias_in` and begins a new neuron. |
| `bias_in` | input | 16 | FP16 bias captured when `neuron_start` is accepted. |
| `product_valid` | input | 1 | A product is available from the ping-pong buffer. |
| `product_in` | input | 16 | FP16 product to add. |
| `group_last` | input | 1 | Marks the final valid product of the current seven-entry group. It does not reset the accumulator. |
| `neuron_last` | input | 1 | Marks the final valid product of the neuron. |
| `product_ready` | output | 1 | High when the accumulator can accept `product_in`. |
| `busy` | output | 1 | High while a neuron accumulation is active. |
| `result_out` | output | 16 | Final FP16 neuron result after the last product has been added. |
| `result_valid` | output | 1 | One-cycle pulse when `result_out` is valid. |

## Operation and reset

`neuron_start` is accepted only while the accumulator is idle. It loads the
bias before any product is accepted. Each accepted product updates the
accumulator with a separately rounded FP16 addition. `group_last` is only a
boundary indication; accumulation continues into the next group. On the
product marked `neuron_last`, the updated sum is written to `result_out` and
`result_valid` pulses for one cycle.

Reset clears `busy`, `result_valid`, `result_out`, and the internal sum.

## Connections

```text
bias_memory
    └── bias_out ───────────────► fp16_accumulator

ping_pong_buffer
    ├── consume_valid, consume_data, consume_last ─► fp16_accumulator
    └── product_ready ◄───────────────────────────── fp16_accumulator

fp16_accumulator
    └── result_out ───► relu (layer one) or argmax (layer two)
```

