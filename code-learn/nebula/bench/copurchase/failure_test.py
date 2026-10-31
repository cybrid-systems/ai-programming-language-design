#!/usr/bin/env python3
"""Failure and mixed-version checks on the single-node tck space.

A successful response must match the hand-checked product list. An error is
acceptable. A successful response with any other product list is a failure.
"""

import os
import sys
import time

_SCRIPT = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT not in sys.path:
    sys.path.insert(0, _SCRIPT)

from nebula3.Config import Config
from nebula3.gclient.net import ConnectionPool

EXPECT = [(30, 1000), (20, 900), (21, 800), (12, 500), (13, 400), (14, 300), (22, 50), (11, 11), (10, 10)]


def main():
    host = os.environ.get("NEBULA_HOST", "127.0.0.1")
    port = int(os.environ.get("NEBULA_PORT", "9669"))
    cfg = Config()
    cfg.timeout = 60000
    pool = ConnectionPool()
    if not pool.init([(host, port)], cfg):
        raise SystemExit(f"cannot connect {host}:{port}")
    session = pool.get_session("root", "nebula")
    try:
        deadline = time.time() + 30
        while time.time() < deadline:
            use = session.execute("USE copurchase_tck")
            if use.is_succeeded():
                break
            time.sleep(1)
        else:
            raise SystemExit(use.error_msg())
        resp = session.execute("COPURCHASE FROM 1 WINDOW 100, 200")
        if not resp.is_succeeded():
            print(f"query_error msg={resp.error_msg()}")
            print("FAILURE_OK error")
            return
        got = []
        for i in range(resp.row_size()):
            got.append((resp.row_values(i)[0].as_int(), resp.row_values(i)[1].as_int()))
        print(f"query_ok got={got}")
        if got != EXPECT:
            raise SystemExit("wrong successful result")
        print("FAILURE_OK exact")
    finally:
        session.release()
        pool.close()


if __name__ == "__main__":
    main()
