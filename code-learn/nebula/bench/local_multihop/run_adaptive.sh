#!/usr/bin/env bash
# Baseline vs static multi-hop vs adaptive, on the 3-storaged namespace cluster.
# Static sends min_local_ratio 0 (guard off). Adaptive sends the guard threshold.
# APPEND_PUSHDOWN_FLAGS=false: this binary does not have the scenario-2 flags.
set -euo pipefail
export PYTHONUNBUFFERED=1
ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/../scenario2/start_dist.sh"
OUT="$ROOT/results"
mkdir -p "$OUT"
PARTS=9
SIZE=300
DEGREE=8
STORAGES="10.88.0.21:9779,10.88.0.22:9779,10.88.0.23:9779"
CONC_BRIDGE="${CONC_BRIDGE:-1,10,50}"
CONC_RTT="${CONC_RTT:-1,10,50}"
ROUNDS="${ROUNDS:-8}"
WARMUP="${WARMUP:-3}"

export APPEND_PUSHDOWN_FLAGS=false
export NEBULA_BIN="${NEBULA_BIN:-/tmp/nebula-380/build/bin}"
export NEBULA_CONF="${NEBULA_CONF:-/tmp/nebula-380/conf}"
export GRAPH_WORKERS=4
export EXTRA_STORAGE_FLAGS=$'--storaged_accept_local_multihop=true\n'

write_graph_flags() {
  local mode="$1"
  python3 - "$mode" <<'PY'
import pathlib, sys
mode = sys.argv[1]
path = pathlib.Path("/tmp/nebula-dist/graph1/nebula-graphd.conf")
text = path.read_text().splitlines()
drop = (
    "--enable_local_multihop=",
    "--local_multihop_affinity=",
    "--enable_adaptive_local_multihop=",
    "--local_multihop_min_local_ratio=",
    "--local_multihop_explore_rate=",
    "--local_multihop_ewma_alpha=",
    "--local_multihop_assumed_rtt_us=",
    "--local_multihop_trace=",
    "--local_multihop_per_part=",
    "--local_multihop_early_flip=",
    "--logbufsecs=",
)
lines = [ln for ln in text if not ln.startswith(drop)]
if mode == "baseline":
    lines += [
        "--enable_local_multihop=false",
        "--local_multihop_affinity=0",
        "--enable_adaptive_local_multihop=false",
    ]
elif mode == "static":
    lines += [
        "--enable_local_multihop=true",
        "--local_multihop_affinity=1",
        "--enable_adaptive_local_multihop=false",
    ]
elif mode == "adaptive-v1":
    lines += [
        "--enable_local_multihop=false",
        "--local_multihop_affinity=0",
        "--enable_adaptive_local_multihop=true",
        "--local_multihop_min_local_ratio=0.6",
        "--local_multihop_explore_rate=0.05",
        "--local_multihop_ewma_alpha=0.2",
        "--local_multihop_assumed_rtt_us=5000",
        "--local_multihop_per_part=false",
        "--local_multihop_early_flip=false",
        "--local_multihop_trace=false",
    ]
elif mode == "adaptive-v2":
    lines += [
        "--enable_local_multihop=false",
        "--local_multihop_affinity=0",
        "--enable_adaptive_local_multihop=true",
        "--local_multihop_min_local_ratio=0.6",
        "--local_multihop_explore_rate=0.05",
        "--local_multihop_ewma_alpha=0.2",
        "--local_multihop_assumed_rtt_us=5000",
        "--local_multihop_per_part=true",
        "--local_multihop_early_flip=true",
        "--local_multihop_trace=false",
    ]
elif mode == "adaptive-v1-trace":
    lines += [
        "--enable_local_multihop=false",
        "--local_multihop_affinity=0",
        "--enable_adaptive_local_multihop=true",
        "--local_multihop_min_local_ratio=0.6",
        "--local_multihop_explore_rate=0.05",
        "--local_multihop_ewma_alpha=0.2",
        "--local_multihop_assumed_rtt_us=5000",
        "--local_multihop_per_part=false",
        "--local_multihop_early_flip=false",
        "--local_multihop_trace=true",
        "--logbufsecs=0",
    ]
elif mode == "adaptive-v2-trace":
    lines += [
        "--enable_local_multihop=false",
        "--local_multihop_affinity=0",
        "--enable_adaptive_local_multihop=true",
        "--local_multihop_min_local_ratio=0.6",
        "--local_multihop_explore_rate=0.05",
        "--local_multihop_ewma_alpha=0.2",
        "--local_multihop_assumed_rtt_us=5000",
        "--local_multihop_per_part=true",
        "--local_multihop_early_flip=true",
        "--local_multihop_trace=true",
        "--logbufsecs=0",
    ]
else:
    raise SystemExit(mode)
path.write_text("\n".join(lines) + "\n")
print("graph mode", mode)
PY
}

restart_graph() {
  local mode="$1"
  write_graph_flags "$mode"
  local pid
  pid="$(cat /tmp/nebula-dist/graph1/pids/daemon.pid 2>/dev/null || true)"
  if [[ -n "$pid" ]]; then
    sudo -n kill "$pid" || true
    for _ in $(seq 1 40); do
      sudo -n kill -0 "$pid" 2>/dev/null || break
      sleep 0.2
    done
  fi
  local lib="/opt/vesoft/third-party/3.3/lib64:/opt/vesoft/third-party/3.3/lib"
  sudo -n ip netns exec ns-graph1 bash -c "ulimit -n 65535; export LD_LIBRARY_PATH='$lib'; setsid /tmp/nebula-380/build/bin/nebula-graphd --flagfile=/tmp/nebula-dist/graph1/nebula-graphd.conf >> /tmp/nebula-dist/graph1/logs/stdout.log 2>&1 < /dev/null & echo \$! > /tmp/nebula-dist/graph1/pids/daemon.pid"
  sleep 3
}

measure() {
  local tag="$1" placement="$2" skip="$3" conc="$4"
  local space="ad_${placement}"
  python3 "$ROOT/measure.py" \
    --host 10.88.0.31 --port 9669 \
    --storage-hosts "$STORAGES" \
    --space "$space" --parts "$PARTS" --replica 1 \
    --community-size "$SIZE" --degree "$DEGREE" \
    --placement "$placement" \
    --concurrency "$conc" --rounds "$ROUNDS" --warmup "$WARMUP" \
    --tag "$tag" --results "$OUT" \
    $skip
}

phase() {
  local rtt="$1" conc="$2" loaded="${3:-0}"
  local mode placement skip
  for mode in baseline static adaptive-v1 adaptive-v2; do
    restart_graph "$mode"
    for placement in affinity random mixed; do
      # Each placement is its own space. Skip only after that space was loaded
      # by an earlier mode in this run.
      skip=""
      if [[ "$loaded" == "1" ]]; then
        skip="--skip-load"
      fi
      measure "${rtt}_${placement}_${mode}" "$placement" "$skip" "$conc"
    done
    loaded=1
  done
}

export EXTRA_GRAPH_FLAGS=$'--enable_local_multihop=false\n--enable_adaptive_local_multihop=false\n'
bash "$DIST" down || true
bash "$DIST" up 0
sleep 4
bash "$DIST" status
bash "$DIST" ping | tee "$OUT/adaptive_ping_bridge.txt" || true

LOADED=0
if [[ "${ADAPTIVE_SKIP_LOAD:-0}" == "1" ]]; then
  LOADED=1
fi
phase bridge "$CONC_BRIDGE" "$LOADED"

restart_graph adaptive-v2-trace
python3 "$ROOT/drift.py" \
  --storage-hosts "$STORAGES" \
  --community-size "$SIZE" --degree "$DEGREE" \
  --affinity-queries 16 --random-queries 24 --return-queries 40 \
  --tag drift_v2_bridge --results "$OUT"

bash "$DIST" usdelay 2.5
sleep 2
# Host-side and peer offloads. ICMP can succeed while TCP times out if these stay on.
sudo -n python3 - <<'PY'
import sys
sys.path.insert(0, "/workspace/code-learn/nebula/bench/scenario2")
import l2_delay
for name in ["v-stor1", "v-stor2", "v-stor3", "v-graph1", "v-meta1", "v-meta2", "v-meta3", "vp-cpu", "v-cpu"]:
    try:
        l2_delay.disable_offload(name)
        print("offload", name)
    except Exception as exc:
        print("offload skip", name, exc)
PY
for ns in ns-stor1 ns-stor2 ns-stor3 ns-graph1; do
  sudo -n ip netns exec "$ns" python3 - <<PY
import sys
sys.path.insert(0, "/workspace/code-learn/nebula/bench/scenario2")
import l2_delay
l2_delay.disable_offload("vp-${ns#ns-}")
print("ns offload", "$ns")
PY
done
sudo -n ip netns exec ns-graph1 ping -n -c 20 -i 0.05 -W 2 -q 10.88.0.21 | tee "$OUT/adaptive_ping_rtt5.txt" || true

phase rtt5 "$CONC_RTT" 1

restart_graph adaptive-v1-trace
python3 "$ROOT/drift.py" \
  --storage-hosts "$STORAGES" \
  --community-size "$SIZE" --degree "$DEGREE" \
  --affinity-queries 12 --random-queries 20 --return-queries 0 \
  --space ad_drift_v1 \
  --tag drift_v1_rtt5 --results "$OUT"
restart_graph adaptive-v2-trace
python3 "$ROOT/drift.py" \
  --storage-hosts "$STORAGES" \
  --community-size "$SIZE" --degree "$DEGREE" \
  --affinity-queries 16 --random-queries 24 --return-queries 48 \
  --space ad_drift_v2 \
  --tag drift_v2_rtt5 --results "$OUT"

echo ADAPTIVE_BENCH_OK
