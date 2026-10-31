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
export EXTRA_STORAGE_FLAGS=$'--storaged_accept_local_multihop=true\n--local_dst_ratio_sample_interval_secs=2\n--local_dst_ratio_sample_edges=64\n--local_dst_ratio_sample_incremental=true\n--local_dst_ratio_sample_tick_ms=100\n--local_dst_ratio_sample_budget_us=1500\n--local_dst_ratio_sample_edges_per_tick=2048\n--local_dst_ratio_sample_parts_per_tick=4\n--heartbeat_interval_secs=2\n'

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
    "--local_multihop_host_batch=",
    "--local_multihop_heartbeat_prior=",
    "--local_multihop_skip_confident_explore=",
    "--local_multihop_collapse_mixed=",
    "--local_multihop_prior_high=",
    "--local_multihop_prior_low=",
    "--local_multihop_prior_stale_ms=",
    "--local_multihop_prior_per_entry=",
    "--local_multihop_plain_baseline=",
    "--logbufsecs=",
    "--heartbeat_interval_secs=",
)
lines = [ln for ln in text if not ln.startswith(drop)]
if mode == "baseline":
    lines += [
        "--enable_local_multihop=false",
        "--local_multihop_affinity=0",
        "--enable_adaptive_local_multihop=false",
        "--heartbeat_interval_secs=2",
    ]
elif mode == "static":
    lines += [
        "--enable_local_multihop=true",
        "--local_multihop_affinity=1",
        "--enable_adaptive_local_multihop=false",
        "--heartbeat_interval_secs=2",
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
        "--local_multihop_host_batch=false",
        "--local_multihop_heartbeat_prior=false",
        "--local_multihop_skip_confident_explore=false",
        "--local_multihop_collapse_mixed=false",
        "--local_multihop_trace=false",
        "--heartbeat_interval_secs=2",
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
        "--local_multihop_host_batch=false",
        "--local_multihop_heartbeat_prior=false",
        "--local_multihop_skip_confident_explore=false",
        "--local_multihop_collapse_mixed=false",
        "--local_multihop_trace=false",
        "--heartbeat_interval_secs=2",
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
        "--local_multihop_host_batch=false",
        "--local_multihop_heartbeat_prior=false",
        "--local_multihop_skip_confident_explore=false",
        "--local_multihop_collapse_mixed=false",
        "--local_multihop_trace=true",
        "--logbufsecs=0",
        "--heartbeat_interval_secs=2",
    ]
elif mode == "adaptive-v3":
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
        "--local_multihop_host_batch=true",
        "--local_multihop_heartbeat_prior=true",
        "--local_multihop_skip_confident_explore=false",
        "--local_multihop_collapse_mixed=false",
        "--local_multihop_trace=false",
        "--heartbeat_interval_secs=2",
    ]
elif mode == "adaptive-v4":
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
        "--local_multihop_host_batch=true",
        "--local_multihop_heartbeat_prior=true",
        "--local_multihop_skip_confident_explore=true",
        "--local_multihop_collapse_mixed=true",
        "--local_multihop_prior_high=0.8",
        "--local_multihop_prior_low=0.4",
        "--local_multihop_prior_stale_ms=30000",
        "--local_multihop_prior_per_entry=false",
        "--local_multihop_plain_baseline=false",
        "--local_multihop_trace=false",
        "--heartbeat_interval_secs=2",
    ]
elif mode == "adaptive-v5":
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
        "--local_multihop_host_batch=true",
        "--local_multihop_heartbeat_prior=true",
        "--local_multihop_skip_confident_explore=true",
        "--local_multihop_collapse_mixed=true",
        "--local_multihop_prior_high=0.8",
        "--local_multihop_prior_low=0.4",
        "--local_multihop_prior_stale_ms=30000",
        "--local_multihop_prior_per_entry=true",
        "--local_multihop_plain_baseline=true",
        "--local_multihop_trace=false",
        "--heartbeat_interval_secs=2",
    ]
elif mode == "adaptive-v4-trace":
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
        "--local_multihop_host_batch=true",
        "--local_multihop_heartbeat_prior=true",
        "--local_multihop_skip_confident_explore=true",
        "--local_multihop_collapse_mixed=true",
        "--local_multihop_prior_high=0.8",
        "--local_multihop_prior_low=0.4",
        "--local_multihop_prior_stale_ms=30000",
        "--local_multihop_prior_per_entry=false",
        "--local_multihop_plain_baseline=false",
        "--local_multihop_trace=true",
        "--logbufsecs=0",
        "--heartbeat_interval_secs=2",
    ]
elif mode == "adaptive-v5-trace":
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
        "--local_multihop_host_batch=true",
        "--local_multihop_heartbeat_prior=true",
        "--local_multihop_skip_confident_explore=true",
        "--local_multihop_collapse_mixed=true",
        "--local_multihop_prior_high=0.8",
        "--local_multihop_prior_low=0.4",
        "--local_multihop_prior_stale_ms=30000",
        "--local_multihop_prior_per_entry=true",
        "--local_multihop_plain_baseline=true",
        "--local_multihop_trace=true",
        "--logbufsecs=0",
        "--heartbeat_interval_secs=2",
    ]
elif mode == "adaptive-v3-trace":
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
        "--local_multihop_host_batch=true",
        "--local_multihop_heartbeat_prior=true",
        "--local_multihop_skip_confident_explore=false",
        "--local_multihop_collapse_mixed=false",
        "--local_multihop_trace=true",
        "--logbufsecs=0",
        "--heartbeat_interval_secs=2",
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
        "--local_multihop_host_batch=false",
        "--local_multihop_heartbeat_prior=false",
        "--local_multihop_skip_confident_explore=false",
        "--local_multihop_collapse_mixed=false",
        "--local_multihop_trace=true",
        "--logbufsecs=0",
        "--heartbeat_interval_secs=2",
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
  # First heartbeat waits one interval (2s) plus up to 0.9s of jitter.
  # The profile query is the steady-state decision, so wait until that
  # reply can install the ratio cache.
  sleep 6
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
  for mode in baseline static adaptive-v4 adaptive-v5; do
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

restart_graph adaptive-v4-trace
python3 "$ROOT/drift.py" \
  --storage-hosts "$STORAGES" \
  --community-size "$SIZE" --degree "$DEGREE" \
  --affinity-queries 8 --random-queries 12 --return-queries 8 \
  --wait-before-return 8 \
  --space ad_drift_v4b \
  --tag drift_v4_bridge --results "$OUT"
restart_graph adaptive-v5-trace
python3 "$ROOT/drift.py" \
  --storage-hosts "$STORAGES" \
  --community-size "$SIZE" --degree "$DEGREE" \
  --affinity-queries 8 --random-queries 12 --return-queries 8 \
  --wait-before-return 8 \
  --space ad_drift_v5b \
  --tag drift_v5_bridge --results "$OUT"

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

restart_graph adaptive-v4-trace
python3 "$ROOT/drift.py" \
  --storage-hosts "$STORAGES" \
  --community-size "$SIZE" --degree "$DEGREE" \
  --affinity-queries 12 --random-queries 16 --return-queries 12 \
  --wait-before-return 8 \
  --space ad_drift_v4 \
  --tag drift_v4_rtt5 --results "$OUT"
restart_graph adaptive-v5-trace
python3 "$ROOT/drift.py" \
  --storage-hosts "$STORAGES" \
  --community-size "$SIZE" --degree "$DEGREE" \
  --affinity-queries 12 --random-queries 16 --return-queries 12 \
  --wait-before-return 8 \
  --space ad_drift_v5 \
  --tag drift_v5_rtt5 --results "$OUT"

# c=50 sampler on/off/full. CPU is storaged utime+stime over the measure.
set_storage_sampler() {
  local mode="$1"
  python3 - "$mode" <<'PY'
import pathlib, sys
mode = sys.argv[1]
drop = (
    "--local_dst_ratio_sample_interval_secs=",
    "--local_dst_ratio_sample_edges=",
    "--local_dst_ratio_sample_incremental=",
    "--local_dst_ratio_sample_tick_ms=",
    "--local_dst_ratio_sample_budget_us=",
    "--local_dst_ratio_sample_edges_per_tick=",
    "--local_dst_ratio_sample_parts_per_tick=",
    "--local_dst_ratio_sample_scan=",
    "--local_dst_ratio_sample_parts=",
)
if mode == "off":
    extra = ["--local_dst_ratio_sample_interval_secs=0"]
elif mode == "full":
    extra = [
        "--local_dst_ratio_sample_interval_secs=2",
        "--local_dst_ratio_sample_edges=64",
        "--local_dst_ratio_sample_incremental=false",
    ]
else:
    extra = [
        "--local_dst_ratio_sample_interval_secs=2",
        "--local_dst_ratio_sample_edges=64",
        "--local_dst_ratio_sample_incremental=true",
        "--local_dst_ratio_sample_tick_ms=100",
        "--local_dst_ratio_sample_budget_us=1500",
        "--local_dst_ratio_sample_edges_per_tick=2048",
        "--local_dst_ratio_sample_parts_per_tick=4",
    ]
for i in (1, 2, 3):
    path = pathlib.Path(f"/tmp/nebula-dist/stor{i}/nebula-storaged.conf")
    lines = [ln for ln in path.read_text().splitlines() if not ln.startswith(drop)]
    lines.extend(extra)
    path.write_text("\n".join(lines) + "\n")
print("storage sampler", mode)
PY
  bash "$DIST" restart-storage 1
  bash "$DIST" restart-storage 2
  bash "$DIST" restart-storage 3
  sleep 4
}

cpu_jiffies() {
  local pid="$1"
  awk '{print $14+$15}' "/proc/${pid}/stat"
}

impact_one() {
  local mode="$1" placement="$2"
  set_storage_sampler "$mode"
  local pid
  pid="$(cat /tmp/nebula-dist/stor1/pids/daemon.pid)"
  local before after
  before="$(cpu_jiffies "$pid")"
  local start
  start="$(date +%s.%N)"
  measure "impact_${mode}_${placement}" "$placement" "--skip-load" 50
  local end
  end="$(date +%s.%N)"
  after="$(cpu_jiffies "$pid")"
  python3 - "$mode" "$placement" "$before" "$after" "$start" "$end" "$(getconf CLK_TCK)" <<'PY'
import sys
mode, placement, before, after, start, end, hz_s = sys.argv[1:]
ticks = int(after) - int(before)
hz = int(hz_s)
wall = float(end) - float(start)
cores = (ticks / hz) / wall if wall > 0 else 0
print(f"SAMPLER_CPU mode={mode} placement={placement} stor1_jiffies={ticks} wall_s={wall:.3f} cores={cores:.4f}")
PY
}

restart_graph adaptive-v5
impact_one off affinity
impact_one off random
impact_one incremental affinity
impact_one incremental random
impact_one full affinity
impact_one full random

echo ADAPTIVE_BENCH_OK
