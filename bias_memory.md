# `bias_memory` blueprint

## Responsibility

`bias_memory` stores all 18 FP16 biases and returns one bias selected by a
logical address. It keeps first-layer and second-layer bias ordering explicit:

- addresses 0 through 7 are `b1[0]` through `b1[7]`;
- addresses 8 through 17 are `b2[0]` through `b2[9]`.

It does not add the bias to an accumulator or select the active neuron.

## Official module header

```systemverilog
module bias_memory (
    input  logic        clk,
    input  logic        rst,
    input  logic        read_req,
    input  logic [4:0]  bias_addr,
    output logic        bias_valid,
    output logic [15:0] bias_out
);
```

## Port contract

| Port | Direction | Width | Meaning |
|---|---:|---:|---|
| `clk` | input | 1 | Positive-edge clock. |
| `rst` | input | 1 | Synchronous, active-high reset. |
| `read_req` | input | 1 | Accepts `bias_addr` on a rising edge. |
| `bias_addr` | input | 5 | Logical bias address 0 through 17. |
| `bias_valid` | output | 1 | Indicates that `bias_out` contains the requested bias. |
| `bias_out` | output | 16 | Registered FP16 bias value. |

## Timing and reset

A request accepted at cycle `t` produces `bias_valid` and `bias_out` at cycle
`t + 1`. Reset clears `bias_valid` and drives `bias_out` to `16'h0000`.
Addresses outside 0 through 17 are invalid and must not be requested by the
controller.

## Connections

```text
controller_fsm
    ├── read_req, bias_addr ───► bias_memory
    └── bias_valid ◄──────────── bias_memory

bias_memory
    └── bias_out ───────────────► fp16_accumulator
```

