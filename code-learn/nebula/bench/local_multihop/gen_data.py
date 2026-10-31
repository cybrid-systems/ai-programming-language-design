#!/usr/bin/env python3
"""Community graph whose vids either share a partition or are shuffled.

Nebula 3.8 INT64 partition id is (vid % partition_num) + 1. An affinity vid
for community c (0-based) and local index i is c + i * partition_num, so the
whole community hashes to part c+1. The random placement keeps the same
edges and permutes vids.
"""

import random


def affinity_vid(community, index, nparts):
    return community + index * nparts


def build(nparts, community_size, degree, seed, affinity):
    rng = random.Random(seed)
    logical = []
    for c in range(nparts):
        for i in range(community_size):
            logical.append((c, i))
    if affinity:
        vids = [affinity_vid(c, i, nparts) for c, i in logical]
    else:
        # Positive ints that still cover every part, but not grouped.
        pool = list(range(1, len(logical) + 1))
        rng.shuffle(pool)
        vids = pool
    vid_of = {logical[k]: vids[k] for k in range(len(logical))}
    edges = []  # (src, dst, rank)
    for c, i in logical:
        src = vid_of[(c, i)]
        targets = set()
        targets.add((i + 1) % community_size)
        while len(targets) < min(degree, community_size - 1):
            targets.add(rng.randrange(community_size))
        targets.discard(i)
        rank = 0
        for j in sorted(targets):
            dst = vid_of[(c, j)]
            edges.append((src, dst, rank))
            rank += 1
    seeds = [vid_of[(c, 0)] for c in range(nparts)]
    return {
        "nparts": nparts,
        "affinity": affinity,
        "vids": vids,
        "edges": edges,
        "seeds": seeds,
        "adj": _adj(edges),
    }


def _adj(edges):
    adj = {}
    for src, dst, _rank in edges:
        adj.setdefault(src, set()).add(dst)
    return adj


def walk(adj, seeds, steps):
    """Vids reached at exactly `steps` hops. Within a hop, dsts are unique."""
    frontier = set(seeds)
    for _ in range(steps):
        nxt = set()
        for vid in frontier:
            nxt.update(adj.get(vid, ()))
        frontier = nxt
        if not frontier:
            break
    return frontier


def walk_range(adj, seeds, lo, hi):
    got = set()
    frontier = set(seeds)
    for step in range(1, hi + 1):
        nxt = set()
        for vid in frontier:
            nxt.update(adj.get(vid, ()))
        frontier = nxt
        if lo <= step <= hi:
            got.update(frontier)
        if not frontier:
            break
    return got
