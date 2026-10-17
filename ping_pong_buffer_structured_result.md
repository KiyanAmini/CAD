# `ping_pong_buffer` behavioral specification

## 1. Responsibility and non-responsibilities

`ping_pong_buffer` is the ordered, two-half storage interface between the
reusable FP16 multiplier and the FP16 accumulator. It accepts valid multiplier
products, stores them in producer order, closes each seven-position group at
`product_last`, and later presents the stored valid products in exactly that
order to the accumulator.

The storage capacity is two independent halves of seven 16-bit entries each.
One half may be collecting a group while the other is being drained. A half
cannot be written while it contains unread data, and a half cannot be read
before its group has been closed.

The module does not multiply, add, round, interpret, or compare FP16 values.
It does not generate products, perform bias handling, perform ReLU, identify a
neuron or digit, or decide the order in which groups are created. It stores and
returns each accepted 16-bit FP16 bit pattern unchanged.

## 2. Port semantics table

All ports are sampled or driven relative to the positive edge of `clk`. `rst`
is synchronous and active high. A request accepted at rising edge `N` changes
the registered state visible in the following cycle; accepting
`consume_start` does not also consume the first product at edge `N`.

| Port | Direction / width | Semantics |
|---|---|---|
| `clk` | input, 1 bit | Positive-edge clock for all state changes. |
| `rst` | input, 1 bit | Synchronous active-high reset. It has priority over every other input. |
| `product_valid` | input, 1 bit | When high, `product_in` is a real FP16 product for the current multiplier position. When low, `product_in` is ignored. |
| `product_in` | input, 16 bits | FP16 product bit pattern to append when a write is accepted. |
| `product_last` | input, 1 bit | Marks the final position of the current seven-position group. The final position may be invalid (`product_valid=0`). |
| `write_ready` | output, 1 bit | High when the selected write half can accept the current write-side event. A valid product is accepted only on an edge where both `product_valid` and `write_ready` are high. |
| `consume_start` | input, 1 bit | Requests that the oldest completed (`FULL`) half become the active read half. It is not itself a product transfer. |
| `consume_ready` | input, 1 bit | High when the accumulator accepts the product currently presented by the buffer. |
| `consume_valid` | output, 1 bit | High while a `READING` half has an unread product presented. |
| `consume_data` | output, 16 bits | The currently presented product bit pattern in original producer order. Meaningful only when `consume_valid=1`. |
| `consume_last` | output, 1 bit | High with the final valid product of the active group; never asserted for padding or another invalid position. |
| `buffer_full` | output, 1 bit | Capacity status: high when no half can accept another valid product for a new or currently open group. This specification makes that meaning explicit because the port name alone is otherwise ambiguous. |
| `buffer_empty` | output, 1 bit | Data-availability status: high when no `FULL` or `READING` half contains a product available to the consumer. A partially written group does not clear `buffer_empty`. |

## 3. Storage and state model

The module contains two halves, numbered 0 and 1. Each half contains:

- seven FP16 storage entries indexed 0 through 6;
- a valid-entry count from 0 through 7;
- a write position for the next accepted valid product;
- a read position for the next product to present; and
- one logical state from `EMPTY`, `WRITING`, `FULL`, or `READING`.

The states mean:

| State | Meaning |
|---|---|
| `EMPTY` | The half has no completed group and no unread product. It is eligible to be selected for a future group. |
| `WRITING` | The half owns the current open group and is collecting valid products in arrival order. Its count is the number already stored. |
| `FULL` | `product_last` has closed the group and at least one valid product is waiting. The half is not yet being presented to the accumulator. |
| `READING` | The half was selected by `consume_start` and is presenting one stored product at a time. |

At most one half is `WRITING` and at most one half is `READING`. Those roles
may coexist, but they must refer to different halves. A `FULL` half is ordered
by group-completion time; `consume_start` selects the oldest completed group.
The write-side selector retains the current `WRITING` half until its group
closes. If no group is open, it selects an eligible `EMPTY` half according to
the deterministic selection policy agreed with the controller.

## 4. Complete state-transition table

The table describes events at a rising edge with `rst=0`. “Accepted” means
that the input event changes architectural state at that edge and its result is
visible in the following cycle.

| Current condition | Input condition at the edge | Required transition and result after the edge |
|---|---|---|
| `EMPTY` write candidate | `product_valid=0`, `product_last=0` | No write occurs; the half remains `EMPTY`. |
| `EMPTY` write candidate | `product_valid=1`, `write_ready=1`, `product_last=0` | Store `product_in` at entry 0, set count to 1, and enter `WRITING`. |
| `EMPTY` write candidate | `product_valid=1`, `write_ready=1`, `product_last=1` | Store the first product at entry 0, set count to 1, and enter `FULL`; the group contains one valid product. |
| `WRITING` with count < 7 | `product_valid=0`, `product_last=0` | Do not change data, count, or position; remain `WRITING`. |
| `WRITING` with count < 7 | `product_valid=1`, `write_ready=1`, `product_last=0` | Store at the next free entry, increment the count, and remain `WRITING`. |
| `WRITING` with count < 7 | `product_valid=1`, `write_ready=1`, `product_last=1` | Store the product, increment the count, and enter `FULL`. |
| `WRITING` with count > 0 | `product_valid=0`, `product_last=1` | Store no data and enter `FULL` with the existing count. This is the normal partial-group/padding close. |
| `WRITING` with count = 0 | `product_valid=0`, `product_last=1` | Protocol violation: a zero-valid group has no product that can carry `consume_last`. No normal consumer-visible group is defined; verification must flag this case. |
| Any write state | `product_valid=1`, `write_ready=0` | The product is not accepted, no state or memory entry changes, and the producer must hold `product_valid`, `product_in`, and `product_last` until a later accepting cycle. |
| `FULL` | `consume_start=0` | Remain `FULL`; all stored data and completion ordering remain unchanged. |
| `FULL` and no active reader | `consume_start=1` | Select the oldest `FULL` half, set its read position to entry 0, and enter `READING`. Its first product is presented in the following cycle. |
| `FULL` while another half is `READING` | `consume_start=1` | Ignore the request; the current read cannot be interrupted or reordered. |
| `READING` | `consume_valid=1`, `consume_ready=0` | Hold `consume_data`, `consume_last`, read position, and count stable. |
| `READING` | `consume_valid=1`, `consume_ready=1`, `consume_last=0` | Remove the presented product, advance the read position, decrement the remaining count, and remain `READING`. |
| `READING` | `consume_valid=1`, `consume_ready=1`, `consume_last=1` | Remove the final product and enter `EMPTY` after the edge. The half is not reusable during that same edge. |
| No `FULL` half | `consume_start=1` | Ignore the request; no product becomes valid. |
| Any state | `consume_ready=1`, `consume_valid=0` | No read occurs and no state changes. |

Write-side and read-side events may be accepted on the same edge when they
refer to different halves. A half that becomes `EMPTY` after its final read is
eligible for writing only in the following cycle.

## 5. Write-side timing and rules

`write_ready` is asserted when the selected write half can accept the current
group position without overwriting unread data. A `WRITING` half is writable
while its count is below seven. If no group is open, an eligible `EMPTY` half
may be selected. A valid product is transferred only on the handshake
`product_valid && write_ready` at a rising edge.

The multiplier presents positions 0 through 6 in order. Valid positions are
appended consecutively; invalid positions create no storage entry and do not
increment the count. `product_last` closes the group after processing the
current position, whether that position was valid or invalid. The usual full
group closes when position 6 is valid and carries `product_last=1`; a partial
group closes when a later position carries `product_last=1` with
`product_valid=0`.

When `write_ready=0`, the buffer must not silently drop or partially accept a
valid product. The producer must hold the complete write-side event until a
later cycle. More than seven accepted valid products in one group is outside
the protocol; no eighth product may overwrite an existing entry.

## 6. Read-side timing and rules

`consume_start` is a request, not a data transfer. When accepted for the
oldest `FULL` half at edge `N`, the half becomes `READING` and presents entry 0
during the following cycle. `consume_valid` remains high while an unread entry
is presented. `consume_data` and `consume_last` are stable during backpressure.

A product is removed only when `consume_valid && consume_ready` are both high
at a rising edge. Non-final transfers advance through the stored entries in
their original order. `consume_last` is high exactly when the current read
position is the final stored valid entry. The final transfer changes the half
to `EMPTY` after the edge and produces no fabricated transfer for unused
positions.

`consume_start` while a read is active is ignored. `consume_start` with no
completed half is ignored. `consume_ready` while `consume_valid=0` has no
effect.

## 7. Full/empty and role-swap rules

The roles are independent: one half may be `WRITING` while the other is
`FULL`, `READING`, or (when no group is available) `EMPTY`. A group becomes
readable only after its `product_last` event has been accepted and the half has
entered `FULL`. A reading half cannot be selected for a new write, and a full
half cannot be selected for writing.

`buffer_empty` is high exactly when neither half is `FULL` nor `READING`.
Therefore it is high for two `EMPTY` halves and while only a partial `WRITING`
group exists; it is low as soon as a completed group is waiting or being
drained.

For this specification, `buffer_full` uses capacity semantics: it is high when
there is no half able to accept another valid product. This includes two halves
that are `FULL`/`READING`, and a sole writable `WRITING` half whose count has
reached seven. It is low if at least one `EMPTY` half is available or the
current `WRITING` half still has a free entry. A completed `FULL` half may
coexist with a writable `WRITING` half, so `buffer_full` is then low.

After a `WRITING` half closes, the other `EMPTY` half may be selected in the
next cycle; the closed half is not written again until its entire group has
been consumed. After a `READING` half transfers its final product, it becomes
eligible only after that edge, preventing same-edge overwrite.

The two-half capacity is never enlarged. Group completion order is preserved
when both halves are full: the consumer starts the half whose `product_last`
was accepted first.

## 8. Reset and default outputs

On every rising edge for which `rst=1`, reset has priority over all write and
read inputs. Both halves become `EMPTY`; all seven entries in each half,
counts, write/read positions, role selectors, completion-order bookkeeping,
and validity flags are cleared.

During and immediately after the reset edge, the required externally visible
defaults are:

| Output | Reset value |
|---|---:|
| `write_ready` | `0` while reset is asserted; after reset is released it may assert for an eligible empty half. |
| `consume_valid` | `0` |
| `consume_data` | `16'h0000` |
| `consume_last` | `0` |
| `buffer_full` | `0` |
| `buffer_empty` | `1` |

Reset discards a partially written group and a partially read group. No input
present on the reset edge is accepted. Once `rst` is low, the empty-buffer
selection rules resume.

## 9. Invalid-input and corner-case behavior

- `product_valid=0`: `product_in` is ignored and no entry is written.
- Invalid padding positions are skipped, not stored as zero products, and do
  not appear at the consumer interface.
- `product_last=1` with `product_valid=0` closes a nonempty open group without
  writing an entry.
- A valid write attempted while `write_ready=0` is not accepted; the producer
  must hold it. The buffer never overwrites a `FULL` or `READING` half.
- A group with more than seven valid products is a protocol error. The eighth
  product must not be written, and the multiplier schedule must be corrected.
- A group closed with zero valid products is also a protocol error because the
  interface has no valid item on which to assert `consume_last`.
- `consume_start` with no `FULL` half, or while another half is `READING`, is
  ignored.
- `consume_ready` without `consume_valid` is an underflow attempt and has no
  effect.
- Requests and data on invalid cycles are ignored. Deterministic zero output
  when `consume_valid=0` is required, but the consumer must rely on
  `consume_valid` rather than the data bits.
- FP16 overflow, underflow, signed zero, subnormal, infinity, and NaN bit
  patterns are not interpreted by this module. Whatever 16-bit pattern the
  multiplier supplies is preserved exactly.

## 10. Interface assumptions and open issues

The surrounding multiplier must hold `product_valid`, `product_in`, and
`product_last` unchanged whenever `write_ready=0`; otherwise lossless flow
control is impossible with only two seven-entry halves. It must emit at most
seven valid products per group and must eventually assert `product_last`.

The accumulator must assert `consume_ready` only when it can accept one
product and must hold it low when backpressured. The controller must not depend
on a same-edge reuse of a half, must issue `consume_start` only for completed
groups, and must preserve the group-completion ordering requirement.

The structured requirements leave these interface decisions unstated and they
must be resolved before RTL freeze:

1. **Write-half selection policy.** The contract requires a deterministic
   eligible-half choice but does not mandate lower-index, round-robin, or
   another policy. The controller must not depend on a particular choice
   unless one is fixed explicitly.
2. **Meaning of `buffer_full`.** This specification resolves the ambiguity as
   “no write capacity.” If surrounding RTL instead expects “a completed half
   is available,” the port name and contract must be revised consistently.
3. **Zero-valid group recovery.** There is no error output and no representable
   `consume_last` transfer for an empty group. The supplied schedule must
   forbid it, or an explicit discard/error policy must be added.
4. **Overflow reporting.** The interface has no error signal for an eighth
   valid product or an end marker without an open group. Verification should
   assert these protocol violations, or an error response must be added.
5. **Completion-order metadata.** If both halves can become `FULL` before the
   consumer starts either, the implementation needs a completion-age bit or
   equivalent mechanism. The controller may not infer age from half number.

