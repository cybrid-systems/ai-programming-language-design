#!/usr/bin/env python3
"""Load an affinity or shuffled community graph and time GO 3 STEPS.

Every latency is ResultSet.latency() (graphd microseconds). The oracle is
gen_data.walk on the same edge list. Nothing is filled in when a query fails.
"""

import argparse
import json
import math
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

_SCRIPT = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT not in sys.path:
    sys.path.insert(0, _SCRIPT)

from gen_data import build, walk
from nebula3.Config import Config
from nebula3.gclient.net import ConnectionPool


def pct(values, p):
    if not values:
        return None
    xs = sorted(values)
    k = (len(xs) - 1) * p / 100.0
    lo = math.floor(k)
    hi = math.ceil(k)
    if lo == hi:
        return xs[int(k)]
    return xs[lo] * (hi - k) + xs[hi] * (k - lo)


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=9669)
    p.add_argument("--storage-hosts", default="", help="comma-separated ip:port to ADD HOSTS")
    p.add_argument("--space", required=True)
    p.add_argument("--parts", type=int, default=9)
    p.add_argument("--replica", type=int, default=1)
    p.add_argument("--community-size", type=int, default=400)
    p.add_argument("--degree", type=int, default=8)
    p.add_argument("--seed", type=int, default=7)
    p.add_argument("--affinity", choices=["true", "false"], required=True)
    p.add_argument("--steps", type=int, default=3)
    p.add_argument("--concurrency", default="1,10,50,100,200")
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--warmup", type=int, default=1)
    p.add_argument("--tag", default="run")
    p.add_argument("--results", default=os.path.join(_SCRIPT, "results"))
    p.add_argument("--load-only", action="store_true")
    p.add_argument("--skip-load", action="store_true")
    return p.parse_args()


class Client:
    def __init__(self, host, port):
        cfg = Config()
        cfg.max_connection_pool_size = 32
        cfg.timeout = 180000
        self.pool = ConnectionPool()
        if not self.pool.init([(host, port)], cfg):
            raise RuntimeError(f"connect {host}:{port} failed")

    def session(self):
        return self.pool.get_session("root", "nebula")

    def close(self):
        self.pool.close()


def execute(session, stmt, tries=8):
    last = None
    for _ in range(tries):
        resp = session.execute(stmt)
        if resp.is_succeeded():
            return resp
        last = resp.error_msg()
        low = (last or "").lower()
        if any(s in low for s in ("not the leader", "leader changed", "not enough", "timeout")):
            time.sleep(1.5)
            continue
        break
    raise RuntimeError(f"{stmt[:160]} -> {last}")


def wait_use(session, space):
    deadline = time.time() + 180
    while time.time() < deadline:
        resp = session.execute(f"USE {space}")
        if resp.is_succeeded():
            return
        time.sleep(2)
    raise RuntimeError(f"USE {space} timed out")


def load(session, args, graph):
    hosts = [h.strip() for h in args.storage_hosts.split(",") if h.strip()]
    if not hosts:
        hosts = [f"{args.host}:9779"]
    add = session.execute("ADD HOSTS " + ", ".join(hosts))
    if not add.is_succeeded() and "Existed" not in (add.error_msg() or ""):
        print("ADD HOSTS", add.error_msg())
    execute(
        session,
        "CREATE SPACE IF NOT EXISTS "
        f"{args.space}(partition_num={args.parts}, replica_factor={args.replica}, vid_type=INT64)",
    )
    wait_use(session, args.space)
    execute(session, "CREATE TAG IF NOT EXISTS person(name string)")
    execute(session, "CREATE EDGE IF NOT EXISTS know()")
    vids = graph["vids"]
    edges = graph["edges"]

    def insert_all():
        for i in range(0, len(vids), 200):
            chunk = ", ".join(f'{v}:("n")' for v in vids[i : i + 200])
            execute(session, f"INSERT VERTEX IF NOT EXISTS person(name) VALUES {chunk}")
        for i in range(0, len(edges), 200):
            chunk = ", ".join(f"{s}->{d}@{r}:()" for s, d, r in edges[i : i + 200])
            execute(session, f"INSERT EDGE IF NOT EXISTS know() VALUES {chunk}")

    deadline = time.time() + 60
    last = None
    while time.time() < deadline:
        try:
            insert_all()
            return
        except RuntimeError as exc:
            last = exc
            if "No schema" not in str(exc) and "not the leader" not in str(exc).lower():
                raise
            time.sleep(3)
    raise RuntimeError(f"schema not ready: {last}")


def query(graph, steps):
    seeds = ", ".join(str(v) for v in graph["seeds"])
    return f"GO {steps} STEPS FROM {seeds} OVER know YIELD DISTINCT know._dst AS dst"


def vids_of(resp):
    got = set()
    for i in range(resp.row_size()):
        got.add(int(resp.row_values(i)[0].as_int()))
    return got


def profile_summary(resp):
    hosts = []
    applied = []
    names = []
    if not resp.plan_desc():
        return {"plan": names, "hosts": hosts, "applied": applied}
    for node in resp.plan_desc().plan_node_descs:
        name = node.name.decode() if isinstance(node.name, (bytes, bytearray)) else str(node.name)
        names.append(name)
        for st in node.profiles or []:
            for k, v in (st.other_stats or {}).items():
                key = k.decode() if isinstance(k, (bytes, bytearray)) else str(k)
                val = v.decode() if isinstance(v, (bytes, bytearray)) else str(v)
                if key.startswith("local_multihop"):
                    applied.append(val)
                if key.startswith("step") and val.startswith("{"):
                    try:
                        parsed = json.loads(val)
                    except json.JSONDecodeError:
                        parsed = {"raw": val}
                    hosts.append(
                        {
                            "state": key,
                            "host": parsed.get("host"),
                            "vertices": parsed.get("vertices"),
                        }
                    )
    return {"plan": names, "hosts": hosts, "applied": applied}


def bench(host, port, space, sql, concurrency, warmup, rounds):
    client = Client(host, port)
    errors = []
    lat_us = []

    def one(_):
        session = client.session()
        try:
            session.execute(f"USE {space}")
            for _i in range(warmup):
                session.execute(sql)
            samples = []
            for _i in range(rounds):
                resp = session.execute(sql)
                if not resp.is_succeeded():
                    return {"error": resp.error_msg(), "samples": samples}
                samples.append(resp.latency())
            return {"samples": samples}
        finally:
            session.release()

    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futs = [pool.submit(one, i) for i in range(concurrency)]
        for fut in as_completed(futs):
            item = fut.result()
            if item.get("error"):
                errors.append(item["error"])
            lat_us.extend(item["samples"])
    wall = time.perf_counter() - t0
    client.close()
    ms = [v / 1000.0 for v in lat_us]
    return {
        "concurrency": concurrency,
        "samples": len(ms),
        "errors": errors[:3],
        "error_count": len(errors),
        "server_ms": {
            "p50": pct(ms, 50),
            "p95": pct(ms, 95),
            "p99": pct(ms, 99),
            "min": min(ms) if ms else None,
            "max": max(ms) if ms else None,
        },
        "qps": (len(ms) / wall) if wall > 0 else None,
        "wall_s": wall,
    }


def main():
    args = parse_args()
    graph = build(
        args.parts,
        args.community_size,
        args.degree,
        args.seed,
        args.affinity == "true",
    )
    expect = walk(graph["adj"], graph["seeds"], args.steps)
    os.makedirs(args.results, exist_ok=True)
    client = Client(args.host, args.port)
    session = client.session()
    report = {
        "tag": args.tag,
        "space": args.space,
        "affinity": args.affinity == "true",
        "parts": args.parts,
        "replica": args.replica,
        "community_size": args.community_size,
        "degree": args.degree,
        "edges": len(graph["edges"]),
        "seeds": graph["seeds"],
        "expect": len(expect),
    }
    try:
        if not args.skip_load:
            load(session, args, graph)
        else:
            wait_use(session, args.space)
        if args.load_only:
            report["loaded"] = True
            path = os.path.join(args.results, f"{args.tag}.json")
            with open(path, "w") as fh:
                json.dump(report, fh)
            print("loaded", path)
            return
        sql = query(graph, args.steps)
        report["sql"] = sql
        resp = execute(session, sql)
        got = vids_of(resp)
        report["check"] = {
            "ok": got == expect,
            "got": len(got),
            "expect": len(expect),
            "missing": sorted(expect - got)[:8],
            "extra": sorted(got - expect)[:8],
            "latency_us": resp.latency(),
        }
        prof = execute(session, "PROFILE " + sql)
        report["profile"] = profile_summary(prof)
        report["profile_us"] = prof.latency()
        print(json.dumps({"check": report["check"], "applied": report["profile"]["applied"], "hosts": report["profile"]["hosts"]}))
        if not report["check"]["ok"]:
            raise SystemExit("oracle mismatch")
        report["levels"] = []
        for n in [int(x) for x in args.concurrency.split(",") if x.strip()]:
            level = bench(args.host, args.port, args.space, sql, n, args.warmup, args.rounds)
            report["levels"].append(level)
            print(json.dumps({"c": n, "p50": level["server_ms"]["p50"], "qps": level["qps"], "errors": level["error_count"]}))
    finally:
        session.release()
        client.close()
    path = os.path.join(args.results, f"{args.tag}.json")
    with open(path, "w") as fh:
        json.dump(report, fh)
    print("wrote", path)


if __name__ == "__main__":
    main()
