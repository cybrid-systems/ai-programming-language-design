#!/usr/bin/env python3
"""Replay item-name assignment from bench/scenario2/gen_data.py (seed 2).

Does not import or modify the bench. The RNG prefix matches make_dataset:
one Random(seed), then one random() per item id in 1..items to pick beauty.
"""

import argparse
import random


def beauty_names(items: int, beauty_ratio: float, seed: int):
    rng = random.Random(seed)
    names = []
    for iid in range(1, items + 1):
        if rng.random() < beauty_ratio:
            names.append(f"i{iid}")
    return names


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--items", type=int, default=2000)
    p.add_argument("--beauty-ratio", type=float, default=0.2)
    p.add_argument("--seed", type=int, default=2)
    p.add_argument("--check", type=int, default=382, help="expected beauty item count")
    args = p.parse_args()
    names = beauty_names(args.items, args.beauty_ratio, args.seed)
    if args.check and len(names) != args.check:
        raise SystemExit(f"expected {args.check} beauty items, got {len(names)}")
    print("\n".join(names))


if __name__ == "__main__":
    main()
