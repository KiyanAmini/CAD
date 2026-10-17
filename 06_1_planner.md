# Section 6 Planner Output — FP16 Fully Connected Accelerator

## 1. Verified facts and discrepancy audit

The two context files are byte-for-byte equivalent. They are treated as one
authoritative source, with `context.md` named below for brevity. All supplied
module blueprints and `spec.md_03` agree on the network dimensions and the
memory ordering. `plan.md_05` is useful as a prior proposal, but it is not
authoritative where it is incomplete.

| ID | Requirement/fact | Source file and section | Status |
|---|---|---|---|
| AUD-001 | System is 784 inputs -> 8 FC1 neurons -> ReLU -> 10 FC2 neurons -> argmax. | `context.md`, §§1,3; `assests/test.py`, model constants | FIXED |
| AUD-002 | RTL is synthesizable SystemVerilog-2012, one positive-edge `clk`, synchronous active-high `rst`. | `context.md`, §2; `spec.md_03`, §1.1 | FIXED |
| AUD-003 | All numeric storage and ports are IEEE-754 binary16 bit patterns, 16 bits wide; addresses and masks are unsigned. | `context.md`, §2; `spec.md_03`, §1.2 | FIXED |
| AUD-004 | Exactly one reusable FP16 multiplier and one reusable FP16 adder; no FP32 accumulator, FMA, tree, or reordering. | `context.md`, §§2,3,7; `spec.md_03`, §1.2 | FIXED |
| AUD-005 | Every multiply rounds to FP16 before the add; every add rounds to FP16 before the next operation. | `context.md`, §§2,3,7; `assests/test.py`, `mac(..., mode="fp16")` | FIXED |
| AUD-006 | FC1 order is neuron-major then pixel-major, with 784 pixels per neuron; FC2 order is digit-major then hidden index 0..7. | `context.md`, §§3,5; `spec.md_03`, §§2,3; `assests/test.py` | FIXED |
| AUD-007 | Bias is loaded before the first product of each neuron and remains in the left-fold accumulator across groups. | `context.md`, §7; `fp16_accumulator.md`; `spec.md_03`, §7 | FIXED |
| AUD-008 | Input image has 784 values, FC1 weights 6272, FC1 bias 8, FC2 weights 80, FC2 bias 10. | `context.md`, §5; physical `.mem` line counts | FIXED |
| AUD-009 | Input memory returns seven pixels one cycle after a legal request; groups are 0..111 and every lane is valid. | `input_memory.md`; `spec.md_03`, §2 | FIXED |
| AUD-010 | Weight SRAM rows are 112 bits / seven FP16 lanes; legal rows are 0..907; FC1 uses rows 0..895 and FC2 rows 896..907. | `weight_sram.md`; `context.md`, §6 | FIXED |
| AUD-011 | Weight SRAM response is exactly seven rising edges after acceptance and preserves request order, including consecutive requests. | `context.md`, §6; `weight_sram.md`; `spec.md_03`, §3.2 | FIXED |
| AUD-012 | Physical row 907 has valid lanes 0..2 only and mask `7'b0000111`; padding must not create products. | `context.md`, §6; `weight_sram.md`; `spec.md_03`, §3.3 | FIXED |
| AUD-013 | FC2 mapping is `flat_index=8*d+h`, `row_addr=896+floor(flat_index/7)`, `row_lane=flat_index%7`; a physical row is not a logical digit group. | `context.md`, §6; `partitioning.md_02`; `spec.md_03`, §§3,12 | FIXED |
| AUD-014 | Multiplier captures seven operands and a lane mask, emits lane positions 0..6 in order, and asserts `group_done` on position 6 even if that position is invalid. | `fp16_multiplier.md`; `spec.md_03`, §5 | FIXED |
| AUD-015 | Ping-pong halves hold at most seven products, preserve order, close on `product_last`, expose oldest full half, and hold read data stable under back-pressure. | `ping_pong_buffer.md`; `spec.md_03`, §6 | FIXED |
| AUD-016 | Partial FC2 group is one valid product in lane 0 followed by six invalid positions; no fabricated products are added. | `context.md`, §7; `layer2_register_file.md`; `spec.md_03`, §§5,8 | FIXED |
| AUD-017 | ReLU maps negative values, including negative zero, to positive zero; otherwise passes the FP16 bit pattern. | `context.md`, §3; `relu.md`; `spec.md_03`, §9 | FIXED |
| AUD-018 | Argmax updates only on strict FP16 greater-than; ties retain the lowest digit index; final logits and prediction remain stable after `done`. | `context.md`, §§3,4; `argmax.md`; `spec.md_03`, §10 | FIXED |
| AUD-019 | Accepted `start` is only legal while idle; busy starts are ignored; `done` is a one-cycle pulse. | `context.md`, §4; all stateful blueprints | FIXED |
| AUD-020 | No functional `initial` block, delay, real number, software FP library, or vendor FP primitive is allowed in the DUT. | `context.md`, §2; `plan.md_05`, global rules | FIXED |
| AUD-021 | The controller header now explicitly includes `bias_valid`, matching the one-cycle response from `bias_memory`. | `controller_fsm.md`, amended official header; `bias_memory.md` | FIXED |
| AUD-022 | The controller header now explicitly includes `layer2_group_valid`, matching the registered response from `layer2_register_file`. | `controller_fsm.md`, amended official header; `layer2_register_file.md` | FIXED |
| AUD-023 | The controller now observes `buffer_consume_valid` and advances only on the accepted `buffer_consume_valid && buffer_consume_ready && buffer_consume_last` handshake. | `controller_fsm.md`; `ping_pong_buffer.md`; `spec.md_03`, §11.1a | FIXED |
| AUD-024 | The controller now observes `buffer_full` before issuing `buffer_consume_start`. | `controller_fsm.md`; `ping_pong_buffer.md`; `partitioning.md_02` | FIXED |
| AUD-025 | The inherited plan describes an arithmetic helper only as a requirement and does not define exact special-value, normalization, or rounding behavior. | `plan.md_05`, §§5,7; `context.md`, §2 | CONFLICT |
| AUD-026 | No top-level wrapper name or memory-loading interface is specified. | `context.md`, §4; `partitioning.md_02` | ASSUMPTION |

### Applied interface resolution

The authority order is `context.md` / `01_context.md`, then module
blueprints and `spec.md_03`, then `partitioning.md_02`, then `plan.md_05`.
AUD-021 through AUD-024 have now been resolved by the smallest explicit
controller status-interface amendment. The amended `controller_fsm` header,
partitioning document, and Section 3 controller specification all define these
five inputs in the same clock and reset domain:

| Amended input | Width | Purpose |
|---|---:|---|
| `bias_valid` | 1 | Accept a bias response only on its one-cycle valid pulse. |
| `layer2_group_valid` | 1 | Accept the one-cycle hidden-group response. |
| `buffer_full` | 1 | Permit `buffer_consume_start` only when a full group is available. |
| `buffer_consume_valid` | 1 | Qualify `buffer_consume_last`; group completion is the accepted last handshake. |
| `buffer_consume_ready` | 1 | Observe the actual consumer-side acceptance condition for the final product. |

The existing `buffer_consume_last` remains an input. The controller advances
from a group-wait state only when
`buffer_consume_valid && buffer_consume_ready && buffer_consume_last` is true.
The controller does not add a product datapath or arithmetic port. The
top-level connects `buffer_consume_ready` to the accumulator's published
`product_ready`; it connects `layer2_group_valid` directly from the layer-two
register file and `bias_valid` directly from bias memory. This amended
interface is now the official, documented contract for the Programmer.

AUD-025 is resolved by the arithmetic plan in §4 below. AUD-026 is a safe
integration assumption: the Programmer shall provide a wrapper named
`fc16_accelerator` with the transaction ports from `context.md`, while the
memory arrays remain externally initialized by a testbench or synthesis
wrapper.

## 2. Recommended build and dependency order

Every item below is a single recommended path; no competing architecture is
being proposed.

| Order | Module/file | Inputs and outputs | Dependencies and reason it precedes the next item |
|---:|---|---|---|
| 1 | `fp16_arith_pkg.sv` or equivalent helper section | FP16 bit patterns to one rounded product or one rounded sum | Defines the only multiplier and adder arithmetic used everywhere else. Unit-test before any datapath module. |
| 2 | `input_memory` | `read_req`, 7-bit group address -> seven pixels, valid, mask | Independent one-cycle memory contract; validates image ordering. |
| 3 | `bias_memory` | bias request/address -> one-cycle bias response | Independent one-cycle parameter memory; required before accumulator integration. |
| 4 | `weight_sram` | row request/address -> seven-lane row exactly seven edges later | Establishes the long-latency row stream and row-907 mask. |
| 5 | `relu` | completed FC1 FP16 result -> combinational hidden result | Stateless and independent; its exact sign behavior is needed before hidden storage. |
| 6 | `fp16_multiplier` | one logical seven-lane input/weight group -> seven-position product stream | Uses the arithmetic helper and feeds the buffer. |
| 7 | `fp16_accumulator` | bias plus ordered buffered products -> one result pulse | Uses the single FP16 adder and defines final-product inclusion. |
| 8 | `ping_pong_buffer` | product stream and ready/valid consume interface -> ordered product stream | Decouples multiplier and accumulator; must be proven before controller timing. |
| 9 | `layer2_register_file` | eight hidden writes and two group reads -> delayed seven-lane hidden groups | Preserves hidden values for all ten digits. |
| 10 | `argmax` | ten indexed valid logits -> stable logits, prediction, done | Independent final reduction; verifies strict-greater ties. |
| 11 | `controller_fsm` | all memory/datapath statuses -> requests, starts, index/address/control pulses | Depends on every exact latency and amended handshake. It must not hide a submodule protocol. |
| 12 | `fc16_accelerator` wrapper/top level | external transaction ports and all submodule connections | Integrates one shared multiplier, one shared accumulator, memories, hidden storage, and argmax. |

Each implementation block receives one or more `// STEP-xxx` comments whose
IDs are defined below. The comments are labels only; the Programmer must not
insert RTL into this document.

## 3. Per-module implementation plan

### 3.1 `controller_fsm`

#### Responsibility and non-responsibilities

The controller accepts one start while idle, sequences FC1 then FC2, issues
all memory requests, gathers FC2 physical rows into logical groups, controls
the shared multiplier/accumulator/buffer, writes eight hidden values, streams
ten logits to argmax, and emits the transaction-level done pulse. It does not
perform FP16 arithmetic, store products, implement memory contents, or decide
FP16 comparisons.

#### Official ports, including the applied status-interface amendment

The official ports are exactly the ports in `controller_fsm.md`: `clk`, `rst`,
`start`, `input_group_valid`, `weight_row_valid`, `weight0_in` through
`weight6_in`, `weight_lane_valid`, `multiplier_busy`,
`buffer_write_ready`, `buffer_consume_last`, `accumulator_result_valid`,
`argmax_done`; outputs `input_read_req`, `input_group_addr`,
`weight_read_req`, `weight_row_addr`, `bias_read_req`, `bias_addr`,
`multiplier_start`, `selected_weight0` through `selected_weight6`,
`selected_weight_valid`, `buffer_consume_start`, `accumulator_start`,
`accumulator_neuron_last`, `hidden_write_en`, `hidden_write_addr`,
`layer2_group_read_req`, `layer2_group_addr`, `argmax_start`,
`argmax_logit_valid`, `argmax_logit_index`, `argmax_logit_last`, `busy`,
`done`. The amended official inputs also include `bias_valid`,
`layer2_group_valid`, `buffer_full`, `buffer_consume_valid`, and
`buffer_consume_ready`, exactly as documented in the audit.

#### Registers, parameters, and ownership

Use one enumerated state register; 3-bit `fc1_neuron` (0..7), 7-bit
`fc1_group` (0..111), 4-bit `fc2_digit` (0..9), and one-bit
`fc2_group` (0 or 1). Own registered bias storage, input/weight response
seen flags, current group-valid flags, the seven logical weight staging
registers, their mask, and FC2 gather bookkeeping: current logical hidden
base, first/second physical row addresses, row count, row-valid count, and
per-lane captured bits. Own all one-cycle control pulses through combinational
defaults, with the state/counters committed in one sequential block.

#### Sequential and combinational blocks

There is one `always_ff` block for reset, state, counters, response capture,
and staging registers. There is one `always_comb` block for safe defaults,
next-state decode, address selection, and all request/start/write/logit
pulses. Blocking assignments are confined to combinational temporaries; all
clocked updates are nonblocking.

#### Complete state table and transitions

| State | Outputs/conditions | Counter and staging action | Legal transition |
|---|---|---|---|
| `IDLE` | `busy=0`, all request/start/write pulses low | Keep final outputs untouched; clear transient flags only on accepted start | `start` -> `FC1_BIAS_REQ`; otherwise stay |
| `FC1_BIAS_REQ` | Pulse `bias_read_req`, address `fc1_neuron` | No counter change | After request edge -> `FC1_BIAS_WAIT` |
| `FC1_BIAS_WAIT` | Wait for amended `bias_valid` | Capture `bias_out` into `bias_reg` exactly once | `bias_valid` -> `FC1_INPUT_WEIGHT_REQ` |
| `FC1_INPUT_WEIGHT_REQ` | Pulse input request at `fc1_group`; pulse weight request at `fc1_neuron*112+fc1_group` | Clear input/weight seen flags | After both request edges -> `FC1_OPERAND_WAIT` |
| `FC1_OPERAND_WAIT` | Hold current addresses; no multiplier start | Capture input group on `input_group_valid`, row and mask on `weight_row_valid` | Both seen and `buffer_write_ready` -> `FC1_MAC_START`; otherwise wait |
| `FC1_MAC_START` | Pulse `accumulator_start` only when `fc1_group=0`; pulse `multiplier_start` | Keep operand staging stable through the acceptance edge | Start edge -> `FC1_GROUP_WAIT` |
| `FC1_GROUP_WAIT` | Wait for full/partial group to close and its products to be consumed | No group increment until the amended accepted-last condition | Accepted `buffer_consume_last`: if group 111 -> `FC1_RESULT_WAIT`; else increment `fc1_group` and -> `FC1_INPUT_WEIGHT_REQ` |
| `FC1_RESULT_WAIT` | No new requests | Wait for accumulator result pulse | `accumulator_result_valid` -> `FC1_RELU_STORE` |
| `FC1_RELU_STORE` | Pulse hidden write at `fc1_neuron` using combinational ReLU output | Hidden write occurs on this state’s accepting edge | If neuron 7 -> `FC2_ARGMAX_START`; else increment neuron, clear group, -> `FC1_BIAS_REQ` |
| `FC2_ARGMAX_START` | Pulse `argmax_start` once | Reset digit to 0 and transient FC2 flags | Request edge -> `FC2_BIAS_REQ` |
| `FC2_BIAS_REQ` | Pulse bias request at `8+fc2_digit` | No digit increment | Request edge -> `FC2_BIAS_WAIT` |
| `FC2_BIAS_WAIT` | Wait for `bias_valid` | Capture FC2 bias in `bias_reg` | Valid edge -> `FC2_GROUP_PREP` |
| `FC2_GROUP_PREP` | Set logical group to 0; pulse hidden-group request and first physical weight request | Set logical hidden base to 0; compute `flat_index=8*digit`; clear selected-lane bits | Request edge -> `FC2_GATHER_WAIT` |
| `FC2_GATHER_WAIT` | Capture returned physical row(s); no multiplier start | For each lane marked valid by the current logical-group mask, copy only the requested physical lane when its row is valid; invalid lanes are neither captured nor awaited. If a second row is needed, issue exactly one next-row request and wait seven edges. | Every valid logical lane captured, selected-weight mask complete, and `layer2_group_valid` seen -> `FC2_OPERAND_WAIT`; otherwise remain or issue next row |
| `FC2_OPERAND_WAIT` | Hold logical weights and hidden operands | Wait for hidden response and available write half | Both valid and `buffer_write_ready` -> `FC2_MAC_START` |
| `FC2_MAC_START` | Pulse `multiplier_start`; pulse `accumulator_start` only for logical group 0 | `selected_weight_valid` is all ones for group 0 and `0000001` for group 1 | Start edge -> `FC2_GROUP_WAIT` |
| `FC2_GROUP_WAIT` | Wait for the current group’s accepted final product | `group=0` never resets accumulator | Accepted `buffer_consume_last`: if group 0, set group=1 and -> `FC2_GROUP_PREP`; if group 1 -> `FC2_RESULT_WAIT` |
| `FC2_RESULT_WAIT` | Wait for final accumulator result | No new group request | `accumulator_result_valid` -> `FC2_LOGIT_SEND` |
| `FC2_LOGIT_SEND` | Pulse argmax valid with `fc2_digit`; assert `logit_last` only for digit 9 | No write to hidden storage | If digit 9 -> `COMPLETE_WAIT`; else increment digit and -> `FC2_BIAS_REQ` |
| `COMPLETE_WAIT` | No requests; hold busy until completion | Wait for argmax’s one-cycle done | On `argmax_done`, pulse controller `done` for exactly one cycle and return to `IDLE`; otherwise wait |

The default recovery for any illegal state is `IDLE` with all pulses low,
transient staging cleared, and `busy=0` on the next edge. `start` is ignored
in every non-idle state. Counters never wrap: an out-of-range increment is a
recovery error and must return to `IDLE` rather than aliasing another neuron,
digit, group, row, or hidden index.

#### Timing and boundary behavior

An accepted start occurs at edge N in `IDLE`; the controller becomes busy
after that edge. A bias request at edge N returns at N+1. An input request at
edge N returns at N+1. A weight request at N returns at N+7. FC1 response
flags are set only on their valid edges, so the multiplier cannot start until
both sources are captured. A multiplier start accepted at edge M exposes
lane 0 during the following cycle and lane 6/group closure during the seventh
following cycle; the buffer writes each valid product on its corresponding
edge. The controller starts consumption only after `buffer_full` is observed,
and treats the group complete only after the last valid product is accepted
under `buffer_consume_valid && buffer_consume_ready`.

The FC2 gather never assumes a physical row is a digit group. Group 0
selects hidden indices 0..6; group 1 selects hidden index 7 in lane 0 and
marks lanes 1..6 invalid. A request or response for row 907 is accepted only
if the selected lane is 0, 1, or 2; any required lane with
`weight_lane_valid=0` is a fatal protocol assertion and must not start the
multiplier. Reset aborts the transaction and flushes all transient flags.

#### Assertions/observables

The testbench shall observe exact FC1 row address `112*n+g`, exact FC2
row/lane formula, no use before seven edges, one bias request per neuron,
two FC2 groups per digit, group completion only on an accepted last item,
hidden writes at addresses 0..7 only, digit order 0..9, `logit_last` only at
digit 9, ignored busy starts, and one controller done pulse.

#### Controller steps

- **STEP-001:** Declare state, bounded counters, bias/operand flags, and FC2 row/lane staging with reset ownership.
- **STEP-002:** Implement the idle-to-FC1 acceptance and FC1 bias/request/wait transitions, including exact address formulas.
- **STEP-003:** Implement FC1 operand capture, multiplier/accumulator start, group completion, result wait, ReLU hidden write, and neuron increment.
- **STEP-004:** Implement FC2 argmax start, bias sequencing, hidden-group request, and physical-row gathering with the required formula and row-907 mask check.
- **STEP-005:** Implement FC2 two-group accumulation, digit logit transfer, final logit marker, completion wait, done pulse, and illegal-state recovery.

### 3.2 `input_memory`

#### Responsibility and ports

Store exactly 784 FP16 pixels loaded in row-major order and return one
consecutive seven-pixel group. Official ports are `clk` (input, 1), `rst`
(input, 1), `read_req` (input, 1), `group_addr` (input, 7),
`group_valid` (output, 1), `input0_out`..`input6_out` (outputs, 16 each),
and `lane_valid` (output, 7). It does not sequence neurons, perform
arithmetic, or choose a layer.

#### Registers, blocks, and timing

Own `pixel_mem[0:783]`, seven output registers, `group_valid`, and
`lane_valid`. Use one `always_ff` block. At an accepting edge N with
`read_req=1` and address 0..111, capture indices `7*group_addr+0..6` and
make the registered response valid after edge N+1. Drive
`lane_valid=1111111` on that response. Reset and invalid addresses clear
valid/mask/data; no address wraps. Consecutive legal requests produce
consecutive responses.

#### Steps and checks

- **STEP-006:** Declare the 784-entry FP16 storage and response registers with reset values.
- **STEP-007:** Implement the one-cycle legal group read and ordered lane capture.
- **STEP-008:** Implement invalid-address behavior, reset flushing, and the always-one valid-lane mask for legal groups.

Assertions cover groups 0, 1, 110, 111, consecutive requests, reset while a
request is pending, and invalid address 112 or above.

### 3.3 `weight_sram`

#### Responsibility and ports

Store 908 physical rows of seven FP16 lanes and provide the exact seven-edge
ordered response. Official ports are `clk`, `rst`, `read_req`, `row_addr[9:0]`,
`row_valid`, `weight0_out`..`weight6_out` (16 each), and `lane_valid[6:0]`.
No FC2 regrouping occurs here.

#### Registers, blocks, and timing

Own `row_mem[0:907][0:6]`, a seven-stage valid/address pipeline whose
acceptance-to-output distance is exactly seven rising edges, seven output
registers, and the output mask. Use one `always_ff` block. At edge N insert a
valid pipeline entry only for `read_req && row_addr<=907`; at edge N+7
register the selected row and assert `row_valid` for one cycle. Every
complete row uses mask `1111111`; row 907 uses `0000111`. Invalid response
slots output zero and `row_valid=0`. Reset flushes all stages and outputs.

#### Steps and checks

- **STEP-009:** Declare physical rows, the seven-stage request pipeline, and reset values.
- **STEP-010:** Shift requests every edge while preserving acceptance order and legal-address qualification.
- **STEP-011:** Emit row data exactly at N+7 with the row-907 mask and zero invalid slots.
- **STEP-012:** Prove address boundaries 0, 895, 896, 906, 907, 908 and consecutive requests.

The testbench must compare response edge numbers, not just eventual data.

### 3.4 `bias_memory`

#### Responsibility and ports

Store 18 FP16 biases. Official ports are `clk`, `rst`, `read_req`,
`bias_addr[4:0]`, `bias_valid`, and `bias_out[15:0]`. Address 0..7 maps to
FC1 bias and 8..17 to FC2 bias; 18..31 are invalid.

#### Registers, blocks, and timing

Own an 18-entry memory, one request/address-valid register, and registered
response. Use one `always_ff` block. A legal request at edge N produces
`bias_valid` and the selected value after edge N+1. Invalid requests have no
architectural effect and produce no valid response. Reset clears the response.

#### Steps and checks

- **STEP-013:** Declare the 18-entry bias storage and one-cycle response registers.
- **STEP-014:** Implement legal request capture, ordered one-cycle response, and address mapping.
- **STEP-015:** Implement reset and invalid-address suppression.

Check addresses 0, 7, 8, 17, 18, consecutive requests, and reset flushing.

### 3.5 `fp16_multiplier`

#### Responsibility and official ports

Implement one reusable binary16 multiplier and a seven-position sequential
stream. Official inputs are `clk`, `rst`, `start_group`, `input0`..`input6`,
`weight0`..`weight6`, and `lane_valid[6:0]`; outputs are `busy`,
`product_valid`, `product_out[15:0]`, `product_index[2:0]`, and `group_done`.
It does not add, accumulate, access memory, or apply FC2 mapping.

#### Registers, blocks, and states

Own seven captured inputs, seven captured weights, one captured validity mask,
3-bit lane counter, `busy`, product register, product-valid, and group-done.
Use one `always_ff` for capture/state/output registers and one `always_comb`
for lane selection and the single rounded product calculation. States are
`IDLE` and `RUN`. `IDLE` accepts start only when not busy; `RUN` visits lane
0 through lane 6 exactly once, returning to `IDLE` after the lane-6 cycle.

#### Timing and boundaries

At edge N, an idle multiplier accepts start and captures all operands. During
the cycle after that edge it presents lane 0; lanes advance one per cycle.
For a valid lane, product_valid is high and the output is the rounded
product. For an invalid lane, product_valid is low and product_out is zero.
Lane 6 asserts group_done regardless of its validity. A start while RUN is
ignored. Reset aborts the group. The controller starts only when the buffer
can accept all seven lane opportunities; therefore no multiplier ready port
is needed.

#### Steps and checks

- **STEP-016:** Capture seven operands, seven weights, and the validity mask only on an accepted idle start.
- **STEP-017:** Select one lane per cycle and invoke the single FP16 multiply helper with no FMA.
- **STEP-018:** Generate product-valid, zero invalid outputs, lane order, lane-6 group_done, busy clearing, and reset/start-while-busy behavior.

Observe positive, negative, zero, subnormal, rounding-boundary, overflow,
invalid-padding, start-while-busy, and reset-during-run cases.

### 3.6 `ping_pong_buffer`

#### Responsibility and official ports

Implement two independent seven-entry FP16 halves between multiplier and
accumulator. Official ports are `clk`, `rst`, `product_valid`, `product_in`,
`product_last`, `write_ready`, `consume_start`, `consume_ready`,
`consume_valid`, `consume_data`, `consume_last`, `buffer_full`, and
`buffer_empty`, with the widths in `ping_pong_buffer.md` (data is 16 bits and
all control ports are one bit). `buffer_full` means at least one full group
is available to read; `buffer_empty` means no unread product is available.

#### Registers, states, and ownership

Own two seven-entry memories; per-half state `EMPTY`, `WRITING`, `FULL`, or
`READING`; write position, read position, valid count; current write/read
selectors; and an age tag identifying the oldest full half. Use one
`always_ff` for memory/state/pointers/counts and one `always_comb` for
selectors, ready/valid/data/last, and next-state decisions.

#### Exact policy

After reset both halves are EMPTY. The lowest-index eligible empty half is
selected initially, then selection alternates deterministically. A valid
product is written only with `product_valid && write_ready`; the producer
must hold a valid product if write_ready is low. `product_last` closes the
currently writing half even when the final multiplier position is invalid;
the valid count, not the lane position, defines the last readable product.
A zero-valid close is a protocol assertion failure and does not fabricate a
word.

`consume_start` is accepted only for the oldest FULL half. Its first data is
presented after the accepting edge. During READING, consume_data,
consume_valid, and consume_last are held stable while consume_ready is low.
The final valid item is removed only on `consume_valid && consume_ready`.
The half becomes EMPTY after that edge and cannot be selected for a write on
the same edge. Simultaneous read/write is legal only when the halves differ.

#### Steps and checks

- **STEP-019:** Reset both halves, selectors, counts, age tags, and status outputs.
- **STEP-020:** Implement ordered writes, capacity/ready, valid-count tracking, and product-last closure for full and partial groups.
- **STEP-021:** Implement oldest-full consume selection, read data/last generation, and accepted final removal.
- **STEP-022:** Implement stable back-pressure behavior, opposite-half simultaneous operation, same-half reuse exclusion, and status outputs.

Test alternating groups, two queued groups, both full, both empty, partial
final groups, producer and consumer back-pressure, reset during each state,
and oldest-first order.

### 3.7 `fp16_accumulator`

#### Responsibility and official ports

Perform one neuron’s ordered FP16 left fold. Official ports are `clk`, `rst`,
`neuron_start`, `bias_in[15:0]`, `product_valid`, `product_in[15:0]`,
`group_last`, `neuron_last`, `product_ready`, `busy`, `result_out[15:0]`,
and `result_valid`. It does not know physical rows or hidden storage.

#### Registers, blocks, and states

Own one 16-bit running sum, captured bias, busy, result register, and
result-valid pulse. Use one `always_ff` for all state and one `always_comb`
for the single rounded FP16 add and readiness. States are `IDLE` and
`ACTIVE`; product_ready is high throughout ACTIVE, so a buffered product
cannot be lost. `group_last` is observed but never resets the sum.

#### Timing and boundaries

At edge N, an idle accumulator accepts neuron_start and loads bias_in. Each
accepted product on a later edge performs exactly one rounded addition. The
product marked neuron_last is included in the new sum; that new sum is
written to result_out and result_valid pulses for one cycle. Busy then clears.
A start while ACTIVE is ignored. Reset clears sum, result, busy, and valid.
The controller provides neuron_last only on the valid product of the final
logical group (FC1 group 111 or FC2 group 1).

#### Steps and checks

- **STEP-023:** Accept neuron_start only while idle and load the bias-first sum.
- **STEP-024:** Accept products in order, apply one rounded FP16 add per handshake, and ignore group_last as a reset.
- **STEP-025:** Include the final product, pulse result_valid, clear busy, and implement reset/start-while-busy behavior.

Check bias placement, every intermediate rounded sum, back-pressure, group
boundaries, final-product inclusion, and result pulse width.

### 3.8 `layer2_register_file`

#### Responsibility and official ports

Preserve hidden activations 0..7 for all ten FC2 digits. Official ports are
`clk`, `rst`, `hidden_write_en`, `hidden_write_addr[2:0]`,
`hidden_write_data[15:0]`, `group_read_req`, `group_addr`, `group_valid`,
`input0_out`..`input6_out` (16 each), and `lane_valid[6:0]`.
Addresses 8 and 9 are reserved and never alias hidden entries.

#### Registers, blocks, and timing

Own ten 16-bit entries and one-cycle registered group-response registers.
Use one `always_ff` block. A legal hidden write at edge N updates its entry
at that edge. A group request at N returns after edge N+1: group 0 is
hidden[0..6] with mask `1111111`; group 1 is hidden[7] in lane 0 with mask
`0000001`. Reset clears all entries and response outputs.

#### Steps and checks

- **STEP-026:** Reset ten entries and all group-response registers.
- **STEP-027:** Implement writes only for addresses 0..7 and ignore reserved addresses.
- **STEP-028:** Implement one-cycle group reads, exact lane ordering/masks, and consecutive requests.

Check every hidden address, both group addresses, reserved writes, reset, and
read-after-write timing.

### 3.9 `relu`

#### Responsibility and official ports

Official ports are `data_in[15:0]`, `valid_in`, `data_out[15:0]`, and
`valid_out`, all in the directions listed in `relu.md`. This is a stateless
combinational module with one `always_comb` block and no reset or clock.

#### Behavior and steps

Default data_out is positive zero and valid_out equals valid_in. When valid,
inspect the FP16 sign bit: sign 1 produces `16'h0000` (including negative
zero and negative infinity); sign 0 passes the exact input bits. The supplied
data are finite; the selected extension policy maps a negative-sign NaN to
positive zero and a nonnegative-sign NaN unchanged.

- **STEP-029:** Implement complete combinational defaults and valid propagation.
- **STEP-030:** Implement sign-bit ReLU and negative-zero normalization.

Check positive/negative finite values, both zeros, invalid input, and the
documented special-value extension.

### 3.10 `argmax`

#### Responsibility and official ports

Official ports are exactly those in `argmax.md`: `clk`, `rst`, `start`,
`logit_valid`, `logit_in[15:0]`, `logit_index[3:0]`, `logit_last`, `busy`,
`prediction[3:0]`, `done`, and ten 16-bit stable logit outputs.

#### Registers, blocks, and states

Own ten logit registers, `best_logit`, `best_index`, `seen_valid`, busy,
prediction, and done. Use one `always_ff` and one `always_comb`. States are
`IDLE` and `COLLECT`; DONE is a one-cycle pulse, not a persistent state.

#### Timing and boundaries

An accepted start at edge N clears previous logits and comparison state.
Each valid index 0..9 writes its indexed output. The first valid sample
initializes the maximum; later samples replace it only on strict FP16
greater-than. Equality retains the earlier index. The final valid sample
with logit_last is compared using its new value before prediction is
registered; done pulses for one cycle, and outputs remain stable until the
next accepted start or reset. Invalid indices and invalid last markers are
ignored. A start while collecting is ignored. For the finite supplied data,
FP16 ordering is ordinary signed numerical ordering; the extension policy
uses NaN-never-greater semantics and canonicalizes no stored logits.

#### Steps and checks

- **STEP-031:** Implement IDLE start acceptance, storage clearing, and COLLECT entry.
- **STEP-032:** Implement indexed logit writes and strict-greater comparison with first-sample initialization.
- **STEP-033:** Include the final sample, pulse done once, hold outputs stable, and recover/reset correctly.

Test increasing, decreasing, tied, final-sample-winning, invalid-index,
invalid-last, busy-start, reset, and stable-after-done sequences.

## 4. Arithmetic plan

The design uses exactly one sequentially reused FP16 multiply datapath in
`fp16_multiplier` and exactly one sequentially reused FP16 add datapath in
`fp16_accumulator`. The helpers operate on 16-bit bit patterns and never
convert to a software floating type or a hidden FP32 running sum.

### 4.1 Binary16 decode and encoding

Decode sign bit `s`, five-bit exponent field `E`, and ten-bit fraction `F`.
For normal values (`1<=E<=30`) use an eleven-bit significand with an implicit
leading one and an unbiased exponent `E-15`. For subnormals (`E=0,F!=0`),
use a zero exponent with no implicit leading one, then left-normalize the
significand while decrementing the effective exponent. For zero (`E=0,F=0`)
the significand is zero. `E=31` denotes infinity when `F=0` and NaN when
`F!=0`.

### 4.2 Multiply helper

For each valid lane, multiply the two eleven-bit significands to a 22-bit
unsigned product, use sign XOR, and add the two effective exponents. Normalize
the product so the leading one is in the binary16 normal position; retain
guard, round, and sticky information. Round to nearest, ties to even by
examining the guard bit and the OR of round/sticky bits plus the retained
least-significant bit. A carry from rounding renormalizes the significand and
increments the exponent. If the exponent overflows, return signed infinity.
If it underflows, right-shift into the subnormal range with a sticky bit and
apply the same round-to-nearest-even rule; a rounded subnormal that reaches
the normal threshold is encoded as the smallest normal. Exact zero inputs
return zero with sign XOR, except an exact cancellation is handled by the
add helper’s zero-sign rule. A finite result is encoded with its rounded
exponent and fraction.

### 4.3 Add helper

Decode both operands, propagate a quiet NaN if either is NaN, and handle
infinity before finite alignment. Opposite-signed infinities produce the
canonical quiet NaN `16'h7E00`; one infinity otherwise passes through its
sign. For finite operands, align the smaller effective exponent to the larger
using a right shift that folds all discarded bits into sticky. Add
same-sign significands or subtract the smaller magnitude from the larger;
the sign of an exact nonzero result is the sign of the larger magnitude. An
exact cancellation returns positive zero. Normalize left after subtraction
or right after carry, then round to nearest-even using guard/round/sticky.
Overflow returns signed infinity; underflow uses the same subnormal shift and
round rule as multiplication. This is a true add after a registered/product
boundary, not an FMA.

### 4.4 Special values and project scope

Supplied memory values are finite and therefore are the primary verification
domain. The deterministic extension is: canonical quiet NaN `7E00` for
invalid operations and any NaN input; infinities follow IEEE sign unless an
invalid infinity operation occurs; exact finite cancellation is `+0`; and
multiply zero by infinity is canonical NaN. ReLU maps a negative-sign value
to positive zero as specified. Argmax treats NaN as never strictly greater.
These policies prevent X-dependent behavior without changing finite results.

### 4.5 Arithmetic steps and observables

- **STEP-034:** Implement binary16 field decode, normal/subnormal classification, and finite/special policy.
- **STEP-035:** Implement the one rounded multiply datapath, normalization, subnormal path, overflow, zero, infinity, and NaN handling.
- **STEP-036:** Implement the one rounded add datapath, exponent alignment with sticky, cancellation/normalization, overflow, subnormal, zero, infinity, and NaN handling.
- **STEP-037:** Verify product-before-add separation and bit-for-bit pure-FP16 MAC results against the supplied reference model.

Critical observables are product bits before every add, accumulator bits after
every add, no extra arithmetic instance in synthesis, and no dependence on
FP32 intermediates.

## 5. Memory and initialization plan

The testbench or synthesis wrapper owns initialization; the DUT has no
functional `initial` block. The loader checks exact nonempty-line counts and
four-hex-digit format before packing rows.

| File | Entries | Logical mapping | Physical storage |
|---|---:|---|---|
| `assests/test_image.mem` | 784 | pixel 0..783, row-major 28x28 | `input_memory.pixel_mem[0:783]` |
| `assests/fc1_weights.mem` | 6272 | `W1[n][p]`, n outer, p inner | `weight_sram.row_mem[0:895][0:6]`; row `r` holds flat entries `7r..7r+6` |
| `assests/fc1_bias.mem` | 8 | `b1[0..7]` | `bias_memory.mem[0:7]` |
| `assests/fc2_weights.mem` | 80 | `W2[d][h]`, d outer, h inner | `weight_sram.row_mem[896:907][0:6]`; row 907 lanes 0..2 valid, 3..6 padding |
| `assests/fc2_bias.mem` | 10 | `b2[0..9]` | `bias_memory.mem[8:17]` |

The row packer must preserve file order and must not pad FC2 into a logical
digit grouping. It may fill the four physical row-907 padding lanes with
zero for deterministic simulation, but the mask remains `0000111` and the
controller must never select them. Bounds checks reject short, long, malformed,
or out-of-range requests. Memory loading through a testbench `readmemh` or a
synthesis initialization mechanism is outside functional DUT behavior and is
permitted only in the wrapper/environment.

## 6. Integration and timing plan

### 6.1 Connection table

| Producer | Signal(s) | Consumer |
|---|---|---|
| `fc16_accelerator` inputs | `clk`, `rst`, `start` | controller and every sequential submodule |
| controller | input request/address | `input_memory` |
| input_memory | seven pixels, `group_valid`, mask | multiplier operand inputs / controller valid capture |
| controller | weight request/address | `weight_sram` |
| weight_sram | row, mask, `row_valid` | controller FC1 forwarding or FC2 lane gather |
| controller | bias request/address | `bias_memory` |
| bias_memory | bias value/`bias_valid` | controller capture, then accumulator `bias_in` |
| controller | selected logical weights/mask and multiplier_start | multiplier |
| controller or layer2 register file | seven input operands | multiplier |
| multiplier | product, valid, group_done | ping-pong write interface |
| ping-pong buffer | `write_ready` | controller start gating |
| controller | `consume_start` | ping-pong buffer |
| buffer | data, valid, last | accumulator product inputs and group_last |
| accumulator | `product_ready` | buffer `consume_ready` and amended controller observe |
| controller | accumulator_start, neuron_last | accumulator |
| accumulator | result/result_valid | ReLU for FC1, argmax input for FC2 |
| ReLU | hidden value/valid | layer2 register file write |
| controller | hidden write enable/address | layer2 register file |
| controller | layer2 group request/address | layer2 register file |
| layer2 register file | delayed group, valid, mask | multiplier operands and amended controller observe |
| controller | argmax start/logit valid/index/last | argmax |
| argmax | done, logits, prediction | controller/top-level outputs |

The controller is the only module that selects FC1 versus FC2 operands. The
top-level connects the one shared multiplier and one shared accumulator; no
parallel copies are allowed. All valid signals are captured only on their
specified response edge. When a port is shared by memory responses, the
controller’s state selects the owner: FC1 states accept input/weight responses;
FC2 gather states accept physical rows; FC2 operand wait accepts the hidden
response. A response outside its owning state is ignored and asserted as a
protocol error.

### 6.2 Accepted-start-to-done sequence

1. On an idle start edge, clear transient controller flags, issue FC1 bias
   request for neuron 0, and leave previous top-level logits/prediction in
   argmax until the planned argmax start.
2. For each FC1 neuron 0..7, receive its bias one edge later; for each group
   0..111 issue an input request and FC1 row request together, wait one and
   seven edges respectively, capture both, start the multiplier and (only on
   group 0) accumulator, write/consume seven products in order, and preserve
   the accumulator across all 112 groups.
3. After group 111’s final accepted product, receive the result pulse, apply
   ReLU, and write one hidden entry. Repeat for all eight neurons.
4. Start argmax once, then for each digit 0..9 load bias address 8+d. For
   logical group 0, request hidden values 0..6 and gather the required one or
   two physical FC2 rows. For logical group 1, request hidden value 7 and
   gather its single physical lane. Start the multiplier with masks
   `1111111` then `0000001`; only group 0 starts the accumulator.
5. After group 1’s final accepted product, forward the result as the digit’s
   indexed logit. Assert logit_last only for digit 9. Argmax writes each
   stable output and includes digit 9 in the strict-greater comparison.
6. On argmax done, controller pulses done for one cycle and returns idle.
   The ten logits and prediction remain unchanged until the next accepted
   start or reset. A start during any busy state is ignored.

### 6.3 Latency alignment and safety rules

The seven-cycle SRAM latency is the dominant alignment constraint. The
controller never derives a weight from the address currently being driven;
it uses only a captured `weight_row_valid` response. Input and bias responses
are likewise used only with their valid pulse. The multiplier is started only
when its seven operand inputs, selected mask, and buffer write capacity are
stable. The buffer’s `consume_data` and `consume_last` remain stable until
the accumulator’s product_ready accepts them. The accumulator’s result pulse
is consumed one controller state later, ensuring the final added product is
included. ReLU and hidden write are separated by that state boundary.

### 6.4 Top-level wrapper steps

- **STEP-038:** Declare the `fc16_accelerator` transaction ports and connect one clock/reset/start domain to the controller and every sequential submodule.
- **STEP-039:** Instantiate exactly one input memory, bias memory, weight SRAM, multiplier, ping-pong buffer, accumulator, hidden register file, ReLU, and argmax; connect the amended controller status inputs without combinational shortcuts around valid/ready contracts.
- **STEP-040:** Implement the controller-selected FC1/FC2 operand muxing, direct buffer-to-accumulator ready/valid path, ReLU hidden-write path, and indexed argmax logit path.
- **STEP-041:** Expose ten stable logits, prediction, controller busy/done behavior, and the reset/start stability rules at the wrapper boundary.

## 7. Verification handoff

The Programmer and Evaluator shall implement the following minimum tests.
Each item names the stimulus, observable result, and plan steps covered.

| Test | Stimulus | Expected observable | Steps |
|---|---|---|---|
| V-001 Reset/idle | Hold rst over an edge, then release without start | All state/status/data outputs zero or inactive; controller IDLE, no done | STEP-001, 008, 009, 013, 019, 023, 026, 031 |
| V-002 One transaction | One-cycle legal start while idle | Exactly one complete sequence, stable ten logits/prediction, one done pulse | STEP-002..005, 033 |
| V-003 Busy start | Assert start during FC1 and FC2 | No restart, no counter corruption, no second done | STEP-002, 005 |
| V-004 Input memory | Read groups 0,1,110,111,112 and consecutive legal groups | One-cycle response, ordered pixels, invalid 112 suppressed | STEP-006..008 |
| V-005 Bias memory | Read addresses 0,7,8,17,18 and consecutive requests | Exact one-cycle ordered responses and invalid suppression | STEP-013..015 |
| V-006 SRAM latency/order | Issue rows 0,895,896,906,907 on consecutive edges plus 908 | Each legal response exactly seven edges later, same order, row-907 mask `0000111` | STEP-009..012 |
| V-007 FP16 multiply | Positive/negative/zero, subnormal, halfway rounding, overflow, NaN/Inf extension | Product bits match the independent FP16 reference; invalid lane emits no product | STEP-016..018, 034..035 |
| V-008 FP16 add | Same-sign, cancellation, exponent alignment, subnormal, halfway rounding, overflow, NaN/Inf extension | Each add rounds before next; no hidden wide sum | STEP-023..025, 034,036 |
| V-009 Ordered FC1 | Use a small directed row set with distinct products and bias | 112 groups per neuron, neuron-major/pixel-major fold, final product included | STEP-002..003, 023..025 |
| V-010 Ping-pong full/empty | Queue two groups, drain with pauses, attempt third write at capacity | Oldest full group first, no overwrite/read-unwritten, ready/back-pressure correct | STEP-019..022 |
| V-011 Ping-pong partial | Close with one valid product and six invalid positions | One product read, last accompanies it, no fabricated zeros | STEP-020..021 |
| V-012 FC2 regrouping | Exercise digits whose eight weights cross physical rows, especially d=1,6,9 | Logical hidden order 0..6 then 7; row 907 only lane 2 for digit 9 hidden 7 | STEP-004, 028 |
| V-013 Hidden storage | Write all eight hidden values, read both groups repeatedly | Values persist through all ten digits; exact masks and one-cycle read latency | STEP-026..028 |
| V-014 ReLU | Positive, negative, +0, -0, invalid, extension special values | Negative and -0 become `0000`; positive bits unchanged; valid propagated | STEP-029..030 |
| V-015 Argmax ties | Increasing, decreasing, equal logits, final sample is maximum | Strict greater only; lowest tied digit; final sample included; one done | STEP-031..033 |
| V-016 Golden end-to-end | Load all supplied `.mem` files and compare bit patterns | FC1 `46BF C10A 4BB5 44D8 4840 4706 4386 C2DF`; hidden `46BF 0000 4BB5 44D8 4840 4706 4386 0000`; logits `411B C2BB 4844 43EB CD2B 43E8 444E CAA1 3310 CAD4`; prediction 2 | STEP-034..041 and all module steps |

The golden vector in V-016 is the pure-FP16 result computed from the supplied
reference model; it is a check value, not a replacement for a cycle-accurate
test. The testbench must also assert that all ten logits and prediction remain
stable after done until the next accepted start/reset.

## Programmer contract

Produce synthesizable SystemVerilog-2012 in `06_2_programmer.v`. It must
contain the ten named submodules (`controller_fsm`, `input_memory`,
`weight_sram`, `bias_memory`, `fp16_multiplier`, `ping_pong_buffer`,
`fp16_accumulator`, `layer2_register_file`, `relu`, and `argmax`) plus the
top-level `fc16_accelerator` wrapper and the single FP16 arithmetic helper
implementation. Preserve every official port name, direction, and width;
implement exactly the five explicitly amended controller inputs and document
them in a file comment. Do not add undocumented ports, functional initial
blocks, delays, real numbers, software floating point, FMA, parallel
multiplier/adders, or alternate memory ordering.

Each implementation block must carry one or more comments of the exact form
`// STEP-xxx` matching this plan’s stable IDs. The Programmer must report any
deviation from this plan, including an interface, state, latency, arithmetic,
or memory-loading deviation, instead of silently changing behavior. The
wrapper may expose internal memories for the testbench, but the transaction
ports remain `clk`, `rst`, `start`, one-cycle `done`, ten 16-bit logits, and
4-bit prediction.

## Reviewer contract

The Reviewer must compare the code line-by-line with this plan and verify:

1. Every official port and the five amended controller inputs are present with
   exact widths and ownership; no hidden interface substitution exists.
2. Every register, memory, counter, state, pulse, and output has one owner,
   reset value, and one planned `always_ff`/`always_comb` role.
3. Every listed FSM state and legal transition is implemented, including
   bounded FC1/FC2 counters, FC2 row gathering, hidden writes, logit transfer,
   completion, and illegal-state recovery.
4. Input/bias one-cycle timing and weight seven-edge timing are exact under
   consecutive requests and reset flushing.
5. Product-before-add FP16 rounding, subnormal/normalization behavior, no
   FMA, no FP32 accumulator, and exactly one reusable multiplier/adder are
   demonstrable in simulation and synthesis structure.
6. Ping-pong oldest-full ordering, write closure, partial groups, same-edge
   read/write restriction, and data stability under consumer back-pressure
   match the contract.
7. FC2 formula, cross-row regrouping, logical group masks, and physical row
   907 padding exclusion are exact.
8. ReLU negative-zero normalization, argmax strict-greater tie behavior,
   final-sample inclusion, stable outputs, and one-cycle done are exact.
9. All V-001 through V-016 checkpoints are present, and any failure is
   returned to the Programmer/Evaluator rather than waived.

## Open issues and stop conditions

### Safe assumptions

- The top-level wrapper name is `fc16_accelerator`, with the transaction
  interface stated in the Programmer contract.
- Memory contents are supplied by the testbench or synthesis wrapper, not by
  functional DUT `initial` blocks.
- The finite supplied data are the required conformance domain; the explicit
  NaN/infinity extension is deterministic but not used to alter finite golden
  results.
- `buffer_full` retains the blueprint’s consumer-side meaning (at least one
  full half), not “all write storage is full.”

### Implementation notes (non-blocking)

- The selected SystemVerilog tool must support synthesizable variable shifts
  and leading-zero detection for the explicitly specified FP16 helper. If it
  does not, the Programmer must use an equivalent synthesizable structural
  implementation and report that deviation; no FP library substitution is
  permitted.

## Readiness verdict

READY FOR PROGRAMMER — the controller status interface is now explicitly
defined and propagated through the controller blueprint, partitioning,
Section 3 specification, and this plan.
