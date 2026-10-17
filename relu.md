# `relu` blueprint

## Responsibility

`relu` applies the scalar IEEE-754 binary16 ReLU operation to a completed
first-layer neuron result:

```text
y = 0.0 when x < 0.0
y = x   otherwise
```

For the finite FP16 values used by this accelerator, a set sign bit produces
zero. This also converts negative zero to positive zero, as required by the
behavioral contract. ReLU is stateless and combinational.

## Official module header

```systemverilog
module relu (
    input  logic [15:0] data_in,
    input  logic        valid_in,
    output logic [15:0] data_out,
    output logic        valid_out
);
```

## Port contract

| Port | Direction | Width | Meaning |
|---|---:|---:|---|
| `data_in` | input | 16 | Completed first-layer FP16 result. |
| `valid_in` | input | 1 | Indicates that `data_in` is a valid neuron result. |
| `data_out` | output | 16 | ReLU result; negative values and negative zero become `16'h0000`. |
| `valid_out` | output | 1 | Combinational copy of `valid_in`. |

`data_out` is allowed to be zero when `valid_in` is low; downstream storage
must use `valid_out` as the write enable. No clock or reset is required because
the module contains no state.

## Connections

```text
fp16_accumulator
    └── result_out, result_valid ───► relu.data_in, relu.valid_in

relu
    └── data_out, valid_out ───► layer2_register_file
```
