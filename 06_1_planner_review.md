# Review of `06_1_planner.md`

## Verdict

The Planner output is approved for the Programmer stage. The controller
status-interface amendment has been applied consistently to the controller
blueprint, partitioning, Section 3 specification, Section 5 revision note, and
the Section 6 planner. The FC2 gather wording has also been corrected to wait
only for lanes marked valid by the current logical-group mask.

## Confirmed correct items

- Network dimensions and operation order are correct.
- Pure-FP16 product-before-add rounding is preserved.
- FC1 and FC2 memory dimensions and ordering are correct.
- The seven-cycle weight-SRAM latency is correctly retained.
- Physical row 907 is correctly identified as `7'b0000111`.
- The FC2 mapping `flat_index=8*d+h`, `row=896+floor(flat/7)`,
  `lane=flat%7` is correct.
- The FC2 logical grouping (hidden 0..6, then hidden 7 with mask
  `7'b0000001`) is correct.
- Ping-pong ordering, partial-group handling, and back-pressure requirements
  are correctly carried forward.
- Bias-first accumulation, ReLU negative-zero normalization, strict-greater
  argmax, and stable post-`done` outputs are correct.
- The golden vector in V-016 was independently checked against
  `assests/test.py`; it matches the supplied pure-FP16 reference and predicts
  digit 2.

## Previously blocking issue — resolved

The original `controller_fsm` blueprint had no inputs for:

```text
bias_valid
layer2_group_valid
buffer_full
buffer_consume_valid
buffer_consume_ready
```

Without equivalent signals, the controller cannot reliably:

- distinguish a valid bias response;
- distinguish a valid layer-two hidden-group response;
- start consuming only when a full ping-pong half exists; or
- qualify `buffer_consume_last` with an actual accepted final-product
  handshake under back-pressure.

The Planner’s five-input amendment is technically justified and is now the
approved official interface. The Programmer must preserve the original ports
and add exactly those five inputs, connecting them to their real producers.

## Required wording correction — P1

In the `controller_fsm` `FC2_WEIGHT_GATHER` state, the Planner says:

> “All seven logical lane selections and `layer2_group_valid` seen”

That is ambiguous and can cause a deadlock for logical group 1, which contains
only one valid product. The required condition is:

> “Every lane marked valid for the current logical group has been captured, the
> selected-weight mask is complete, and `layer2_group_valid` has been observed.
> Invalid lanes are intentionally not captured or awaited.”

For group 0, the required mask is `7'b1111111`; for group 1, it is
`7'b0000001`.

## Non-blocking observations

1. The NaN/infinity behavior is an explicitly documented extension beyond the
   finite supplied data. It is acceptable, but should remain labeled as a
   deterministic extension rather than a requirement derived from the golden
   model.
2. The `fc16_accelerator` wrapper name is an assumption because no official
   top-level module name was supplied. It is safe only if the course harness
   accepts that name or the name is changed before Programmer handoff.
3. The memory-loading plan is consistent with the no-functional-`initial`
   restriction, provided loading remains in the testbench/synthesis wrapper.
4. The Planner’s arithmetic plan is detailed enough for a Programmer, but the
   eventual Reviewer must check the actual bit-level implementation rather than
   accepting the prose description.

## Safe handoff condition

The Planner output is safe to forward because:

1. the five controller status signals are approved and documented; and
2. the FC2 gather completion condition waits only for valid logical lanes.

**READY FOR PROGRAMMER.**
