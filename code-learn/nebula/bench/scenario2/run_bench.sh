#!/usr/bin/env bash
# Scenario 2 latency helper. Prints 未实测 and exits 2 when nebula-console is absent.
# Does not fabricate P50/P99. See code-learn/nebula/12-scenario2-bench.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$ROOT/out}"
CONSOLE="${NEBULA_CONSOLE:-}"
ADDR="${NEBULA_ADDR:-127.0.0.1:9669}"
USER_NAME="${NEBULA_USER:-root}"
PASSWORD="${NEBULA_PASSWORD:-nebula}"
ROUNDS="${ROUNDS:-20}"
WARMUP="${WARMUP:-3}"

mkdir -p "$OUT"
python3 "$ROOT/gen_data.py" --out "$OUT" "$@"

if [[ -z "$CONSOLE" || ! -x "$CONSOLE" ]]; then
  echo "未实测: nebula-console not found (set NEBULA_CONSOLE). nGQL is in $OUT"
  echo "No P50/P99. Single-node loopback would still not reproduce cross-host RPC cost."
  exit 2
fi

HOST="${ADDR%%:*}"
PORT="${ADDR##*:}"

run_file() {
  local file="$1"
  "$CONSOLE" -addr "$HOST" -port "$PORT" -u "$USER_NAME" -p "$PASSWORD" -f "$file"
}

if [[ "${NEBULA_SKIP_LOAD:-0}" != "1" ]]; then
  run_file "$OUT/schema_stock.ngql"
  echo "Wait for the space to be ready, then REBUILD TAG INDEX item_type_idx before timing."
  run_file "$OUT/data_stock.ngql"
fi

# Split queries into Q1 and Q4. Timing is single-threaded console latency, not 10-200 concurrency.
python3 - "$OUT" <<'PY'
import pathlib, sys
out = pathlib.Path(sys.argv[1])
text = (out / "queries.ngql").read_text()
parts = [p.strip() for p in text.split(";") if p.strip() and not p.strip().startswith("--")]
# USE + Q1, then Q4's three statements are already one script block in queries.ngql.
# Keep the file intact; the shell sends the whole file once for a smoke PROFILE.
(out / "q_all.ngql").write_text("PROFILE " + text.replace("USE beauty_buy;\n", "USE beauty_buy;\nPROFILE ", 1))
print("smoke query file", out / "queries.ngql")
PY

mkdir -p "$OUT/profile"
echo "Sequential smoke (not the concurrency sweep):"
run_file "$OUT/queries.ngql" | tee "$OUT/profile/smoke.txt"

python3 "$ROOT/concurrent.py" || {
  echo "并发未实测: nebula3 python client is not importable."
}

echo "Sequential rounds=$ROUNDS are not a substitute for concurrency ${CONCURRENCY:-10,50,100,200}."
echo "Fill code-learn/nebula/12-scenario2-bench.md only with numbers this script printed."
