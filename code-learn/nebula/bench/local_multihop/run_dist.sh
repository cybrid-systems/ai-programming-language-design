#!/usr/bin/env bash
# 3 metad + 3 storaged + 1 graphd. APPEND_PUSHDOWN_FLAGS=false because this
# binary does not have the scenario-2 pushdown flags.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/../scenario2/start_dist.sh"
OUT="$ROOT/results"
mkdir -p "$OUT"
PARTS=9
SIZE=300
DEGREE=8
STORAGES="10.88.0.21:9779,10.88.0.22:9779,10.88.0.23:9779"

export APPEND_PUSHDOWN_FLAGS=false
export NEBULA_BIN="${NEBULA_BIN:-/tmp/nebula-380/build/bin}"
export NEBULA_CONF="${NEBULA_CONF:-/tmp/nebula-380/conf}"
export GRAPH_WORKERS=4
export EXTRA_STORAGE_FLAGS=$'--storaged_accept_local_multihop=true\n'

graph_flags() {
  local enable="$1" affinity="$2"
  export EXTRA_GRAPH_FLAGS
  EXTRA_GRAPH_FLAGS=$(printf -- '--enable_local_multihop=%s\n--local_multihop_affinity=%s\n' "$enable" "$affinity")
}

restart_graph() {
  local enable="$1" affinity="$2"
  graph_flags "$enable" "$affinity"
  # Rewrite only the graph conf, then bounce that process.
  python3 - "$enable" "$affinity" <<'PY'
import pathlib, sys
enable, affinity = sys.argv[1:]
path = pathlib.Path("/tmp/nebula-dist/graph1/nebula-graphd.conf")
text = path.read_text()
lines = [ln for ln in text.splitlines() if not ln.startswith("--enable_local_multihop=") and not ln.startswith("--local_multihop_affinity=")]
lines.append(f"--enable_local_multihop={enable}")
lines.append(f"--local_multihop_affinity={affinity}")
path.write_text("\n".join(lines) + "\n")
print("graph conf", enable, affinity)
PY
  local pid
  pid="$(cat /tmp/nebula-dist/graph1/pids/daemon.pid 2>/dev/null || true)"
  if [[ -n "$pid" ]]; then
    sudo -n kill "$pid" || true
    for _ in $(seq 1 30); do
      sudo -n kill -0 "$pid" 2>/dev/null || break
      sleep 0.2
    done
  fi
  local lib="/opt/vesoft/third-party/3.3/lib64:/opt/vesoft/third-party/3.3/lib"
  sudo -n ip netns exec ns-graph1 bash -c "ulimit -n 65535; export LD_LIBRARY_PATH='$lib'; setsid /tmp/nebula-380/build/bin/nebula-graphd --flagfile=/tmp/nebula-dist/graph1/nebula-graphd.conf >> /tmp/nebula-dist/graph1/logs/stdout.log 2>&1 < /dev/null & echo \$! > /tmp/nebula-dist/graph1/pids/daemon.pid"
  sleep 2
}

measure() {
  local tag="$1" affinity="$2" skip="$3"
  local conc="${4:-1,10,50,100,200}"
  python3 "$ROOT/measure.py" \
    --host 10.88.0.31 --port 9669 \
    --storage-hosts "$STORAGES" \
    --space "dist_${affinity}" --parts "$PARTS" --replica 1 \
    --community-size "$SIZE" --degree "$DEGREE" \
    --affinity "$affinity" \
    --concurrency "$conc" --rounds 5 \
    --tag "$tag" --results "$OUT" \
    $skip
}

graph_flags false 0
bash "$DIST" down || true
bash "$DIST" up 0
sleep 3
bash "$DIST" ping | tee "$OUT/ping_bridge.txt" || true

# pass 1 loads
for affinity in true false; do
  restart_graph false 0
  measure "dist_bridge_pass1_${affinity}_flagfalse" "$affinity" ""
  restart_graph true 1
  measure "dist_bridge_pass1_${affinity}_flagtrue" "$affinity" "--skip-load"
done
# pass 2 no load
for affinity in true false; do
  restart_graph false 0
  measure "dist_bridge_pass2_${affinity}_flagfalse" "$affinity" "--skip-load"
  restart_graph true 1
  measure "dist_bridge_pass2_${affinity}_flagtrue" "$affinity" "--skip-load"
done

bash "$DIST" usdelay 2.5
sleep 1
sudo -n ip netns exec ns-graph1 ping -n -c 10 -i 0.05 -W 1 -q 10.88.0.21 | tee "$OUT/ping_rtt5.txt" || true
for affinity in true false; do
  restart_graph false 0
  measure "dist_rtt5_${affinity}_flagfalse" "$affinity" "--skip-load"
  restart_graph true 1
  measure "dist_rtt5_${affinity}_flagtrue" "$affinity" "--skip-load"
done
echo DIST_OK
