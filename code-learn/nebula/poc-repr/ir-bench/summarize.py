#!/usr/bin/env python3
"""Summarize alternating baseline/P0 JSON from measure.py. No invented numbers."""

import json
import statistics
import sys
from pathlib import Path


def load_runs(directory):
    runs = []
    for path in sorted(Path(directory).glob("r*-*.json")):
        name = path.name[: -len(".json")]
        # r1-base, r2-p0
        round_s, variant = name.split("-", 1)
        data = json.loads(path.read_text())
        runs.append({"round": round_s, "variant": variant, "path": str(path), "data": data})
    return runs


def level_map(run):
    out = {}
    for qname, entry in run["data"].get("queries", {}).items():
        for level in entry.get("levels") or []:
            out[(qname, level["concurrency"])] = {
                "check_ok": entry.get("ok"),
                "server_p50": (level.get("server_ms") or {}).get("p50"),
                "server_p95": (level.get("server_ms") or {}).get("p95"),
                "server_p99": (level.get("server_ms") or {}).get("p99"),
                "client_p50": (level.get("client_ms") or {}).get("p50"),
                "client_p95": (level.get("client_ms") or {}).get("p95"),
                "client_p99": (level.get("client_ms") or {}).get("p99"),
                "qps": level.get("qps"),
                "ok": level.get("ok"),
                "errors": level.get("errors"),
                "watermark_errors": level.get("watermark_errors"),
                "worker_errors": level.get("worker_errors") or [],
                "samples": level.get("samples"),
                "rss": level.get("rss"),
            }
    return out


def rss_kb(level, proc):
    rss = (level or {}).get("rss") or {}
    sampled = (rss.get("sampled_rss_kb_max") or {}).get(proc)
    after = ((rss.get("after") or {}).get(proc) or {}).get("hwm_kb")
    before = ((rss.get("before") or {}).get(proc) or {}).get("hwm_kb")
    return sampled, before, after


def watermark_count(level):
    """Sample errors plus warmup failures.

    measure.py counts "high watermark" only on finished samples. A warmup
    failure is stored in worker_errors and leaves samples at 0, so the
    counter stays 0 unless this function also scans worker_errors.
    """
    n = level.get("watermark_errors") or 0
    for text in level.get("worker_errors") or []:
        if "watermark" in text.lower():
            n += 1
    return n


def median(xs):
    xs = [x for x in xs if x is not None]
    if not xs:
        return None
    return statistics.median(xs)


def main():
    directory = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).with_name("results"))
    runs = load_runs(directory)
    if not runs:
        print(f"no r*-*.json in {directory}")
        return 1
    by_variant = {}
    for run in runs:
        by_variant.setdefault(run["variant"], []).append(level_map(run))
    queries = ["q_users", "q_sales", "q_model"]
    concurrencies = [1, 10, 50, 100, 200]
    print(f"runs={len(runs)} variants={ {k: len(v) for k, v in by_variant.items()} }")
    for q in queries:
        print(f"\n## {q}")
        for c in concurrencies:
            print(f"  concurrency {c}")
            for variant, maps in by_variant.items():
                rows = [m.get((q, c)) for m in maps]
                rows = [r for r in rows if r]
                if not rows:
                    print(f"    {variant}: missing")
                    continue
                def col(key):
                    return [r[key] for r in rows]

                g_rss = [rss_kb(r, "nebula-graphd")[0] for r in rows]
                s_rss = [rss_kb(r, "nebula-storaged")[0] for r in rows]
                clean = [
                    r
                    for r in rows
                    if r["errors"] == 0
                    and not r["worker_errors"]
                    and r["server_p50"] is not None
                ]

                def rng(key, subset):
                    xs = [r[key] for r in subset if r.get(key) is not None]
                    if not xs:
                        return "n=0"
                    return (
                        f"n={len(xs)} med={median(xs):.3f} "
                        f"min={min(xs):.3f} max={max(xs):.3f}"
                    )

                print(
                    "    {v}: all n={n} ok={ok} err={err} wm={wm}".format(
                        v=variant,
                        n=len(rows),
                        ok=col("ok"),
                        err=col("errors"),
                        wm=[watermark_count(r) for r in rows],
                    )
                )
                print(f"      clean server_p50 {rng('server_p50', clean)}")
                print(f"      clean server_p95 {rng('server_p95', clean)}")
                print(f"      clean server_p99 {rng('server_p99', clean)}")
                print(f"      clean qps {rng('qps', clean)}")
                print(f"      clean client_p50 {rng('client_p50', clean)}")
                print(
                    "      clean graphd_rss_kb "
                    f"{rng('graphd_rss', [{'graphd_rss': rss_kb(r, 'nebula-graphd')[0]} for r in clean])}"
                )
                print(
                    "      clean storaged_rss_kb "
                    f"{rng('storaged_rss', [{'storaged_rss': rss_kb(r, 'nebula-storaged')[0]} for r in clean])}"
                )
    checks = []
    for run in runs:
        for qname, entry in run["data"].get("queries", {}).items():
            checks.append((run["round"], run["variant"], qname, entry.get("ok"), entry.get("check") or entry.get("sales_check")))
    print("\n## checks")
    for item in checks:
        print(item[0], item[1], item[2], "ok", item[3])
    return 0


if __name__ == "__main__":
    sys.exit(main())
