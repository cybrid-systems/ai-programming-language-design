#!/usr/bin/env bash
# Co-purchase bench on the 3-storaged namespace cluster.
# Sampler is off so its ticks are not in the latency. Data is loaded once.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="${ROOT}/../scenario2/start_dist.sh"
OUT="${COPURCHASE_OUT:-/tmp/copurchase-bench}"
mkdir -p "$OUT"

export APPEND_PUSHDOWN_FLAGS=true
export EXTRA_GRAPH_FLAGS="--enable_copurchase=true
--copurchase_edge=buy
--copurchase_tag=product
--copurchase_sales_prop=sales
"
export EXTRA_STORAGE_FLAGS="--storaged_accept_copurchase=true
--local_dst_ratio_sample_interval_secs=0
"

if [[ ! -f "${ROOT}/graph.npz" ]]; then
  python3 "${ROOT}/generate.py" --out "${ROOT}/graph.npz"
fi

bash "$DIST" down || true
bash "$DIST" up 0
bash "$DIST" ping | tee "$OUT/ping_bridge.txt" || true

python3 -u "${ROOT}/measure.py" --label bridge --out "$OUT/bridge.json" \
  --graph "${ROOT}/graph.npz" | tee "$OUT/bridge.log"

bash "$DIST" usdelay 2.5
sudo -n ip netns exec ns-graph1 ping -n -c 20 -i 0.05 -W 2 -q 10.88.0.21 | tee "$OUT/ping_rtt5.txt" || true
python3 -u "${ROOT}/measure.py" --label rtt5 --skip-load --skip-accuracy \
  --out "$OUT/rtt5.json" --graph "${ROOT}/graph.npz" | tee "$OUT/rtt5.log"

echo "BENCH_DONE"
