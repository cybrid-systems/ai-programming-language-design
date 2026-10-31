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


def build(nparts, community_size, degree, seed, affinity=True, placement=None):
    """placement is affinity, random, or mixed.

    mixed keeps even communities on one part and shuffles odd communities
    across the vid pool that those communities would have owned. That pool
    is exactly the odd parts, so each odd community is spread over those
    parts instead of sitting on one.
    """
    if placement is None:
        placement = "affinity" if affinity else "random"
    rng = random.Random(seed)
    logical = []
    for c in range(nparts):
        for i in range(community_size):
            logical.append((c, i))
    natural = [affinity_vid(c, i, nparts) for c, i in logical]
    if placement == "affinity":
        vids = natural
    elif placement == "random":
        # Positive ints that still cover every part, but not grouped.
        pool = list(range(1, len(logical) + 1))
        rng.shuffle(pool)
        vids = pool
    elif placement == "mixed":
        vid_of = {}
        used = set()
        for c, i in logical:
            if c % 2 == 0:
                vid = affinity_vid(c, i, nparts)
                vid_of[(c, i)] = vid
                used.add(vid)
        rest_keys = [(c, i) for c, i in logical if c % 2 == 1]
        rest_vids = [v for v in natural if v not in used]
        rng.shuffle(rest_vids)
        for key, vid in zip(rest_keys, rest_vids):
            vid_of[key] = vid
        vids = [vid_of[key] for key in logical]
    else:
        raise ValueError(placement)
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
        "affinity": placement == "affinity",
        "placement": placement,
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
