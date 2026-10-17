# Ping-Pong Buffer Specification

## Purpose

The `ping_pong_buffer` stores the FP16 products produced by the reusable
multiplier until the reusable accumulator can consume them. It has two
independent seven-entry halves. While one half is being filled, the other can
be read, allowing product generation and accumulation to overlap.

The buffer stores and returns 16-bit FP16 bit patterns; it does not perform
multiplication, addition, rounding, ReLU, or control of the neural-network
layers.

## Module interface

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

- `clk` is the positive-edge clock.
- `rst` is synchronous and active high.
- `product_valid` indicates that `product_in` is a real multiplier product.
- `product_in` is written only when `product_valid` and `write_ready` are both
  high at a rising edge.
- `product_last` marks the final position of the current seven-position
  multiplier group. That position may be invalid, so it does not necessarily
  add an entry.
- `write_ready` indicates that the current write half has room for a valid
  product.
- `consume_start` asks the buffer to begin reading a completed half.
- `consume_ready` indicates that the accumulator can accept the presented
  product.
- `consume_valid` and `consume_data` present the next stored product.
- `consume_last` accompanies the final stored valid product of the group.
- `buffer_full` indicates that both halves are unavailable for another valid
  write. `buffer_empty` indicates that no completed or actively read product
  is available to the consumer.

## Storage and roles

Each half contains seven FP16 entries, a valid-product count, a write index,
and a read index. A half has one of four logical roles:

| Role | Meaning |
|---|---|
| `EMPTY` | No group is stored; the half may be selected for writing. |
| `WRITING` | A multiplier group is being collected in producer order. |
| `FULL` | `product_last` has closed the group and its products await reading. |
| `READING` | The accumulator is receiving the stored products in order. |

At most one half is written and at most one half is read at a time. The two
roles must use different halves, but a write and a read may occur in the same
clock cycle on different halves. A completed group is not read until its
`product_last` event has been accepted. A half is not reused for writing until
its final stored product has been consumed.

## Write behavior

After reset, an empty half is selected for the first group. While a half is
`WRITING`, each accepted valid product is stored at the next free entry and
the valid count is incremented. Invalid multiplier positions
(`product_valid=0`) are skipped and do not store a zero or advance the count.

When `product_last=1`, the current group closes. If the final position is
valid, that product is written before the half becomes `FULL`; if it is
invalid, the half becomes `FULL` with the products already collected. The
normal group has seven valid products, while the final second-layer group may
contain only one valid product.

If `product_valid=1` while `write_ready=0`, the product is not accepted and no
state changes. The multiplier must keep `product_valid`, `product_in`, and
`product_last` stable until a later cycle in which `write_ready=1`. A group
must never provide more than seven valid products; an eighth product cannot be
stored without overwriting existing data.

## Read behavior

`consume_start` selects the oldest completed (`FULL`) half. It is a control
request, not a product transfer, so the first product is presented after the
request is accepted. While a half is `READING`, `consume_valid` is asserted
and `consume_data` remains stable until `consume_ready` is asserted.

A product is removed only on a rising edge where
`consume_valid && consume_ready` are both high. Products are presented in the
same order in which they were accepted from the multiplier. `consume_last` is
high with the final stored valid product. After that transfer, the half becomes
`EMPTY` and may be selected for a later group.

`consume_start` is ignored if no half is `FULL` or if another half is already
being read. `consume_ready` without `consume_valid` has no effect.

## Status signals

`buffer_empty` is high when neither half is `FULL` nor `READING`; a partially
filled `WRITING` half is not yet readable. It is low as soon as a completed
group is waiting or being drained.

`buffer_full` is high when neither half can accept another valid product. It
is low if an empty half is available or the active writing half still has a
free entry. Thus one full/read half and one writable half do not make the
buffer full.

## Reset behavior

On every rising edge with `rst=1`, both halves become `EMPTY`. All stored
entries, counts, pointers, and role-selection state are cleared. Outputs are
set to safe defaults:

```text
write_ready   = 0
consume_valid = 0
consume_data  = 16'h0000
consume_last  = 0
buffer_full   = 0
buffer_empty  = 1
```

No product or consume request is accepted on a reset edge. Once reset is
released, `write_ready` may assert for an available empty half.

## Surrounding-module expectations

The multiplier must hold a valid product until `write_ready` is asserted and
must mark the end of every group with `product_last`. The accumulator must
hold `consume_ready` low when it cannot accept data and must consume products
only when `consume_valid` is high. The controller must start reads only for
completed groups and must not assume that a half can be written on the same
edge on which its final read is accepted.

