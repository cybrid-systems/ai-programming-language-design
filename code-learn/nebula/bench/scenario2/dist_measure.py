#!/usr/bin/env python3
"""Load and measure the beauty queries on the network-namespace cluster.

Host fan-out comes from PROFILE `step* resp [i]` (host, vertices). The same
python oracle as the single-node bench checks users, per-user sums, and the
amount-group total. This script does not invent a latency: every sample is a
ResultSet from the address in --host/--port.
"""

import argparse
import json
import os
import sys
import time

# concurrent.py in this directory shadows the stdlib. Drop the script dir
# before any stdlib concurrent import (measure.py does that itself), then put
# it back so `import measure` can see this directory.
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path = [p for p in sys.path if os.path.abspath(p or os.getcwd()) != _SCRIPT_DIR]
sys.path.insert(0, _SCRIPT_DIR)

import measure  # noqa: E402
from gen_data import make_dataset  # noqa: E402


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("phase", choices=["hosts", "load", "measure", "probe"])
    p.add_argument("--host", default="10.88.0.31")
    p.add_argument("--port", type=int, default=9669)
    p.add_argument("--user", default="root")
    p.add_argument("--password", default="nebula")
    p.add_argument("--storage-hosts", default="10.88.0.21:9779,10.88.0.22:9779,10.88.0.23:9779")
    p.add_argument("--space", default="beauty_p9_rf1")
    p.add_argument("--parts", type=int, default=9)
    p.add_argument("--replica", type=int, default=1)
    p.add_argument("--users", type=int, default=800)
    p.add_argument("--items", type=int, default=200)
    p.add_argument("--edges", type=int, default=20000)
    p.add_argument("--seed", type=int, default=2)
    p.add_argument("--now", type=int, default=1761436800)
    p.add_argument("--window", type=int, default=90 * 24 * 3600)
    p.add_argument("--beauty-ratio", type=float, default=0.2)
    p.add_argument("--recent-ratio", type=float, default=0.4)
    p.add_argument("--batch", type=int, default=250)
    p.add_argument("--queries", default="q_users,q_sales,q_count,q_by_amount")
    p.add_argument("--concurrency", default="1,10")
    p.add_argument("--warmup", type=int, default=1)
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--expect-partial", default="true", choices=["true", "false"])
    p.add_argument("--tag", default="dist")
    p.add_argument("--results", default=os.path.join(_SCRIPT_DIR, "results", "dist"))
    return p.parse_args()


def dataset(args):
    return make_dataset(
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


def once(session, stmt):
    resp = session.execute(stmt)
    if not resp.is_succeeded():
        raise RuntimeError(f"{stmt[:160]} -> code={resp.error_code()} msg={resp.error_msg()}")
    return resp


def show_rows(session, stmt):
    try:
        resp = once(session, stmt)
        return measure.rows_of(resp)
    except RuntimeError as exc:
        return [{"error": str(exc)}]


def add_hosts(session, hosts):
    stmt = "ADD HOSTS " + ", ".join(hosts)
    resp = session.execute(stmt)
    print(f"{stmt} ok={resp.is_succeeded()} msg={resp.error_msg()}", flush=True)
    deadline = time.time() + 180
    last = None
    while time.time() < deadline:
        show = session.execute("SHOW HOSTS")
        if show.is_succeeded():
            rows = measure.rows_of(show)
            last = rows
            blob = " ".join(str(c) for row in rows for c in row).upper()
            print(f"SHOW HOSTS {rows}", flush=True)
            online = sum(1 for row in rows if any(str(c).upper() == "ONLINE" for c in row))
            if online >= len(hosts) and "OFFLINE" not in blob:
                return rows
        time.sleep(3)
    raise RuntimeError(f"hosts not all ONLINE: {last}")


def host_stats(nodes):
    found = []
    for node in nodes or []:
        for prof in node.get("profiles") or []:
            for key, val in (prof.get("other_stats") or {}).items():
                if not str(key).startswith("step"):
                    continue
                host = None
                vertices = None
                if isinstance(val, str) and val.startswith("{"):
                    try:
                        parsed = json.loads(val)
                        host = parsed.get("host")
                        vertices = parsed.get("vertices")
                    except json.JSONDecodeError:
                        parsed = val
                found.append({"state": key, "host": host, "vertices": vertices, "raw": val})
    return found


def load_space(args, session, data):
    execute = measure.execute
    execute(
        session,
        "CREATE SPACE IF NOT EXISTS "
        f"{args.space}(partition_num={args.parts}, replica_factor={args.replica}, vid_type=INT64)",
    )
    measure.wait_use(session, args.space, timeout=180)
    for stmt in (
        "CREATE TAG IF NOT EXISTS user(name string)",
        "CREATE TAG IF NOT EXISTS item(name string, type string)",
        "CREATE EDGE IF NOT EXISTS buy(ts int, amount double)",
    ):
        execute(session, stmt)
    time.sleep(6)
    users = [f'{uid}:("{name}")' for uid, name in data["users"]]
    items = [f'{vid}:("{name}", "{kind}")' for vid, name, kind in data["items"]]
    edges = [
        f"{uid}->{iid}@{rank}:({ts}, {amount})"
        for uid, iid, rank, ts, amount, _kind in data["edges"]
    ]
    measure.batched(session, "INSERT VERTEX user(name) VALUES ", users, args.batch)
    measure.batched(session, "INSERT VERTEX item(name, type) VALUES ", items, args.batch)
    measure.batched(session, "INSERT EDGE buy(ts, amount) VALUES ", edges, args.batch)
    execute(session, "CREATE TAG INDEX IF NOT EXISTS item_type_idx ON item(type(16))")
    measure.rebuild(session, "REBUILD TAG INDEX item_type_idx")


def check_query(name, spec, resp, data):
    if spec["kind"] == "users":
        got = measure.user_set(resp)
        return measure.check_users(name, got, data["recent_beauty_users"])
    if spec["kind"] == "sales_top":
        # Caller passes the full aggregate, not the top 100.
        return measure.check_sales(measure.sales_map(resp), data["sales"])
    if spec["kind"] == "counts":
        got = {}
        keys = list(resp.keys())
        ui, ni = keys.index("uid"), keys.index("n")
        for i in range(resp.row_size()):
            row = resp.row_values(i)
            got[int(measure.cell(row[ui]))] = int(measure.cell(row[ni]))
        expect = {}
        for uid, _iid, _rank, ts, _amount, kind in data["edges"]:
            if kind == "beauty" and ts > data["cutoff"]:
                expect[uid] = expect.get(uid, 0) + 1
        return {
            "ok": got == expect,
            "got": len(got),
            "expect": len(expect),
            "sum_got": int(sum(got.values())),
            "sum_expect": int(sum(expect.values())),
        }
    if spec["kind"] == "amount_groups":
        total = 0
        keys = list(resp.keys())
        ni = keys.index("n")
        for i in range(resp.row_size()):
            total += int(measure.cell(resp.row_values(i)[ni]))
        return {
            "ok": total == data["matching_edges"],
            "groups": resp.row_size(),
            "sum_got": total,
            "sum_expect": data["matching_edges"],
        }
    raise RuntimeError(spec["kind"])


def main():
    args = parse_args()
    data = dataset(args)
    os.makedirs(args.results, exist_ok=True)
    client = measure.Nebula(args)
    session = client.session()
    report = {
        "phase": args.phase,
        "tag": args.tag,
        "space": args.space,
        "parts": args.parts,
        "replica": args.replica,
        "hardware": measure.hardware(),
        "dataset": {
            "users": args.users,
            "items": args.items,
            "edges": args.edges,
            "parts": args.parts,
            "cutoff": data["cutoff"],
            "beauty_items": data["beauty_items"],
            "recent_beauty_users": len(data["recent_beauty_users"]),
            "matching_edges": data["matching_edges"],
            "sales_sum": float(sum(data["sales"].values())),
        },
        "ok": True,
    }
    try:
        hosts = [h.strip() for h in args.storage_hosts.split(",") if h.strip()]
        if args.phase == "hosts":
            report["hosts"] = add_hosts(session, hosts)
        elif args.phase == "load":
            add_hosts(session, hosts)
            load_space(args, session, data)
            report["hosts"] = show_rows(session, "SHOW HOSTS")
            measure.execute(session, f"USE {args.space}")
            report["parts"] = show_rows(session, "SHOW PARTS")
        else:
            measure.execute(session, f"USE {args.space}")
            report["hosts"] = show_rows(session, "SHOW HOSTS")
            report["parts"] = show_rows(session, "SHOW PARTS")
            names = [n.strip() for n in args.queries.split(",") if n.strip()]
            report["queries"] = {}
            for name in names:
                spec = measure.QUERIES[name]
                sql = spec["sql"](data["cutoff"])
                print(f"== {args.tag} {name}", flush=True)
                entry = {"sql": sql}
                started = time.perf_counter()
                run = once if args.phase == "probe" else measure.execute
                try:
                    if spec["kind"] == "sales_top":
                        full = run(session, measure.q_sales_all(data["cutoff"]))
                        entry["sales_check"] = check_query(name, spec, full, data)
                        resp = run(session, sql)
                        entry["top_rows"] = measure.rows_of(resp)[:5]
                        entry["result_rows"] = resp.row_size()
                        entry["ok"] = entry["sales_check"]["ok"]
                        profile_sql = sql
                    else:
                        resp = run(session, sql)
                        entry["check"] = check_query(name, spec, resp, data)
                        entry["result_rows"] = resp.row_size()
                        entry["ok"] = entry["check"]["ok"]
                        profile_sql = sql
                    prof = measure.run_profile(session, args.space, profile_sql)
                    entry["profile_rows"] = prof.get("rows")
                    entry["profile_server_us"] = prof.get("server_us")
                    entry["hosts"] = host_stats(prof.get("plan", {}).get("nodes"))
                    entry["partial"] = "partialAgg" in json.dumps(prof.get("plan"))
                    entry["plan_names"] = [n["name"] for n in prof.get("plan", {}).get("nodes", [])]
                    if args.phase == "measure" and entry["ok"]:
                        levels = []
                        for n in [int(x) for x in args.concurrency.split(",") if x.strip()]:
                            level = measure.bench_one(args, args.space, sql, n)
                            levels.append(level)
                            print(
                                json.dumps(
                                    {
                                        "q": name,
                                        "c": n,
                                        "qps": level.get("qps"),
                                        "server_ms": level.get("server_ms"),
                                        "errors": level.get("errors"),
                                    }
                                ),
                                flush=True,
                            )
                            if level.get("errors") or level.get("worker_errors"):
                                entry["ok"] = False
                        entry["levels"] = levels
                except Exception as exc:  # probe must record the failure, not hide it
                    entry["ok"] = False
                    entry["error"] = str(exc)
                    print(f"{name} ERROR {exc}", flush=True)
                entry["wall_s"] = round(time.perf_counter() - started, 3)
                expect_partial = args.expect_partial == "true"
                want_partial = {
                    "q_sales": expect_partial,
                    "q_count": expect_partial,
                    "q_by_amount": False,
                }.get(name)
                if want_partial is not None and entry.get("partial") is not None:
                    entry["want_partial"] = want_partial
                    if entry["partial"] != want_partial:
                        entry["ok"] = False
                        entry["plan_mismatch"] = True
                if not entry["ok"]:
                    report["ok"] = False
                report["queries"][name] = entry
    finally:
        session.release()
        client.close()
    path = os.path.join(args.results, f"{args.tag}.json")
    measure.dump(path, report)
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
