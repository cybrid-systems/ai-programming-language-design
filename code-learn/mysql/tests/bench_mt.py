#!/usr/bin/env python3
"""B-Tree optimization: multi-threaded benchmark with connection pooling.
Usage: python3 bench_mt.py [rows] [threads] [duration_sec]
"""
import mysql.connector
import time
import random
import statistics
import sys
import uuid as uuid_mod
from concurrent.futures import ThreadPoolExecutor, as_completed
from threading import local

SOCKET = "/tmp/mysql_opt.sock"
ROWS = int(sys.argv[1]) if len(sys.argv) > 1 else 50000
THREADS = int(sys.argv[2]) if len(sys.argv) > 2 else 8
DURATION = int(sys.argv[3]) if len(sys.argv) > 3 else 10

tls = local()

def get_conn():
    if not hasattr(tls, "conn") or tls.conn is None:
        tls.conn = mysql.connector.connect(
            unix_socket=SOCKET, user="root", database="btree_bench",
            connection_timeout=10, autocommit=True)
    return tls.conn

def sql(query, params=None):
    c = get_conn()
    cursor = c.cursor()
    cursor.execute(query, params or ())
    try:
        return cursor.fetchall()
    finally:
        cursor.close()

def setup(mode, rows):
    sql("SET GLOBAL innodb_btree_optimizations=" + mode)
    sql("DROP TABLE IF EXISTS bench")
    sql("""CREATE TABLE bench (
        id INT AUTO_INCREMENT PRIMARY KEY,
        val BIGINT NOT NULL,
        uuid_col VARCHAR(36),
        INDEX idx_uuid(uuid_col)
    ) ENGINE=InnoDB""")

    # Batch insert
    batch_size = 500
    for start in range(0, rows, batch_size):
        end = min(start + batch_size, rows)
        vals = ",".join([
            f"({i}, '{str(uuid_mod.uuid4())}')"
            for i in range(start + 1, end + 1)
        ])
        sql(f"INSERT INTO bench(val, uuid_col) VALUES {vals}")

    # Warmup
    for _ in range(100):
        sql("SELECT id FROM bench WHERE id = %s", (random.randint(1, rows),))

def bench_point_label(mode, label, n, duration):
    """Point queries, return latencies."""
    latencies = []
    stop_at = time.time() + duration
    while time.time() < stop_at:
        for _ in range(n):
            t0 = time.perf_counter()
            rid = random.randint(1, ROWS)
            sql("SELECT id FROM bench WHERE id = %s", (rid,))
            lat = time.perf_counter() - t0
            latencies.append(lat)
            if time.time() >= stop_at:
                break
    return latencies

def bench_point_thread(mode, duration, results_list):
    """Thread worker for point queries."""
    sql("SET GLOBAL innodb_btree_optimizations=" + mode)
    latencies = []
    stop_at = time.time() + duration
    while time.time() < stop_at:
        t0 = time.perf_counter()
        rid = random.randint(1, ROWS)
        sql("SELECT id FROM bench WHERE id = %s", (rid,))
        lat = time.perf_counter() - t0
        latencies.append(lat)
    results_list.extend(latencies)

def bench_range_thread(mode, duration, results_list):
    """Thread worker for range scans."""
    sql("SET GLOBAL innodb_btree_optimizations=" + mode)
    latencies = []
    stop_at = time.time() + duration
    while time.time() < stop_at:
        a = random.randint(1, ROWS - 100)
        t0 = time.perf_counter()
        sql("SELECT COUNT(*) FROM bench WHERE id BETWEEN %s AND %s", (a, a + 100))
        lat = time.perf_counter() - t0
        latencies.append(lat)
    results_list.extend(latencies)

def bench_uuid_point_thread(mode, duration, results_list):
    """Thread worker for UUID point queries."""
    sql("SET GLOBAL innodb_btree_optimizations=" + mode)
    # Get all UUIDs once
    uuids = [r[0] for r in sql("SELECT uuid_col FROM bench LIMIT 10000")]
    latencies = []
    stop_at = time.time() + duration
    while time.time() < stop_at:
        u = random.choice(uuids)
        t0 = time.perf_counter()
        sql("SELECT id FROM bench WHERE uuid_col = %s", (u,))
        lat = time.perf_counter() - t0
        latencies.append(lat)
    results_list.extend(latencies)

def run_bench(name, bench_fn, mode, duration, threads):
    results = []
    with ThreadPoolExecutor(max_workers=threads) as ex:
        futures = [ex.submit(bench_fn, mode, duration, results) for _ in range(threads)]
        for f in as_completed(futures):
            f.result()

    if not results:
        return 0, 0, 0, 0
    
    results.sort()
    n = len(results)
    total = sum(results)
    avg = total / n
    p50 = results[int(n * 0.50)]
    p95 = results[int(n * 0.95)]
    p99 = results[int(n * 0.99)]
    qps = n / duration
    
    print(f"  {name}: {qps:.0f} qps  |  avg={avg*1e6:.0f}μs  p50={p50*1e6:.0f}μs  p95={p95*1e6:.0f}μs  p99={p99*1e6:.0f}μs")
    return qps, avg, p50, p99

def main():
    print("=" * 72)
    print("B-TREE OPTIMIZATION — MULTI-THREAD BENCHMARK")
    print(f"  Rows={ROWS:,}  Threads={THREADS}  Duration={DURATION}s")
    print("  MySQL 9.6.0 ARM64 | Buffer Pool=1G | Page=16K")
    print("=" * 72)

    # Setup data (with optimizations OFF first)
    print("\n[Setup] Preparing data (OFF mode)...")
    setup("OFF", ROWS)

    modes = ["OFF", "ON"]
    results = {}

    for mode in modes:
        print(f"\n{'='*72}")
        print(f"innodb_btree_optimizations = {mode}")
        print(f"{'='*72}")

        sql("SET GLOBAL innodb_btree_optimizations=" + mode)
        time.sleep(0.5)

        mode_results = {}

        # 1. Point lookup
        print("\n--- Point Lookup (PK) ---")
        qps, avg, p50, p99 = run_bench("PK point", bench_point_thread, mode, DURATION, THREADS)
        mode_results["point_qps"] = qps
        mode_results["point_avg"] = avg
        mode_results["point_p50"] = p50
        mode_results["point_p99"] = p99

        # 2. Range scan
        print("\n--- Range Scan (PK, span=100) ---")
        qps, avg, p50, p99 = run_bench("PK range", bench_range_thread, mode, DURATION, THREADS)
        mode_results["range_qps"] = qps
        mode_results["range_avg"] = avg

        # 3. UUID point lookup (secondary index)
        print("\n--- UUID Point Lookup (Secondary Index) ---")
        qps, avg, p50, p99 = run_bench("UUID point", bench_uuid_point_thread, mode, DURATION, THREADS)
        mode_results["uuid_qps"] = qps
        mode_results["uuid_avg"] = avg

        results[mode] = mode_results

    print("\n" + "=" * 72)
    print("SUMMARY")
    print("=" * 72)
    print(f"{'Metric':<30} {'OFF':>12} {'ON':>12} {'Change':>12}")
    print("-" * 66)

    for label, key in [
        ("PK Point (qps)", "point_qps"),
        ("PK Range (qps)", "range_qps"),
        ("UUID Point (qps)", "uuid_qps"),
    ]:
        off_v = results["OFF"][key]
        on_v = results["ON"][key]
        pct = ((on_v - off_v) / off_v * 100) if off_v > 0 else 0
        print(f"{label:<30} {off_v:>12.0f} {on_v:>12.0f} {pct:>+11.1f}%")

    print("\nNotes:")
    print(f"  - {THREADS} concurrent connections (connection pooling)")
    print(f"  - {ROWS} rows in table, {DURATION}s per test")
    print("  - All differences are preliminary; multiple runs recommended")

if __name__ == "__main__":
    # pip install mysql-connector-python first
    main()
