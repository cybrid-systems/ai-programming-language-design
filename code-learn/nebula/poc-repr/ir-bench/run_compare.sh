#!/usr/bin/env bash
# Alternate baseline and P0 on the same data directory.
# Does not touch code-learn/nebula/bench/ or patches/.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${NEBULA_ROOT:-/tmp/nebula-cluster}"
OUT="${HERE}/results"
BASE_BIN="${BASE_BIN:-/tmp/nebula-bins/base}"
P0_BIN="${P0_BIN:-/tmp/nebula-bins/p0}"
export NEBULA_ROOT="$ROOT"
export LD_LIBRARY_PATH="/opt/vesoft/third-party/3.3/lib64:/opt/vesoft/third-party/3.3/lib:${LD_LIBRARY_PATH:-}"
mkdir -p "$OUT"

start() {
  local bin="$1"
  NEBULA_BIN="$bin" NEBULA_ROOT="$ROOT" "$HERE/start_cluster.sh" stop || true
  NEBULA_BIN="$bin" NEBULA_ROOT="$ROOT" "$HERE/start_cluster.sh" start
  python3 "$HERE/measure.py" ping --results "$OUT"
}

run_measure() {
  local tag="$1"
  python3 "$HERE/measure.py" measure \
    --tag "$tag" \
    --results "$OUT" \
    --seed 2 \
    --queries q_users,q_sales,q_model \
    --concurrency 1,10,50,100,200 \
    --warmup 2 \
    --rounds 5
  local rc=$?
  echo "measure $tag exit=$rc"
  return 0
}

echo "load with baseline"
start "$BASE_BIN"
python3 "$HERE/measure.py" load --results "$OUT" --seed 2

# Three pairs. The first binary of each pair alternates, so each build
# is measured three times and is equally often the cold start.
pairs=(
  "base p0"
  "p0 base"
  "base p0"
)
round=0
for pair in "${pairs[@]}"; do
  round=$((round + 1))
  for variant in $pair; do
    if [[ "$variant" == "base" ]]; then
      bin="$BASE_BIN"
    else
      bin="$P0_BIN"
    fi
    tag="r${round}-${variant}"
    echo "==== $tag $(date -u +%Y-%m-%dT%H:%M:%SZ) ===="
    start "$bin"
    run_measure "$tag"
  done
done

echo "done $(date -u +%Y-%m-%dT%H:%M:%SZ)"
