#!/usr/bin/env python3
"""Load scenario-2 data and measure the stock, patched, and model plans.

Numbers written under results/ come from this process. The script never fills
in a latency it did not record. Server latency is ResultSet.latency()
(graphd latency_in_us). Client latency is wall time around session.execute,
which includes Python decode of the result.
"""

import argparse
import hashlib
import json
import math
import os
import platform
import socket
import sys
import threading
import time

# This directory contains concurrent.py, which shadows the stdlib package when
# the script's own directory is on sys.path[0].
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path = [p for p in sys.path if os.path.abspath(p or os.getcwd()) != _SCRIPT_DIR]
from concurrent.futures import ThreadPoolExecutor, as_completed  # noqa: E402

sys.path.insert(0, _SCRIPT_DIR)
from gen_data import make_dataset  # noqa: E402


STOCK_SPACE = "beauty_stock"
MODEL_SPACE = "beauty_model"

TRANSIENT = (
    "spacenotfound",
    "not the leader",
    "leader changed",
    "host not enough",
    "not enough",
    "tagnotfound",
    "edgenotfound",
    "not found",
    "not exist",
    "not existed",
    "schema",
    "timeout",
    "not ready",
    "part",
    "leader",
    "retry",
    "io error",
    "vid len",
    "space not found",
)


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("phase", choices=["load", "measure"])
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=9669)
    p.add_argument("--user", default="root")
    p.add_argument("--password", default="nebula")
    p.add_argument("--users", type=int, default=4000)
    p.add_argument("--items", type=int, default=2000)
    p.add_argument("--edges", type=int, default=500000)
    p.add_argument("--beauty-ratio", type=float, default=0.2)
    p.add_argument("--recent-ratio", type=float, default=0.4)
    p.add_argument("--now", type=int, default=1761436800)
    p.add_argument("--window", type=int, default=90 * 24 * 3600)
    p.add_argument("--seed", type=int, default=2)
    p.add_argument("--parts", type=int, default=10)
    p.add_argument("--batch", type=int, default=250)
    p.add_argument("--tag", default="run", help="result file prefix, e.g. flag_off")
    p.add_argument("--queries", default="q_users,q_sales,q_model")
    p.add_argument("--concurrency", default="1,10,50,100,200")
    p.add_argument("--warmup", type=int, default=2)
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--results", default=os.path.join(os.path.dirname(__file__), "results"))
    return p.parse_args()


def q_users(cutoff):
    return (
        'LOOKUP ON item WHERE item.type == "beauty" YIELD id(vertex) AS id '
        f"| GO 1 STEP FROM $-.id OVER buy REVERSELY WHERE buy.ts > {cutoff} "
        "YIELD DISTINCT buy._dst AS user"
    )


def q_sales(cutoff):
    return (
        'LOOKUP ON item WHERE item.type == "beauty" YIELD id(vertex) AS id '
        f"| GO 1 STEP FROM $-.id OVER buy REVERSELY WHERE buy.ts > {cutoff} "
        "YIELD buy._dst AS uid, buy.amount AS amt "
        "| GROUP BY $-.uid YIELD $-.uid AS uid, sum($-.amt) AS sales "
        "| ORDER BY $-.sales DESC | LIMIT 100"
    )


def q_sales_all(cutoff):
    return (
        'LOOKUP ON item WHERE item.type == "beauty" YIELD id(vertex) AS id '
        f"| GO 1 STEP FROM $-.id OVER buy REVERSELY WHERE buy.ts > {cutoff} "
        "YIELD buy._dst AS uid, buy.amount AS amt "
        "| GROUP BY $-.uid YIELD $-.uid AS uid, sum($-.amt) AS sales"
    )


def q_model(cutoff):
    return (
        'LOOKUP ON buy WHERE buy.item_type == "beauty" AND buy.ts > '
        f"{cutoff} YIELD src(edge) AS user"
    )


def q_model_distinct(cutoff):
    # DISTINCT is a graphd dedup of the index rows. The index scan itself is unchanged.
    return (
        'LOOKUP ON buy WHERE buy.item_type == "beauty" AND buy.ts > '
        f"{cutoff} YIELD DISTINCT src(edge) AS user"
    )


def q_count(cutoff):
    # Same scan as q_sales, but COUNT. Partial agg merges counts with SUM.
    return (
        'LOOKUP ON item WHERE item.type == "beauty" YIELD id(vertex) AS id '
        f"| GO 1 STEP FROM $-.id OVER buy REVERSELY WHERE buy.ts > {cutoff} "
        "YIELD buy._dst AS uid, buy.amount AS amt "
        "| GROUP BY $-.uid YIELD $-.uid AS uid, count($-.amt) AS n"
    )


def q_by_amount(cutoff):
    # Group key is the amount, not the dst. The partial-agg rule must leave this
    # on ExpandAll. Every matching edge is counted once.
    return (
        'LOOKUP ON item WHERE item.type == "beauty" YIELD id(vertex) AS id '
        f"| GO 1 STEP FROM $-.id OVER buy REVERSELY WHERE buy.ts > {cutoff} "
        "YIELD buy.amount AS amt "
        "| GROUP BY $-.amt YIELD $-.amt AS amt, count(*) AS n"
    )


QUERIES = {
    "q_users": {"space": STOCK_SPACE, "sql": q_users, "kind": "users"},
    "q_sales": {"space": STOCK_SPACE, "sql": q_sales, "kind": "sales_top"},
    "q_count": {"space": STOCK_SPACE, "sql": q_count, "kind": "counts"},
    "q_by_amount": {"space": STOCK_SPACE, "sql": q_by_amount, "kind": "amount_groups"},
    "q_model": {"space": MODEL_SPACE, "sql": q_model, "kind": "users_dup"},
    "q_model_distinct": {"space": MODEL_SPACE, "sql": q_model_distinct, "kind": "users"},
}


def hardware():
    cpu = ""
    try:
        with open("/proc/cpuinfo", encoding="utf-8") as f:
            for line in f:
                if line.lower().startswith("model name"):
                    cpu = line.split(":", 1)[1].strip()
                    break
    except OSError:
        pass
    mem = {}
    try:
        with open("/proc/meminfo", encoding="utf-8") as f:
            for line in f:
                if line.startswith(("MemTotal", "MemAvailable", "SwapTotal")):
                    mem[line.split(":")[0]] = line.split(":", 1)[1].strip()
    except OSError:
        pass
    return {
        "platform": platform.platform(),
        "machine": platform.machine(),
        "python": platform.python_version(),
        "cpu_model": cpu,
        "cpu_count": os.cpu_count(),
        "meminfo": mem,
        "hostname": socket.gethostname(),
    }


def dec(value):
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return value


def cell(value):
    if value.is_null() or value.is_empty():
        return None
    if value.is_int():
        return value.as_int()
    if value.is_double():
        return value.as_double()
    if value.is_string():
        return value.as_string()
    if value.is_bool():
        return value.as_bool()
    return str(value)


def rows_of(resp):
    out = []
    for i in range(resp.row_size()):
        out.append([cell(v) for v in resp.row_values(i)])
    return out


def plan_to_dict(plan):
    if plan is None:
        return None
    nodes = []
    for node in plan.plan_node_descs or []:
        profiles = []
        for stat in node.profiles or []:
            other = stat.other_stats or {}
            profiles.append(
                {
                    "rows": stat.rows,
                    "exec_duration_in_us": stat.exec_duration_in_us,
                    "total_duration_in_us": stat.total_duration_in_us,
                    "other_stats": {dec(k): dec(v) for k, v in other.items()},
                }
            )
        desc = []
        for pair in node.description or []:
            desc.append({"key": dec(pair.key), "value": dec(pair.value)})
        nodes.append(
            {
                "name": dec(node.name),
                "id": node.id,
                "description": desc,
                "profiles": profiles,
                "dependencies": list(node.dependencies or []),
            }
        )
    return {
        "optimize_time_in_us": plan.optimize_time_in_us,
        "nodes": nodes,
    }


def percentile(sorted_vals, p):
    """Linear interpolation. rank = p/100 * (n-1)."""
    n = len(sorted_vals)
    if n == 0:
        return None
    if n == 1:
        return sorted_vals[0]
    rank = (p / 100.0) * (n - 1)
    lo = int(math.floor(rank))
    hi = min(lo + 1, n - 1)
    frac = rank - lo
    return sorted_vals[lo] * (1.0 - frac) + sorted_vals[hi] * frac


def summarize(samples):
    ok = [s for s in samples if s["ok"]]
    bad = [s for s in samples if not s["ok"]]
    client = sorted(s["client_ms"] for s in ok)
    server = sorted(s["server_us"] / 1000.0 for s in ok if s["server_us"] is not None)
    rows = sorted({s["rows"] for s in ok})
    return {
        "samples": len(samples),
        "ok": len(ok),
        "errors": len(bad),
        "first_error": bad[0]["error"] if bad else None,
        "client_ms": {
            "p50": percentile(client, 50),
            "p95": percentile(client, 95),
            "p99": percentile(client, 99),
            "min": client[0] if client else None,
            "max": client[-1] if client else None,
        },
        "server_ms": {
            "p50": percentile(server, 50),
            "p95": percentile(server, 95),
            "p99": percentile(server, 99),
            "min": server[0] if server else None,
            "max": server[-1] if server else None,
        },
        "row_counts": rows,
    }


class Nebula:
    def __init__(self, args):
        from nebula3.Config import Config
        from nebula3.gclient.net import ConnectionPool

        self.args = args
        self.Config = Config
        self.ConnectionPool = ConnectionPool
        config = Config()
        config.max_connection_pool_size = 8
        config.timeout = 120000
        self.pool = ConnectionPool()
        if not self.pool.init([(args.host, args.port)], config):
            raise RuntimeError(f"pool init failed {args.host}:{args.port}")

    def session(self):
        return self.pool.get_session(self.args.user, self.args.password)

    def close(self):
        self.pool.close()


def execute(session, stmt, attempts=40):
    last = None
    for i in range(attempts):
        resp = session.execute(stmt)
        if resp.is_succeeded():
            return resp
        msg = resp.error_msg() or ""
        last = f"code={resp.error_code()} msg={msg}"
        low = msg.lower()
        if not any(token in low for token in TRANSIENT):
            raise RuntimeError(f"FAILED {stmt[:400]}\n{last}")
        time.sleep(min(2 + i // 4, 5))
    raise RuntimeError(f"FAILED after retries {stmt[:400]}\n{last}")


def wait_hosts(session, timeout=180):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        add = session.execute("ADD HOSTS 127.0.0.1:9779")
        show = session.execute("SHOW HOSTS")
        if show.is_succeeded():
            rows = rows_of(show)
            last = rows
            blob = " ".join(str(c) for row in rows for c in row).upper()
            print(f"SHOW HOSTS {rows} add_ok={add.is_succeeded()} add_msg={add.error_msg()}", flush=True)
            if "ONLINE" in blob:
                return rows
        else:
            print(f"SHOW HOSTS failed {show.error_msg()}", flush=True)
        time.sleep(3)
    raise RuntimeError(f"storage host not ONLINE: {last}")


def wait_use(session, space, timeout=180):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        resp = session.execute(f"USE {space}")
        if resp.is_succeeded():
            return
        last = resp.error_msg()
        time.sleep(2)
    raise RuntimeError(f"USE {space} failed: {last}")


def batched(session, prefix, values, batch):
    total = len(values)
    for i in range(0, total, batch):
        chunk = values[i : i + batch]
        execute(session, prefix + ", ".join(chunk))
        done = min(i + batch, total)
        if done == total or (i // batch) % 20 == 0:
            print(f"  {prefix[:48]} {done}/{total}", flush=True)


def job_status(rows):
    """SHOW JOB's first row is (id, command, status, ...). Later rows are counters.

    Those counters contain the substring 'Failed:0', so status has to come from
    the status column only.
    """
    if not rows or len(rows[0]) < 3:
        return ""
    return str(rows[0][2]).upper()


def rebuild(session, stmt):
    last_err = None
    for attempt in range(10):
        try:
            return rebuild_once(session, stmt)
        except RuntimeError as exc:
            last_err = exc
            text = str(exc)
            if "E_INDEX_NOT_FOUND" not in text and "not found" not in text.lower():
                raise
            print(f"retry {stmt} attempt={attempt} after schema heartbeat", flush=True)
            time.sleep(4)
    raise last_err


def rebuild_once(session, stmt):
    resp = execute(session, stmt)
    rows = rows_of(resp)
    print(f"{stmt} -> {rows}", flush=True)
    job_id = None
    if rows and rows[0] and isinstance(rows[0][0], int):
        job_id = rows[0][0]
    if job_id is None:
        raise RuntimeError(f"no job id from {stmt}: {rows}")
    deadline = time.time() + 900
    last = None
    while time.time() < deadline:
        show = execute(session, f"SHOW JOB {job_id}")
        last = rows_of(show)
        status = job_status(last)
        print(f"  job {job_id} status={status} {last}", flush=True)
        if status in ("FAILED", "STOPPED", "REMOVED"):
            raise RuntimeError(f"job {job_id} failed: {last}")
        if status == "FINISHED":
            return last
        time.sleep(3)
    raise RuntimeError(f"job {job_id} timeout: {last}")


def drop_spaces(session):
    for space in (STOCK_SPACE, MODEL_SPACE):
        resp = session.execute(f"DROP SPACE IF EXISTS {space}")
        if not resp.is_succeeded():
            # Older parsers reject IF EXISTS; a missing space is fine.
            msg = (resp.error_msg() or "").lower()
            if "not exist" not in msg and "not found" not in msg:
                alt = session.execute(f"DROP SPACE {space}")
                if not alt.is_succeeded():
                    alt_msg = (alt.error_msg() or "").lower()
                    if "not exist" not in alt_msg and "not found" not in alt_msg:
                        raise RuntimeError(f"DROP SPACE {space}: {resp.error_msg()} / {alt.error_msg()}")
        print(f"dropped {space}", flush=True)
    deadline = time.time() + 120
    while time.time() < deadline:
        show = execute(session, "SHOW SPACES")
        names = set()
        for row in rows_of(show):
            names.update(str(c) for c in row)
        if STOCK_SPACE not in names and MODEL_SPACE not in names:
            # Storage drops parts on the next heartbeats. Recreating sooner
            # makes INSERT fail with "Invalid space vid len".
            print("spaces gone from meta; waiting for storage to drop parts", flush=True)
            time.sleep(20)
            return
        time.sleep(2)
    raise RuntimeError("spaces still present after DROP")


def load(args, data):
    client = Nebula(args)
    session = client.session()
    try:
        wait_hosts(session)
        drop_spaces(session)
        for space in (STOCK_SPACE, MODEL_SPACE):
            execute(
                session,
                "CREATE SPACE IF NOT EXISTS "
                f"{space}(partition_num={args.parts}, replica_factor=1, vid_type=INT64)",
            )
            print(f"created {space}", flush=True)
        for space in (STOCK_SPACE, MODEL_SPACE):
            wait_use(session, space)
            print(f"USE {space} ok", flush=True)

        wait_use(session, STOCK_SPACE)
        for stmt in (
            "CREATE TAG IF NOT EXISTS user(name string)",
            "CREATE TAG IF NOT EXISTS item(name string, type string)",
            "CREATE EDGE IF NOT EXISTS buy(ts int, amount double)",
        ):
            execute(session, stmt)
        user_vals = [f'{uid}:("{name}")' for uid, name in data["users"]]
        item_vals = [f'{vid}:("{name}", "{kind}")' for vid, name, kind in data["items"]]
        edge_vals = [
            f"{uid}->{iid}@{rank}:({ts}, {amount})"
            for uid, iid, rank, ts, amount, _kind in data["edges"]
        ]
        print("insert stock", flush=True)
        batched(session, "INSERT VERTEX user(name) VALUES ", user_vals, args.batch)
        batched(session, "INSERT VERTEX item(name, type) VALUES ", item_vals, args.batch)
        batched(session, "INSERT EDGE buy(ts, amount) VALUES ", edge_vals, args.batch)
        execute(session, "CREATE TAG INDEX IF NOT EXISTS item_type_idx ON item(type(16))")
        rebuild(session, "REBUILD TAG INDEX item_type_idx")

        wait_use(session, MODEL_SPACE)
        for stmt in (
            "CREATE TAG IF NOT EXISTS user(name string)",
            "CREATE TAG IF NOT EXISTS item(name string, type string)",
            "CREATE EDGE IF NOT EXISTS buy(ts int, amount double, item_type string)",
        ):
            execute(session, stmt)
        model_vals = [
            f'{uid}->{iid}@{rank}:({ts}, {amount}, "{kind}")'
            for uid, iid, rank, ts, amount, kind in data["edges"]
        ]
        print("insert model", flush=True)
        batched(session, "INSERT VERTEX user(name) VALUES ", user_vals, args.batch)
        batched(session, "INSERT VERTEX item(name, type) VALUES ", item_vals, args.batch)
        batched(session, "INSERT EDGE buy(ts, amount, item_type) VALUES ", model_vals, args.batch)
        execute(session, "CREATE TAG INDEX IF NOT EXISTS item_type_idx ON item(type(16))")
        execute(
            session,
            "CREATE EDGE INDEX IF NOT EXISTS buy_type_ts_idx ON buy(item_type(16), ts)",
        )
        rebuild(session, "REBUILD TAG INDEX item_type_idx")
        rebuild(session, "REBUILD EDGE INDEX buy_type_ts_idx")
    finally:
        session.release()
        client.close()


def column(resp, name):
    keys = list(resp.keys())
    if name not in keys:
        raise RuntimeError(f"column {name} not in {keys}")
    idx = keys.index(name)
    return [cell(resp.row_values(i)[idx]) for i in range(resp.row_size())]


def user_set(resp):
    return set(column(resp, "user"))


def sales_map(resp):
    keys = list(resp.keys())
    ui = keys.index("uid")
    si = keys.index("sales")
    out = {}
    for i in range(resp.row_size()):
        row = resp.row_values(i)
        out[cell(row[ui])] = cell(row[si])
    return out


def digest(ids):
    blob = "\n".join(str(i) for i in sorted(ids)).encode()
    return hashlib.sha256(blob).hexdigest()


def check_users(name, got, expect):
    missing = sorted(expect - got)[:20]
    extra = sorted(got - expect)[:20]
    ok = got == expect
    return {
        "name": name,
        "ok": ok,
        "got": len(got),
        "expect": len(expect),
        "missing_sample": missing,
        "extra_sample": extra,
        "sha256": digest(got),
        "expect_sha256": digest(expect),
    }


def check_sales(got, expect):
    bad = []
    for uid, exp in expect.items():
        g = got.get(uid)
        if g is None or abs(float(g) - float(exp)) > 1e-4:
            bad.append({"uid": uid, "got": g, "expect": exp})
            if len(bad) >= 10:
                break
    extra = [uid for uid in got if uid not in expect]
    return {
        "ok": not bad and not extra and len(got) == len(expect),
        "got": len(got),
        "expect": len(expect),
        "mismatch_sample": bad,
        "extra_sample": extra[:10],
        "sum_got": float(sum(got.values())) if got else 0.0,
        "sum_expect": float(sum(expect.values())),
    }


def run_profile(session, space, sql):
    execute(session, f"USE {space}")
    resp = execute(session, "PROFILE " + sql, attempts=3)
    try:
        plan = plan_to_dict(resp.plan_desc())
    except Exception as exc:  # keep the run; the raw failure is the record
        plan = {"error": repr(exc)}
    return {
        "rows": resp.row_size(),
        "server_us": resp.latency(),
        "client_us": resp.whole_latency(),
        "keys": list(resp.keys()),
        "plan": plan,
    }


def bench_one(args, space, sql, concurrency):
    from nebula3.Config import Config
    from nebula3.gclient.net import ConnectionPool

    config = Config()
    config.max_connection_pool_size = concurrency + 4
    config.timeout = 180000
    pool = ConnectionPool()
    if not pool.init([(args.host, args.port)], config):
        raise RuntimeError("bench pool init failed")
    barrier = threading.Barrier(concurrency)
    samples = []
    starts = []
    ends = []
    lock = threading.Lock()
    errors = []

    def worker():
        session = pool.get_session(args.user, args.password)
        local = []
        try:
            use = session.execute(f"USE {space}")
            if not use.is_succeeded():
                raise RuntimeError(use.error_msg())
            for _ in range(args.warmup):
                warm = session.execute(sql)
                if not warm.is_succeeded():
                    raise RuntimeError(f"warmup failed: {warm.error_msg()}")
            barrier.wait(timeout=600)
            t0 = time.perf_counter()
            for _ in range(args.rounds):
                a = time.perf_counter()
                resp = session.execute(sql)
                b = time.perf_counter()
                local.append(
                    {
                        "ok": resp.is_succeeded(),
                        "client_ms": (b - a) * 1000.0,
                        "server_us": resp.latency() if resp.is_succeeded() else None,
                        "error": None if resp.is_succeeded() else resp.error_msg(),
                        "rows": resp.row_size() if resp.is_succeeded() else None,
                    }
                )
            t1 = time.perf_counter()
            with lock:
                samples.extend(local)
                starts.append(t0)
                ends.append(t1)
        except Exception as exc:  # barrier may be broken; record and continue
            with lock:
                errors.append(repr(exc))
            try:
                barrier.abort()
            except Exception:
                pass
        finally:
            session.release()

    with ThreadPoolExecutor(max_workers=concurrency) as pool_ex:
        futs = [pool_ex.submit(worker) for _ in range(concurrency)]
        for fut in as_completed(futs):
            fut.result()
    pool.close()
    wall = None
    qps = None
    ok = sum(1 for s in samples if s["ok"])
    if starts and ends:
        wall = max(ends) - min(starts)
        if wall > 0:
            qps = ok / wall
    summary = summarize(samples)
    summary["concurrency"] = concurrency
    summary["warmup_per_worker"] = args.warmup
    summary["rounds_per_worker"] = args.rounds
    summary["wall_s"] = wall
    summary["qps"] = qps
    summary["worker_errors"] = errors
    summary["samples_raw"] = samples
    return summary


def measure(args, data):
    names = [n.strip() for n in args.queries.split(",") if n.strip()]
    for name in names:
        if name not in QUERIES:
            raise SystemExit(f"unknown query {name}")
    client = Nebula(args)
    session = client.session()
    expect_users = set(data["recent_beauty_users"])
    report = {
        "tag": args.tag,
        "hardware": hardware(),
        "dataset": {
            "users": args.users,
            "items": args.items,
            "edges": args.edges,
            "beauty_ratio": args.beauty_ratio,
            "recent_ratio": args.recent_ratio,
            "seed": args.seed,
            "parts": args.parts,
            "now": args.now,
            "window": args.window,
            "cutoff": data["cutoff"],
            "beauty_items": data["beauty_items"],
            "recent_beauty_users": len(expect_users),
            "matching_edges": data["matching_edges"],
            "sales_users": len(data["sales"]),
            "sales_sum": int(sum(data["sales"].values())),
        },
        "percentile": "linear interpolation, rank = p/100 * (n-1) on successful samples",
        "queries": {},
        "ok": True,
    }
    try:
        for name in names:
            spec = QUERIES[name]
            sql = spec["sql"](data["cutoff"])
            print(f"== {args.tag} {name}", flush=True)
            execute(session, f"USE {spec['space']}")
            entry = {"sql": sql, "space": spec["space"]}
            if spec["kind"] == "users":
                resp = execute(session, sql)
                got = user_set(resp)
                entry["check"] = check_users(name, got, expect_users)
                entry["result_rows"] = resp.row_size()
            elif spec["kind"] == "users_dup":
                resp = execute(session, sql)
                got = user_set(resp)
                entry["check"] = check_users(name, got, expect_users)
                entry["result_rows"] = resp.row_size()
                entry["duplicate_rows"] = resp.row_size() - len(got)
            elif spec["kind"] == "sales_top":
                full = execute(session, q_sales_all(data["cutoff"]))
                entry["sales_check"] = check_sales(sales_map(full), data["sales"])
                resp = execute(session, sql)
                entry["top_rows"] = rows_of(resp)
                entry["result_rows"] = resp.row_size()
            elif spec["kind"] == "counts":
                resp = execute(session, sql)
                got = {}
                for row in rows_of(resp):
                    got[int(row[0])] = int(row[1])
                expect = {}
                for uid, _iid, _rank, ts, _amount, kind in data["edges"]:
                    if kind == "beauty" and ts > data["cutoff"]:
                        expect[uid] = expect.get(uid, 0) + 1
                entry["check"] = {
                    "ok": got == expect,
                    "got": len(got),
                    "expect": len(expect),
                    "sum_got": int(sum(got.values())),
                    "sum_expect": int(sum(expect.values())),
                }
                entry["result_rows"] = resp.row_size()
            elif spec["kind"] == "amount_groups":
                resp = execute(session, sql)
                got = rows_of(resp)
                total = 0
                for row in got:
                    total += int(row[1])
                entry["check"] = {
                    "ok": total == data["matching_edges"],
                    "groups": len(got),
                    "sum_got": total,
                    "sum_expect": data["matching_edges"],
                }
                entry["result_rows"] = resp.row_size()
            else:
                raise RuntimeError(spec["kind"])
            if spec["kind"] == "sales_top":
                entry["ok"] = entry["sales_check"]["ok"]
            elif spec["kind"] in ("counts", "amount_groups"):
                entry["ok"] = entry["check"]["ok"]
            else:
                entry["ok"] = entry["check"]["ok"]
            if not entry["ok"]:
                report["ok"] = False
            print(f"check {name} ok={entry['ok']} rows={entry['result_rows']}", flush=True)
            entry["profile"] = run_profile(session, spec["space"], sql)
            levels = []
            if entry["ok"]:
                for n in [int(x) for x in args.concurrency.split(",") if x.strip()]:
                    print(f"bench {name} concurrency={n}", flush=True)
                    level = bench_one(args, spec["space"], sql, n)
                    brief = {
                        k: level[k]
                        for k in (
                            "concurrency",
                            "samples",
                            "ok",
                            "errors",
                            "client_ms",
                            "server_ms",
                            "row_counts",
                            "wall_s",
                            "qps",
                            "worker_errors",
                            "first_error",
                        )
                    }
                    print(json.dumps(brief, ensure_ascii=False), flush=True)
                    levels.append(level)
                    if level["errors"] or level["worker_errors"]:
                        report["ok"] = False
            entry["levels"] = levels
            report["queries"][name] = entry
            dump(os.path.join(args.results, f"{args.tag}.json"), report)
    finally:
        session.release()
        client.close()
    return report


def dump(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)
    print(f"wrote {path}", flush=True)


def main():
    args = parse_args()
    data = make_dataset(
        args.users,
        args.items,
        args.edges,
        args.beauty_ratio,
        args.recent_ratio,
        args.now,
        args.window,
        args.seed,
        args.parts,
    )
    print(
        f"dataset users={args.users} items={args.items} edges={args.edges} "
        f"beauty_items={data['beauty_items']} recent_users={len(data['recent_beauty_users'])} "
        f"matching_edges={data['matching_edges']} cutoff={data['cutoff']}",
        flush=True,
    )
    os.makedirs(args.results, exist_ok=True)
    if args.phase == "load":
        meta = {
            "hardware": hardware(),
            "dataset": {
                "users": args.users,
                "items": args.items,
                "edges": args.edges,
                "beauty_ratio": args.beauty_ratio,
                "recent_ratio": args.recent_ratio,
                "seed": args.seed,
                "parts": args.parts,
                "cutoff": data["cutoff"],
                "beauty_items": data["beauty_items"],
                "recent_beauty_users": len(data["recent_beauty_users"]),
                "matching_edges": data["matching_edges"],
                "sales_sum": int(sum(data["sales"].values())),
            },
        }
        load(args, data)
        dump(os.path.join(args.results, "load_meta.json"), meta)
        return 0
    report = measure(args, data)
    dump(os.path.join(args.results, f"{args.tag}.json"), report)
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
