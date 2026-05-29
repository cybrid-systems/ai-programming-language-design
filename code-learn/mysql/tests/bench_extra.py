#!/usr/bin/env python3
"""B-Tree extra benchmarks: string scan, space, dense insert, mixed workload."""
import pymysql, time, random, statistics
from concurrent.futures import ThreadPoolExecutor, as_completed

SOCK = "/tmp/mysql_opt.sock"
TH = 8

def conn():
    return pymysql.connect(unix_socket=SOCK, user="root", database="btree_bench", autocommit=True)

def sql(db, q):
    c = conn()
    cur = c.cursor()
    if db: c.select_db(db)
    cur.execute(q)
    r = cur.fetchall()
    c.close()
    return r

# ===== 1. String scan — URL keys with common prefix =====
print("=" * 60)
print("1. STRING SCAN — URL keys (Prefix Truncation)")
print("=" * 60)

for mode in ["OFF", "ON"]:
    sql(None, f"SET GLOBAL innodb_btree_optimizations={mode}")
    sql(None, "SET GLOBAL innodb_adaptive_hash_index=OFF")
    sql(None, "DROP TABLE IF EXISTS btree_bench.str_scan")
    sql(None, """CREATE TABLE btree_bench.str_scan (
        id INT AUTO_INCREMENT PRIMARY KEY,
        url VARCHAR(255) NOT NULL,
        INDEX idx_url(url)
    ) ENGINE=InnoDB""")

    N = 20000
    domains = ["example.com", "test.org", "company.net"]
    for s in range(0, N, 500):
        e = min(s+500, N)
        vals = ",".join([f'("https://{random.choice(domains)}/api/v1/user/{random.randint(1,99999)}")' for _ in range(s+1, e+1)])
        sql(None, f"INSERT INTO btree_bench.str_scan(url) VALUES {vals}")

    # Warmup
    c = conn(); cur = c.cursor()
    for _ in range(200):
        cur.execute("SELECT COUNT(*) FROM str_scan WHERE url LIKE 'https://example.com/%'")
        cur.fetchall()
    c.close()

    dur = 10
    def worker(dur, res):
        c = conn(); cur = c.cursor(); lat = []; stop = time.time()+dur
        while time.time() < stop:
            d = random.choice(domains)
            t0 = time.perf_counter()
            cur.execute(f"SELECT COUNT(*) FROM str_scan WHERE url LIKE 'https://{d}/%'")
            cur.fetchall()
            lat.append(time.perf_counter()-t0)
        c.close(); res.extend(lat)

    print(f"  [{mode}] String range scan...", end=" ", flush=True)
    r = []
    with ThreadPoolExecutor(max_workers=TH) as ex:
        for f in as_completed([ex.submit(worker, dur, r) for _ in range(TH)]): f.result()
    r.sort(); nq=len(r); qps=nq/dur; p50=r[int(nq*0.5)]; p95=r[int(nq*0.95)]
    print(f"{qps:.0f} qps  p50={p50*1e3:.1f}ms  p95={p95*1e3:.1f}ms")

# ===== 2. Space usage =====
print("\n" + "=" * 60)
print("2. SPACE USAGE")
print("=" * 60)

for mode in ["OFF", "ON"]:
    sql(None, f"SET GLOBAL innodb_btree_optimizations={mode}")
    sql(None, "DROP TABLE IF EXISTS btree_bench.space_test")
    sql(None, """CREATE TABLE btree_bench.space_test (
        id INT AUTO_INCREMENT PRIMARY KEY,
        url VARCHAR(255) NOT NULL,
        INDEX idx_url(url)
    ) ENGINE=InnoDB""")

    N = 20000
    for s in range(0, N, 500):
        e = min(s+500, N)
        vals = ",".join([f'("https://example.com/path/{random.randint(1,99999)}")' for _ in range(s+1, e+1)])
        sql(None, f"INSERT INTO btree_bench.space_test(url) VALUES {vals}")

    rows = sql(None, "SHOW TABLE STATUS FROM btree_bench LIKE 'space_test'")
    data_len = rows[0][6]  # Data_length
    idx_len = rows[0][8]  # Index_length
    print(f"  [{mode}] rows={N:,} data={data_len:,} idx={idx_len:,}  data/row={data_len/N:.0f}  idx/row={idx_len/N:.0f}")

# ===== 3. Dense integer insert =====
print("\n" + "=" * 60)
print("3. DENSE INTEGER INSERT (Fully-Dense scenario)")
print("=" * 60)

for mode in ["OFF", "ON"]:
    sql(None, f"SET GLOBAL innodb_btree_optimizations={mode}")
    sql(None, "SET GLOBAL innodb_adaptive_hash_index=OFF")
    sql(None, "DROP TABLE IF EXISTS btree_bench.dense_ins")
    sql(None, """CREATE TABLE btree_bench.dense_ins (
        id INT AUTO_INCREMENT PRIMARY KEY,
        val BIGINT NOT NULL
    ) ENGINE=InnoDB""")

    N = 50000
    t0 = time.perf_counter()
    for s in range(0, N, 500):
        e = min(s+500, N)
        vals = ",".join([f"({i})" for i in range(s+1, e+1)])
        sql(None, f"INSERT INTO btree_bench.dense_ins(val) VALUES {vals}")
    dt = time.perf_counter()-t0
    print(f"  [{mode}] Insert {N}: {dt:.3f}s ({N/dt:.0f} rows/s)")

    # Point query
    c = conn(); cur = c.cursor()
    for _ in range(200):
        cur.execute(f"SELECT id FROM dense_ins WHERE id = {random.randint(1,N)}")
        cur.fetchall()
    c.close()

    dur = 8
    def pt_worker(dur, res):
        c = conn(); cur = c.cursor(); lat = []; stop = time.time()+dur
        while time.time() < stop:
            t0 = time.perf_counter()
            cur.execute(f"SELECT id FROM dense_ins WHERE id = {random.randint(1,N)}")
            cur.fetchall()
            lat.append(time.perf_counter()-t0)
        c.close(); res.extend(lat)

    print(f"  [{mode}] Dense PK point...", end=" ", flush=True)
    r = []
    with ThreadPoolExecutor(max_workers=TH) as ex:
        for f in as_completed([ex.submit(pt_worker, dur, r) for _ in range(TH)]): f.result()
    r.sort(); nq=len(r); qps=nq/dur; p50=r[int(nq*0.5)]; p95=r[int(nq*0.95)]
    print(f"{qps:.0f} qps  p50={p50*1e3:.1f}ms  p95={p95*1e3:.1f}ms")

# ===== 4. Mixed workload =====
print("\n" + "=" * 60)
print("4. MIXED WORKLOAD (70% read + 30% insert)")
print("=" * 60)

for mode in ["OFF", "ON"]:
    sql(None, f"SET GLOBAL innodb_btree_optimizations={mode}")
    sql(None, "SET GLOBAL innodb_adaptive_hash_index=OFF")
    sql(None, "DROP TABLE IF EXISTS btree_bench.mixed")
    sql(None, """CREATE TABLE btree_bench.mixed (
        id INT AUTO_INCREMENT PRIMARY KEY,
        val BIGINT NOT NULL
    ) ENGINE=InnoDB""")
    for s in range(0, 10000, 500):
        e = min(s+500, 10000)
        vals = ",".join([f"({i})" for i in range(s+1, e+1)])
        sql(None, f"INSERT INTO btree_bench.mixed(val) VALUES {vals}")

    dur = 10
    COUNTER = [10000]
    def mix_worker(dur, res):
        c = conn(); cur = c.cursor(); lat = []; stop = time.time()+dur
        while time.time() < stop:
            if random.random() < 0.7:
                t0 = time.perf_counter()
                cur.execute(f"SELECT id FROM mixed WHERE id = {random.randint(1,10000)}")
                cur.fetchall()
                lat.append(time.perf_counter()-t0)
            else:
                t0 = time.perf_counter()
                cur.execute("INSERT INTO mixed(val) VALUES(1)")
                lat.append(time.perf_counter()-t0)
        c.close(); res.extend(lat)

    print(f"  [{mode}] Mixed 70/30...", end=" ", flush=True)
    r = []
    with ThreadPoolExecutor(max_workers=TH) as ex:
        for f in as_completed([ex.submit(mix_worker, dur, r) for _ in range(TH)]): f.result()
    r.sort(); nq=len(r); qps=nq/dur; p50=r[int(nq*0.5)]
    print(f"{qps:.0f} tps  p50={p50*1e3:.1f}ms")

print("\n" + "=" * 60)
print("ALL DONE")
print("=" * 60)
