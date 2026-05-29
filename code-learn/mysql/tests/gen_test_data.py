#!/usr/bin/env python3
"""B-Tree optimization test data generator.
Usage: python3 gen_test_data.py <mode> <count> [output.csv]

Modes:
  seq     - Sequential integers (Fully-Dense best case)
  uuid    - Random UUID strings (Heads + Hints scenario)
  email   - Same-domain emails (Prefix Truncation best case)
  zipf    - Zipf-distributed integers (skewed access)
"""
import uuid
import random
import csv
import sys


def gen_sequential_ints(n):
    return [(i, i * 2) for i in range(n)]


def gen_random_uuid(n):
    return [(str(uuid.uuid4()), i) for i in range(n)]


def gen_same_domain_email(n):
    return [(f"user{i:05d}@company.com", i) for i in range(n)]


def gen_zipf_int(n, alpha=1.5):
    keys = []
    for _ in range(n):
        k = int(random.paretovariate(alpha - 1)) + 1
        keys.append((k, _))
    return keys


def gen_url_like(n):
    paths = ["/api", "/blog", "/docs", "/user", "/admin"]
    return [
        (f"https://example.com{random.choice(paths)}/{random.randint(0,9999)}", i)
        for i in range(n)
    ]


GENERATORS = {
    "seq": gen_sequential_ints,
    "uuid": gen_random_uuid,
    "email": gen_same_domain_email,
    "zipf": gen_zipf_int,
    "url": gen_url_like,
}


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "uuid"
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 10000
    out = sys.argv[3] if len(sys.argv) > 3 else None

    gen = GENERATORS.get(mode)
    if not gen:
        print(f"Unknown mode: {mode}. Choose from: {', '.join(GENERATORS.keys())}")
        sys.exit(1)

    data = gen(n)
    w = csv.writer(open(out, "w", newline="") if out else sys.stdout)
    w.writerow(["key", "val"])
    for k, val in data:
        w.writerow([k, val])

    if out:
        print(f"Generated {n} rows ({mode}) -> {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
