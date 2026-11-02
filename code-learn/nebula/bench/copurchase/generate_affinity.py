#!/usr/bin/env python3
"""User-product graph with three vid placements.

Nebula INT64 part id is vid % partition_num + 1 for a non-negative vid.
affinityVid(seq, partIndex, parts) = seq * parts + partIndex lands on
part partIndex+1. A community is one part, so one storaged after balance
leads every vid in that community.

random keeps the same purchase pairs and assigns vids from a shuffled
positive pool, so parts no longer follow the community.

mixed keeps even communities on their part and shuffles odd communities
across the parts those communities would have owned.
"""

import argparse
import json
import os

import numpy as np

NOW = 1761868800
DAY = 86400


def affinity_vid(seq, part_index, parts):
    return int(seq) * int(parts) + int(part_index)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--users", type=int, default=3000)
    parser.add_argument("--products", type=int, default=300)
    parser.add_argument("--parts", type=int, default=9)
    parser.add_argument("--communities", type=int, default=9)
    parser.add_argument("--placement", choices=("affinity", "random", "mixed"), required=True)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--alpha", type=float, default=1.0)
    parser.add_argument("--days", type=int, default=60)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    if args.communities != args.parts:
        raise SystemExit("this generator puts one community on one part, so communities == parts")
    rng = np.random.default_rng(args.seed)
    parts = args.parts
    users_per = args.users // args.communities
    products_per = args.products // args.communities
    if users_per < 2 or products_per < 1:
        raise SystemExit("community is empty")

    logical_users = []
    logical_products = []
    for c in range(args.communities):
        for i in range(users_per):
            logical_users.append((c, i))
        for i in range(products_per):
            logical_products.append((c, i))

    def natural(kind_seq, community):
        # seq starts at 1 so vid 0 is not used. Communities do not share seq.
        return affinity_vid(kind_seq, community, parts)

    # Product seqs start after every user seq so a user and a product never share a vid.
    user_seq = {key: n + 1 for n, key in enumerate(logical_users)}
    product_base_seq = len(logical_users) + 1
    product_seq = {key: product_base_seq + n for n, key in enumerate(logical_products)}
    natural_user = {key: natural(user_seq[key], key[0]) for key in logical_users}
    natural_product = {key: natural(product_seq[key], key[0]) for key in logical_products}

    if args.placement == "affinity":
        user_of = natural_user
        product_of = natural_product
    elif args.placement == "random":
        pool_u = list(natural_user.values())
        pool_p = list(natural_product.values())
        rng.shuffle(pool_u)
        rng.shuffle(pool_p)
        user_of = {key: int(pool_u[i]) for i, key in enumerate(logical_users)}
        product_of = {key: int(pool_p[i]) for i, key in enumerate(logical_products)}
    else:
        user_of = {}
        product_of = {}
        used_u = set()
        used_p = set()
        for key in logical_users:
            if key[0] % 2 == 0:
                user_of[key] = natural_user[key]
                used_u.add(user_of[key])
        for key in logical_products:
            if key[0] % 2 == 0:
                product_of[key] = natural_product[key]
                used_p.add(product_of[key])
        odd_u = [key for key in logical_users if key[0] % 2 == 1]
        odd_p = [key for key in logical_products if key[0] % 2 == 1]
        rest_u = [v for v in natural_user.values() if v not in used_u]
        rest_p = [v for v in natural_product.values() if v not in used_p]
        rng.shuffle(rest_u)
        rng.shuffle(rest_p)
        for key, vid in zip(odd_u, rest_u):
            user_of[key] = int(vid)
        for key, vid in zip(odd_p, rest_p):
            product_of[key] = int(vid)

    # Purchases stay inside the community, then a few cross edges are added
    # for mixed/random so the canonical product part leaves the user's part.
    weights = 1.0 / np.arange(1, products_per + 1, dtype=np.float64) ** args.alpha
    weights /= weights.sum()
    start = NOW - args.days * DAY
    rows = []
    cross_n = 0
    for c, i in logical_users:
        user = user_of[(c, i)]
        k = 4 + (i % 5)
        local = rng.choice(products_per, size=min(k, products_per), replace=False, p=weights)
        ts = rng.integers(start, NOW + 1, size=len(local), dtype=np.int64)
        for idx, stamp in zip(local, ts):
            rows.append((int(user), int(product_of[(c, int(idx))]), int(stamp)))
        if args.placement != "affinity" and int(rng.integers(0, 5)) == 0:
            other = int((c + 1 + int(rng.integers(0, args.communities - 1))) % args.communities)
            dest = product_of[(other, int(rng.integers(0, products_per)))]
            rows.append((int(user), int(dest), int(rng.integers(start, NOW + 1))))
            cross_n += 1
    edges = np.asarray(rows, dtype=np.int64)
    product_ids = np.asarray([product_of[key] for key in logical_products], dtype=np.int64)
    perm = rng.permutation(len(product_ids))
    sales = (1_000_000 // (1 + perm)).astype(np.int64)
    meta = {
        "placement": args.placement,
        "users": int(len(logical_users)),
        "products": int(len(logical_products)),
        "parts": parts,
        "communities": args.communities,
        "edges": int(edges.shape[0]),
        "cross_edges": cross_n,
        "seed": args.seed,
        "now": NOW,
        "window_30d": [NOW - 30 * DAY, NOW],
        "window_7d": [NOW - 7 * DAY, NOW],
        "vid": "affinityVid(seq, community, parts); random/mixed permute those vids",
    }
    np.savez_compressed(args.out, edges=edges, product_ids=product_ids, sales=sales)
    meta_path = os.path.splitext(args.out)[0] + ".json"
    with open(meta_path, "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=2)
        fh.write("\n")
    print(json.dumps(meta), flush=True)


if __name__ == "__main__":
    main()
