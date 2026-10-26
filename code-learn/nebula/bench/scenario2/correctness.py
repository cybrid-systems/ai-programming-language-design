#!/usr/bin/env python3
"""Small-graph checks for partial edge aggregate.

The 500k beauty set has no null amounts. This script builds a 3-part space
with a null amount, two ranks on the same vertex pair, a second edge type,
an empty filter, and shapes that must stay on ExpandAll (group by amount,
AVG, now()).
"""

import argparse
import json
import os
import sys
import time

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path = [p for p in sys.path if os.path.abspath(p or os.getcwd()) != _SCRIPT_DIR]


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=9669)
    p.add_argument("--user", default="root")
    p.add_argument("--password", default="nebula")
    p.add_argument("--space", default="edge_cases")
    p.add_argument("--expect-partial", default="true")
    p.add_argument("--out", default="")
    return p.parse_args()


def cell(value):
    if value.is_null() or value.is_empty():
        return None
    if value.is_int():
        return int(value.as_int())
    if value.is_double():
        return float(value.as_double())
    if value.is_string():
        return value.as_string()
    return str(value)


def rows_of(resp):
    out = []
    for i in range(resp.row_size()):
        out.append([cell(v) for v in resp.row_values(i)])
    return out


def execute(session, stmt, attempts=8):
    last = None
    for _ in range(attempts):
        resp = session.execute(stmt)
        if resp.is_succeeded():
            return resp
        last = f"code={resp.error_code()} msg={resp.error_msg()}"
        time.sleep(2)
    raise RuntimeError(f"{stmt[:120]} -> {last}")


def plan_nodes(resp):
    plan = resp.plan_desc()
    nodes = []
    for node in plan.plan_node_descs:
        desc = []
        for pair in node.description or []:
            desc.append({"key": pair.key.decode() if isinstance(pair.key, bytes) else str(pair.key),
                         "value": pair.value.decode() if isinstance(pair.value, bytes) else str(pair.value)})
        nodes.append({"name": node.name.decode() if isinstance(node.name, bytes) else str(node.name),
                      "id": node.id,
                      "description": desc,
                      "dependencies": list(node.dependencies or [])})
    return nodes


def has_partial(nodes):
    blob = json.dumps(nodes)
    return "partialAgg" in blob


def norm(rows):
    def key(row):
        return tuple("" if c is None else str(c) for c in row)
    return sorted(rows, key=key)


def close(got, expect):
    if len(got) != len(expect):
        return False
    for g, e in zip(norm(got), norm(expect)):
        if len(g) != len(e):
            return False
        for a, b in zip(g, e):
            if a is None or b is None:
                if a != b:
                    return False
            elif isinstance(b, float) or isinstance(a, float):
                if abs(float(a) - float(b)) > 1e-6:
                    return False
            elif a != b:
                return False
    return True


def main():
    args = parse_args()
    expect_partial = args.expect_partial.lower() in ("1", "true", "yes")
    from nebula3.Config import Config
    from nebula3.gclient.net import ConnectionPool

    config = Config()
    config.max_connection_pool_size = 4
    config.timeout = 120000
    pool = ConnectionPool()
    if not pool.init([(args.host, args.port)], config):
        raise SystemExit(f"pool init failed {args.host}:{args.port}")
    session = pool.get_session(args.user, args.password)
    report = {"space": args.space, "expect_partial": expect_partial, "cases": [], "ok": True}
    try:
        execute(session, f"DROP SPACE IF EXISTS {args.space}")
        time.sleep(8)
        execute(
            session,
            "CREATE SPACE "
            f"{args.space}(partition_num=3, replica_factor=1, vid_type=INT64)",
        )
        deadline = time.time() + 90
        while True:
            resp = session.execute(f"USE {args.space}")
            if resp.is_succeeded():
                break
            if time.time() > deadline:
                raise RuntimeError(resp.error_msg())
            time.sleep(2)
        for stmt in (
            "CREATE TAG person(name string)",
            "CREATE EDGE buy(amount int, ts int)",
            "CREATE EDGE gift(amount int, ts int)",
        ):
            execute(session, stmt)
        time.sleep(8)
        execute(
            session,
            'INSERT VERTEX person(name) VALUES 1:("u1"), 2:("u2"), 3:("u3"), 10:("i1"), 11:("i2")',
        )
        execute(
            session,
            "INSERT EDGE buy(amount, ts) VALUES "
            "1->10@0:(5, 10), 1->11@0:(7, 10), 1->11@1:(NULL, 10), "
            "2->10@0:(4, 1), 3->11@0:(9, 10)",
        )
        execute(session, "INSERT EDGE gift(amount, ts) VALUES 1->10@0:(3, 10)")

        cases = [
            {
                "name": "reverse_sum_count_null",
                "sql": (
                    "GO FROM 10, 11 OVER buy REVERSELY WHERE buy.ts > 5 "
                    "YIELD buy._dst AS uid, buy.amount AS amt "
                    "| GROUP BY $-.uid YIELD $-.uid AS uid, sum($-.amt) AS sales, count($-.amt) AS n"
                ),
                "expect": [[1, 12, 2], [3, 9, 1]],
                "partial": True,
            },
            {
                "name": "reverse_min_max",
                "sql": (
                    "GO FROM 10 OVER buy REVERSELY WHERE buy.ts > 5 "
                    "YIELD buy._dst AS uid, buy.amount AS amt "
                    "| GROUP BY $-.uid YIELD $-.uid AS uid, min($-.amt) AS lo, max($-.amt) AS hi"
                ),
                "expect": [[1, 5, 5]],
                "partial": True,
            },
            {
                "name": "empty_filter",
                "sql": (
                    "GO FROM 10, 11 OVER buy REVERSELY WHERE buy.ts > 100 "
                    "YIELD buy._dst AS uid, buy.amount AS amt "
                    "| GROUP BY $-.uid YIELD $-.uid AS uid, sum($-.amt) AS sales"
                ),
                "expect": [],
                "partial": True,
            },
            {
                "name": "no_filter_sum",
                "sql": (
                    "GO FROM 10, 11 OVER buy REVERSELY "
                    "YIELD buy._dst AS uid, buy.amount AS amt "
                    "| GROUP BY $-.uid YIELD $-.uid AS uid, sum($-.amt) AS sales, count($-.amt) AS n"
                ),
                "expect": [[1, 12, 2], [2, 4, 1], [3, 9, 1]],
                "partial": True,
            },
            {
                "name": "forward_sum",
                "sql": (
                    "GO FROM 1 OVER buy "
                    "YIELD buy._dst AS item, buy.amount AS amt "
                    "| GROUP BY $-.item YIELD $-.item AS item, sum($-.amt) AS sales"
                ),
                "expect": [[10, 5], [11, 7]],
                "partial": True,
            },
            {
                "name": "bidirect_matches_reverse",
                "sql": (
                    "GO FROM 10, 11 OVER buy BIDIRECT "
                    "YIELD buy._dst AS uid, buy.amount AS amt "
                    "| GROUP BY $-.uid YIELD $-.uid AS uid, sum($-.amt) AS sales"
                ),
                "expect": [[1, 12], [2, 4], [3, 9]],
                "partial": True,
            },
            {
                "name": "second_edge_type",
                "sql": (
                    "GO FROM 10 OVER gift REVERSELY WHERE gift.ts > 5 "
                    "YIELD gift._dst AS uid, gift.amount AS amt "
                    "| GROUP BY $-.uid YIELD $-.uid AS uid, sum($-.amt) AS sales"
                ),
                "expect": [[1, 3]],
                "partial": True,
            },
            {
                "name": "group_by_amount_not_pushed",
                "sql": (
                    "GO FROM 10, 11 OVER buy REVERSELY WHERE buy.ts > 5 "
                    "YIELD buy.amount AS amt "
                    "| GROUP BY $-.amt YIELD $-.amt AS amt, count(*) AS n"
                ),
                # ts>5 keeps the NULL amount edge. count(*) counts that row;
                # count(amount) would not. NULL is its own group.
                "expect": [[None, 1], [5, 1], [7, 1], [9, 1]],
                "partial": False,
            },
            {
                "name": "avg_not_pushed",
                "sql": (
                    "GO FROM 10 OVER buy REVERSELY WHERE buy.ts > 5 "
                    "YIELD buy._dst AS uid, buy.amount AS amt "
                    "| GROUP BY $-.uid YIELD $-.uid AS uid, avg($-.amt) AS a"
                ),
                "expect": [[1, 5.0]],
                "partial": False,
            },
            {
                "name": "now_not_pushed",
                "sql": (
                    "GO FROM 10, 11 OVER buy REVERSELY WHERE buy.ts > now() "
                    "YIELD buy._dst AS uid, buy.amount AS amt "
                    "| GROUP BY $-.uid YIELD $-.uid AS uid, sum($-.amt) AS sales"
                ),
                "expect": [],
                "partial": False,
            },
        ]
        for case in cases:
            resp = execute(session, case["sql"])
            prof = execute(session, "PROFILE " + case["sql"])
            nodes = plan_nodes(prof)
            pushed = has_partial(nodes)
            want_push = case["partial"] and expect_partial
            got = rows_of(resp)
            ok = close(got, case["expect"]) and (pushed == want_push)
            entry = {
                "name": case["name"],
                "ok": ok,
                "rows": got,
                "expect": case["expect"],
                "partial_in_plan": pushed,
                "want_partial": want_push,
                "server_us": resp.latency(),
                "plan_names": [n["name"] for n in nodes],
            }
            if not ok:
                report["ok"] = False
                entry["plan"] = nodes
            report["cases"].append(entry)
            print(
                f"{case['name']} ok={ok} rows={got} partial={pushed} want={want_push}",
                flush=True,
            )
    finally:
        session.release()
        pool.close()
    text = json.dumps(report, ensure_ascii=False, indent=2)
    if args.out:
        os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")
        print(f"wrote {args.out}", flush=True)
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
