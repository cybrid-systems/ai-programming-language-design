#!/usr/bin/env python3
"""Insert expose edges so Q2 (expose MINUS buy) can run.

Each user is exposed to every product they bought, plus products they did
not buy. Two of the unbought products are exposed twice (different ranks)
so YIELD DISTINCT has duplicates to collapse. Q2's result is the unbought
set. Rank stores exposed_at. --edge-scale must match the buy load: it
multiplies the extra products and is passed through to make_buys. Default
1 is the documented fixture. load inserts into the existing expose edge.
Change scale only after gen_vertices.py recreates the space.
"""

import argparse
import json
import os
import random
from collections import defaultdict

from gen_buy import make_buys
from gen_vertices import (
    NOW_SEC,
    WINDOW_90D,
    batched,
    connect,
    execute,
    key_name,
    make_vertices,
    rows_of,
    wait_job,
    wait_online,
    wait_use,
)

WINDOW_30M = 1800
EXTRA_ACTIVE = 8
EXTRA_INACTIVE = 4
DUP_EXTRAS = 2
EDGE_DDL = "CREATE EDGE IF NOT EXISTS expose(exposed_at int, position int)"
INSERT_PREFIX = "INSERT EDGE expose(exposed_at, position) VALUES "


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("phase", nargs="?", choices=["check", "load"], default="load")
    p.add_argument("--host", default=os.environ.get("NEBULA_ADDR", "127.0.0.1"))
    p.add_argument("--port", type=int, default=int(os.environ.get("NEBULA_PORT", "9669")))
    p.add_argument("--user", default=os.environ.get("NEBULA_USER", "root"))
    p.add_argument("--password", default=os.environ.get("NEBULA_PASS", "nebula"))
    p.add_argument("--batch", type=int, default=200)
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--now", type=int, default=NOW_SEC)
    p.add_argument(
        "--edge-scale",
        type=int,
        default=1,
        help="multiply extra exposes and the buy set they cover; 1 is the documented fixture",
    )
    p.add_argument(
        "--manifest",
        default=os.path.join(os.path.dirname(__file__), "out", "vertices_manifest.json"),
    )
    p.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "out"))
    return p.parse_args()


def vertex_args(spec):
    return argparse.Namespace(
        users=spec["counts"]["users"],
        products=spec["counts"]["products"],
        types=spec["counts"]["categories"],
        beauty_ratio=spec["beauty_ratio"],
        active_ratio=0.30,
        on_shelf_ratio=0.95,
        now=spec["now_sec"],
        seed=spec["seed"],
    )


def make_exposes(vertices, buys, now, seed, edge_scale=1):
    if edge_scale < 1:
        raise SystemExit("--edge-scale must be >= 1")
    rng = random.Random(seed + 19)
    on_shelf = [p["vid"] for p in vertices["products"] if p["status"] == 1]
    bought = defaultdict(list)
    for edge in buys:
        bought[edge["src"]].append(edge)
    recent_lo, recent_hi = now - WINDOW_30M + 1, now
    edges = []
    expected = {}
    for user in vertices["users"]:
        uid = user["vid"]
        owned_edges = bought[uid]
        owned = {edge["dst"] for edge in owned_edges}
        extra_base = EXTRA_ACTIVE if user["active"] else EXTRA_INACTIVE
        extra_n = extra_base * edge_scale
        if len(on_shelf) <= len(owned) + extra_n:
            raise SystemExit(f"user {uid} has no room for {extra_n} extra exposes")
        extras = []
        seen = set(owned)
        while len(extras) < extra_n:
            dst = rng.choice(on_shelf)
            if dst not in seen:
                seen.add(dst)
                extras.append(dst)
        expected[uid] = list(extras)
        for edge in owned_edges:
            edges.append(
                {
                    "src": uid,
                    "dst": edge["dst"],
                    "ts": edge["ts"] - 30,
                    "position": rng.randrange(0, 10),
                }
            )
        for index, dst in enumerate(extras):
            ts = rng.randint(recent_lo, recent_hi)
            edges.append({"src": uid, "dst": dst, "ts": ts, "position": rng.randrange(0, 10)})
            if index < DUP_EXTRAS:
                other = ts - 1 if ts > recent_lo else ts + 1
                edges.append(
                    {"src": uid, "dst": dst, "ts": other, "position": rng.randrange(0, 10)}
                )
    return edges, expected


def validate(edges, expected, buys):
    seen = set()
    for edge in edges:
        key = (edge["src"], edge["dst"], edge["ts"])
        if key in seen:
            raise SystemExit(f"duplicate expose {key}")
        seen.add(key)
    bought = defaultdict(set)
    for edge in buys:
        bought[edge["src"]].add(edge["dst"])
    exposed = defaultdict(set)
    for edge in edges:
        exposed[edge["src"]].add(edge["dst"])
    for uid, extras in expected.items():
        if set(extras) & bought[uid]:
            raise SystemExit(f"user {uid} extra overlaps a purchase")
        if set(extras) != exposed[uid] - bought[uid]:
            raise SystemExit(f"user {uid} expose-minus-buy mismatch")
        if not bought[uid].issubset(exposed[uid]):
            raise SystemExit(f"user {uid} is missing an expose of a purchase")


def edge_clause(edge):
    return (
        f'{edge["src"]}->{edge["dst"]}@{edge["ts"]}:'
        f'({edge["ts"]}, {edge["position"]})'
    )


def q2_stmt(uid):
    return (
        f"GO FROM {uid} OVER expose YIELD DISTINCT dst(edge) AS pid "
        f"MINUS "
        f"GO FROM {uid} OVER buy YIELD DISTINCT dst(edge) AS pid"
    )


def query_pids(session, stmt):
    resp = execute(session, stmt)
    keys = [key_name(k) for k in resp.keys()]
    idx = keys.index("pid")
    return {row[idx] for row in rows_of(resp)}


def verify(session, expected):
    for uid in (2, 1):
        got = query_pids(session, q2_stmt(uid))
        want = set(expected[uid])
        if got != want:
            raise RuntimeError(
                f"Q2 user {uid} got {len(got)} expect {len(want)} "
                f"missing={sorted(want - got)[:5]} extra={sorted(got - want)[:5]}"
            )
        print(f"Q2 user {uid} returned {len(got)} pids", flush=True)
        for pid in sorted(got):
            print(f"  pid={pid}", flush=True)


def write_manifest(path, edges, expected, seed, now, edge_scale):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    info = {
        "space": "reco",
        "seed": seed,
        "now_sec": now,
        "edge_scale": edge_scale,
        "rank_is_exposed_at": True,
        "counts": {"edges": len(edges)},
        "q2_user_2": sorted(expected[2]),
        "q2_user_1": sorted(expected[1]),
    }
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(info, fh, ensure_ascii=False, indent=2)
        fh.write("\n")


def load(args, edges, expected):
    pool, session = connect(args)
    try:
        wait_online(session)
        wait_use(session)
        execute(session, EDGE_DDL)
        print("edge expose ready", flush=True)
        batched(session, INSERT_PREFIX, [edge_clause(e) for e in edges], args.batch)
        wait_job(session, "SUBMIT JOB STATS")
        verify(session, expected)
    finally:
        session.release()
        pool.close()


def main():
    args = parse_args()
    with open(args.manifest, encoding="utf-8") as fh:
        spec = json.load(fh)
    if spec["now_sec"] != args.now or spec["seed"] != args.seed:
        raise SystemExit("manifest now/seed does not match this load")
    vertices = make_vertices(vertex_args(spec))
    active = sum(1 for u in vertices["users"] if u["active"])
    if active != spec["counts"]["active_users"]:
        raise SystemExit("regenerated users do not match the loaded space")
    buys = make_buys(vertices, args.now, args.seed, args.edge_scale)
    edges, expected = make_exposes(vertices, buys, args.now, args.seed, args.edge_scale)
    validate(edges, expected, buys)
    out = os.path.join(args.out, "expose_manifest.json")
    write_manifest(out, edges, expected, args.seed, args.now, args.edge_scale)
    print(
        f"expose edges={len(edges)} edge_scale={args.edge_scale} "
        f"q2_user_2={len(expected[2])} q2_user_1={len(expected[1])}",
        flush=True,
    )
    if args.phase == "check":
        print(f"wrote {out}", flush=True)
        return
    load(args, edges, expected)
    print(f"loaded expose into reco; manifest {out}", flush=True)


if __name__ == "__main__":
    main()
