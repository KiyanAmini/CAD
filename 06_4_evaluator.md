# 06_4 Evaluator Report

Scope: evaluation of `06_2_programmer.v` (and `06_2_programmer_tb.sv`) against
`context.md` / `01_context.md`, `spec.md_03`, `06_1_planner.md` and the reviewer
report `06_3_reviewer.md`.

## 1. Execution environment and what could / could not be run

| Item | Status |
|---|---|
| Verilog simulator (`iverilog`, `vvp`, Verilator, ...) | **Not available** in the evaluation sandbox (no network route to apt/PyPI/conda, no simulator preinstalled). `06_2_programmer_tb.sv` and `tests/fc16_unit_tb.sv` therefore were **not executed** here. |
| Python 3 + numpy | Available. Used for the golden model and for a line-by-line Python transliteration of `fp16_pkg::fp16_mul/fp16_add` (`tools/fp16_arith_check.py`). |
| Supplied assets | Present and well-formed: 6272 / 8 / 80 / 10 / 784 lines in `fc1_weights.mem`, `fc1_bias.mem`, `fc2_weights.mem`, `fc2_bias.mem`, `test_image.mem`. |

Consequence: every statement below that says "verified" refers to the Python
golden model and to the Python transliteration of the RTL arithmetic. Statements
about cycle-accurate RTL behaviour (23,931-cycle completion, `TESTBENCH PASS`)
are those recorded in `06_3_reviewer.md`; they were **not reproduced** by this
Evaluator. The exact commands to reproduce them are in section 6.

## 2. Evidence collected

### 2.1 Golden model (pure FP16, `MODE="fp16"`)

Re-computed with numpy using the same loop order as `assests/test.py`:

```text
fc1    : 46bf c10a 4bb5 44d8 4840 4706 4386 c2df
hidden : 46bf 0000 4bb5 44d8 4840 4706 4386 0000
logits : 411b c2bb 4844 43eb cd2b 43e8 444e caa1 3310 cad4
digit  : 2
```

These logits are identical to the constants hard-coded in
`06_2_programmer_tb.sv` (`expected_logits[0..9]`), so the testbench oracle is
correct.

### 2.2 Differential test of the RTL arithmetic against numpy float16

`tools/fp16_arith_check.py` transliterates the arithmetic of `fp16_pkg` and
compares it with `np.float16` multiply and add.

| Version of the arithmetic | Directed edge pairs | Random finite pairs | Network replay |
|---|---|---|---|
| As delivered by the Programmer (before this evaluation) | not covered by earlier tests | **17 multiply mismatches / 148,608** | matches (the supplied image does not hit the defect) |
| After the corrections in section 4 | 0 / 190,096 | 0 / 150,000 | logits and digit match section 2.1 |

## 3. Findings (deviations from `context.md`)

### EVAL-001 (P1, functional) - double rounding / exponent skew in `fp16_mul` for tiny products

- Requirement: `context.md` section 2 ("every multiply result is rounded to
  FP16"), section 9 ("bit-for-bit" match with `test.py`).
- Symptom: for some products in or just below the subnormal range the RTL result
  is exactly twice the correct value, e.g. `0x0c55 * 0x2763` -> RTL `0x0100`,
  reference `0x0080`; `0x1155 * 0x0600` -> RTL `0x0002`, reference `0x0001`.
- Root cause: the multiplier first rounded the 11-bit significand and, if that
  rounding carried (`main_sig >= 2048`), incremented `expv`. The subnormal branch
  then used the *incremented* exponent together with the *un-incremented*
  `work` value, so the shift was one position too small. Independently, deciding
  "normal vs. subnormal" after a normal-precision rounding is double rounding.
- Why the supplied test did not see it: the golden image does not produce such a
  product; the defect needs a result that rounds across the subnormal boundary
  (frequency about 1e-4 per random pair). Another image could hit it.
- Correction applied: the branch is now decided on the pre-rounding exponent
  (`expv < -14`); in that case the unrounded significand is shifted to the -14
  boundary and rounded exactly once. The same restructuring was applied to both
  sign paths of `fp16_add` (the carry/exponent skew has the same structure,
  although no mismatch was observed there).
- Verification: 0 mismatches over 340k pairs (section 2.2).

### EVAL-002 (P2, compliance) - `(-0) + (-0)` returned `+0`

- Requirement: IEEE-754 round-to-nearest, bit-exact with numpy (`context.md`
  sections 2 and 9). `(-0)+(-0) = -0`; any other zero sum is `+0`.
- Correction applied: `fp16_add = {a[15] & b[15], 15'h0000}` for the both-zero
  case. Verified by the directed edge sweep.

### EVAL-003 (P2, verification gap) - Section 9 items not covered by the testbench

`06_2_programmer_tb.sv` checks the end-to-end transaction (items 2, 6, 7 of
`context.md` section 9) and that a start while busy is ignored. It does not
check: (1) reset behaviour, (3) SRAM seven-cycle latency, (4) product and
ordered-accumulation correctness in isolation, (5) ReLU. The reviewer table
listed V-004..V-006, V-010..V-012, V-014 and V-015 as NOT RUN.

- Correction applied: new `tests/fc16_unit_tb.sv` plus
  `tests/fp16_vectors.mem` (4096 numpy-derived multiply/add vectors) covering
  FP16 arithmetic, SRAM latency and row-907 mask, ReLU, argmax tie-breaking and
  one-cycle `done`, and mid-transaction synchronous reset.
- Status: written but **not executed** (no simulator here). It must be compiled
  and run with the commands in section 6.

### EVAL-004 (P3, performance) - cycle count

Completion takes about 23.9k cycles (value recorded by the reviewer; consistent
with a static estimate of ~26 cycles per 7-product group x 896 groups plus the
FC2 phase). The controller serialises request, 7-cycle SRAM latency, 7 multiplier
cycles and 7 accumulator cycles for every group, so the ping-pong buffer never
overlaps multiplication with accumulation. `spec.pdf` states that the clock-cycle
count is part of the grade. A pipelined controller (prefetch the next row while
the current group is multiplied/accumulated) could reach roughly 7 cycles per
group (about 6.3k-6.5k cycles in total). This was **not** implemented: it is a
controller redesign that cannot be validated without a simulator, and the
current design is functionally compliant.

### EVAL-005 (P3, deliverables) - items required by `HW1.pdf` / `spec.pdf` that were missing

| Required deliverable | State before evaluation | Action |
|---|---|---|
| `01_context.md` | present | - |
| `partitioning.md_02` + diagram in `sub_modules.zip` | markdown present, no image, no zip | `diagrams/datapath.svg/png`, `sub_modules.zip` created |
| `spec.md_03` | present | - |
| `prompt_before_after.md_04` | present, both prompts, results and analysis | - |
| `plan.md_05` + `code.v_05` | `plan.md_05` present; code only as `code.md` | `code.v_05` extracted from `code.md` |
| `06_1_planner.md`, `06_2_programmer.v`, `06_3_reviewer.md` | present | - |
| `06_4_evaluator.md` | **missing** | this file |
| datapath and FSM figures next to the code (`spec.pdf`) | missing | `diagrams/datapath.*`, `diagrams/controller_fsm.*` |
| `CAD_CA1_<SID1>_<SID2>.zip` | not built | needs the two student numbers; see section 7 |

## 4. Corrections made by the Evaluator

1. `06_2_programmer.v`: single-rounding subnormal handling in `fp16_mul` and in
   both sign paths of `fp16_add`; correct signed-zero result in `fp16_add`.
2. `tests/fc16_unit_tb.sv`, `tests/fp16_vectors.mem`, `tools/fp16_arith_check.py`.
3. Missing deliverables of section 3 (EVAL-005).

No port, FSM state or module boundary was changed, so the Reviewer's
interface table and step traceability (`06_3_reviewer.md`) remain valid; only
the lines of `fp16_mul`/`fp16_add` moved.

## 5. Analysis of model deviation (Evaluator's view)

The Programmer's arithmetic passed the supplied image because the dominant
paths (normal x normal -> normal) were right; the failure needed a rare
combination (rounding carry at the subnormal boundary). This is the typical LLM
failure the assignment describes: a local fix (REV-002) repaired the visible
symptom (`0001*3c00`) but left the structural cause (decision after rounding).
Directed vectors against an independent oracle, rather than a single golden
image, are what exposed it. The Planner/Reviewer chain also did not require
bit-exact unit vectors for the helper functions (V-007/V-008 listed only a
handful of directed cases).

## 6. Commands for the pending simulation (run from the repository root)

```bash
# end-to-end golden transaction (expect: TESTBENCH PASS, 23,931-ish cycles)
iverilog -g2012 -s fc16_programmer_tb -o /tmp/fc16_tb.out \
  06_2_programmer.v 06_2_programmer_tb.sv
vvp /tmp/fc16_tb.out

# unit tests (expect: FP16 vectors: 4096 checked, mul mismatches=0, add mismatches=0
#             and UNIT TESTBENCH PASS)
iverilog -g2012 -s fc16_unit_tb -o /tmp/fc16_unit.out \
  06_2_programmer.v tests/fc16_unit_tb.sv
vvp /tmp/fc16_unit.out

# simulator-free arithmetic check (already run here, expect: RESULT: PASS)
python3 tools/fp16_arith_check.py
```

If `fc16_unit_tb` reports a compile error, it is a testbench syntax issue (it
could not be compiled here); the RTL change itself is limited to the
`fp16_pkg` functions. Any `vvp` failure log should be fed back to this role.

## 7. Verdict

**CONDITIONAL PASS.**

- Functional: the golden vector is consistent with the independent Python
  model; the arithmetic defects EVAL-001/002 were found and corrected, and the
  corrected arithmetic is bit-exact against numpy on 340k pairs.
- Open items: (a) re-run both testbenches with a real simulator (the RTL edit
  and the new unit testbench were not compiled here); (b) cycle-count
  optimisation (EVAL-004) is a decision for the team; (c) build the final
  `CAD_CA1_<SID1>_<SID2>.zip` with the student numbers and make sure each
  teammate can explain every module (the assignment requires full mastery of the
  code).
