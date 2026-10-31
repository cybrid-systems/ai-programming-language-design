"""Ranking shared by the generator check and the bench.

This matches src/common/algorithm/Copurchase.h:
window inclusive; coCount = distinct focus products; purchaseCount = all
in-window edges; ties are purchaseCount, latest timestamp, smaller user id;
sales ties break to the smaller product id.
"""

from collections import defaultdict


def top_products(edges, start, end, k=5):
    acc = {}
    for _user, pid, ts in edges:
        if ts < start or ts > end:
            continue
        count, latest = acc.get(pid, (0, -1))
        acc[pid] = (count + 1, max(latest, ts))
    rows = [(count, latest, -pid, pid) for pid, (count, latest) in acc.items()]
    rows.sort(reverse=True)
    return [pid for _c, _t, _n, pid in rows[:k]]


def score_users(by_user, focus, start, end):
    focus = set(focus)
    scores = []
    for user, edges in by_user.items():
        co = set()
        products = set()
        purchases = 0
        latest = -1
        for pid, ts in edges:
            if ts < start or ts > end:
                continue
            purchases += 1
            latest = max(latest, ts)
            products.add(pid)
            if pid in focus:
                co.add(pid)
        if not co:
            continue
        scores.append((len(co), purchases, latest, -user, user, products))
    scores.sort(reverse=True)
    return scores


def exact(by_user, by_product, sales, user, start, end, k_prod=5, k_user=15, k_sales=20):
    mine = [(user, pid, ts) for pid, ts in by_user.get(user, [])]
    focus = top_products(mine, start, end, k_prod)
    buyers = {}
    for pid in focus:
        for other, ts in by_product.get(pid, []):
            if other == user or ts < start or ts > end:
                continue
            buyers[other] = True
    scoped = {uid: by_user[uid] for uid in buyers}
    ranked = score_users(scoped, focus, start, end)[:k_user]
    pids = set()
    for row in ranked:
        pids.update(row[5])
    order = sorted(((-sales[pid], pid, pid) for pid in pids))
    products = [(pid, int(sales[pid])) for _s, _p, pid in order[:k_sales]]
    users = [(row[4], row[0], row[1], row[2]) for row in ranked]
    return {"focus": focus, "users": users, "products": products}


def part_of(vid, parts):
    return int(vid) % parts + 1


def naive(by_user, by_product, sales, user, start, end, parts, k_prod=5, k_user=15, k_sales=20):
    mine = [(user, pid, ts) for pid, ts in by_user.get(user, [])]
    focus = top_products(mine, start, end, k_prod)
    per_part = defaultdict(list)
    for pid in focus:
        part = part_of(pid, parts)
        for other, ts in by_product.get(pid, []):
            if other == user or ts < start or ts > end:
                continue
            per_part[part].append((other, pid, ts))
    merged = {}
    for hits in per_part.values():
        acc = {}
        for buyer, pid, ts in hits:
            row = acc.setdefault(buyer, {"pids": set(), "pc": 0, "ts": -1})
            row["pids"].add(pid)
            row["pc"] += 1
            row["ts"] = max(row["ts"], ts)
        local = []
        for buyer, row in acc.items():
            local.append((len(row["pids"]), row["pc"], row["ts"], -buyer, buyer, set(row["pids"])))
        local.sort(reverse=True)
        for row in local[:k_user]:
            got = merged.setdefault(row[4], {"pids": set(), "pc": 0, "ts": -1})
            got["pids"].update(row[5])
            got["pc"] += row[1]
            got["ts"] = max(got["ts"], row[2])
    ranked = []
    for buyer, row in merged.items():
        ranked.append((len(row["pids"]), row["pc"], row["ts"], -buyer, buyer, row["pids"]))
    ranked.sort(reverse=True)
    ranked = ranked[:k_user]
    pids = set()
    for row in ranked:
        pids.update(row[5])
    order = sorted(((-sales[pid], pid, pid) for pid in pids))
    products = [(pid, int(sales[pid])) for _s, _p, pid in order[:k_sales]]
    users = [(row[4], row[0], row[1], row[2]) for row in ranked]
    return {"focus": focus, "users": users, "products": products}


def overlap(got_ids, expect_ids):
    if not expect_ids:
        return 1.0 if not got_ids else 0.0
    return len(set(got_ids) & set(expect_ids)) / float(len(expect_ids))
