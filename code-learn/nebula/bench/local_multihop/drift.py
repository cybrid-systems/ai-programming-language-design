#!/usr/bin/env python3
"""Switch one space from affinity edges to random edges and record each query.

The shape key is space + edge type + steps, so both phases share the EWMA.
Client latency is ResultSet.latency(). The choice line is graphd's
adaptive_multihop log, which is the decision for that query. This script
does not insert hidden warmup queries.
"""

import argparse
import json
import os
import time

from gen_data import build, walk
from measure import Client, bench, execute, pct, query, vids_of, wait_use


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", default="10.88.0.31")
    p.add_argument("--port", type=int, default=9669)
    p.add_argument("--storage-hosts", required=True)
    p.add_argument("--space", default="ad_drift")
    p.add_argument("--parts", type=int, default=9)
    p.add_argument("--replica", type=int, default=1)
    p.add_argument("--community-size", type=int, default=300)
    p.add_argument("--degree", type=int, default=8)
    p.add_argument("--seed", type=int, default=7)
    p.add_argument("--steps", type=int, default=3)
    p.add_argument("--affinity-queries", type=int, default=30)
    p.add_argument("--random-queries", type=int, default=40)
    p.add_argument("--window", type=int, default=10)
    p.add_argument("--log", default="/tmp/nebula-dist/graph1/logs/nebula-graphd.INFO")
    p.add_argument("--tag", default="drift")
    p.add_argument("--results", default=os.path.join(os.path.dirname(__file__), "results"))
    return p.parse_args()


def load_graph(session, args, graph):
    from measure import load

    load(session, args, graph)


def delete_edges(session, edges):
    for i in range(0, len(edges), 40):
        chunk = ", ".join(f"{s}->{d}@{r}" for s, d, r in edges[i : i + 40])
        execute(session, f"DELETE EDGE know {chunk}")


def log_lines(path, start):
    with open(path, "r", errors="replace") as fh:
        fh.seek(start)
        return [ln.strip() for ln in fh if "adaptive_multihop " in ln]


def parse_choice(line):
    fields = {}
    for part in line.split():
        if "=" in part and part.startswith(("choice", "walk_us", "ratio", "early", "hop", "rpc", "steps", "space")):
            k, v = part.split("=", 1)
            fields[k] = v
    return fields


def run_phase(session, space, sql, expect, n, log_path):
    rows = []
    for i in range(n):
        pos = os.path.getsize(log_path) if os.path.exists(log_path) else 0
        try:
            t_resp = execute(session, sql, tries=4)
        except RuntimeError as exc:
            rows.append({"i": i, "error": str(exc)})
            continue
        got = vids_of(t_resp)
        # The log line is written before the response is fully flushed, but
        # give a short beat if the line has not landed yet.
        lines = []
        for _ in range(20):
            lines = log_lines(log_path, pos)
            if lines:
                break
            time.sleep(0.05)
        choice = parse_choice(lines[-1]) if lines else {}
        rows.append(
            {
                "i": i,
                "latency_us": t_resp.latency(),
                "ok": got == expect,
                "got": len(got),
                "choice": choice.get("choice"),
                "walk_us": int(choice["walk_us"]) if "walk_us" in choice else None,
                "ratio": float(choice["ratio"]) if "ratio" in choice else None,
                "early": int(choice["early"]) if "early" in choice else None,
                "hop": int(choice["hop"]) if "hop" in choice else None,
                "rpc": int(choice["rpc"]) if "rpc" in choice else None,
                "log_lines": len(lines),
            }
        )
    return rows


def windows(rows, size):
    out = []
    for i in range(0, len(rows), size):
        chunk = rows[i : i + size]
        lats = [r["latency_us"] / 1000.0 for r in chunk if r.get("latency_us") is not None]
        choices = [r.get("choice") for r in chunk]
        out.append(
            {
                "from": i,
                "n": len(chunk),
                "ok": sum(1 for r in chunk if r.get("ok")),
                "errors": sum(1 for r in chunk if r.get("error")),
                "multi": sum(1 for c in choices if c == "multi"),
                "base": sum(1 for c in choices if c == "base"),
                "missing_choice": sum(1 for c in choices if c is None),
                "early": sum(1 for r in chunk if r.get("early") == 1),
                "p50_ms": pct(lats, 50),
                "p99_ms": pct(lats, 99),
                "rpc_median": pct([r["rpc"] for r in chunk if r.get("rpc") is not None], 50),
            }
        )
    return out


def main():
    args = parse_args()
    os.makedirs(args.results, exist_ok=True)
    aff = build(args.parts, args.community_size, args.degree, args.seed, placement="affinity")
    rnd = build(args.parts, args.community_size, args.degree, args.seed, placement="random")
    aff_expect = walk(aff["adj"], aff["seeds"], args.steps)
    rnd_expect = walk(rnd["adj"], rnd["seeds"], args.steps)
    client = Client(args.host, args.port)
    session = client.session()
    report = {
        "tag": args.tag,
        "space": args.space,
        "affinity_expect": len(aff_expect),
        "random_expect": len(rnd_expect),
        "note": "latency_us is ResultSet.latency(); choice comes from the graphd log of that query",
    }
    try:
        drop = session.execute(f"DROP SPACE IF EXISTS {args.space}")
        if not drop.is_succeeded() and "not existed" not in (drop.error_msg() or "").lower():
            # A missing space is fine. Anything else is reported and we still try to load.
            print("DROP SPACE", drop.error_msg())
        time.sleep(2)
        load_graph(session, args, aff)
        aff_sql = query(aff, args.steps)
        rnd_sql = query(rnd, args.steps)
        report["affinity"] = run_phase(
            session, args.space, aff_sql, aff_expect, args.affinity_queries, args.log
        )
        delete_edges(session, aff["edges"])
        # New vids and edges. Old affinity vertices stay; the new seeds do not use them.
        load_graph(session, args, rnd)
        report["random"] = run_phase(
            session, args.space, rnd_sql, rnd_expect, args.random_queries, args.log
        )
        report["affinity_windows"] = windows(report["affinity"], args.window)
        report["random_windows"] = windows(report["random"], args.window)
        print(json.dumps({"affinity_windows": report["affinity_windows"], "random_windows": report["random_windows"]}))
    finally:
        session.release()
        client.close()
    path = os.path.join(args.results, f"{args.tag}.json")
    with open(path, "w") as fh:
        json.dump(report, fh)
    print("wrote", path)


if __name__ == "__main__":
    main()
