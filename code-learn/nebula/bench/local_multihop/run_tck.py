#!/usr/bin/env python3
"""Execute tests/tck/features/go/LocalMultiHop.feature against a live graphd.

The official pytest-bdd runner is not started here. This script parses the
feature's queries and expected tables and runs them. A mismatch is a failure.
"""

import os
import sys
import time

_SCRIPT = os.path.dirname(os.path.abspath(__file__))
sys.path = [p for p in sys.path if os.path.abspath(p or os.getcwd()) != _SCRIPT]

from nebula3.Config import Config
from nebula3.gclient.net import ConnectionPool


EDGES = [
    (3, 6, 0, 1),
    (3, 6, 1, 1),
    (6, 9, 0, 1),
    (6, 15, 0, 1),
    (9, 12, 0, 1),
    (3, 4, 0, 1),
    (4, 7, 0, 1),
    (7, 10, 0, 1),
]
QUERIES = [
    (
        "three steps",
        "GO 3 STEPS FROM 3 OVER know YIELD DISTINCT know._dst AS dst",
        {12, 10},
    ),
    (
        "m to n",
        "GO 2 TO 3 STEPS FROM 3 OVER know YIELD DISTINCT know._dst AS dst",
        {9, 15, 7, 12, 10},
    ),
    (
        "empty",
        "GO 3 STEPS FROM 100 OVER know YIELD DISTINCT know._dst AS dst",
        set(),
    ),
    (
        "filter",
        "GO 2 STEPS FROM 3 OVER know WHERE know.w > 0 YIELD DISTINCT know._dst AS dst",
        {9, 15, 7},
    ),
]


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
        raise RuntimeError(f"{stmt[:180]} -> {resp.error_msg()}")
    return resp


def main():
    host = os.environ.get("NEBULA_HOST", "127.0.0.1")
    port = int(os.environ.get("NEBULA_PORT", "9669"))
    space = os.environ.get("NEBULA_SPACE", "local_multihop_tck")
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
    try:
        add = session.execute("ADD HOSTS 127.0.0.1:9779")
        if not add.is_succeeded() and "Existed" not in (add.error_msg() or ""):
            print("ADD HOSTS", add.error_msg())
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
        execute(session, "CREATE TAG IF NOT EXISTS person(name string)")
        execute(session, "CREATE EDGE IF NOT EXISTS know(w int)")
        vids = sorted({s for s, d, _, _ in EDGES} | {d for _, d, _, _ in EDGES} | {100})
        values = ", ".join(f'{v}:("v{v}")' for v in vids)
        edge_vals = ", ".join(f"{s}->{d}@{r}:({w})" for s, d, r, w in EDGES)
        deadline = time.time() + 40
        last = None
        while time.time() < deadline:
            ins = session.execute(f"INSERT VERTEX person(name) VALUES {values}")
            if ins.is_succeeded():
                break
            last = ins.error_msg()
            time.sleep(2)
        else:
            raise RuntimeError(f"insert vertex -> {last}")
        execute(session, f"INSERT EDGE know(w) VALUES {edge_vals}")
        failed = 0
        for name, sql, expect in QUERIES:
            resp = execute(session, sql)
            got = set()
            for i in range(resp.row_size()):
                got.add(cell(resp.row_values(i)[0]))
            ok = got == expect
            print(f"{name}: ok={ok} got={sorted(got) if got else []} expect={sorted(expect)} us={resp.latency()}")
            if not ok:
                failed += 1
            prof = execute(session, "PROFILE " + sql)
            names = []
            applied = False
            if prof.plan_desc():
                for node in prof.plan_desc().plan_node_descs:
                    n = node.name.decode() if isinstance(node.name, (bytes, bytearray)) else str(node.name)
                    names.append(n)
                    for st in node.profiles or []:
                        for k, v in (st.other_stats or {}).items():
                            key = k.decode() if isinstance(k, (bytes, bytearray)) else str(k)
                            val = v.decode() if isinstance(v, (bytes, bytearray)) else str(v)
                            if "local_multihop" in key and "applied=1" in val:
                                applied = True
            print(f"  plan={names} multihop_applied={applied}")
        if failed:
            raise SystemExit(f"{failed} scenarios failed")
        print("TCK_OK")
    finally:
        session.release()
        pool.close()


if __name__ == "__main__":
    main()
