#!/usr/bin/env python3
"""Affinity-local co-purchase vs v2 (NOAFFINITY) vs four-statement nGQL.

Latency is ResultSet.latency(), microseconds, reported in ms.
QPS is completed queries / wall clock of the wave.
rpc and payload come from copurchase_plan. They count storage RPCs and the
integer fields of the copurchase request and response, not TCP bytes.
veth_bytes is the sum of rx+tx on v-stor1..3 across the wave, including
heartbeats. CPU is utime+stime jiffies. RSS is VmRSS at the end of the wave.
"""

import argparse
import json
import os
import re
import sys
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

import numpy as np

_SCRIPT = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT not in sys.path:
    sys.path.insert(0, _SCRIPT)

from nebula3.Config import Config
from nebula3.gclient.net import ConnectionPool

from ground import exact
from measure import (
    baseline,
    cell,
    execute,
    log_text,
    percentile,
    proc_sample,
    table,
    wait_use,
)

PLAN_RE = re.compile(
    r"copurchase_plan mode=(\w+) fallback=(\d+) prune=(\d+) pruned=(\d+) sent=(\d+) "
    r"rounds=(\d+) buyers=(\d+) failure=(\S+) "
    r"hop_rows=([0-9,]+) hop_hosts=([0-9,]+) scanned=([0-9,]+) "
    r"users=(\S*) products=(\S*) "
    r"affinity=(\d+) stop=(\d+) reason=(\S+) ratio=([-\d.eE+]+) cov=([-\d.eE+]+) "
    r"rpc=(\d+) payload=(\d+)"
)


def connect(host, port):
    cfg = Config()
    cfg.max_connection_pool_size = 160
    cfg.timeout = 180000
    pool = ConnectionPool()
    deadline = time.time() + 90
    while time.time() < deadline:
        if pool.init([(host, port)], cfg):
            return pool
        time.sleep(1)
    raise SystemExit(f"cannot connect {host}:{port}")


def hosts_ready(session):
    resp = session.execute("SHOW HOSTS")
    if not resp.is_succeeded():
        return False
    online = 0
    for i in range(resp.row_size()):
        status = resp.row_values(i)[2].as_string()
        if status == "ONLINE":
            online += 1
    return online >= 3


def load(session, space, edges, product_ids, sales, parts, replica):
    deadline = time.time() + 60
    while time.time() < deadline:
        add = session.execute("ADD HOSTS 10.88.0.21:9779, 10.88.0.22:9779, 10.88.0.23:9779")
        if add.is_succeeded() or "Existed" in (add.error_msg() or ""):
            if hosts_ready(session):
                break
        time.sleep(1)
    else:
        raise SystemExit("storage hosts not online")
    execute(
        session,
        "CREATE SPACE IF NOT EXISTS "
        f"{space}(partition_num={parts}, replica_factor={replica}, vid_type=INT64)",
    )
    wait_use(session, space)
    execute(session, "CREATE TAG IF NOT EXISTS product(sales int)")
    execute(session, "CREATE TAG IF NOT EXISTS user()")
    execute(session, "CREATE EDGE IF NOT EXISTS buy()")
    deadline = time.time() + 90
    while time.time() < deadline:
        if (
            session.execute("DESCRIBE TAG product").is_succeeded()
            and session.execute("DESCRIBE TAG user").is_succeeded()
            and session.execute("DESCRIBE EDGE buy").is_succeeded()
        ):
            break
        time.sleep(1)
    else:
        raise SystemExit("schema not ready")
    users = sorted({int(u) for u in edges[:, 0]})
    sales_of = {int(product_ids[i]): int(sales[i]) for i in range(len(product_ids))}
    for i in range(0, len(users), 300):
        chunk = ", ".join(f"{uid}:()" for uid in users[i : i + 300])
        stmt = f"INSERT VERTEX user() VALUES {chunk}"
        deadline = time.time() + 60
        while time.time() < deadline:
            resp = session.execute(stmt)
            if resp.is_succeeded():
                break
            time.sleep(1)
        else:
            raise RuntimeError(resp.error_msg())
    pids = list(sales_of)
    for i in range(0, len(pids), 300):
        chunk = ", ".join(f"{pid}:({sales_of[pid]})" for pid in pids[i : i + 300])
        execute(session, f"INSERT VERTEX product(sales) VALUES {chunk}")
    total = len(edges)
    for i in range(0, total, 300):
        chunk = ", ".join(
            f"{int(edges[j, 0])}->{int(edges[j, 1])}@{int(edges[j, 2])}:()"
            for j in range(i, min(i + 300, total))
        )
        execute(session, f"INSERT EDGE buy() VALUES {chunk}")
        if i and i % 30000 == 0:
            print(f"inserted edges {i}/{total}", flush=True)
    print(f"loaded space={space} edges={total} users={len(users)} products={len(pids)}", flush=True)
    return sales_of


def indexes(edges):
    by_user = defaultdict(list)
    by_product = defaultdict(list)
    for user, pid, ts in edges.tolist():
        by_user[int(user)].append((int(pid), int(ts)))
        by_product[int(pid)].append((int(user), int(ts)))
    return by_user, by_product


def pushdown(session, user, start, end, mode):
    stmt = f"COPURCHASE FROM {user} WINDOW {start}, {end}"
    if mode == "v2":
        stmt += " NOAFFINITY"
    resp = execute(session, stmt)
    rows = []
    for i in range(resp.row_size()):
        rows.append(tuple(cell(v) for v in resp.row_values(i)))
    return rows, resp.latency()


def veth_bytes():
    total = 0
    missing = False
    for i in (1, 2, 3):
        for kind in ("rx_bytes", "tx_bytes"):
            path = f"/sys/class/net/v-stor{i}/statistics/{kind}"
            try:
                total += int(open(path, encoding="utf-8").read())
            except OSError:
                missing = True
    return None if missing else total


def parse_plans(text):
    plans = []
    for match in PLAN_RE.finditer(text):
        plans.append(
            {
                "mode": match.group(1),
                "fallback": int(match.group(2)),
                "rounds": int(match.group(6)),
                "buyers": int(match.group(7)),
                "failure": match.group(8),
                "hop_hosts": [int(x) for x in match.group(10).split(",")],
                "affinity": int(match.group(14)),
                "stop": int(match.group(15)),
                "reason": match.group(16),
                "ratio": float(match.group(17)),
                "cov": float(match.group(18)),
                "rpc": int(match.group(19)),
                "payload": int(match.group(20)),
                "users": match.group(12),
                "products": match.group(13),
            }
        )
    return plans


def wave(pool, jobs):
    errors = []
    lats = []
    started = time.perf_counter()

    def one(job):
        session = pool.get_session("root", "nebula")
        try:
            wait_use(session, job["space"])
            if job["mode"] == "ngql":
                _users, products, lat, _rounds, _info = baseline(
                    session, job["user"], job["start"], job["end"]
                )
                return lat, products
            _rows, lat = pushdown(session, job["user"], job["start"], job["end"], job["mode"])
            return lat, _rows
        finally:
            session.release()

    workers = 1 if jobs and jobs[0].get("conc", 1) == 1 else max(1, len(jobs))
    with ThreadPoolExecutor(max_workers=workers) as pool_ex:
        futs = [pool_ex.submit(one, job) for job in jobs]
        for fut in futs:
            try:
                lat, _rows = fut.result()
                lats.append(lat)
            except Exception as exc:  # noqa: BLE001 - recorded, not swallowed
                errors.append(str(exc))
    wall = time.perf_counter() - started
    return lats, errors, wall


def summarize(lats, errors, wall, n):
    return {
        "n": n,
        "errors": len(errors),
        "error_sample": errors[:3],
        "p50_ms": None if not lats else percentile(lats, 50) / 1000.0,
        "p99_ms": None if not lats else percentile(lats, 99) / 1000.0,
        "qps": None if wall <= 0 else (n - len(errors)) / wall,
        "wall_s": wall,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--graph", required=True)
    parser.add_argument("--space", required=True)
    parser.add_argument("--host", default="10.88.0.31")
    parser.add_argument("--port", type=int, default=9669)
    parser.add_argument("--parts", type=int, default=9)
    parser.add_argument("--log-dir", default="/tmp/nebula-dist/graph1/logs")
    parser.add_argument("--out", required=True)
    parser.add_argument("--skip-load", action="store_true")
    parser.add_argument("--label", default="")
    parser.add_argument("--concs", default="1,50,100")
    parser.add_argument("--latency-n", type=int, default=20)
    parser.add_argument("--accuracy-users", type=int, default=8)
    args = parser.parse_args()

    blob = np.load(args.graph)
    edges = blob["edges"]
    product_ids = blob["product_ids"]
    sales_arr = blob["sales"]
    meta_path = os.path.splitext(args.graph)[0] + ".json"
    meta = json.load(open(meta_path, encoding="utf-8"))
    start, end = meta["window_30d"]
    pool = connect(args.host, args.port)
    session = pool.get_session("root", "nebula")
    sales = None
    try:
        if args.skip_load:
            wait_use(session, args.space)
            sales = {int(product_ids[i]): int(sales_arr[i]) for i in range(len(product_ids))}
        else:
            sales = load(session, args.space, edges, product_ids, sales_arr, args.parts, 1)
    finally:
        session.release()

    by_user, by_product = indexes(edges)
    users = sorted(by_user)
    # The local chain is attempted only after a finished sample has been
    # heartbeated to graphd. Probe until the plan says so, or the wait expires.
    warmup = {"reason": None, "waited_s": 0}
    probe = pool.get_session("root", "nebula")
    try:
        wait_use(probe, args.space)
        t0 = time.time()
        offset_w = {}
        while time.time() - t0 < 45:
            _text, offset_w = log_text(args.log_dir, offset_w)
            try:
                pushdown(probe, users[0], start, end, "local")
            except Exception as exc:  # noqa: BLE001
                warmup["error"] = str(exc)
                break
            text_w, offset_w = log_text(args.log_dir, offset_w)
            found = parse_plans(text_w)
            if found:
                warmup["reason"] = found[-1]["reason"]
                warmup["mode"] = found[-1]["mode"]
                warmup["ratio"] = found[-1]["ratio"]
                warmup["cov"] = found[-1]["cov"]
                warmup["stop"] = found[-1]["stop"]
                if found[-1]["mode"] == "local" or found[-1]["reason"] in ("stats", "ratio", "cov"):
                    break
            time.sleep(2)
        warmup["waited_s"] = round(time.time() - t0, 3)
    finally:
        probe.release()
    print(f"warmup {warmup}", flush=True)
    acc_users = [users[int(i * 997) % len(users)] for i in range(args.accuracy_users)]
    session = pool.get_session("root", "nebula")
    accuracy = []
    try:
        wait_use(session, args.space)
        for mode in ("local", "v2", "ngql"):
            for user in acc_users:
                truth = exact(by_user, by_product, sales, user, start, end)
                if mode == "ngql":
                    _u, products, _lat, _r, _info = baseline(session, user, start, end)
                    got = products
                else:
                    got, _lat = pushdown(session, user, start, end, mode)
                same = [(int(a), int(b)) for a, b in got] == [
                    (int(a), int(b)) for a, b in truth["products"]
                ]
                accuracy.append({"mode": mode, "user": int(user), "same": bool(same), "got": len(got)})
                if not same:
                    print(
                        f"MISMATCH mode={mode} user={user} got={got} truth={truth['products']}",
                        flush=True,
                    )
    finally:
        session.release()

    offset = {}
    _ignored, offset = log_text(args.log_dir, offset)
    concs = [int(x) for x in args.concs.split(",") if x]
    latency = {}
    before_cpu = {
        "graphd": proc_sample("nebula-graphd"),
        "storaged": proc_sample("nebula-storaged"),
    }
    for mode in ("local", "v2", "ngql"):
        for conc in concs:
            n = args.latency_n if conc == 1 else conc
            jobs = []
            for i in range(n):
                jobs.append(
                    {
                        "space": args.space,
                        "mode": mode,
                        "user": users[i % len(users)],
                        "start": start,
                        "end": end,
                        "conc": conc,
                    }
                )
            v0 = veth_bytes()
            cpu0 = {
                "graphd": proc_sample("nebula-graphd"),
                "storaged": proc_sample("nebula-storaged"),
            }
            lats, errors, wall = wave(pool, jobs)
            v1 = veth_bytes()
            cpu1 = {
                "graphd": proc_sample("nebula-graphd"),
                "storaged": proc_sample("nebula-storaged"),
            }
            cell_report = summarize(lats, errors, wall, n)
            cell_report["veth_bytes"] = None if v0 is None or v1 is None else v1 - v0
            cell_report["veth_note"] = "v-stor1..3 rx+tx delta, includes heartbeats"
            def delta(kind):
                prev = {row["pid"]: row for row in cpu0[kind]}
                out = []
                for row in cpu1[kind]:
                    old = prev.get(row["pid"])
                    if old is None:
                        continue
                    out.append(
                        {
                            "pid": row["pid"],
                            "cpu_jiffies": row["cpu_jiffies"] - old["cpu_jiffies"],
                            "rss_kb": row["rss_kb"],
                        }
                    )
                return out
            cell_report["graphd"] = delta("graphd")
            cell_report["storaged"] = delta("storaged")
            latency[f"{mode}/c{conc}"] = cell_report
            print(
                f"{args.label} {mode} c={conc} p50={cell_report['p50_ms']} "
                f"p99={cell_report['p99_ms']} qps={cell_report['qps']} "
                f"err={cell_report['errors']} veth={cell_report['veth_bytes']}",
                flush=True,
            )
    text, _offset = log_text(args.log_dir, offset)
    plans = parse_plans(text)
    report = {
        "label": args.label,
        "warmup": warmup,
        "meta": meta,
        "window": [start, end],
        "accuracy": accuracy,
        "accuracy_same": sum(1 for row in accuracy if row["same"]),
        "accuracy_n": len(accuracy),
        "latency": latency,
        "plans_n": len(plans),
        "plans_mode": {},
        "cpu_rss_note": "jiffies are utime+stime over the wave; rss_kb is VmRSS after the wave",
    }
    for plan in plans:
        slot = report["plans_mode"].setdefault(plan["mode"], {"n": 0, "rpc": [], "payload": [], "reason": {}})
        slot["n"] += 1
        slot["rpc"].append(plan["rpc"])
        slot["payload"].append(plan["payload"])
        slot["reason"][plan["reason"]] = slot["reason"].get(plan["reason"], 0) + 1
    for slot in report["plans_mode"].values():
        slot["rpc_p50"] = percentile(slot["rpc"], 50)
        slot["payload_p50"] = percentile(slot["payload"], 50)
    # The process sample before the waves is recorded so a reader can see the
    # pids. It is not a latency number.
    report["procs_before"] = {k: len(v) for k, v in before_cpu.items()}
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)
        fh.write("\n")
    print(f"wrote {args.out} accuracy {report['accuracy_same']}/{report['accuracy_n']}", flush=True)
    pool.close()


if __name__ == "__main__":
    main()
