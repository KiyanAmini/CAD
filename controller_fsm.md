# `controller_fsm` blueprint

## Responsibility

`controller_fsm` is the control-plane sequencer for one complete image
transaction. It accepts `start` only while idle, performs all eight first-layer
neurons before beginning the second layer, and advances addresses only when
the corresponding memory/datapath handshake permits it.

Its state sequencing is:

```text
IDLE
  -> LOAD_FC1_BIAS / REQUEST_FC1_GROUP / RUN_FC1_GROUP
  -> STORE_HIDDEN (repeat for neurons 0..7)
  -> LOAD_FC2_BIAS / REQUEST_FC2_GROUP / RUN_FC2_GROUP
  -> STREAM_LOGIT (repeat for digits 0..9)
  -> COMPLETE
  -> IDLE
```

The controller does not perform FP16 arithmetic or store product/accumulator
streams. It generates addresses, valid/start pulses, layer/neuron/group
indices, and the final transaction `done` indication. It does contain the
small non-arithmetic second-layer weight staging registers needed to regroup
globally flattened SRAM rows into one digit's logical seven-product group.

## Official module header

```systemverilog
module controller_fsm (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic        input_group_valid,
    input  logic        bias_valid,
    input  logic        layer2_group_valid,
    input  logic        weight_row_valid,
    input  logic [15:0] weight0_in,
    input  logic [15:0] weight1_in,
    input  logic [15:0] weight2_in,
    input  logic [15:0] weight3_in,
    input  logic [15:0] weight4_in,
    input  logic [15:0] weight5_in,
    input  logic [15:0] weight6_in,
    input  logic [6:0]  weight_lane_valid,
    input  logic        multiplier_busy,
    input  logic        buffer_write_ready,
    input  logic        buffer_full,
    input  logic        buffer_consume_valid,
    input  logic        buffer_consume_ready,
    input  logic        buffer_consume_last,
    input  logic        accumulator_result_valid,
    input  logic        argmax_done,
    output logic        input_read_req,
    output logic [6:0]  input_group_addr,
    output logic        weight_read_req,
    output logic [9:0]  weight_row_addr,
    output logic        bias_read_req,
    output logic [4:0]  bias_addr,
    output logic        multiplier_start,
    output logic [15:0] selected_weight0,
    output logic [15:0] selected_weight1,
    output logic [15:0] selected_weight2,
    output logic [15:0] selected_weight3,
    output logic [15:0] selected_weight4,
    output logic [15:0] selected_weight5,
    output logic [15:0] selected_weight6,
    output logic [6:0]  selected_weight_valid,
    output logic        buffer_consume_start,
    output logic        accumulator_start,
    output logic        accumulator_neuron_last,
    output logic        hidden_write_en,
    output logic [2:0]  hidden_write_addr,
    output logic        layer2_group_read_req,
    output logic        layer2_group_addr,
    output logic        argmax_start,
    output logic        argmax_logit_valid,
    output logic [3:0]  argmax_logit_index,
    output logic        argmax_logit_last,
    output logic        busy,
    output logic        done
);
```

## Port contract

The memory and datapath status inputs tell the FSM when a request has arrived,
when a reusable unit is idle, and when a buffered group has been consumed. The
`bias_valid` and `layer2_group_valid` inputs are the registered one-cycle
responses from `bias_memory` and `layer2_register_file`. `buffer_full` permits
`buffer_consume_start` only when an oldest full half exists. A group is
considered consumed only when `buffer_consume_valid`,
`buffer_consume_ready`, and `buffer_consume_last` are all high in the same
cycle; this prevents a held last item under back-pressure from advancing the
FSM. The output
requests and addresses select the next input group, weight row, bias, hidden
write slot, and second-layer logit index. `weight0_in` through `weight6_in`
and `weight_lane_valid` are the physical row returned by `weight_sram`.
`selected_weight0` through `selected_weight6` and
`selected_weight_valid` are the logical group presented to the multiplier.
`busy` is high from an accepted `start` until completion; `done` is a
one-cycle pulse after `argmax_done`.

For layer one, the selected weight group is the physical SRAM row. For layer
two, the controller uses `flat_index = 8 * digit + hidden_index`,
`row_addr = 896 + floor(flat_index / 7)`, and `row_lane = flat_index % 7` to
gather the required weights. The first logical group for a digit has hidden
indices 0 through 6 and `selected_weight_valid=7'b1111111`; the second has
hidden index 7 in lane 0 and `selected_weight_valid=7'b0000001`.

The FSM ignores `start` while busy. Reset returns it to `IDLE`, clears all
indices and requests, and deasserts `busy` and `done`.

## Connections

```text
controller_fsm ───► input_memory, weight_sram, bias_memory
controller_fsm ───► fp16_multiplier, ping_pong_buffer, fp16_accumulator
controller_fsm ───► layer2_register_file, argmax

bias_memory ────────────────► bias_valid ───────────────► controller_fsm
layer2_register_file ───────► layer2_group_valid ───────► controller_fsm
ping_pong_buffer ───────────► buffer_full/consume_valid/consume_last ─► controller_fsm
fp16_accumulator.product_ready ─► buffer_consume_ready ─► controller_fsm

input_memory ──────────────────► fp16_multiplier
weight_sram ───► controller_fsm staging ───► fp16_multiplier
fp16_multiplier ──────────────► ping_pong_buffer
ping_pong_buffer ─────────────► fp16_accumulator
fp16_accumulator ─────────────► relu (layer one) / argmax (layer two)
relu ─────────────────────────► layer2_register_file
layer2_register_file ─────────► fp16_multiplier (layer two)
```
