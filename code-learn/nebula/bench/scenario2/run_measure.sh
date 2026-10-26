#!/usr/bin/env bash
# Load once, measure flag-off, restart graphd with the dst-only flag, measure flag-on.
# The same patched binary is both sides: flag off keeps the v3.8 GetNeighbors path.
set -euo pipefail
cd "$(dirname "$0")"

RESULTS="${RESULTS:-$(pwd)/results}"
USERS="${USERS:-4000}"
ITEMS="${ITEMS:-2000}"
EDGES="${EDGES:-500000}"
CONCURRENCY="${CONCURRENCY:-1,10,50,100,200}"
WARMUP="${WARMUP:-2}"
ROUNDS="${ROUNDS:-5}"
COMMON=(
  --users "$USERS" --items "$ITEMS" --edges "$EDGES"
  --results "$RESULTS" --concurrency "$CONCURRENCY"
  --warmup "$WARMUP" --rounds "$ROUNDS"
)

mkdir -p "$RESULTS"
{
  echo "g++: $(g++-12 --version | head -n 1)"
  echo "gcc: $(gcc-12 --version | head -n 1)"
  echo "nebula_git: $(git -C /tmp/nebula-380 rev-parse HEAD 2>/dev/null || true)"
  echo "nebula_describe: $(git -C /tmp/nebula-380 describe --tags --always 2>/dev/null || true)"
  echo "third_party: /opt/vesoft/third-party/3.3"
  uname -a
  nproc
} | tee "$RESULTS/build_env.txt"

if [[ "${SKIP_LOAD:-0}" != "1" ]]; then
  python3 measure.py load "${COMMON[@]}"
fi

python3 measure.py measure --tag flag_off --queries q_users,q_sales,q_model "${COMMON[@]}"

ENABLE_DST_ONLY=true ./start_cluster.sh restart-graphd
for _ in $(seq 1 60); do
  if (echo >/dev/tcp/127.0.0.1/9669) >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

python3 measure.py measure --tag flag_on --queries q_users,q_sales "${COMMON[@]}"
echo "measure done"
