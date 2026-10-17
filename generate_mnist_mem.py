#!/usr/bin/env python3
"""Select one MNIST example and write it as an IEEE-754 FP16 .mem file.

The generated file contains 784 normalized pixels (one 16-bit hex value per
line), matching the input format expected by the accelerator.

Examples:
    python generate_mnist_mem.py
    python generate_mnist_mem.py --seed 7 --output assests/random_image.mem
    python generate_mnist_mem.py --split train --index 123
"""

from __future__ import annotations

import argparse
import random
from pathlib import Path

import numpy as np


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--split", choices=("train", "test"), default="test")
    parser.add_argument(
        "--index",
        type=int,
        default=None,
        help="specific row to use; if omitted, choose a random row",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=None,
        help="seed for reproducible random selection",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("assests/random_image.mem"),
        help="destination .mem file (default: assests/random_image.mem)",
    )
    parser.add_argument(
        "--dataset",
        default="ylecun/mnist",
        help="Hugging Face dataset name (default: ylecun/mnist)",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    try:
        from datasets import load_dataset
    except ImportError as exc:
        raise SystemExit(
            "This script needs the Hugging Face datasets package. "
            "Install it with: pip install datasets"
        ) from exc

    dataset = load_dataset(args.dataset, split=args.split)

    if args.index is None:
        rng = random.Random(args.seed)
        index = rng.randrange(len(dataset))
    else:
        index = args.index
        if not 0 <= index < len(dataset):
            raise SystemExit(
                f"index {index} is outside {args.split!r} split "
                f"(valid range: 0..{len(dataset) - 1})"
            )

    row = dataset[index]
    image = row["image"]
    label = int(row["label"])

    # HF decodes MNIST's image column as a PIL image. Converting through uint8
    # also handles array-like image values without changing their pixel bytes.
    pixels_u8 = np.asarray(image, dtype=np.uint8)
    if pixels_u8.size != 28 * 28:
        raise SystemExit(f"expected a 28x28 image, got shape {pixels_u8.shape}")

    # The RTL consumes values in [0, 1] as binary16, not raw 0..255 bytes.
    pixels_fp16 = (pixels_u8.reshape(-1).astype(np.float32) / 255.0).astype(
        np.float16
    )
    bits = pixels_fp16.view(np.uint16)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="ascii") as mem_file:
        for value in bits:
            mem_file.write(f"{int(value):04X}\n")

    print(f"split:  {args.split}")
    print(f"index:  {index}")
    print(f"label:  {label}")
    print(f"output: {args.output}")
    print("wrote:  784 FP16 pixels")


if __name__ == "__main__":
    main()
