#!/usr/bin/env bash
# Build the final HW1 archive:  tools/make_submission.sh <SID1> <SID2>
# Produces CAD_CA1_<SID1>_<SID2>.zip in the repository root with the files
# required by HW1.pdf (Section 6 deliverables) and spec.pdf.
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: $0 <SID1> <SID2>" >&2; exit 1; }
cd "$(dirname "$0")/.."
out="CAD_CA1_$1_$2.zip"
rm -f "$out"
zip -r "$out" \
  01_context.md partitioning.md_02 sub_modules.zip spec.md_03 prompt_before_after.md_04 \
  ping_pong_buffer_unstructured_result.md ping_pong_buffer_structured_result.md \
  plan.md_05 code.v_05 \
  06_1_planner.md 06_2_programmer.v 06_2_programmer_tb.sv 06_3_reviewer.md 06_4_evaluator.md \
  diagrams tests tools README.md assests/*.mem generate_mnist_mem.py
echo "created $out"
