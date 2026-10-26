#!/usr/bin/env python3
"""Generate nGQL for scenario 2. Does not talk to a cluster and does not invent latencies."""

import argparse
import os
import random


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--users", type=int, default=1000)
    p.add_argument("--items", type=int, default=200)
    p.add_argument("--edges", type=int, default=5000)
    p.add_argument("--beauty-ratio", type=float, default=0.15)
    p.add_argument("--recent-ratio", type=float, default=0.2)
    p.add_argument("--now", type=int, default=1761436800, help="unix seconds used as 'now'")
    p.add_argument("--window", type=int, default=90 * 24 * 3600)
    p.add_argument("--seed", type=int, default=2)
    p.add_argument("--parts", type=int, default=10)
    p.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "out"))
    return p.parse_args()


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def make_dataset(users, items, edges, beauty_ratio, recent_ratio, now, window, seed, parts):
    """One RNG stream shared by the stock schema and the model schema.

    Rank is a per (user, item) counter so a second purchase does not overwrite
    the first. Time lives in the ts property. item_type on the model edge is
    copied from the item vertex.
    """
    rng = random.Random(seed)
    cutoff = now - window
    beauty_items = []
    other_items = []
    user_rows = [(uid, f"u{uid}") for uid in range(1, users + 1)]
    item_rows = []
    for iid in range(1, items + 1):
        vid = 100000000 + iid
        kind = "beauty" if rng.random() < beauty_ratio else "other"
        item_rows.append((vid, f"i{iid}", kind))
        (beauty_items if kind == "beauty" else other_items).append(vid)
    if not beauty_items:
        beauty_items.append(item_rows[0][0])

    edge_rows = []
    recent_beauty_users = set()
    sales = {}
    beauty_item_set = set(beauty_items)
    rank_of = {}
    matching_edges = 0
    for _ in range(edges):
        uid = rng.randint(1, users)
        if rng.random() < beauty_ratio and beauty_items:
            iid = rng.choice(beauty_items)
            kind = "beauty"
        else:
            pool = other_items or beauty_items
            iid = rng.choice(pool)
            kind = "beauty" if iid in beauty_item_set else "other"
        if rng.random() < recent_ratio:
            ts = rng.randint(cutoff + 1, now)
        else:
            ts = rng.randint(cutoff - window, cutoff)
        amount = rng.randint(1, 500)
        pair = (uid, iid)
        rank = rank_of.get(pair, 0)
        rank_of[pair] = rank + 1
        edge_rows.append((uid, iid, rank, ts, amount, kind))
        if kind == "beauty" and ts > cutoff:
            recent_beauty_users.add(uid)
            sales[uid] = sales.get(uid, 0) + amount
            matching_edges += 1
    return {
        "users": user_rows,
        "items": item_rows,
        "edges": edge_rows,
        "cutoff": cutoff,
        "now": now,
        "window": window,
        "parts": parts,
        "seed": seed,
        "beauty_items": len(beauty_items),
        "recent_beauty_users": recent_beauty_users,
        "sales": sales,
        "matching_edges": matching_edges,
    }


def main():
    args = parse_args()
    os.makedirs(args.out, exist_ok=True)
    data = make_dataset(
        args.users,
        args.items,
        args.edges,
        args.beauty_ratio,
        args.recent_ratio,
        args.now,
        args.window,
        args.seed,
        args.parts,
    )
    cutoff = data["cutoff"]
    recent_beauty_users = data["recent_beauty_users"]
    user_rows = [
        f'INSERT VERTEX user(name) VALUES {uid}:("{name}");' for uid, name in data["users"]
    ]
    item_rows = [
        f'INSERT VERTEX item(name, type) VALUES {vid}:("{name}", "{kind}");'
        for vid, name, kind in data["items"]
    ]
    stock_edges = [
        f"INSERT EDGE buy(ts, amount) VALUES {uid}->{iid}@{rank}:({ts}, {amount});"
        for uid, iid, rank, ts, amount, _kind in data["edges"]
    ]
    model_edges = [
        "INSERT EDGE buy(ts, amount, item_type) VALUES "
        f'{uid}->{iid}@{rank}:({ts}, {amount}, "{kind}");'
        for uid, iid, rank, ts, amount, kind in data["edges"]
    ]

    space = (
        "CREATE SPACE IF NOT EXISTS beauty_buy"
        f"(partition_num={args.parts}, replica_factor=1, vid_type=INT64);\n"
        "USE beauty_buy;\n"
    )
    stock_schema = space + """
CREATE TAG IF NOT EXISTS user(name string);
CREATE TAG IF NOT EXISTS item(name string, type string);
CREATE EDGE IF NOT EXISTS buy(ts int, amount double);
CREATE TAG INDEX IF NOT EXISTS item_type_idx ON item(type(16));
"""
    model_schema = space + """
CREATE TAG IF NOT EXISTS user(name string);
CREATE TAG IF NOT EXISTS item(name string, type string);
CREATE EDGE IF NOT EXISTS buy(ts int, amount double, item_type string);
CREATE TAG INDEX IF NOT EXISTS item_type_idx ON item(type(16));
CREATE EDGE INDEX IF NOT EXISTS buy_type_ts_idx ON buy(item_type(16), ts);
"""
    queries = f"""-- cutoff {cutoff} = now {args.now} - window {args.window}
-- expected distinct users with a recent beauty purchase: {len(recent_beauty_users)}
-- Q1 / Q2 (Q2 requires --enable_dst_only_edge_filter=true on a patched cluster)
USE beauty_buy;
LOOKUP ON item WHERE item.type == "beauty" YIELD id(vertex) AS id
| GO 1 STEP FROM $-.id OVER buy REVERSELY
    WHERE buy.ts > {cutoff}
    YIELD DISTINCT buy._dst AS user;

-- Q4 sales. Same plan with or without the dst-only flag.
LOOKUP ON item WHERE item.type == "beauty" YIELD id(vertex) AS id
| GO 1 STEP FROM $-.id OVER buy REVERSELY
    WHERE buy.ts > {cutoff}
    YIELD buy._dst AS uid, buy.amount AS amt
| GROUP BY $-.uid
    YIELD $-.uid AS uid, sum($-.amt) AS sales
| ORDER BY $-.sales DESC
| LIMIT 100;

-- Q3 modeling space (load schema_model.ngql + data_model.ngql)
LOOKUP ON buy WHERE buy.item_type == "beauty" AND buy.ts > {cutoff}
YIELD src(edge) AS user;
"""
    write(os.path.join(args.out, "schema_stock.ngql"), stock_schema)
    write(os.path.join(args.out, "schema_model.ngql"), model_schema)
    write(os.path.join(args.out, "data_stock.ngql"), "USE beauty_buy;\n" + "\n".join(user_rows + item_rows + stock_edges) + "\n")
    write(os.path.join(args.out, "data_model.ngql"), "USE beauty_buy;\n" + "\n".join(user_rows + item_rows + model_edges) + "\n")
    write(os.path.join(args.out, "queries.ngql"), queries)
    write(
        os.path.join(args.out, "oracle.txt"),
        "\n".join(str(u) for u in sorted(recent_beauty_users)) + "\n",
    )
    print(
        f"wrote {args.out}: users={args.users} items={args.items} edges={args.edges} "
        f"beauty_items={data['beauty_items']} recent_beauty_users={len(recent_beauty_users)} "
        f"matching_edges={data['matching_edges']} cutoff={cutoff}"
    )


if __name__ == "__main__":
    main()
