# HW1-1 FP16 MNIST Accelerator

This repository contains the Section 6 hardware implementation and verification
for a small FP16 fully connected MNIST classifier:

```text
784 input pixels → 8 hidden neurons with ReLU → 10 output logits
```

The RTL is in [`06_2_programmer.v`](06_2_programmer.v), and the self-checking
testbench is in [`06_2_programmer_tb.sv`](06_2_programmer_tb.sv).

## Repository contents

- `06_2_programmer.v` — accelerator RTL and FP16 datapath modules.
- `06_2_programmer_tb.sv` — simulation testbench.
- `assests/` — FP16 model weights, biases, and the original test image.
- `generate_mnist_mem.py` — selects an MNIST row and converts it to a hardware-ready `.mem` file.
- `06_1_planner.md`, `06_3_reviewer.md`, and related notes — design and review documentation.

The directory is named `assests` in the existing project files, so keep that
spelling when using the commands below.

## Prerequisites

Install Icarus Verilog for simulation. The random-image script also requires
Python, NumPy, and the Hugging Face `datasets` package:

```bash
python3 -m pip install numpy datasets
```

## Run the known golden test

From the repository root, compile the RTL and testbench:

```bash
iverilog -g2012 -s fc16_programmer_tb \
  -o /tmp/fc16_tb.out \
  06_2_programmer.v 06_2_programmer_tb.sv
```

Run the compiled simulation:

```bash
vvp /tmp/fc16_tb.out
```

The default testbench reads the model and image files from `assests/`, checks
the expected logits and prediction, and should finish with:

```text
TESTBENCH PASS
```

## Generate a random MNIST image

Use the Python script to select a random image from the Hugging Face MNIST test
split and write its 784 normalized pixels as binary16 hexadecimal values:

```bash
python3 generate_mnist_mem.py
```

This creates:

```text
assests/random_image.mem
```

The script prints the selected row index and its expected digit label. To make
the random choice reproducible, provide a seed:

```bash
python3 generate_mnist_mem.py --seed 7
```

To choose a particular row or use the training split:

```bash
python3 generate_mnist_mem.py --index 123
python3 generate_mnist_mem.py --split train --seed 7
```

The original `assests/test_image.mem` is not overwritten.

## Test the generated image

The testbench accepts a different image at simulation time. Recompile if
needed, then run it with the path to the generated file and the label printed
by the Python script. For example, if the script printed label `7`:

```bash
vvp /tmp/fc16_tb.out \
  +IMAGE_MEM=assests/random_image.mem \
  +EXPECTED_LABEL=7 \
  +SKIP_GOLDEN
```

For a non-default image, `+SKIP_GOLDEN` disables the original image's
hard-coded logits. The testbench still checks that the accelerator completes
and, when `+EXPECTED_LABEL` is supplied, checks the predicted digit against the
MNIST label.

To test completion without checking a label:

```bash
vvp /tmp/fc16_tb.out \
  +IMAGE_MEM=assests/random_image.mem \
  +SKIP_GOLDEN
```

The model weights and biases remain the same; only the input image changes.

## Additional verification and deliverables

- `tests/fc16_unit_tb.sv` + `tests/fp16_vectors.mem` - directed unit tests
  (FP16 multiply/add vs. numpy vectors, SRAM 7-edge latency, ReLU, argmax ties,
  reset while busy). Run:

  ```bash
  iverilog -g2012 -s fc16_unit_tb -o /tmp/fc16_unit.out \
    06_2_programmer.v tests/fc16_unit_tb.sv
  vvp /tmp/fc16_unit.out
  ```

- `tools/fp16_arith_check.py` - simulator-free check of the RTL FP16 arithmetic
  against numpy (`python3 tools/fp16_arith_check.py`).
- `06_4_evaluator.md` - Evaluator report (findings, corrections, open items).
- `diagrams/` - datapath and controller FSM figures (also in `sub_modules.zip`).
- `code.v_05` - Section 5 code extracted from `code.md`.
- `tools/make_submission.sh <SID1> <SID2>` - builds `CAD_CA1_<SID1>_<SID2>.zip`.
