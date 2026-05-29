#!/bin/bash
# bench.sh — Quick B-Tree optimization baseline benchmark
# Usage: bash bench.sh [rows]

set -euo pipefail

ROWS=${1:-10000}
MYSQL="./runtime_output_directory/mysql -u root -S /tmp/mysql_opt.sock"
BENCH_DIR="/tmp/btree_bench_$(date +%Y%m%d_%H%M)"
mkdir -p "$BENCH_DIR"

cd ~/code/mysql/build

bench_int() {
  local mode=$1 rows=$2 label=$3

  echo "  Insert ${rows} seq PK..."
  $MYSQL btree_bench -e "DROP TABLE IF EXISTS bench_int;
    CREATE TABLE bench_int (id INT AUTO_INCREMENT PRIMARY KEY, val BIGINT) ENGINE=InnoDB;"

  local t0=$($MYSQL -N -e "SELECT MICROSECOND(NOW(6)) + UNIX_TIMESTAMP(NOW(6))*1000000")
  for i in $(seq 1 $rows); do
    $MYSQL btree_bench -e "INSERT INTO bench_int(val) VALUES($i)"
  done
  local t1=$($MYSQL -N -e "SELECT MICROSECOND(NOW(6)) + UNIX_TIMESTAMP(NOW(6))*1000000")
  local dt=$((t1 - t0))
  echo "    ${dt}μs ($((rows * 1000000 / dt)) rows/sec)" >> "$BENCH_DIR/${label}.txt"

  echo "  Point queries..."
  local t0=$($MYSQL -N -e "SELECT MICROSECOND(NOW(6)) + UNIX_TIMESTAMP(NOW(6))*1000000")
  for i in $(seq 1 500); do
    $MYSQL btree_bench -N -e "SELECT id FROM bench_int WHERE id=$((RANDOM % rows + 1))" > /dev/null
  done
  local t1=$($MYSQL -N -e "SELECT MICROSECOND(NOW(6)) + UNIX_TIMESTAMP(NOW(6))*1000000")
  local dt=$((t1 - t0))
  echo "    Point 500x: ${dt}μs ($((500 * 1000000 / dt)) qps)" >> "$BENCH_DIR/${label}.txt"
}

bench_uuid() {
  local mode=$1 n=$2 label=$3

  echo "  Insert ${n} UUIDs..."
  $MYSQL btree_bench -e "DROP TABLE IF EXISTS bench_uuid;
    CREATE TABLE bench_uuid (
      id INT AUTO_INCREMENT PRIMARY KEY,
      uuid_col VARCHAR(36) NOT NULL,
      INDEX idx_uuid(uuid_col)
    ) ENGINE=InnoDB;"

  local t0=$($MYSQL -N -e "SELECT MICROSECOND(NOW(6)) + UNIX_TIMESTAMP(NOW(6))*1000000")
  for i in $(seq 1 $n); do
    local u=$(uuidgen)
    $MYSQL btree_bench -e "INSERT INTO bench_uuid(uuid_col) VALUES('$u')"
  done
  local t1=$($MYSQL -N -e "SELECT MICROSECOND(NOW(6)) + UNIX_TIMESTAMP(NOW(6))*1000000")
  local dt=$((t1 - t0))
  echo "    ${dt}μs ($((n * 1000000 / dt)) rows/sec)" >> "$BENCH_DIR/${label}.txt"

  echo "  UUID point queries..."
  local t0=$($MYSQL -N -e "SELECT MICROSECOND(NOW(6)) + UNIX_TIMESTAMP(NOW(6))*1000000")
  for i in $(seq 1 200); do
    local u=$($MYSQL btree_bench -N -e "SELECT uuid_col FROM bench_uuid ORDER BY RAND() LIMIT 1")
    $MYSQL btree_bench -N -e "SELECT id FROM bench_uuid WHERE uuid_col='$u'" > /dev/null
  done
  local t1=$($MYSQL -N -e "SELECT MICROSECOND(NOW(6)) + UNIX_TIMESTAMP(NOW(6))*1000000")
  local dt=$((t1 - t0))
  echo "    UUID point 200x: ${dt}μs" >> "$BENCH_DIR/${label}.txt"
}

echo "========== B-Tree Optimization Benchmark =========="
echo "Rows: $ROWS"
echo "Output: $BENCH_DIR"

$MYSQL -e "DROP DATABASE IF EXISTS btree_bench; CREATE DATABASE btree_bench;"

for mode in OFF ON; do
  echo ""
  echo "=== innodb_btree_optimizations = ${mode} ==="
  $MYSQL -e "SET GLOBAL innodb_btree_optimizations=${mode}"

  bench_int "$mode" "$ROWS" "int_${mode,,}"
  bench_uuid "$mode" "$((ROWS / 2))" "uuid_${mode,,}"
done

echo ""
echo "========== RESULTS =========="
echo ""

for label in int_off int_on uuid_off uuid_on; do
  echo "--- ${label} ---"
  cat "$BENCH_DIR/${label}.txt" 2>/dev/null || true
  echo ""
done

# Comparison summary
echo "========== COMPARISON =========="
echo "Metric              | OFF       | ON        | Change"
echo "--------------------|-----------|-----------|-------"
for metric in "Insert" "Point"; do
  off_val=$(grep "^    ${metric}" "$BENCH_DIR/int_off.txt" 2>/dev/null | head -1 | grep -oP '\d+ rows/sec|\d+ qps' || echo "-")
  on_val=$(grep  "^    ${metric}" "$BENCH_DIR/int_on.txt" 2>/dev/null  | head -1 | grep -oP '\d+ rows/sec|\d+ qps' || echo "-")
  printf "%-20s| %-10s| %-10s| %s\n" "PK ${metric}" "$off_val" "$on_val" ""
done
for metric in "Insert" "UUID point"; do
  off_val=$(grep "^    ${metric}" "$BENCH_DIR/uuid_off.txt" 2>/dev/null | head -1 | grep -oP '\d+ rows/sec|\d+ qps' || echo "-")
  on_val=$(grep  "^    ${metric}" "$BENCH_DIR/uuid_on.txt" 2>/dev/null  | head -1 | grep -oP '\d+ rows/sec|\d+ qps' || echo "-")
  printf "%-20s| %-10s| %-10s| %s\n" "UUID ${metric}" "$off_val" "$on_val" ""
done
