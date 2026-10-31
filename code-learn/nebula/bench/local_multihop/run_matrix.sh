#!/usr/bin/env bash
# Alternating single-node matrix: flag off/on x affinity/random.
# Each pass reuses loaded spaces. Passes are sequential so the noise is the
# spread across passes, not a made-up interval.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="${ROOT}/results"
mkdir -p "$OUT"
HOST="${NEBULA_HOST:-127.0.0.1}"
PORT="${NEBULA_PORT:-9669}"
PARTS="${PARTS:-9}"
SIZE="${COMMUNITY_SIZE:-300}"
DEGREE="${DEGREE:-8}"
CONC="${CONCURRENCY:-1,10,50,100,200}"
ROUNDS="${ROUNDS:-5}"
PASSES="${PASSES:-3}"

start_graph() {
  local enable="$1" affinity="$2"
  ENABLE_LOCAL_MULTIHOP="$enable" LOCAL_MULTIHOP_AFFINITY="$affinity" \
    STORAGED_ACCEPT_LOCAL_MULTIHOP=true \
    bash "$ROOT/start_single.sh" restart-graphd
  sleep 2
}

for pass in $(seq 1 "$PASSES"); do
  for affinity in true false; do
    space="lmh_${affinity}_p${PARTS}"
    for enable in false true; do
      aff_val=0
      [[ "$enable" == "true" ]] && aff_val=1
      start_graph "$enable" "$aff_val"
      tag="single_pass${pass}_${affinity}_flag${enable}"
      skip=()
      [[ "$pass" != "1" || "$enable" != "false" ]] && skip=(--skip-load)
      # Load once per space, on the first flag-off pass.
      if [[ "$pass" == "1" && "$enable" == "false" ]]; then
        skip=()
      else
        skip=(--skip-load)
      fi
      python3 "$ROOT/measure.py" \
        --host "$HOST" --port "$PORT" \
        --space "$space" --parts "$PARTS" \
        --community-size "$SIZE" --degree "$DEGREE" \
        --affinity "$affinity" \
        --concurrency "$CONC" --rounds "$ROUNDS" \
        --tag "$tag" --results "$OUT" \
        "${skip[@]}"
    done
  done
done
echo MATRIX_OK
