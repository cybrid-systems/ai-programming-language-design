#!/usr/bin/env python3
"""Time the optimized reco Q1–Q6 statements on one binary.

The comparison point is the optimized nGQL, not the graphd-side baseline.
Pass --label so each binary writes its own JSON. --out is required and is
never the shared results.json from measure_pushdown.py.
"""

import argparse
import hashlib
import json
import statistics
import sys
import time
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_vertices import execute, rows_of  # noqa: E402
from measure_pushdown import QUERIES, plan_of  # noqa: E402

# Correctness probe. Stops before Q4's reverse expansion so the co_buy
# histogram is visible. Not included in the latency table.
Q4_TOPK = (
    "UNWIND range(1, 10000) AS uid "
    "| GO FROM $-.uid OVER buy YIELD buy._dst AS pid "
    "| ORDER BY $-.pid "
    "| GROUP BY $-.pid YIELD $-.pid AS pid, COUNT(*) AS co_buy "
    "| ORDER BY $-.co_buy DESC | LIMIT 100"
)

# Full group maps, before LIMIT. Sorted-row sha is the partial-agg check.
# ORDER BY the vid stays so the ExpandAll GROUP BY bug does not empty the map.
GROUP_PROBES = {
    "q4": (
        "UNWIND range(1, 10000) AS uid "
        "| GO FROM $-.uid OVER buy YIELD buy._dst AS pid "
        "| ORDER BY $-.pid "
        "| GROUP BY $-.pid YIELD $-.pid AS pid, COUNT(*) AS co_buy"
    ),
    "q5": (
        "GO FROM 2 OVER buy YIELD DISTINCT buy._dst AS x "
        "| GO FROM $-.x OVER buy REVERSELY YIELD DISTINCT buy._dst AS u2 "
        "| GO FROM $-.u2 OVER buy YIELD buy._dst AS y "
        "| ORDER BY $-.y "
        "| GROUP BY $-.y YIELD $-.y AS rec_item, COUNT(1) AS score"
    ),
    "q6": (
        "GO FROM 10000031733 OVER buy REVERSELY YIELD DISTINCT buy._dst AS uid "
        "| GO FROM $-.uid OVER buy WHERE buy._dst != 10000031733 "
        "YIELD buy._dst AS item "
        "| ORDER BY $-.item "
        "| GROUP BY $-.item YIELD $-.item AS rec_item, COUNT(1) AS score"
    ),
}


def fingerprint(rows):
    as_tuples = [tuple(row) for row in rows]
    canonical = json.dumps(sorted(as_tuples), ensure_ascii=False, separators=(",", ":"))
    hist = None
    if rows and len(rows[0]) >= 2 and all(isinstance(row[-1], int) for row in rows):
        counts = Counter(row[-1] for row in rows)
        hist = {str(k): counts[k] for k in sorted(counts, reverse=True)}
    return {
        "rows": len(rows),
        "unique": len(set(as_tuples)),
        "sha256": hashlib.sha256(canonical.encode()).hexdigest(),
        "sample": as_tuples[:5],
        "last_col_hist": hist,
    }


def connect():
    from nebula3.Config import Config
    from nebula3.gclient.net import ConnectionPool, Session

    cfg = Config()
    cfg.max_connection_pool_size = 4
    cfg.timeout = 300_000
    last = "not tried"
    for _ in range(30):
        pool = ConnectionPool()
        if pool.init([("127.0.0.1", 9669)], cfg):
            conn = pool.get_connection()
            auth = conn.authenticate("root", "nebula")
            session = Session(conn, auth, pool)
            execute(session, "USE reco")
            return pool, session
        last = "pool.init failed"
        time.sleep(1)
    raise RuntimeError(f"cannot reach graphd: {last}")


def measure(session, stmt, rounds):
    explain = execute(session, "EXPLAIN " + stmt)
    plan = plan_of(explain)
    samples = []
    last_rows = None
    for i in range(rounds + 1):
        started = time.perf_counter()
        resp = execute(session, stmt)
        wall_us = int((time.perf_counter() - started) * 1_000_000)
        sample = {
            "server_us": resp.latency(),
            "whole_us": resp.whole_latency(),
            "wall_us": wall_us,
            "rows": resp.row_size(),
        }
        if i == 0:
            sample["warmup"] = True
        else:
            samples.append(sample)
        last_rows = rows_of(resp)
    servers = sorted(s["server_us"] for s in samples)
    walls = sorted(s["wall_us"] for s in samples)
    return {
        "plan": plan,
        "spine": [n["name"] for n in plan["nodes"]],
        "fingerprint": fingerprint(last_rows),
        "samples": samples,
        "server_us_min": servers[0],
        "server_us_p50": int(statistics.median(servers)),
        "server_us_max": servers[-1],
        "wall_us_p50": int(statistics.median(walls)),
    }


def q4_probe(session):
    resp = execute(session, Q4_TOPK)
    rows = rows_of(resp)
    counts = Counter(row[1] for row in rows)
    stable = sorted(row[0] for row in rows if isinstance(row[1], int) and row[1] >= 7)
    return {
        "rows": len(rows),
        "co_buy_hist": {str(k): counts[k] for k in sorted(counts, reverse=True)},
        "pids_co_buy_ge_7": stable,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", required=True)
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    pool, session = connect()
    report = {
        "label": args.label,
        "rounds": args.rounds,
        "statements": "opt",
        "loadavg_start": Path("/proc/loadavg").read_text().split()[:3],
        "queries": {},
    }
    try:
        for name in ("q1", "q2", "q3", "q4", "q5", "q6"):
            print("==", name, flush=True)
            try:
                got = measure(session, QUERIES[name]["opt"], args.rounds)
            except Exception as exc:  # noqa: BLE001 - record and keep going
                got = {"error": str(exc)}
                print("  ERROR", exc, flush=True)
                try:
                    pool.close()
                except Exception:
                    pass
                pool, session = connect()
            else:
                fp = got["fingerprint"]
                print(
                    "  rows",
                    fp["rows"],
                    "p50_us",
                    got["server_us_p50"],
                    "sha",
                    fp["sha256"][:12],
                    "spine",
                    " ".join(got["spine"]),
                    flush=True,
                )
            report["queries"][name] = got
        try:
            report["q4_topk"] = q4_probe(session)
            print("q4_topk", report["q4_topk"]["co_buy_hist"], flush=True)
        except Exception as exc:  # noqa: BLE001
            report["q4_topk"] = {"error": str(exc)}
            print("q4_topk ERROR", exc, flush=True)
        report["group_probes"] = {}
        for name, stmt in GROUP_PROBES.items():
            print("== group", name, flush=True)
            try:
                explain = execute(session, "EXPLAIN " + stmt)
                resp = execute(session, stmt)
                rows = rows_of(resp)
                got = {
                    "spine": [n["name"] for n in plan_of(explain)["nodes"]],
                    "server_us": resp.latency(),
                    "fingerprint": fingerprint(rows),
                }
                print(
                    "  rows",
                    got["fingerprint"]["rows"],
                    "sha",
                    got["fingerprint"]["sha256"][:12],
                    "spine",
                    " ".join(got["spine"]),
                    flush=True,
                )
            except Exception as exc:  # noqa: BLE001
                got = {"error": str(exc)}
                print("  ERROR", exc, flush=True)
                try:
                    pool.close()
                except Exception:
                    pass
                pool, session = connect()
            report["group_probes"][name] = got
    finally:
        try:
            pool.close()
        except Exception:
            pass
    report["loadavg_end"] = Path("/proc/loadavg").read_text().split()[:3]
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("wrote", out)


if __name__ == "__main__":
    main()
