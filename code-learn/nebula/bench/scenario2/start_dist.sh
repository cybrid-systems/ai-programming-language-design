#!/usr/bin/env bash
# Multi-process NebulaGraph on one VM, isolated with network namespaces.
# This is not a multi-machine cluster: CPU, disk, and page cache are shared.
# Cross-host delay is tc netem on each namespace veth. Ping between namespaces
# is the RTT to report; a delay of D on every veth egress is about 2D.
set -euo pipefail

BIN="${NEBULA_BIN:-/tmp/nebula-380/build/bin}"
ROOT="${NEBULA_DIST_ROOT:-/tmp/nebula-dist}"
SRC_CONF="${NEBULA_CONF:-/tmp/nebula-380/conf}"
TZ="${NEBULA_TZ:-/tmp/nebula-380/resources/date_time_zonespec.csv}"
META_N="${META_N:-3}"
STORAGE_N="${STORAGE_N:-3}"
GRAPH_N="${GRAPH_N:-1}"
ENABLE_DST_ONLY="${ENABLE_DST_ONLY:-true}"
ENABLE_PARTIAL_EDGE_AGG="${ENABLE_PARTIAL_EDGE_AGG:-true}"
GRAPH_WORKERS="${GRAPH_WORKERS:-4}"
STORAGE_WORKERS="${STORAGE_WORKERS:-4}"
BLOCK_CACHE_MB="${BLOCK_CACHE_MB:-64}"
ACTION="${1:-up}"
DELAY="${2:-${NETEM_DELAY:-0}}"

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo -n)
fi

ip() { "${SUDO[@]}" /usr/sbin/ip "$@"; }
tc() { "${SUDO[@]}" /usr/sbin/tc "$@"; }

meta_ip() { printf '10.88.0.%s' "$((10 + $1))"; }     # 1 -> .11
stor_ip() { printf '10.88.0.%s' "$((20 + $1))"; }     # 1 -> .21
graph_ip() { printf '10.88.0.%s' "$((30 + $1))"; }    # 1 -> .31

meta_addrs() {
  local i acc=""
  for i in $(seq 1 "$META_N"); do
    [[ -n "$acc" ]] && acc+=","
    acc+="$(meta_ip "$i"):9559"
  done
  printf '%s' "$acc"
}

ns_exists() { ip netns list | awk '{print $1}' | grep -qx "$1"; }

write_conf() {
  local role="$1" ipaddr="$2" dir="$3"
  mkdir -p "$dir"/{logs,pids,data}
  python3 - "$SRC_CONF" "$dir" "$role" "$ipaddr" "$(meta_addrs)" \
    "$ENABLE_DST_ONLY" "$ENABLE_PARTIAL_EDGE_AGG" "$GRAPH_WORKERS" \
    "$STORAGE_WORKERS" "$BLOCK_CACHE_MB" "$TZ" <<'PY'
import sys
from pathlib import Path
src, dst, role, ipaddr, metas, dst_only, partial, gworkers, sworkers, cache, tz = sys.argv[1:]
src, dst = Path(src), Path(dst)
name = {"meta": "nebula-metad", "storage": "nebula-storaged", "graph": "nebula-graphd"}[role]
text = (src / f"{name}.conf.default").read_text()
repls = [
    ("--daemonize=true", "--daemonize=false"),
    ("--redirect_stdout=true", "--redirect_stdout=false"),
    ("--pid_file=pids/nebula-metad.pid", f"--pid_file={dst}/pids/nebula-metad.pid"),
    ("--pid_file=pids/nebula-storaged.pid", f"--pid_file={dst}/pids/nebula-storaged.pid"),
    ("--pid_file=pids/nebula-graphd.pid", f"--pid_file={dst}/pids/nebula-graphd.pid"),
    ("--log_dir=logs", f"--log_dir={dst}/logs"),
    ("--data_path=data/meta", f"--data_path={dst}/data"),
    ("--data_path=data/storage", f"--data_path={dst}/data"),
    ("--meta_server_addrs=127.0.0.1:9559", f"--meta_server_addrs={metas}"),
    ("--local_ip=127.0.0.1", f"--local_ip={ipaddr}"),
    ("--rocksdb_block_cache=4", f"--rocksdb_block_cache={cache}"),
]
for old, new in repls:
    if old in text:
        text = text.replace(old, new, 1)
text += f"\n--timezone_file={tz}\n"
text += f"--rocksdb_block_cache={cache}\n"
if role == "storage":
    text += f"--num_worker_threads={sworkers}\n"
if role == "graph":
    text += f"--enable_dst_only_edge_filter={dst_only}\n"
    text += f"--enable_partial_edge_agg={partial}\n"
    text += f"--num_worker_threads={gworkers}\n"
(dst / f"{name}.conf").write_text(text)
print(f"conf {role} {ipaddr} -> {dst}")
PY
}

ensure_link() {
  local ns="$1" ipaddr="$2" hostif="$3" nsif="$4"
  ip netns add "$ns" 2>/dev/null || true
  ip link del "$hostif" 2>/dev/null || true
  ip link add "$hostif" type veth peer name "$nsif"
  ip link set "$nsif" netns "$ns"
  ip link set "$hostif" master br-nebula
  ip link set "$hostif" up
  ip netns exec "$ns" /usr/sbin/ip link set lo up
  ip netns exec "$ns" /usr/sbin/ip link set "$nsif" up
  ip netns exec "$ns" /usr/sbin/ip addr flush dev "$nsif"
  ip netns exec "$ns" /usr/sbin/ip addr add "${ipaddr}/24" dev "$nsif"
  ip netns exec "$ns" /usr/sbin/ip route replace default via 10.88.0.1
  # Shared-subnet bridge. Loose rp_filter avoids dropping replies that the
  # bridge delivers on a different veth than the route lookup expected.
  ip netns exec "$ns" /usr/sbin/sysctl -qw "net.ipv4.conf.${nsif}.rp_filter=0"
  ip netns exec "$ns" /usr/sbin/sysctl -qw net.ipv4.conf.all.rp_filter=0
}

sysctl_w() {
  if [[ "$(id -u)" -eq 0 ]]; then
    sysctl -qw "$@"
  else
    sudo -n sysctl -qw "$@"
  fi
}

setup_net() {
  sysctl_w net.ipv4.ip_forward=1 || true
  sysctl_w net.ipv4.conf.all.rp_filter=0 || true
  # br_netfilter sends bridge-forwarded frames through iptables. On this VM
  # that drops namespace-to-namespace traffic while host-to-namespace still
  # works. Turn the hooks off so storaged can reach metad across the bridge.
  sysctl_w net.bridge.bridge-nf-call-iptables=0 || true
  sysctl_w net.bridge.bridge-nf-call-ip6tables=0 || true
  sysctl_w net.bridge.bridge-nf-call-arptables=0 || true
  ip link add br-nebula type bridge 2>/dev/null || true
  ip addr replace 10.88.0.1/24 dev br-nebula
  ip link set br-nebula up
  local i
  for i in $(seq 1 "$META_N"); do
    ensure_link "ns-meta$i" "$(meta_ip "$i")" "v-meta$i" "vp-meta$i"
  done
  for i in $(seq 1 "$STORAGE_N"); do
    ensure_link "ns-stor$i" "$(stor_ip "$i")" "v-stor$i" "vp-stor$i"
  done
  for i in $(seq 1 "$GRAPH_N"); do
    ensure_link "ns-graph$i" "$(graph_ip "$i")" "v-graph$i" "vp-graph$i"
  done
}

apply_netem() {
  local delay="$1"
  local ns ifc
  for ns in $(ip netns list | awk '{print $1}' | grep -E '^ns-(meta|stor|graph)'); do
    ifc=$(ip netns exec "$ns" /usr/sbin/ip -o link show | awk -F': ' '/vp-/{print $2; exit}' | cut -d@ -f1)
    [[ -z "$ifc" ]] && continue
    ip netns exec "$ns" /usr/sbin/tc qdisc del dev "$ifc" root 2>/dev/null || true
    if [[ "$delay" != "0" && "$delay" != "0us" && "$delay" != "0ms" ]]; then
      ip netns exec "$ns" /usr/sbin/tc qdisc add dev "$ifc" root netem delay "$delay"
    fi
  done
  echo "netem_delay=$delay (egress on every vp-*; ping RTT is about 2x)"
}

start_one() {
  local ns="$1" dir="$2" bin="$3" conf="$4"
  local lib="/opt/vesoft/third-party/3.3/lib64:/opt/vesoft/third-party/3.3/lib"
  ip netns exec "$ns" bash -c "ulimit -n 65535; export LD_LIBRARY_PATH='$lib'; setsid '$bin' --flagfile='$conf' >> '$dir/logs/stdout.log' 2>&1 < /dev/null & echo \$! > '$dir/pids/daemon.pid'"
}

stop_one() {
  local dir="$1"
  local pidfile="$dir/pids/daemon.pid"
  if [[ -f "$pidfile" ]]; then
    local pid
    pid="$(cat "$pidfile" || true)"
    if [[ -n "${pid}" ]] && "${SUDO[@]}" kill -0 "$pid" 2>/dev/null; then
      "${SUDO[@]}" kill "$pid" || true
      for _ in $(seq 1 40); do
        "${SUDO[@]}" kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
      done
      "${SUDO[@]}" kill -0 "$pid" 2>/dev/null && "${SUDO[@]}" kill -9 "$pid" || true
    fi
    rm -f "$pidfile"
  fi
}

up() {
  [[ -x "$BIN/nebula-graphd" && -x "$BIN/nebula-storaged" && -x "$BIN/nebula-metad" ]] || {
    echo "missing binaries under $BIN" >&2
    exit 1
  }
  mkdir -p "$ROOT"
  setup_net
  local i dir
  for i in $(seq 1 "$META_N"); do
    dir="$ROOT/meta$i"
    write_conf meta "$(meta_ip "$i")" "$dir"
    stop_one "$dir"
    start_one "ns-meta$i" "$dir" "$BIN/nebula-metad" "$dir/nebula-metad.conf"
  done
  sleep 3
  for i in $(seq 1 "$STORAGE_N"); do
    dir="$ROOT/stor$i"
    write_conf storage "$(stor_ip "$i")" "$dir"
    stop_one "$dir"
    start_one "ns-stor$i" "$dir" "$BIN/nebula-storaged" "$dir/nebula-storaged.conf"
  done
  sleep 2
  for i in $(seq 1 "$GRAPH_N"); do
    dir="$ROOT/graph$i"
    write_conf graph "$(graph_ip "$i")" "$dir"
    stop_one "$dir"
    start_one "ns-graph$i" "$dir" "$BIN/nebula-graphd" "$dir/nebula-graphd.conf"
  done
  apply_netem "$DELAY"
  echo "graphd $(graph_ip 1):9669 metas=$(meta_addrs) storages=$STORAGE_N"
}

down_procs() {
  local i
  for i in $(seq 1 "$GRAPH_N"); do stop_one "$ROOT/graph$i"; done
  for i in $(seq 1 "$STORAGE_N"); do stop_one "$ROOT/stor$i"; done
  for i in $(seq 1 "$META_N"); do stop_one "$ROOT/meta$i"; done
}

down_net() {
  local i
  for i in $(seq 1 "$GRAPH_N"); do ip netns del "ns-graph$i" 2>/dev/null || true; ip link del "v-graph$i" 2>/dev/null || true; done
  for i in $(seq 1 "$STORAGE_N"); do ip netns del "ns-stor$i" 2>/dev/null || true; ip link del "v-stor$i" 2>/dev/null || true; done
  for i in $(seq 1 "$META_N"); do ip netns del "ns-meta$i" 2>/dev/null || true; ip link del "v-meta$i" 2>/dev/null || true; done
  ip link del br-nebula 2>/dev/null || true
}

ping_pair() {
  local src="$1" dst="$2"
  ip netns exec "$src" /usr/bin/ping -n -c 20 -i 0.05 -W 1 -q "$dst" || true
}

# This kernel is built with CONFIG_NET_SCH_NETEM unset, so `netem` fails with
# "Specified qdisc kind is unknown". usdelay is the substitute used for the
# numbers in 17-distributed-bench.md: a userspace L2 forwarder. One-way delay
# is applied only between namespace veths. The host-to-graphd path is not
# delayed. Ping from ns-graph1 to a storaged is the RTT to report.
# Measured RTT is about 2 * delay, plus the forwarder's own floor (sub-ms).
usdelay() {
  local ms="${1:-0}"
  local here
  here="$(cd "$(dirname "$0")" && pwd)"
  sysctl_w net.bridge.bridge-nf-call-iptables=0 || true
  sysctl_w net.bridge.bridge-nf-call-ip6tables=0 || true
  sysctl_w net.bridge.bridge-nf-call-arptables=0 || true
  ip link add v-cpu type veth peer name vp-cpu 2>/dev/null || true
  ip link set v-cpu master br-nebula
  ip link set v-cpu up
  ip link set vp-cpu up
  local i
  for i in $(seq 1 "$META_N"); do
    ip link set "v-meta$i" nomaster || true
    ip link set "v-meta$i" up
    ip netns exec "ns-meta$i" python3 -c "import sys; sys.path.insert(0, '$here'); import l2_delay; l2_delay.disable_offload('vp-meta$i')"
  done
  for i in $(seq 1 "$STORAGE_N"); do
    ip link set "v-stor$i" nomaster || true
    ip link set "v-stor$i" up
    ip netns exec "ns-stor$i" python3 -c "import sys; sys.path.insert(0, '$here'); import l2_delay; l2_delay.disable_offload('vp-stor$i')"
  done
  for i in $(seq 1 "$GRAPH_N"); do
    ip link set "v-graph$i" nomaster || true
    ip link set "v-graph$i" up
    ip netns exec "ns-graph$i" python3 -c "import sys; sys.path.insert(0, '$here'); import l2_delay; l2_delay.disable_offload('vp-graph$i')"
  done
  local ports=""
  for i in $(seq 1 "$META_N"); do ports+="v-meta$i,"; done
  for i in $(seq 1 "$STORAGE_N"); do ports+="v-stor$i,"; done
  for i in $(seq 1 "$GRAPH_N"); do ports+="v-graph$i,"; done
  ports="${ports%,}"
  if [[ -f /exec-daemon/tmux.portal.conf ]]; then
    tmux -f /exec-daemon/tmux.portal.conf kill-session -t l2-delay 2>/dev/null || true
    "${SUDO[@]}" pkill -f 'l2_delay.py' 2>/dev/null || true
    sleep 0.2
    tmux -f /exec-daemon/tmux.portal.conf new-session -d -s l2-delay -- \
      sudo -n python3 "$here/l2_delay.py" --delay-ms "$ms" --uplink vp-cpu --ports "$ports"
  else
    "${SUDO[@]}" pkill -f 'l2_delay.py' 2>/dev/null || true
    sleep 0.2
    sudo -n python3 "$here/l2_delay.py" --delay-ms "$ms" --uplink vp-cpu --ports "$ports" >/tmp/l2-delay.log 2>&1 &
    echo $! >/tmp/l2-delay.pid
  fi
  echo "usdelay_ms=$ms (namespace-to-namespace one way; ping RTT is about 2x plus forwarder floor)"
}

case "$ACTION" in
  up) up ;;
  down)
    down_procs
    down_net
    ;;
  stop) down_procs ;;
  netem) apply_netem "$DELAY" ;;
  usdelay) usdelay "$DELAY" ;;
  ping)
    echo "graph -> stor1"
    ping_pair ns-graph1 "$(stor_ip 1)"
    echo "stor1 -> stor2"
    if [[ "$STORAGE_N" -ge 2 ]]; then
      ping_pair ns-stor1 "$(stor_ip 2)"
    fi
    echo "graph -> meta1"
    ping_pair ns-graph1 "$(meta_ip 1)"
    ;;
  restart-storage)
    idx="${2:-1}"
    stop_one "$ROOT/stor$idx"
    start_one "ns-stor$idx" "$ROOT/stor$idx" "$BIN/nebula-storaged" "$ROOT/stor$idx/nebula-storaged.conf"
    ;;
  kill-storage)
    idx="${2:-1}"
    pid="$(cat "$ROOT/stor$idx/pids/daemon.pid")"
    "${SUDO[@]}" kill -9 "$pid" || true
    echo "killed stor$idx pid=$pid"
    ;;
  status)
    ip netns list
    for i in $(seq 1 "$META_N") $(seq 1 "$STORAGE_N") $(seq 1 "$GRAPH_N"); do :; done
    for dir in "$ROOT"/meta* "$ROOT"/stor* "$ROOT"/graph*; do
      [[ -d "$dir" ]] || continue
      pid="$(cat "$dir/pids/daemon.pid" 2>/dev/null || true)"
      if [[ -n "$pid" ]] && "${SUDO[@]}" kill -0 "$pid" 2>/dev/null; then
        echo "up $dir pid=$pid"
      else
        echo "down $dir pid=${pid:-none}"
      fi
    done
    ;;
  *)
    echo "usage: $0 {up|down|stop|netem <delay>|usdelay <ms>|ping|restart-storage N|kill-storage N|status}" >&2
    exit 2
    ;;
esac
