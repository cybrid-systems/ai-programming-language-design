#!/usr/bin/env bash
# Affinity / random / mixed co-purchase on the 3-storaged namespace cluster.
# Sampler stays on so graphd can see out-edge ratio and buyer-host coverage.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="${ROOT}/../scenario2/start_dist.sh"
OUT="${COPURCHASE_OUT:-${ROOT}/results/affinity}"
mkdir -p "$OUT"

export NEBULA_BIN="${NEBULA_BIN:-/tmp/nebula-380/build/bin}"
export APPEND_PUSHDOWN_FLAGS=true
export EXTRA_GRAPH_FLAGS="--enable_copurchase=true
--copurchase_affinity=true
--copurchase_edge=buy
--copurchase_tag=product
--copurchase_sales_prop=sales
--heartbeat_interval_secs=2
--local_multihop_prior_stale_ms=120000
"
export EXTRA_STORAGE_FLAGS="--storaged_accept_copurchase=true
--copurchase_mirror_in_edges=true
--heartbeat_interval_secs=2
--local_dst_ratio_sample_interval_secs=1
--local_dst_ratio_sample_tick_ms=1000
--local_dst_ratio_sample_edges_per_tick=8192
--local_dst_ratio_sample_budget_us=3000
--local_dst_ratio_sample_parts_per_tick=3
"

bash "$DIST" down || true
bash "$DIST" up 0
bash "$DIST" ping | tee "$OUT/ping-bridge.txt" || true

for placement in affinity random mixed; do
  python3 "${ROOT}/generate_affinity.py" \
    --placement "$placement" --seed 42 \
    --out "${OUT}/${placement}.npz"
done

# One load+measure per placement. The cluster is not wiped between placements;
# each placement uses its own space.
for placement in affinity random mixed; do
  python3 -u "${ROOT}/measure_affinity.py" \
    --graph "${OUT}/${placement}.npz" \
    --space "cp_${placement}" \
    --label "bridge-${placement}" \
    --out "${OUT}/bridge-${placement}.json" \
    | tee "${OUT}/bridge-${placement}.log"
done

bash "$DIST" usdelay 2.5
sudo -n ip netns exec ns-graph1 ping -n -c 20 -i 0.05 -W 2 -q 10.88.0.21 \
  | tee "$OUT/ping-rtt5.txt" || true
for placement in affinity random mixed; do
  python3 -u "${ROOT}/measure_affinity.py" \
    --graph "${OUT}/${placement}.npz" \
    --space "cp_${placement}" \
    --skip-load \
    --label "rtt5-${placement}" \
    --out "${OUT}/rtt5-${placement}.json" \
    | tee "${OUT}/rtt5-${placement}.log"
done

echo "AFFINITY_BENCH_DONE"
