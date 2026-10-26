#!/usr/bin/env python3
"""Optional concurrency driver. Exits 0 after saying 未实测 when the client is missing.

This file does not invent latencies. A successful run prints percentiles from
wall-clock samples of session.execute.
"""

import os
import statistics
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed


def main():
    try:
        from nebula3.gclient.net import ConnectionPool
        from nebula3.Config import Config
    except ImportError:
        print("并发未实测: import nebula3 failed")
        return 0

    addr = os.environ.get("NEBULA_ADDR", "127.0.0.1:9669")
    host, port = addr.split(":")
    user = os.environ.get("NEBULA_USER", "root")
    password = os.environ.get("NEBULA_PASSWORD", "nebula")
    levels = [int(x) for x in os.environ.get("CONCURRENCY", "10,50,100,200").split(",") if x]
    query = os.environ.get("BENCH_QUERY", "").strip()
    if not query:
        print("并发未实测: set BENCH_QUERY to one statement from out/queries.ngql")
        return 0
    config = Config()
    pool = ConnectionPool()
    if not pool.init([(host, int(port))], config):
        print("并发未实测: connection pool init failed")
        return 2

    def one(_i):
        session = pool.get_session(user, password)
        try:
            start = time.perf_counter()
            resp = session.execute(query)
            elapsed = (time.perf_counter() - start) * 1000.0
            ok = resp.is_succeeded()
            return ok, elapsed
        finally:
            session.release()

    for n in levels:
        samples = []
        errors = 0
        with ThreadPoolExecutor(max_workers=n) as ex:
            futs = [ex.submit(one, i) for i in range(n)]
            for fut in as_completed(futs):
                ok, elapsed = fut.result()
                if not ok:
                    errors += 1
                samples.append(elapsed)
        samples.sort()
        if not samples:
            print(f"concurrency={n} no samples")
            continue
        p50 = statistics.median(samples)
        p99 = samples[max(0, int(round(0.99 * (len(samples) - 1))))]
        print(
            f"concurrency={n} n={len(samples)} errors={errors} "
            f"p50_ms={p50:.2f} p99_ms={p99:.2f}"
        )
    pool.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
