#!/usr/bin/env python3
"""Insert buy edges for the reco baseline. Vertices must already be loaded.

Rank is the purchase timestamp, and buy.timestamp stores the same value.
Q1 reads rank(edge), then filters, sorts, and limits in graphd.

Per active user: 12 purchases inside (now-1800, now], 8 inside the 90-day
window but outside those 30 minutes. Per inactive user: 3 purchases older
than 90 days. Destinations are on-shelf products. User 2 is active, so
Q1 FROM 2 returns 10 rows. User 1 is inactive, so Q1 FROM 1 returns none.
"""

import argparse
import json
import os
import random

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
RECENT_PER_ACTIVE = 12
OLDER_PER_ACTIVE = 8
OLDER_PER_INACTIVE = 3
# timestamp is a reserved type name, so the column is quoted.
EDGE_DDL = (
    "CREATE EDGE IF NOT EXISTS buy("
    "`timestamp` int, ad_slot_id int, quantity int, order_id string)"
)
INSERT_PREFIX = "INSERT EDGE buy(`timestamp`, ad_slot_id, quantity, order_id) VALUES "


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
        "--manifest",
        default=os.path.join(os.path.dirname(__file__), "out", "vertices_manifest.json"),
    )
    p.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "out"))
    return p.parse_args()


def vertex_args(spec):
    ns = argparse.Namespace(
        users=spec["counts"]["users"],
        products=spec["counts"]["products"],
        types=spec["counts"]["categories"],
        beauty_ratio=spec["beauty_ratio"],
        active_ratio=0.30,
        on_shelf_ratio=0.95,
        now=spec["now_sec"],
        seed=spec["seed"],
    )
    return ns


def make_buys(vertices, now, seed):
    rng = random.Random(seed + 7)
    on_shelf = [p["vid"] for p in vertices["products"] if p["status"] == 1]
    if len(on_shelf) < RECENT_PER_ACTIVE + OLDER_PER_ACTIVE:
        raise SystemExit("not enough on-shelf products")
    recent_lo, recent_hi = now - WINDOW_30M + 1, now
    mid_lo, mid_hi = now - WINDOW_90D, now - WINDOW_30M - 1
    old_lo, old_hi = now - 730 * 24 * 3600, now - WINDOW_90D - 1
    edges = []
    for user in vertices["users"]:
        if user["active"]:
            recent_n, older_n, older_span = RECENT_PER_ACTIVE, OLDER_PER_ACTIVE, (mid_lo, mid_hi)
        else:
            recent_n, older_n, older_span = 0, OLDER_PER_INACTIVE, (old_lo, old_hi)
        need = recent_n + older_n
        dsts = rng.sample(on_shelf, need)
        times = []
        if recent_n:
            times.extend(rng.sample(range(recent_lo, recent_hi + 1), recent_n))
        times.extend(rng.sample(range(older_span[0], older_span[1] + 1), older_n))
        for dst, ts in zip(dsts, times):
            edges.append(
                {
                    "src": user["vid"],
                    "dst": dst,
                    "ts": ts,
                    "ad_slot_id": rng.randrange(0, 5),
                    "quantity": rng.randint(1, 5),
                    "order_id": f"o-{user['vid']}-{ts}",
                }
            )
    return edges


def validate(edges, vertices, now):
    seen = set()
    cutoff = now - WINDOW_30M
    active = {u["vid"] for u in vertices["users"] if u["active"]}
    recent = {uid: 0 for uid in active}
    for edge in edges:
        key = (edge["src"], edge["dst"], edge["ts"])
        if key in seen:
            raise SystemExit(f"duplicate edge {key}")
        seen.add(key)
        if edge["src"] in active and edge["ts"] >= cutoff:
            recent[edge["src"]] += 1
    short = [uid for uid, n in recent.items() if n != RECENT_PER_ACTIVE]
    if short:
        raise SystemExit(f"{len(short)} active users do not have {RECENT_PER_ACTIVE} recent buys")
    inactive_recent = [
        e for e in edges if e["src"] not in active and e["ts"] >= cutoff
    ]
    if inactive_recent:
        raise SystemExit("inactive user has a purchase inside 30 minutes")


def q1_oracle(edges, uid, now, limit=10):
    cutoff = now - WINDOW_30M
    rows = [e for e in edges if e["src"] == uid and e["ts"] >= cutoff]
    rows.sort(key=lambda e: e["ts"], reverse=True)
    return rows[:limit]


def edge_clause(edge):
    return (
        f'{edge["src"]}->{edge["dst"]}@{edge["ts"]}:'
        f'({edge["ts"]}, {edge["ad_slot_id"]}, {edge["quantity"]}, "{edge["order_id"]}")'
    )


def q1_stmt(uid, now):
    # A bare comparison on rank is rewritten to `*._rank` and pushed into
    # storaged, which rejects the star edge name. The always-false disjunct
    # keeps this filter in graphd. It does not change the matched rows.
    cutoff = now - WINDOW_30M
    return (
        f"GO FROM {uid} OVER buy "
        "YIELD dst(edge) AS pid, rank(edge) AS ts "
        f"| YIELD $-.pid AS pid, $-.ts AS ts "
        f"WHERE $-.ts >= {cutoff} OR $-.pid != $-.pid "
        "| ORDER BY $-.ts DESC | LIMIT 10"
    )


def query_rows(session, stmt):
    resp = execute(session, stmt)
    keys = [key_name(k) for k in resp.keys()]
    pid_i = keys.index("pid")
    ts_i = keys.index("ts")
    out = []
    for row in rows_of(resp):
        out.append((row[pid_i], row[ts_i]))
    return out


def verify(session, edges, now):
    expect = [(e["dst"], e["ts"]) for e in q1_oracle(edges, 2, now)]
    got = query_rows(session, q1_stmt(2, now))
    if got != expect:
        raise RuntimeError(f"Q1 user 2 mismatch\n got={got}\n expect={expect}")
    empty = query_rows(session, q1_stmt(1, now))
    if empty:
        raise RuntimeError(f"Q1 user 1 expected no rows, got {empty}")
    top = expect[0]
    prop = execute(
        session,
        f"FETCH PROP ON buy 2->{top[0]}@{top[1]} "
        "YIELD buy.`timestamp` AS timestamp, buy.order_id AS order_id",
    )
    keys = [key_name(k) for k in prop.keys()]
    if prop.row_size() < 1 or "timestamp" not in keys:
        raise RuntimeError(f"missing buy.timestamp columns={keys}")
    ts_cell = rows_of(prop)[0][keys.index("timestamp")]
    if ts_cell != top[1]:
        raise RuntimeError(f"buy.timestamp {ts_cell} != rank {top[1]}")
    print(f"Q1 user 2 returned {len(got)} rows; user 1 returned 0", flush=True)
    for pid, ts in got:
        print(f"  pid={pid} ts={ts}", flush=True)


def write_manifest(path, edges, now, seed):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    top = q1_oracle(edges, 2, now)
    info = {
        "space": "reco",
        "seed": seed,
        "now_sec": now,
        "window_30m_sec": WINDOW_30M,
        "rank_is_timestamp": True,
        "counts": {
            "edges": len(edges),
            "recent_per_active_user": RECENT_PER_ACTIVE,
            "older_90d_per_active_user": OLDER_PER_ACTIVE,
            "older_per_inactive_user": OLDER_PER_INACTIVE,
        },
        "q1_user_2": [{"pid": e["dst"], "ts": e["ts"]} for e in top],
    }
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(info, fh, ensure_ascii=False, indent=2)
        fh.write("\n")


def load(args, edges, now):
    pool, session = connect(args)
    try:
        wait_online(session)
        wait_use(session)
        execute(session, EDGE_DDL)
        print("edge buy ready", flush=True)
        batched(session, INSERT_PREFIX, [edge_clause(e) for e in edges], args.batch)
        wait_job(session, "SUBMIT JOB STATS")
        verify(session, edges, now)
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
    on_shelf = sum(1 for p in vertices["products"] if p["status"] == 1)
    if active != spec["counts"]["active_users"] or on_shelf != spec["counts"]["on_shelf_products"]:
        raise SystemExit(
            f"regenerated vertices do not match the loaded space "
            f"(active {active} vs {spec['counts']['active_users']}, "
            f"on_shelf {on_shelf} vs {spec['counts']['on_shelf_products']})"
        )
    edges = make_buys(vertices, args.now, args.seed)
    validate(edges, vertices, args.now)
    out = os.path.join(args.out, "buy_manifest.json")
    write_manifest(out, edges, args.now, args.seed)
    print(f"buy edges={len(edges)} recent_per_active={RECENT_PER_ACTIVE}", flush=True)
    if args.phase == "check":
        print(f"wrote {out}", flush=True)
        return
    load(args, edges, args.now)
    print(f"loaded buy into reco; manifest {out}", flush=True)


if __name__ == "__main__":
    main()
