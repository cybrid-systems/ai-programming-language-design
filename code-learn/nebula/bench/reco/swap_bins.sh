#!/usr/bin/env bash
# Swap the local /tmp/nb cluster onto binaries from one directory.
# Usage: swap_bins.sh <bin-dir> <graphd|all>
# graphd leaves metad and storaged on whatever is already running.
# all stops every daemon and starts metad, storaged, graphd from <bin-dir>.
# cwd is /tmp/nb so the flagfiles' relative pid, log, and data paths resolve.
set -u
ROOT=/tmp/nb
BIN=${1:?bin-dir}
MODE=${2:?graphd|all}
cd "$ROOT" || exit 1

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1; }

stop_one() {
  local name=$1
  local pidf="pids/nebula-$name.pid"
  if [ -f "$pidf" ]; then
    local pid
    pid=$(cat "$pidf")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
      done
      if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
        sleep 0.5
      fi
      echo "$name stopped ($pid)"
    else
      echo "$name pidfile stale"
    fi
    rm -f "$pidf"
  else
    echo "$name: no pidfile"
  fi
}

start_one() {
  local name=$1
  if [ ! -x "$BIN/nebula-$name" ]; then
    echo "missing $BIN/nebula-$name" >&2
    exit 1
  fi
  "$BIN/nebula-$name" --flagfile="conf/$name.conf" >/dev/null 2>&1 || true
  local port
  case "$name" in
    metad) port=9559 ;;
    storaged) port=9779 ;;
    graphd) port=9669 ;;
  esac
  for _ in $(seq 1 40); do
    if port_open "$port"; then
      echo "$name up on $port ($(cat "pids/nebula-$name.pid" 2>/dev/null || echo '?'))"
      return 0
    fi
    sleep 0.5
  done
  echo "$name failed to listen on $port" >&2
  tail -20 "logs/${name}-stderr.log" 2>/dev/null || true
  exit 1
}

case "$MODE" in
  graphd)
    stop_one graphd
    start_one graphd
    ;;
  all)
    stop_one graphd
    stop_one storaged
    stop_one metad
    start_one metad
    sleep 2
    start_one storaged
    sleep 2
    start_one graphd
    ;;
  *)
    echo "usage: swap_bins.sh <bin-dir> <graphd|all>" >&2
    exit 1
    ;;
esac
