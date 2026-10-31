#!/usr/bin/env python3
"""Power-law purchase graph for the co-purchase bench.

Users 1..N, products PRODUCT_BASE.., one buy edge per (user, product).
Edge rank is a unix timestamp uniform over the last 60 days. Product sales is
an integer vertex property, shuffled independently of popularity.
"""

import argparse
import json
import os

import numpy as np

NOW = 1761868800
DAY = 86400


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--users", type=int, default=20000)
    parser.add_argument("--products", type=int, default=2000)
    parser.add_argument("--product-base", type=int, default=1000001)
    parser.add_argument("--alpha", type=float, default=1.0)
    parser.add_argument("--days", type=int, default=60)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "graph.npz"))
    args = parser.parse_args()
    rng = np.random.default_rng(args.seed)
    weights = 1.0 / np.arange(1, args.products + 1, dtype=np.float64) ** args.alpha
    weights /= weights.sum()
    start = NOW - args.days * DAY
    rows = []
    for user in range(1, args.users + 1):
        k = 8 + (user % 23)
        picks = rng.choice(args.products, size=k, replace=False, p=weights)
        ts = rng.integers(start, NOW + 1, size=k, dtype=np.int64)
        for idx, stamp in zip(picks, ts):
            rows.append((user, args.product_base + int(idx), int(stamp)))
        if user % 5000 == 0:
            print(f"generated users={user} edges={len(rows)}", flush=True)
    edges = np.asarray(rows, dtype=np.int64)
    perm = rng.permutation(args.products)
    sales = (1_000_000 // (1 + perm)).astype(np.int64)
    meta = {
        "users": args.users,
        "products": args.products,
        "product_base": args.product_base,
        "alpha": args.alpha,
        "days": args.days,
        "seed": args.seed,
        "now": NOW,
        "edges": int(edges.shape[0]),
        "window_30d": [NOW - 30 * DAY, NOW],
        "window_7d": [NOW - 7 * DAY, NOW],
        "purchases_per_user": "8 + (user % 23), distinct products",
        "rank": "unix seconds, one edge per user-product",
        "sales": "1000000 / (1 + permutation), independent of popularity",
    }
    np.savez_compressed(args.out, edges=edges, sales=sales, product_base=np.int64(args.product_base))
    meta_path = os.path.splitext(args.out)[0] + ".json"
    with open(meta_path, "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=2)
        fh.write("\n")
    print(json.dumps(meta), flush=True)


if __name__ == "__main__":
    main()
