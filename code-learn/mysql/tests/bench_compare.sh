#!/bin/bash
# bench_compare.sh — Compare innodb_btree_optimizations=ON vs OFF
#
# Prerequisites:
#   - MySQL 8.4 server running on localhost (socket: /tmp/mysql.sock)
#   - sysbench installed
#   - mysql CLI with root access
#
# Usage: bash bench_compare.sh [table_size] [time_seconds]

set -euo pipefail

TABLE_SIZE=${1:-50000}
TIME=${2:-30}
MYSQL="mysql -u root -S /tmp/mysql.sock"
SYSBENCH="sysbench /usr/share/sysbench/oltp_read_write.lua"
RESULT_DIR="/tmp/btree_opt_bench_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULT_DIR"

echo "=== B-Tree Optimization Benchmark ==="
echo "Table size: $TABLE_SIZE  |  Duration: ${TIME}s"
echo "Results: $RESULT_DIR"
echo ""

run_one() {
    local mode=$1
    local label=$2
    local result_file="${RESULT_DIR}/${label}.txt"

    echo "--- Mode: $mode ($label) ---"

    # Recreate database
    $MYSQL -e "DROP DATABASE IF EXISTS sbtest; CREATE DATABASE sbtest;"

    # Prepare data
    $SYSBENCH \
        --mysql-socket=/tmp/mysql.sock --mysql-user=root \
        --tables=4 --table-size=$TABLE_SIZE prepare

    # Set optimization mode
    $MYSQL -e "SET GLOBAL innodb_btree_optimizations=${mode}"

    # Warmup
    echo "  Warming up (10s)..."
    $SYSBENCH \
        --mysql-socket=/tmp/mysql.sock --mysql-user=root \
        --tables=4 --table-size=$TABLE_SIZE \
        --threads=4 --time=10 run > /dev/null 2>&1

    # Measurement
    echo "  Running (${TIME}s)..."
    $SYSBENCH \
        --mysql-socket=/tmp/mysql.sock --mysql-user=root \
        --tables=4 --table-size=$TABLE_SIZE \
        --threads=8 --time=$TIME --report-interval=5 run \
        2>&1 | tee "$result_file"

    # Collect metadata
    $MYSQL -e "SHOW STATUS LIKE 'InnoDB_pages_created';" \
        >> "${RESULT_DIR}/meta_${label}.txt"
    $MYSQL -e "SHOW STATUS LIKE 'Innodb_rows_%';" \
        >> "${RESULT_DIR}/meta_${label}.txt"

    # Cleanup
    $MYSQL -e "DROP DATABASE sbtest;"
    echo ""
}

# ========== 1. sysbench OLTP Read-Write ==========
echo "========================================"
echo "1. sysbench OLTP Read-Write"
echo "========================================"
run_one "OFF" "oltp_off"
run_one "ON"  "oltp_on"

# ========== 2. Point Select Only ==========
echo "========================================"
echo "2. sysbench Point Select"
echo "========================================"
POINT="sysbench /usr/share/sysbench/oltf_point_select.lua"

for mode in OFF ON; do
    label="point_$(echo $mode | tr 'A-Z' 'a-z')"
    $MYSQL -e "DROP DATABASE IF EXISTS sbtest; CREATE DATABASE sbtest;"
    $POINT --mysql-socket=/tmp/mysql.sock --mysql-user=root \
        --tables=4 --table-size=$TABLE_SIZE prepare
    $MYSQL -e "SET GLOBAL innodb_btree_optimizations=${mode}"
    $POINT --mysql-socket=/tmp/mysql.sock --mysql-user=root \
        --tables=4 --table-size=$TABLE_SIZE \
        --threads=8 --time=$TIME --report-interval=5 run \
        2>&1 | tee "${RESULT_DIR}/${label}.txt"
    $MYSQL -e "DROP DATABASE sbtest;"
done

# ========== 3. Custom DDL: String Index ==========
echo "========================================"
echo "3. Custom: UUID secondary index"
echo "========================================"
$MYSQL -e "CREATE DATABASE IF NOT EXISTS bench;"

for mode in OFF ON; do
    label="uuid_$(echo $mode | tr 'A-Z' 'a-z')"
    echo "  Mode: $mode"

    $MYSQL bench -e "
        DROP TABLE IF EXISTS uuid_test;
        CREATE TABLE uuid_test (
            id INT AUTO_INCREMENT PRIMARY KEY,
            uuid_str VARCHAR(36) NOT NULL,
            data BIGINT NOT NULL,
            INDEX idx_uuid(uuid_str)
        ) ENGINE=InnoDB;
        SET GLOBAL innodb_btree_optimizations=${mode};
    "

    # Generate UUID data
    python3 "$(dirname $0)/gen_test_data.py" uuid $TABLE_SIZE /tmp/uuid_data.csv

    # Load data
    $MYSQL bench -e "
        START TRANSACTION;
        LOAD DATA LOCAL INFILE '/tmp/uuid_data.csv'
        INTO TABLE uuid_test (uuid_str, data);
        COMMIT;
    "

    # Measure point lookup
    $MYSQL bench -e "SELECT COUNT(*) FROM uuid_test WHERE uuid_str = (SELECT uuid_str FROM uuid_test ORDER BY RAND() LIMIT 1);" \
        >> "${RESULT_DIR}/${label}_lookup.txt" 2>&1

    echo "  Done" >> "${RESULT_DIR}/${label}.txt"
done

$MYSQL -e "DROP DATABASE IF EXISTS bench;"

# ========== Summary ==========
echo ""
echo "========================================"
echo "SUMMARY"
echo "========================================"
echo ""
echo "--- OLTP Read-Write ---"
grep -A2 "transactions:" "${RESULT_DIR}"/oltp_*.txt 2>/dev/null || true
echo ""
echo "--- Point Select ---"
grep -A2 "transactions:" "${RESULT_DIR}"/point_*.txt 2>/dev/null || true
echo ""
echo "Results saved to: $RESULT_DIR"
