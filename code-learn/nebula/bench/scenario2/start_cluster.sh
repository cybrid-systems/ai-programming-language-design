#!/usr/bin/env bash
# Start one metad, one storaged, and one graphd from a v3.8.0 build tree.
# Daemons run in tmux (daemonize=false) so a dropped shell does not kill them.
set -euo pipefail

BIN="${NEBULA_BIN:-/tmp/nebula-380/build/bin}"
ROOT="${NEBULA_ROOT:-/tmp/nebula-cluster}"
SRC_CONF="${NEBULA_CONF:-/tmp/nebula-380/conf}"
ENABLE_DST_ONLY="${ENABLE_DST_ONLY:-false}"
ENABLE_PARTIAL_EDGE_AGG="${ENABLE_PARTIAL_EDGE_AGG:-false}"
GRAPH_WORKERS="${GRAPH_WORKERS:-}"
TMUX_CONF="/exec-daemon/tmux.portal.conf"
ACTION="${1:-start}"

if [[ ! -x "$BIN/nebula-graphd" ]]; then
  echo "missing $BIN/nebula-graphd" >&2
  exit 1
fi

mkdir -p "$ROOT"/{conf,logs,pids,data/meta,data/storage}

python3 - "$ROOT" "$SRC_CONF" "$ENABLE_DST_ONLY" "$GRAPH_WORKERS" "$ENABLE_PARTIAL_EDGE_AGG" <<'PY'
import sys
from pathlib import Path

root, src, flag, workers, partial = sys.argv[1:]
src = Path(src)
dst = Path(root) / "conf"

def rewrite(name, mapping):
    text = (src / name).read_text()
    for old, new in mapping:
        if old not in text:
            raise SystemExit(f"{name}: missing line {old}")
        text = text.replace(old, new, 1)
    (dst / name).write_text(text)

rewrite("nebula-metad.conf.default", [
    ("--daemonize=true", "--daemonize=false"),
    ("--pid_file=pids/nebula-metad.pid", f"--pid_file={root}/pids/nebula-metad.pid"),
    ("--log_dir=logs", f"--log_dir={root}/logs"),
    ("--data_path=data/meta", f"--data_path={root}/data/meta"),
    ("--redirect_stdout=true", "--redirect_stdout=false"),
])
# The installed name drops the .default suffix.
(dst / "nebula-metad.conf").write_text((dst / "nebula-metad.conf.default").read_text())

rewrite("nebula-storaged.conf.default", [
    ("--daemonize=true", "--daemonize=false"),
    ("--pid_file=pids/nebula-storaged.pid", f"--pid_file={root}/pids/nebula-storaged.pid"),
    ("--log_dir=logs", f"--log_dir={root}/logs"),
    ("--data_path=data/storage", f"--data_path={root}/data/storage"),
    ("--redirect_stdout=true", "--redirect_stdout=false"),
    ("--rocksdb_block_cache=4", "--rocksdb_block_cache=256"),
])
(dst / "nebula-storaged.conf").write_text((dst / "nebula-storaged.conf.default").read_text())

rewrite("nebula-graphd.conf.default", [
    ("--daemonize=true", "--daemonize=false"),
    ("--pid_file=pids/nebula-graphd.pid", f"--pid_file={root}/pids/nebula-graphd.pid"),
    ("--log_dir=logs", f"--log_dir={root}/logs"),
    ("--redirect_stdout=true", "--redirect_stdout=false"),
])
text = (dst / "nebula-graphd.conf.default").read_text()
text += f"\n--enable_dst_only_edge_filter={flag}\n"
text += f"--enable_partial_edge_agg={partial}\n"
if workers:
    # Command-line gflags use the last assignment. Appending overrides the
    # default in nebula-graphd.conf.default (--num_worker_threads=0 means
    # hardware concurrency) when a positive value is requested.
    text += f"--num_worker_threads={workers}\n"
(dst / "nebula-graphd.conf").write_text(text)
# The binary default looks for the install layout share/resources/. Point every
# daemon at the csv shipped in the source tree.
tz = "/tmp/nebula-380/resources/date_time_zonespec.csv"
for name in ("nebula-metad.conf", "nebula-storaged.conf", "nebula-graphd.conf"):
    path = dst / name
    path.write_text(path.read_text() + f"\n--timezone_file={tz}\n")
print(
    f"wrote conf under {dst} enable_dst_only_edge_filter={flag} "
    f"enable_partial_edge_agg={partial} graph_workers={workers or 'default'}"
)
PY

export LD_LIBRARY_PATH="/opt/vesoft/third-party/3.3/lib64:/opt/vesoft/third-party/3.3/lib:${LD_LIBRARY_PATH:-}"

tmux_bin() {
  if [[ -f "$TMUX_CONF" ]]; then
    tmux -f "$TMUX_CONF" "$@"
  else
    tmux "$@"
  fi
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
        sleep 0.5
      done
      if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" || true
      fi
    fi
    rm -f "$pidfile"
  fi
}

launch() {
  local session="$1"
  local bin="$2"
  local conf="$3"
  tmux_bin has-session -t "=$session" 2>/dev/null && tmux_bin kill-session -t "$session" || true
  tmux_bin new-session -d -s "$session" -c "$ROOT" -- bash -lc \
    "ulimit -n 65535; export LD_LIBRARY_PATH='$LD_LIBRARY_PATH'; exec '$bin' --flagfile='$conf'"
}

case "$ACTION" in
  start)
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
    stop_pid "$ROOT/pids/nebula-graphd.pid"
    launch nebula-graphd "$BIN/nebula-graphd" "$ROOT/conf/nebula-graphd.conf"
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
    echo "usage: $0 {start|restart-graphd|stop}" >&2
    exit 2
    ;;
esac

echo "action=$ACTION enable_dst_only_edge_filter=$ENABLE_DST_ONLY enable_partial_edge_agg=$ENABLE_PARTIAL_EDGE_AGG graph_workers=${GRAPH_WORKERS:-default} root=$ROOT"
