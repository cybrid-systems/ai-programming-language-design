#!/usr/bin/env python3
"""Time baseline vs pushdown-enabling nGQL for reco Q1–Q6 and dump plans.

Runs against the local graphd. Does not load data. Each scenario is independent:
pass --only q1 (repeatable) to measure one statement pair.
"""

import argparse
import hashlib
import json
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_vertices import execute, rows_of  # noqa: E402

KEEP_KEYS = {
    "filter",
    "edgeProps",
    "edgeColumns",
    "limit",
    "count",
    "dedup",
    "joinInput",
    "groupKeys",
    "columns",
    "factors",
    "inputVar",
    "scanType",
    "index_id",
}

QUERIES = {
    "q1": {
        "base": (
            "GO FROM 2 OVER buy YIELD dst(edge) AS pid, rank(edge) AS ts "
            "| YIELD $-.pid AS pid, $-.ts AS ts "
            "WHERE $-.ts >= 1761436800 - 1800 OR $-.pid != $-.pid "
            "| ORDER BY $-.ts DESC | LIMIT 10"
        ),
        "opt": (
            "GO FROM 2 OVER buy WHERE buy._rank >= 1761436800 - 1800 "
            "YIELD buy._dst AS pid, buy._rank AS ts "
            "| ORDER BY $-.ts DESC | LIMIT 10"
        ),
    },
    "q2": {
        "base": (
            "GO FROM 2 OVER expose YIELD DISTINCT dst(edge) AS pid "
            "MINUS GO FROM 2 OVER buy YIELD DISTINCT dst(edge) AS pid"
        ),
        "opt": (
            "GO FROM 2 OVER expose YIELD DISTINCT expose._dst AS pid "
            "MINUS GO FROM 2 OVER buy YIELD DISTINCT buy._dst AS pid"
        ),
    },
    "q3": {
        "base": (
            "LOOKUP ON product WHERE product.type == 1 YIELD id(vertex) AS pid "
            "| GO FROM $-.pid OVER buy REVERSELY "
            "YIELD src(edge) AS uid, rank(edge) AS ts "
            "| YIELD $-.uid AS uid, $-.ts AS ts "
            "WHERE $-.ts >= 1761436800 - 7776000 OR $-.uid != $-.uid "
            "| YIELD DISTINCT $-.uid AS high_potential_user | LIMIT 5000"
        ),
        "opt": (
            "LOOKUP ON product WHERE product.type == 1 YIELD id(vertex) AS pid "
            "| GO FROM $-.pid OVER buy REVERSELY "
            "WHERE buy._rank >= 1761436800 - 7776000 "
            "YIELD buy._dst AS uid "
            "| YIELD DISTINCT $-.uid AS high_potential_user | LIMIT 5000"
        ),
    },
    "q4": {
        "base": (
            "UNWIND range(1, 10000) AS uid "
            "| GO FROM $-.uid OVER buy YIELD dst(edge) AS pid, $$.product.type AS t "
            "| GROUP BY $-.pid YIELD $-.pid AS pid, COUNT(*) AS co_buy "
            "| ORDER BY $-.co_buy DESC | LIMIT 100 "
            "| GO FROM $-.pid OVER buy REVERSELY "
            "YIELD DISTINCT src(edge) AS ext_user | LIMIT 100000"
        ),
        "opt": (
            "UNWIND range(1, 10000) AS uid "
            "| GO FROM $-.uid OVER buy YIELD buy._dst AS pid "
            "| ORDER BY $-.pid "
            "| GROUP BY $-.pid YIELD $-.pid AS pid, COUNT(*) AS co_buy "
            "| ORDER BY $-.co_buy DESC | LIMIT 100 "
            "| GO FROM $-.pid OVER buy REVERSELY "
            "YIELD DISTINCT buy._dst AS ext_user | LIMIT 100000"
        ),
    },
    "q5": {
        "base": (
            "GO FROM 2 OVER buy YIELD DISTINCT dst(edge) AS x "
            "| GO FROM $-.x OVER buy REVERSELY YIELD DISTINCT src(edge) AS u2 "
            "| GO FROM $-.u2 OVER buy YIELD dst(edge) AS y "
            "| ORDER BY $-.y "
            "| GROUP BY $-.y YIELD $-.y AS rec_item, COUNT(1) AS score "
            "| ORDER BY $-.score DESC | LIMIT 20"
        ),
        "opt": (
            "GO FROM 2 OVER buy YIELD DISTINCT buy._dst AS x "
            "| GO FROM $-.x OVER buy REVERSELY YIELD DISTINCT buy._dst AS u2 "
            "| GO FROM $-.u2 OVER buy YIELD buy._dst AS y "
            "| ORDER BY $-.y "
            "| GROUP BY $-.y YIELD $-.y AS rec_item, COUNT(1) AS score "
            "| ORDER BY $-.score DESC | LIMIT 20"
        ),
    },
    "q6": {
        "base": (
            "GO FROM 10000031733 OVER buy REVERSELY YIELD DISTINCT src(edge) AS uid "
            "| GO FROM $-.uid OVER buy YIELD dst(edge) AS item "
            "| YIELD $-.item AS item WHERE $-.item != 10000031733 "
            "| ORDER BY $-.item "
            "| GROUP BY $-.item YIELD $-.item AS rec_item, COUNT(1) AS score "
            "| ORDER BY $-.score DESC | LIMIT 20"
        ),
        "opt": (
            "GO FROM 10000031733 OVER buy REVERSELY YIELD DISTINCT buy._dst AS uid "
            "| GO FROM $-.uid OVER buy WHERE buy._dst != 10000031733 "
            "YIELD buy._dst AS item "
            "| ORDER BY $-.item "
            "| GROUP BY $-.item YIELD $-.item AS rec_item, COUNT(1) AS score "
            "| ORDER BY $-.score DESC | LIMIT 20"
        ),
    },
}


def decode(value):
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return value


def plan_of(resp):
    desc = resp.plan_desc()
    nodes = []
    if desc is None or not desc.plan_node_descs:
        return {"optimize_time_in_us": None, "nodes": []}
    for node in desc.plan_node_descs:
        fields = {}
        for pair in node.description or []:
            key = decode(pair.key)
            if key in KEEP_KEYS:
                fields[key] = decode(pair.value)
        nodes.append(
            {
                "id": node.id,
                "name": decode(node.name),
                "deps": list(node.dependencies or []),
                "fields": fields,
            }
        )
    return {"optimize_time_in_us": desc.optimize_time_in_us, "nodes": nodes}


def fingerprint(rows):
    # Stable multiset. Ties in LIMIT keep this from requiring one order.
    as_tuples = [tuple(row) for row in rows]
    canonical = json.dumps(sorted(as_tuples), ensure_ascii=False, separators=(",", ":"))
    return {
        "rows": len(rows),
        "unique": len(set(as_tuples)),
        "sha256": hashlib.sha256(canonical.encode()).hexdigest(),
        "sample": as_tuples[:5],
    }


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
    return {
        "plan": plan,
        "fingerprint": fingerprint(last_rows),
        "samples": samples,
        "server_us_min": servers[0],
        "server_us_p50": int(statistics.median(servers)),
        "server_us_max": servers[-1],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", choices=sorted(QUERIES), action="append")
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    names = args.only or list(QUERIES)
    from nebula3.Config import Config
    from nebula3.gclient.net import ConnectionPool, Session

    cfg = Config()
    cfg.max_connection_pool_size = 4
    cfg.timeout = 300_000
    pool = ConnectionPool()
    if not pool.init([("127.0.0.1", 9669)], cfg):
        raise RuntimeError("cannot reach graphd")
    conn = pool.get_connection()
    auth = conn.authenticate("root", "nebula")
    session = Session(conn, auth, pool)
    execute(session, "USE reco")
    report = {"rounds": args.rounds, "queries": {}}
    for name in names:
        print("==", name, flush=True)
        pair = {}
        for kind in ("base", "opt"):
            print(" ", kind, flush=True)
            pair[kind] = measure(session, QUERIES[name][kind], args.rounds)
            fp = pair[kind]["fingerprint"]
            print(
                "   rows",
                fp["rows"],
                "p50_us",
                pair[kind]["server_us_p50"],
                "nodes",
                [n["name"] for n in pair[kind]["plan"]["nodes"]],
                flush=True,
            )
        base_set = pair["base"]["fingerprint"]
        opt_set = pair["opt"]["fingerprint"]
        pair["same_row_count"] = base_set["rows"] == opt_set["rows"]
        pair["same_multiset"] = base_set["sha256"] == opt_set["sha256"]
        report["queries"][name] = pair
    pool.close()
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(report, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    print("wrote", args.out)


if __name__ == "__main__":
    main()
