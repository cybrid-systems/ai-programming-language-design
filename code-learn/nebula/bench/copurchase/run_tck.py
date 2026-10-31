#!/usr/bin/env python3
"""Hand-checked co-purchase graph against a live graphd.

Schema: tag product(sales int), edge buy() with rank = timestamp.
Window is inclusive. Expected rows are computed from the same edges the
inserts use, with the ranking in src/common/algorithm/Copurchase.h.
"""

import os
import sys
import time

_SCRIPT = os.path.dirname(os.path.abspath(__file__))
sys.path = [p for p in sys.path if os.path.abspath(p or os.getcwd()) != _SCRIPT]

from nebula3.Config import Config
from nebula3.gclient.net import ConnectionPool

# user, product, rank. User 1 is the seed.
EDGES = [
    (1, 14, 180),
    (1, 13, 170),
    (1, 12, 160),
    (1, 11, 150),
    (1, 10, 100),
    (1, 15, 50),
    (5, 10, 110),
    (5, 11, 120),
    (5, 12, 130),
    (5, 13, 140),
    (5, 30, 190),
    (2, 14, 181),
    (2, 13, 171),
    (2, 12, 161),
    (2, 20, 150),
    (3, 14, 182),
    (3, 13, 172),
    (3, 21, 160),
    (4, 14, 183),
    (4, 22, 140),
    (6, 23, 150),
]
SALES = {
    10: 10,
    11: 11,
    12: 500,
    13: 400,
    14: 300,
    15: 1,
    20: 900,
    21: 800,
    22: 50,
    23: 40,
    30: 1000,
}
# sales desc, pid asc. Every in-window product of users 5,2,3,4.
EXPECT = [(30, 1000), (20, 900), (21, 800), (12, 500), (13, 400), (14, 300), (22, 50), (11, 11), (10, 10)]
WINDOW = (100, 200)


def cell(value):
    if value.is_null() or value.is_empty():
        return None
    if value.is_int():
        return int(value.as_int())
    if value.is_string():
        return value.as_string()
    return str(value)


def execute(session, stmt):
    resp = session.execute(stmt)
    if not resp.is_succeeded():
        raise RuntimeError(f"{stmt[:240]} -> {resp.error_msg()}")
    return resp


def rows(resp):
    out = []
    for i in range(resp.row_size()):
        out.append(tuple(cell(v) for v in resp.row_values(i)))
    return out


def load(session, space):
    execute(
        session,
        f"CREATE SPACE IF NOT EXISTS {space}"
        "(partition_num=3, replica_factor=1, vid_type=INT64)",
    )
    ready = time.time() + 90
    while time.time() < ready:
        use = session.execute(f"USE {space}")
        if use.is_succeeded():
            break
        time.sleep(2)
    else:
        raise SystemExit(f"USE {space} failed")
    execute(session, "CREATE TAG IF NOT EXISTS product(sales int)")
    execute(session, "CREATE EDGE IF NOT EXISTS buy()")
    vids = sorted(set(SALES) | {src for src, _, _ in EDGES} | {dst for _, dst, _ in EDGES})
    values = ", ".join(f"{vid}:({SALES.get(vid, 0)})" for vid in vids)
    edge_vals = ", ".join(f"{src}->{dst}@{rank}:()" for src, dst, rank in EDGES)
    deadline = time.time() + 40
    last = None
    while time.time() < deadline:
        ins = session.execute(f"INSERT VERTEX product(sales) VALUES {values}")
        if ins.is_succeeded():
            break
        last = ins.error_msg()
        time.sleep(2)
    else:
        raise RuntimeError(f"insert vertex -> {last}")
    execute(session, f"INSERT EDGE buy() VALUES {edge_vals}")


def baseline_products(session):
    """nGQL equivalent. Server statements fetch edges; ranking matches Copurchase.h."""
    start, end = WINDOW
    focus = [row[0] for row in rows(execute(
        session,
        "GO FROM 1 OVER buy WHERE buy._rank >= "
        f"{start} AND buy._rank <= {end} "
        "YIELD buy._dst AS pid, buy._rank AS ts "
        "| GROUP BY $-.pid YIELD $-.pid AS pid, count(*) AS cnt, max($-.ts) AS ts "
        "| ORDER BY $-.cnt DESC, $-.ts DESC, $-.pid ASC | LIMIT 5",
    ))]
    idlist = ",".join(str(pid) for pid in focus)
    inbound = rows(execute(
        session,
        f"GO FROM {idlist} OVER buy REVERSELY "
        f"WHERE buy._rank >= {start} AND buy._rank <= {end} "
        "YIELD buy._dst AS buyer, buy._src AS pid, buy._rank AS ts",
    ))
    print(f"  ngql_inbound={inbound}")
    buyers = sorted({row[0] for row in inbound if row[0] != 1})
    if not buyers:
        return []
    idlist = ",".join(str(uid) for uid in buyers)
    outbound = rows(execute(
        session,
        f"GO FROM {idlist} OVER buy "
        f"WHERE buy._rank >= {start} AND buy._rank <= {end} "
        "YIELD buy._src AS uid, buy._dst AS pid, buy._rank AS ts",
    ))
    print(f"  ngql_outbound={outbound}")
    focus_set = set(focus)
    scores = {}
    for uid, pid, ts in outbound:
        if uid == 1:
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
        return []
    idlist = ",".join(str(pid) for pid in pids)
    fetched = rows(execute(
        session,
        f"FETCH PROP ON product {idlist} YIELD id(vertex) AS pid, product.sales AS sales",
    ))
    print(f"  ngql_fetch={fetched}")
    order = sorted(((row[1], -row[0], row[0]) for row in fetched), reverse=True)
    return [(pid, sales) for sales, _, pid in order[:20]]


def check(name, got, expect):
    ok = got == expect
    print(f"{name}: ok={ok} got={got} expect={expect}")
    return ok


def main():
    host = os.environ.get("NEBULA_HOST", "127.0.0.1")
    port = int(os.environ.get("NEBULA_PORT", "9669"))
    space = os.environ.get("NEBULA_SPACE", "copurchase_tck")
    cfg = Config()
    cfg.max_connection_pool_size = 4
    cfg.timeout = 120000
    pool = ConnectionPool()
    deadline = time.time() + 90
    while time.time() < deadline:
        if pool.init([(host, port)], cfg):
            break
        time.sleep(1)
    else:
        raise SystemExit(f"cannot connect {host}:{port}")
    session = pool.get_session("root", "nebula")
    failed = 0
    try:
        add = session.execute("ADD HOSTS 127.0.0.1:9779")
        if not add.is_succeeded() and "Existed" not in (add.error_msg() or ""):
            print("ADD HOSTS", add.error_msg())
        load(session, space)
        start, end = WINDOW
        for mode, stmt in (
            ("exact", f"COPURCHASE FROM 1 WINDOW {start}, {end}"),
            ("naive", f"COPURCHASE FROM 1 WINDOW {start}, {end} NAIVE"),
        ):
            resp = execute(session, stmt)
            got = rows(resp)
            if not check(mode, got, EXPECT):
                failed += 1
            print(f"  latency_us={resp.latency()}")
        hop1 = (
            "GO FROM 1 OVER buy WHERE buy._rank >= 100 AND buy._rank <= 200 "
            "YIELD buy._dst AS pid, buy._rank AS ts "
            "| GROUP BY $-.pid YIELD $-.pid AS pid, count(*) AS cnt, max($-.ts) AS ts "
            "| ORDER BY $-.cnt DESC, $-.ts DESC, $-.pid ASC | LIMIT 5"
        )
        resp = execute(session, hop1)
        got = rows(resp)
        expect_hop1 = [(14, 1, 180), (13, 1, 170), (12, 1, 160), (11, 1, 150), (10, 1, 100)]
        if not check("ngql_hop1", got, expect_hop1):
            failed += 1
        print(f"  latency_us={resp.latency()}")
        base = baseline_products(session)
        if not check("ngql_baseline", base, EXPECT):
            failed += 1
        if failed:
            raise SystemExit(f"{failed} scenarios failed")
        print("TCK_OK")
    finally:
        session.release()
        pool.close()


if __name__ == "__main__":
    main()
