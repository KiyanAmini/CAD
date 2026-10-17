# `argmax` blueprint

## Responsibility

`argmax` receives the ten final FP16 logits in digit-index order, stores them
for stable output, and selects the predicted digit. It compares logits using
FP16 ordering and updates the winning index only for a strictly larger value;
therefore ties retain the lowest digit index.

## Official module header

```systemverilog
module argmax (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic        logit_valid,
    input  logic [15:0] logit_in,
    input  logic [3:0]  logit_index,
    input  logic        logit_last,
    output logic        busy,
    output logic [3:0]  prediction,
    output logic        done,
    output logic [15:0] logit0_out,
    output logic [15:0] logit1_out,
    output logic [15:0] logit2_out,
    output logic [15:0] logit3_out,
    output logic [15:0] logit4_out,
    output logic [15:0] logit5_out,
    output logic [15:0] logit6_out,
    output logic [15:0] logit7_out,
    output logic [15:0] logit8_out,
    output logic [15:0] logit9_out
);
```

## Port contract

| Port | Direction | Width | Meaning |
|---|---:|---:|---|
| `clk` | input | 1 | Positive-edge clock. |
| `rst` | input | 1 | Synchronous, active-high reset. |
| `start` | input | 1 | Begins collection of one set of ten logits. |
| `logit_valid` | input | 1 | `logit_in` and `logit_index` are valid this cycle. |
| `logit_in` | input | 16 | Final FP16 logit. |
| `logit_index` | input | 4 | Digit index 0 through 9. |
| `logit_last` | input | 1 | Marks the final logit of the transaction. |
| `busy` | output | 1 | High while collecting logits. |
| `prediction` | output | 4 | Lowest-index digit attaining the maximum logit. |
| `done` | output | 1 | One-cycle pulse after the final logit and prediction are stored. |
| `logit0_out` ... `logit9_out` | output | 16 each | Stable final logits, held until the next `start` or reset. |

## Operation and reset

`start` clears the previous transaction's stored logits and begins a new
comparison. Each valid logit is written to its indexed output register. The
first valid logit initializes the running maximum; later logits replace it
only when strictly greater. When `logit_last` is accepted, the final
prediction is stored and `done` pulses for exactly one cycle. Reset clears all
logits, `prediction`, `busy`, and `done`.

## Connections

```text
fp16_accumulator (second layer)
    └── result_out ───► argmax.logit_in

controller_fsm
    ├── start, logit_valid, logit_index, logit_last ───► argmax
    └── argmax.done ◄─────────────────────────────────── argmax
```

