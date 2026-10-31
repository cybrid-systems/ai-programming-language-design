#!/usr/bin/env python3
"""Load the generated graph and compare baseline nGQL, naive pushdown, exact pushdown.

Server latency is ResultSet.latency() in microseconds. QPS uses the wall clock
of each concurrency wave. copurchase_plan lines are read from the graphd log.
Baseline client rounds are the nGQL statements that ran. Numbers in the JSON
are measured; this script does not fill missing samples.
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

from ground import exact, naive, overlap

PLAN_RE = re.compile(
    r"copurchase_plan mode=(\w+) fallback=(\d+) rounds=(\d+) buyers=(\d+) "
    r"hop_rows=([0-9,]+) hop_hosts=([0-9,]+) scanned=([0-9,]+) "
    r"users=(\S*) products=(\S*)"
)


def percentile(values, pct):
    if not values:
        return None
    ordered = sorted(values)
    idx = min(len(ordered) - 1, int(round((pct / 100.0) * (len(ordered) - 1))))
    return ordered[idx]


def connect(host, port):
    cfg = Config()
    cfg.max_connection_pool_size = 64
    cfg.timeout = 180000
    pool = ConnectionPool()
    deadline = time.time() + 90
    while time.time() < deadline:
        if pool.init([(host, port)], cfg):
            return pool
        time.sleep(1)
    raise SystemExit(f"cannot connect {host}:{port}")


def execute(session, stmt):
    resp = session.execute(stmt)
    if not resp.is_succeeded():
        raise RuntimeError(f"{stmt[:220]} -> {resp.error_msg()}")
    return resp


def cell(value):
    if value.is_null() or value.is_empty():
        return None
    if value.is_int():
        return int(value.as_int())
    if value.is_string():
        return value.as_string()
    return str(value)


def table(resp):
    out = []
    for i in range(resp.row_size()):
        out.append(tuple(cell(v) for v in resp.row_values(i)))
    return out


def wait_use(session, space):
    deadline = time.time() + 120
    while time.time() < deadline:
        use = session.execute(f"USE {space}")
        if use.is_succeeded():
            return
        time.sleep(2)
    raise SystemExit(f"USE {space} failed")


def load(session, space, edges, sales, product_base, parts, replica):
    add = session.execute("ADD HOSTS 10.88.0.21:9779, 10.88.0.22:9779, 10.88.0.23:9779")
    if not add.is_succeeded() and "Existed" not in (add.error_msg() or ""):
        print("ADD HOSTS", add.error_msg(), flush=True)
    execute(
        session,
        "CREATE SPACE IF NOT EXISTS "
        f"{space}(partition_num={parts}, replica_factor={replica}, vid_type=INT64)",
    )
    wait_use(session, space)
    execute(session, "CREATE TAG IF NOT EXISTS product(sales int)")
    execute(session, "CREATE TAG IF NOT EXISTS user()")
    execute(session, "CREATE EDGE IF NOT EXISTS buy()")
    users = sorted(set(int(u) for u in edges[:, 0]))
    products = [product_base + i for i in range(len(sales))]
    deadline = time.time() + 60
    while time.time() < deadline:
        product_ok = session.execute("DESCRIBE TAG product").is_succeeded()
        user_ok = session.execute("DESCRIBE TAG user").is_succeeded()
        edge_ok = session.execute("DESCRIBE EDGE buy").is_succeeded()
        if product_ok and user_ok and edge_ok:
            break
        time.sleep(1)
    else:
        raise SystemExit("schema not ready")
    first = True
    for i in range(0, len(users), 400):
        chunk = ", ".join(f"{uid}:()" for uid in users[i : i + 400])
        stmt = f"INSERT VERTEX user() VALUES {chunk}"
        if first:
            deadline = time.time() + 40
            while time.time() < deadline:
                resp = session.execute(stmt)
                if resp.is_succeeded():
                    break
                time.sleep(1)
            else:
                raise RuntimeError(f"insert user -> {resp.error_msg()}")
            first = False
        else:
            execute(session, stmt)
    for i in range(0, len(products), 400):
        chunk = ", ".join(
            f"{products[j]}:({int(sales[products[j] - product_base])})"
            for j in range(i, min(i + 400, len(products)))
        )
        execute(session, f"INSERT VERTEX product(sales) VALUES {chunk}")
    total = len(edges)
    for i in range(0, total, 400):
        chunk = ", ".join(
            f"{int(edges[j, 0])}->{int(edges[j, 1])}@{int(edges[j, 2])}:()"
            for j in range(i, min(i + 400, total))
        )
        execute(session, f"INSERT EDGE buy() VALUES {chunk}")
        if i % 40000 == 0:
            print(f"inserted edges {i}/{total}", flush=True)
    print(f"loaded edges={total} products={len(products)} users={len(users)}", flush=True)


def indexes(edges):
    by_user = defaultdict(list)
    by_product = defaultdict(list)
    for user, pid, ts in edges.tolist():
        by_user[int(user)].append((int(pid), int(ts)))
        by_product[int(pid)].append((int(user), int(ts)))
    return by_user, by_product


def baseline(session, user, start, end):
    """Four nGQL statements. Ranking of the fetched edges is client-side.

    Returned latency is the sum of ResultSet.latency(). Wall time of this
    function includes the client sort and is not the server latency.
    """
    lats = []
    rounds = 0
    hop1 = execute(
        session,
        f"GO FROM {user} OVER buy WHERE buy._rank >= {start} AND buy._rank <= {end} "
        "YIELD buy._dst AS pid, buy._rank AS ts "
        "| GROUP BY $-.pid YIELD $-.pid AS pid, count(*) AS cnt, max($-.ts) AS ts "
        "| ORDER BY $-.cnt DESC, $-.ts DESC, $-.pid ASC | LIMIT 5",
    )
    lats.append(hop1.latency())
    rounds += 1
    focus = [row[0] for row in table(hop1)]
    if not focus:
        return [], [], sum(lats), rounds, {"hop1": len(focus)}
    idlist = ",".join(str(pid) for pid in focus)
    inbound = execute(
        session,
        f"GO FROM {idlist} OVER buy REVERSELY "
        f"WHERE buy._rank >= {start} AND buy._rank <= {end} "
        "YIELD buy._dst AS buyer, buy._src AS pid, buy._rank AS ts",
    )
    lats.append(inbound.latency())
    rounds += 1
    inbound_rows = table(inbound)
    buyers = sorted({row[0] for row in inbound_rows if row[0] != user})
    if not buyers:
        return [], [], sum(lats), rounds, {"hop1": len(focus), "inbound": len(inbound_rows)}
    idlist = ",".join(str(uid) for uid in buyers)
    outbound = execute(
        session,
        f"GO FROM {idlist} OVER buy "
        f"WHERE buy._rank >= {start} AND buy._rank <= {end} "
        "YIELD buy._src AS uid, buy._dst AS pid, buy._rank AS ts",
    )
    lats.append(outbound.latency())
    rounds += 1
    focus_set = set(focus)
    scores = {}
    for uid, pid, ts in table(outbound):
        if uid == user:
            continue
        score = scores.setdefault(uid, {"co": set(), "pc": 0, "ts": -1, "pids": set()})
        score["pc"] += 1
        score["ts"] = max(score["ts"], ts)
        score["pids"].add(pid)
        if pid in focus_set:
            score["co"].add(pid)
    ranked = sorted(
        ((len(s["co"]), s["pc"], s["ts"], -uid, uid, s["pids"]) for uid, s in scores.items() if s["co"]),
        reverse=True,
    )[:15]
    pids = sorted({pid for *_, products in ranked for pid in products})
    if not pids:
        return [row[4] for row in ranked], [], sum(lats), rounds, {
            "hop1": len(focus),
            "inbound": len(inbound_rows),
            "outbound": outbound.row_size(),
        }
    idlist = ",".join(str(pid) for pid in pids)
    fetched = execute(
        session,
        f"FETCH PROP ON product {idlist} YIELD id(vertex) AS pid, product.sales AS sales",
    )
    lats.append(fetched.latency())
    rounds += 1
    order = sorted(((row[1], -row[0], row[0]) for row in table(fetched)), reverse=True)
    products = [(pid, sales) for sales, _, pid in order[:20]]
    return [row[4] for row in ranked], products, sum(lats), rounds, {
        "hop1": len(focus),
        "inbound": len(inbound_rows),
        "outbound": outbound.row_size(),
        "fetch": fetched.row_size(),
    }


def pushdown(session, user, start, end, naive_mode):
    stmt = f"COPURCHASE FROM {user} WINDOW {start}, {end}"
    if naive_mode:
        stmt += " NAIVE"
    resp = execute(session, stmt)
    return table(resp), resp.latency()


def log_text(log_dir, offset):
    chunks = []
    new_offset = dict(offset)
    if not log_dir or not os.path.isdir(log_dir):
        return "", new_offset
    seen_real = set()
    for name in os.listdir(log_dir):
        if "graphd" not in name:
            continue
        path = os.path.join(log_dir, name)
        if not os.path.isfile(path):
            continue
        real = os.path.realpath(path)
        if real in seen_real:
            continue
        seen_real.add(real)
        size = os.path.getsize(path)
        start = offset.get(path, 0)
        if size < start:
            start = 0
        with open(path, "rb") as fh:
            fh.seek(start)
            chunks.append(fh.read().decode("utf-8", "replace"))
        new_offset[path] = size
    return "".join(chunks), new_offset


def parse_plans(text):
    plans = []
    for match in PLAN_RE.finditer(text):
        plans.append(
            {
                "mode": match.group(1),
                "fallback": int(match.group(2)),
                "rounds": int(match.group(3)),
                "buyers": int(match.group(4)),
                "hop_rows": [int(x) for x in match.group(5).split(",")],
                "hop_hosts": [int(x) for x in match.group(6).split(",")],
                "scanned": [int(x) for x in match.group(7).split(",")],
                "users": match.group(8),
                "products": match.group(9),
            }
        )
    return plans


def user_ids(plan):
    if not plan["users"]:
        return []
    return [int(piece.split(":")[0]) for piece in plan["users"].split(",") if piece]


def product_ids(plan):
    if not plan["products"]:
        return []
    return [int(piece.split(":")[0]) for piece in plan["products"].split(",") if piece]


def summarize(lat_us, wall_s, n):
    return {
        "n": n,
        "p50_ms": None if percentile(lat_us, 50) is None else percentile(lat_us, 50) / 1000.0,
        "p99_ms": None if percentile(lat_us, 99) is None else percentile(lat_us, 99) / 1000.0,
        "qps": None if wall_s <= 0 else n / wall_s,
        "wall_s": wall_s,
        "latency": "ResultSet.latency microseconds, reported in ms",
        "qps_def": "completed queries / wall clock of this wave",
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--graph", default=os.path.join(_SCRIPT, "graph.npz"))
    parser.add_argument("--host", default=os.environ.get("NEBULA_HOST", "10.88.0.31"))
    parser.add_argument("--port", type=int, default=9669)
    parser.add_argument("--space", default="copurchase")
    parser.add_argument("--parts", type=int, default=9)
    parser.add_argument("--replica", type=int, default=1)
    parser.add_argument("--log-dir", default="/tmp/nebula-dist/graph1/logs")
    parser.add_argument("--out", required=True)
    parser.add_argument("--skip-load", action="store_true")
    parser.add_argument("--skip-accuracy", action="store_true")
    parser.add_argument("--accuracy-users", type=int, default=12)
    parser.add_argument("--latency-n", type=int, default=30)
    parser.add_argument("--label", default="bridge")
    args = parser.parse_args()

    blob = np.load(args.graph)
    edges = blob["edges"]
    sales_arr = blob["sales"]
    product_base = int(blob["product_base"])
    sales = {product_base + i: int(sales_arr[i]) for i in range(len(sales_arr))}
    meta_path = os.path.splitext(args.graph)[0] + ".json"
    with open(meta_path, encoding="utf-8") as fh:
        meta = json.load(fh)
    windows = {"30d": meta["window_30d"], "7d": meta["window_7d"]}
    by_user, by_product = indexes(edges)
    pool = connect(args.host, args.port)
    session = pool.get_session("root", "nebula")
    report = {
        "label": args.label,
        "meta": meta,
        "parts": args.parts,
        "replica": args.replica,
        "host": args.host,
        "measured": True,
    }
    try:
        if not args.skip_load:
            load(session, args.space, edges, sales_arr, product_base, args.parts, args.replica)
        else:
            wait_use(session, args.space)
        users = [1 + i * 997 for i in range(args.accuracy_users)]
        users = [u for u in users if u in by_user][: args.accuracy_users]
        offset = {}
        _text, offset = log_text(args.log_dir, offset)
        accuracy = []
        if args.skip_accuracy:
            report["accuracy"] = []
            report["accuracy_note"] = "skipped; overlap was measured on the bridge run"
        for window_name, (start, end) in ([] if args.skip_accuracy else windows.items()):
            for user in users:
                truth = exact(by_user, by_product, sales, user, start, end)
                naive_truth = naive(
                    by_user, by_product, sales, user, start, end, args.parts
                )
                for mode in ("exact", "naive", "baseline"):
                    t0 = time.perf_counter()
                    if mode == "baseline":
                        got_users, got_products, lat, rounds, hop_rows = baseline(
                            session, user, start, end
                        )
                    else:
                        got, lat = pushdown(session, user, start, end, mode == "naive")
                        got_products = [(row[0], row[1]) for row in got]
                        got_users = []
                        rounds = None
                        hop_rows = None
                    accuracy.append(
                        {
                            "mode": mode,
                            "window": window_name,
                            "user": user,
                            "latency_us": lat,
                            "wall_s": time.perf_counter() - t0,
                            "client_rounds": rounds,
                            "baseline_rows": hop_rows,
                            "product_overlap": overlap(
                                [pid for pid, _s in got_products],
                                [pid for pid, _s in truth["products"]],
                            ),
                            "product_exact": got_products == truth["products"],
                            "naive_product_overlap_vs_exact_truth": overlap(
                                [pid for pid, _s in got_products],
                                [pid for pid, _s in truth["products"]],
                            )
                            if mode == "naive"
                            else None,
                            "server_users_filled_later": mode != "baseline",
                            "baseline_user_overlap": overlap(got_users, [u[0] for u in truth["users"]])
                            if mode == "baseline"
                            else None,
                            "python_naive_users": [u[0] for u in naive_truth["users"]],
                            "python_naive_user_overlap": overlap(
                                [u[0] for u in naive_truth["users"]],
                                [u[0] for u in truth["users"]],
                            ),
                            "python_naive_product_overlap": overlap(
                                [pid for pid, _s in naive_truth["products"]],
                                [pid for pid, _s in truth["products"]],
                            ),
                        }
                    )
                    print(
                        f"acc {mode} {window_name} user={user} "
                        f"prod_overlap={accuracy[-1]['product_overlap']:.3f} us={lat}",
                        flush=True,
                    )
        text, offset = log_text(args.log_dir, offset)
        plans = parse_plans(text)
        plan_i = 0
        for row in accuracy:
            if row["mode"] == "baseline":
                continue
            while plan_i < len(plans) and plans[plan_i]["mode"] != row["mode"]:
                plan_i += 1
            if plan_i >= len(plans):
                row["plan"] = None
                continue
            plan = plans[plan_i]
            plan_i += 1
            row["plan"] = {
                "rounds": plan["rounds"],
                "fallback": plan["fallback"],
                "buyers": plan["buyers"],
                "hop_rows": plan["hop_rows"],
                "hop_hosts": plan["hop_hosts"],
                "scanned": plan["scanned"],
            }
            got_users = user_ids(plan)
            truth = exact(
                by_user,
                by_product,
                sales,
                row["user"],
                *windows[row["window"]],
            )
            row["user_overlap"] = overlap(got_users, [u[0] for u in truth["users"]])
            row["user_exact"] = got_users == [u[0] for u in truth["users"]]
            if row["mode"] == "naive":
                row["server_vs_python_naive"] = overlap(got_users, row.get("python_naive_users") or [])
            row["logged_product_exact"] = product_ids(plan) == [pid for pid, _s in truth["products"]]
        report["accuracy"] = accuracy

        latency = {}
        lat_users = [u for u in range(1, 400, 7) if u in by_user]
        for window_name, (start, end) in windows.items():
            for mode in ("exact", "naive", "baseline"):
                for conc in (1, 10, 50):
                    n = args.latency_n if conc == 1 else conc
                    queries = [
                        (lat_users[(i * 3) % len(lat_users)], start, end, mode)
                        for i in range(n)
                    ]

                    def one(job):
                        user, w0, w1, kind = job
                        local = pool.get_session("root", "nebula")
                        try:
                            execute(local, f"USE {args.space}")
                            if kind == "baseline":
                                _u, _p, lat, rounds, hop_rows = baseline(local, user, w0, w1)
                                return lat, rounds, hop_rows, None
                            _rows, lat = pushdown(local, user, w0, w1, kind == "naive")
                            return lat, None, None, None
                        except Exception as exc:
                            return None, None, None, str(exc)
                        finally:
                            local.release()

                    t0 = time.perf_counter()
                    if conc == 1:
                        results = [one(job) for job in queries]
                    else:
                        with ThreadPoolExecutor(max_workers=conc) as pool_exec:
                            results = list(pool_exec.map(one, queries))
                    wall = time.perf_counter() - t0
                    errors = [item[3] for item in results if item[3]]
                    lats = [item[0] for item in results if item[0] is not None]
                    key = f"{mode}:{window_name}:c{conc}"
                    cell_report = summarize(lats, wall, len(lats))
                    cell_report["errors"] = len(errors)
                    if errors:
                        cell_report["error_example"] = errors[0][:400]
                    ok = next((item for item in results if item[0] is not None), None)
                    if mode == "baseline" and ok and ok[1] is not None:
                        cell_report["client_rounds"] = ok[1]
                        cell_report["baseline_rows_example"] = ok[2]
                        cell_report["client_rounds_note"] = (
                            "nGQL statements per query, measured. "
                            "Storage host fanout is not in this number."
                        )
                    latency[key] = cell_report
                    print(f"lat {key} {cell_report}", flush=True)
        text, offset = log_text(args.log_dir, offset)
        lat_plans = parse_plans(text)
        by_mode = defaultdict(list)
        for plan in lat_plans:
            by_mode[plan["mode"]].append(plan)
        plan_summary = {}
        for mode, group in by_mode.items():
            plan_summary[mode] = {
                "n": len(group),
                "rounds_median": percentile([p["rounds"] for p in group], 50),
                "fallback_n": sum(p["fallback"] for p in group),
                "hop_rows_median": [
                    percentile([p["hop_rows"][i] for p in group if len(p["hop_rows"]) > i], 50)
                    for i in range(4)
                ],
                "hop_hosts_median": [
                    percentile([p["hop_hosts"][i] for p in group if len(p["hop_hosts"]) > i], 50)
                    for i in range(4)
                ],
                "scanned_median": [
                    percentile([p["scanned"][i] for p in group if len(p["scanned"]) > i], 50)
                    for i in range(4)
                ],
                "buyers_median": percentile([p["buyers"] for p in group], 50),
            }
        report["latency"] = latency
        report["plan_summary"] = plan_summary
        report["plan_summary_note"] = (
            "Medians of copurchase_plan lines emitted during the latency waves. "
            "hop_rows are storage rows_returned summed across hosts "
            "(hop2a is graphd-deduped buyer ids). Baseline has no plan line."
        )
    finally:
        session.release()
        pool.close()
        with open(args.out, "w", encoding="utf-8") as fh:
            json.dump(report, fh, indent=2)
            fh.write("\n")
        print(f"wrote {args.out}", flush=True)


if __name__ == "__main__":
    main()
