#!/usr/bin/env bash
# One metad + one storaged + one graphd for the local multi-hop bench.
# Does not pass the scenario-2 pushdown flags; this tree is clean v3.8.0
# plus the local multi-hop patch.
set -euo pipefail

BIN="${NEBULA_BIN:-/tmp/nebula-380/build/bin}"
ROOT="${NEBULA_ROOT:-/tmp/nebula-cluster}"
SRC_CONF="${NEBULA_CONF:-/tmp/nebula-380/conf}"
TZ="${NEBULA_TZ:-/tmp/nebula-380/resources/date_time_zonespec.csv}"
ENABLE_LOCAL_MULTIHOP="${ENABLE_LOCAL_MULTIHOP:-false}"
LOCAL_MULTIHOP_AFFINITY="${LOCAL_MULTIHOP_AFFINITY:-0}"
STORAGED_ACCEPT="${STORAGED_ACCEPT_LOCAL_MULTIHOP:-true}"
GRAPH_WORKERS="${GRAPH_WORKERS:-4}"
ACTION="${1:-start}"
TMUX_CONF="/exec-daemon/tmux.portal.conf"

tmux_bin() {
  if [[ -f "$TMUX_CONF" ]]; then
    /exec-daemon/tmux -f "$TMUX_CONF" "$@"
  else
    tmux "$@"
  fi
}

write_conf() {
  mkdir -p "$ROOT"/{conf,logs,pids,data/meta,data/storage}
  python3 - "$ROOT" "$SRC_CONF" "$TZ" "$ENABLE_LOCAL_MULTIHOP" \
    "$LOCAL_MULTIHOP_AFFINITY" "$STORAGED_ACCEPT" "$GRAPH_WORKERS" <<'PY'
import sys
from pathlib import Path
root, src, tz, enable, affinity, accept, workers = sys.argv[1:]
src, dst = Path(src), Path(root) / "conf"
dst.mkdir(parents=True, exist_ok=True)

def rewrite(name, pairs):
    text = (src / name).read_text()
    for old, new in pairs:
        if old not in text:
            raise SystemExit(f"{name}: missing {old}")
        text = text.replace(old, new, 1)
    return text

common = [
    ("--daemonize=true", "--daemonize=false"),
    ("--redirect_stdout=true", "--redirect_stdout=false"),
    ("--log_dir=logs", f"--log_dir={root}/logs"),
]
meta = rewrite("nebula-metad.conf.default", common + [
    ("--pid_file=pids/nebula-metad.pid", f"--pid_file={root}/pids/nebula-metad.pid"),
    ("--data_path=data/meta", f"--data_path={root}/data/meta"),
])
meta += f"\n--timezone_file={tz}\n"
(dst / "nebula-metad.conf").write_text(meta)
stor = rewrite("nebula-storaged.conf.default", common + [
    ("--pid_file=pids/nebula-storaged.pid", f"--pid_file={root}/pids/nebula-storaged.pid"),
    ("--data_path=data/storage", f"--data_path={root}/data/storage"),
    ("--rocksdb_block_cache=4", "--rocksdb_block_cache=256"),
])
stor += f"\n--timezone_file={tz}\n--storaged_accept_local_multihop={accept}\n"
(dst / "nebula-storaged.conf").write_text(stor)
graph = rewrite("nebula-graphd.conf.default", common + [
    ("--pid_file=pids/nebula-graphd.pid", f"--pid_file={root}/pids/nebula-graphd.pid"),
])
graph += (
    f"\n--timezone_file={tz}\n"
    f"--enable_local_multihop={enable}\n"
    f"--local_multihop_affinity={affinity}\n"
    f"--num_worker_threads={workers}\n"
)
(dst / "nebula-graphd.conf").write_text(graph)
print(f"conf enable={enable} affinity={affinity} accept={accept} workers={workers}")
PY
}

stop_pid() {
  local pidfile="$1"
  if [[ -f "$pidfile" ]]; then
    local pid
    pid="$(cat "$pidfile" || true)"
    if [[ -n "${pid}" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" || true
      for _ in $(seq 1 30); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.3
      done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" || true
    fi
    rm -f "$pidfile"
  fi
}

launch() {
  local session="$1" bin="$2" conf="$3"
  tmux_bin kill-session -t "$session" 2>/dev/null || true
  tmux_bin new-session -d -s "$session" -c "$ROOT" -- bash -lc \
    "ulimit -n 65535; export LD_LIBRARY_PATH='/opt/vesoft/third-party/3.3/lib64:/opt/vesoft/third-party/3.3/lib'; exec '$bin' --flagfile='$conf'"
}

case "$ACTION" in
  start)
    write_conf
    stop_pid "$ROOT/pids/nebula-graphd.pid"
    stop_pid "$ROOT/pids/nebula-storaged.pid"
    stop_pid "$ROOT/pids/nebula-metad.pid"
    launch nebula-metad "$BIN/nebula-metad" "$ROOT/conf/nebula-metad.conf"
    sleep 2
    launch nebula-storaged "$BIN/nebula-storaged" "$ROOT/conf/nebula-storaged.conf"
    sleep 2
    launch nebula-graphd "$BIN/nebula-graphd" "$ROOT/conf/nebula-graphd.conf"
    ;;
  restart-graphd)
    write_conf
    stop_pid "$ROOT/pids/nebula-graphd.pid"
    launch nebula-graphd "$BIN/nebula-graphd" "$ROOT/conf/nebula-graphd.conf"
    ;;
  restart-storaged)
    write_conf
    stop_pid "$ROOT/pids/nebula-storaged.pid"
    launch nebula-storaged "$BIN/nebula-storaged" "$ROOT/conf/nebula-storaged.conf"
    ;;
  stop)
    stop_pid "$ROOT/pids/nebula-graphd.pid"
    stop_pid "$ROOT/pids/nebula-storaged.pid"
    stop_pid "$ROOT/pids/nebula-metad.pid"
    tmux_bin kill-session -t nebula-graphd 2>/dev/null || true
    tmux_bin kill-session -t nebula-storaged 2>/dev/null || true
    tmux_bin kill-session -t nebula-metad 2>/dev/null || true
    ;;
  *)
    echo "usage: $0 {start|restart-graphd|restart-storaged|stop}" >&2
    exit 2
    ;;
esac
echo "action=$ACTION root=$ROOT"
