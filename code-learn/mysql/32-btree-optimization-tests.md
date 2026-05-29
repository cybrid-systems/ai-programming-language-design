# 32-btree-optimization-tests — B-Tree 优化测试计划与基线

> 基于 MySQL 8.4 源码（`~/code/mysql`）
> 测试目标分支：`feat/btrees-are-back`
> 本文档定义了六个优化 + 自适应布局的功能验证和性能基线测量方案
> 分析日期：2026-05-29

## 1. 测试总览

### 1.1 测试层级

| 层级 | 范围 | 工具 | 耗时 |
|------|------|------|------|
| L1 单元测试 | 单个页操作（page0cur, page0page） | Google Test / 独立 C++ 程序 | ~1min |
| L2 集成测试 | B+Tree 操作（btr0cur, btr0btr） | mtr (MySQL Test Run) | ~5min |
| L3 系统基准 | 完整 MySQL + sysbench / TPCC | sysbench + 自定义脚本 | ~30min |

### 1.2 基线对比

所有性能测试对比两个配置：

```sql
SET GLOBAL innodb_btree_optimizations=OFF;  /* 基线：原始 InnoDB */
SET GLOBAL innodb_btree_optimizations=ON;   /* 优化后 */
```

控制变量：
- 相同的数据集大小
- 相同的 MySQL 配置（除 `innodb_btree_optimizations` 外）
- 预热 buffer pool 后再测量
- 每次测试之间重启 buffer pool（`SET GLOBAL innodb_buffer_pool_dump_now=ON` 等）

## 2. L1 单元测试

### 2.1 UUID 字符串 key 场景

测试：字符串类二级索引的搜索和插入效率。

```
表结构: CREATE TABLE t1 (id VARCHAR(36), data INT, INDEX idx_id(id));
数据:    UUID 格式的字符串（36 字节，随机分布）
操作:    插入 1000 行 + 精确查找 + 范围扫描
预期:
  - Heads 过滤: 90%+ slot 级 Head 预比较命中
  - Hints: 16-slot 采样缩小搜索范围至 1/16
  - Prefix Truncation: 页级公共前缀 > 8 字节
```

### 2.1 整数主键场景

测试：`INT AUTO_INCREMENT` 聚簇索引的插入和扫描。

```
表结构: CREATE TABLE t2 (id INT AUTO_INCREMENT PRIMARY KEY, val BIGINT);
数据:    顺序插入 1000 行
操作:    插入 + 精确查找 + 范围扫描
预期:
  - Fully-Dense: bitmap 直接定位，O(1) "是否存在" 检查
  - Semi-Dense: slot 阈值 1-2，线性扫描最多 2 条
  - Heads: 4KB 预比较，高基数下 0% 碰撞
```

### 2.3 页级操作直接测试

独立 C++ 程序，直接调用 InnoDB page 函数:

```cpp
// 伪代码 — page-level verification (see test_page_operations.cc)
void test_page_search_with_heads() {
  buf_block_t *block = create_test_page();
  page_t *page = buf_block_get_frame(block);
  page_create(block, mtr, true, FIL_PAGE_INDEX);

  // 插入若干记录（整数 key）
  for (int k = 10; k < 100; k += 10) {
    rec_t *rec = create_test_rec(k);
    page_cur_insert_rec_low(cur, index, rec, offsets, mtr);
  }

  // 验证二分搜索经过 Heads 预过滤后正确找到位置
  page_cur_t cursor;
  page_cur_search_with_match(block, index, tuple, PAGE_CUR_LE,
                             &up_match, &low_match, &cursor, nullptr);
  assert(cursor_has_correct_key(&cursor, target_key));
}
```

## 3. L2 集成测试

### 3.1 mtr 测试用例

创建 MySQL Test Run (mtr) 测试文件：

```
# test case: btree_heads_basic.test
--echo # Test B-Tree Heads optimization basic correctness

SET GLOBAL innodb_btree_optimizations = ON;

CREATE TABLE t1 (a INT AUTO_INCREMENT PRIMARY KEY, b VARCHAR(36));
--disable_query_log
INSERT INTO t1(b) VALUES ('uuid-xxxx-xxxx-xxxx'), ... 100行;
--enable_query_log

# 验证精确查找
SELECT * FROM t1 WHERE a = 42;  # 验证 Fully-Dense bitmap 路径
SELECT * FROM t1 WHERE b = 'uuid-yyyy-yyyy-yyyy';  # 验证 Heads+Hints 路径

# 验证范围扫描
SELECT * FROM t1 WHERE a BETWEEN 10 AND 20;
SELECT * FROM t1 WHERE b LIKE 'uuid-aaaa%';

SET GLOBAL innodb_btree_optimizations = OFF;

# 重复验证（确保 OFF 下行为也正确）
SELECT * FROM t1 WHERE a = 42;
SELECT * FROM t1 WHERE b = 'uuid-yyyy-yyyy-yyyy';
```

## 4. L3 系统基准测试

### 4.1 sysbench 场景

```bash
#!/bin/bash
# bench_compare.sh — 对比 ON/OFF 性能

MYSQL="mysql -u root -S /tmp/mysql.sock"

for mode in OFF ON; do
  echo "=== Testing innodb_btree_optimizations=${mode} ==="

  # 重建测试库
  $MYSQL -e "DROP DATABASE IF EXISTS sbtest; CREATE DATABASE sbtest;"
  sysbench /usr/share/sysbench/oltp_read_write.lua \
    --mysql-socket=/tmp/mysql.sock --mysql-user=root \
    --tables=4 --table-size=100000 prepare

  # 设置优化开关
  $MYSQL -e "SET GLOBAL innodb_btree_optimizations=${mode}"

  # 预热 + 测试
  sysbench /usr/share/sysbench/oltp_read_write.lua \
    --mysql-socket=/tmp/mysql.sock --mysql-user=root \
    --tables=4 --table-size=100000 \
    --threads=8 --time=60 --report-interval=10 run \
    | tee "result_${mode}.txt"

  # 清理
  $MYSQL -e "DROP DATABASE sbtest;"
done

# 结果对比
echo "=== Comparison ==="
grep "queries performed" result_OFF.txt result_ON.txt
grep "read/write requests" result_OFF.txt result_ON.txt
grep "avg:" result_OFF.txt result_ON.txt
```

### 4.2 自定义性能场景

除了标准 sysbench OLTP，还测试以下针对性场景：

#### 场景 A：纯整数自增主键（Fully-Dense/Semi-Dense）

```sql
CREATE TABLE perf_int (
  id INT AUTO_INCREMENT PRIMARY KEY,
  val BIGINT NOT NULL,
  padding CHAR(64)
) ENGINE=InnoDB;

-- 大量顺序插入 + 点查
INSERT INTO perf_int(val, padding) VALUES (1, '...'), (2, '...'), ... 100k 行;
SELECT * FROM perf_int WHERE id BETWEEN 100 AND 200;
SELECT * FROM perf_int WHERE id = 54321;
```

**基线指标：**
- 插入吞吐: rows/sec
- 点查延迟: μs
- 范围扫描: rows/sec
- 页分裂次数: `SHOW STATUS LIKE 'InnoDB_pages_created'`

#### 场景 B：UUID 二级索引（Heads + Hints + Prefix Truncation）

```sql
CREATE TABLE perf_uuid (
  id INT AUTO_INCREMENT PRIMARY KEY,
  uuid_str VARCHAR(36) NOT NULL,
  data BIGINT,
  INDEX idx_uuid(uuid_str)
) ENGINE=InnoDB;

-- 随机 UUID 插入 + 点查
INSERT INTO perf_uuid(uuid_str, data) VALUES (UUID(), ...), ... 100k 行;
SELECT * FROM perf_uuid WHERE uuid_str = '550e8400-e29b-41d4-a716-446655440000';
```

**基线指标：**
- 二级索引插入吞吐
- UUID 点查延迟
- 索引页分裂率

#### 场景 C：电子邮件索引（Heads 高碰撞场景）

```sql
CREATE TABLE perf_email (
  id INT AUTO_INCREMENT PRIMARY KEY,
  email VARCHAR(255) NOT NULL,
  INDEX idx_email(email)
) ENGINE=InnoDB;

-- 同一域名的不同邮箱（高度公共前缀）
INSERT INTO perf_email(email) VALUES
  ('alice@company.com'), ('bob@company.com'), ... 100k 行不同用户名相同域名;
```

**预期 Heads 收益：** 所有 Head（`comp`）相同，Head 预比较在 slot 级大部分匹配 → 几乎全命中 → 影响最小化。但 Prefix Truncation 在此场景有显著收益（公共前缀 `@company.com` 被截断）。

#### 场景 D：复合索引多字段

```sql
CREATE TABLE perf_comp (
  user_id INT NOT NULL,
  ts DATETIME(3) NOT NULL,
  action VARCHAR(32) NOT NULL,
  data JSON,
  PRIMARY KEY (user_id, ts, action)
) ENGINE=InnoDB;
```

多字段比较是 `cmp_dtuple_rec_with_match_low` 中最昂贵的路径之一。

## 5. 验证检查清单

### 5.1 功能正确性

| # | 检查项 | 方法 | 通过标准 |
|---|--------|------|---------|
| 1 | Heads 搜索命中 | 在 page_cur_search_with_match 加 print | Heads 预过滤路径执行次数 > 0 |
| 2 | Hints 搜索范围缩小 | 检查 low/up 初始值 | low > 0 或 up < n_slots-1 |
| 3 | Fingerprint 跳过线性扫描 | 线性扫描循环计数 | count < 期望值 |
| 4 | Semi-Dense split | INSERT 后 n_owned | n_owned <= 2 |
| 5 | Fully-Dense bitmap | bitmap 位正确设置 | bitmap[idx] == 1 当且仅当 key 存在 |
| 6 | Prefix Truncation | 前缀计算 | 页内所有记录共享前缀 |
| 7 | 自适应布局切换 | reorganize 后检查标志 | PAGE_LAYOUT_* 正确设置 |

### 5.2 性能验收标准

| 场景 | OFF vs ON 对比 | 目标 |
|------|---------------|------|
| 整数 PK 顺序插入 | tps | ON ≥ OFF (Heads overhead 应在 <3%) |
| 整数 PK 点查 | latency p50/p99 | ON 比 OFF 快 10-40% |
| UUID 二级索引插入 | tps | ON ≥ OFF (Prefix Truncation 节省空间) |
| UUID 二级索引点查 | latency | ON 比 OFF 快 25-60% |
| 邮箱索引点查 | latency | ON 比 OFF 快 10-30% |
| 范围扫描 | rows/sec | ON ≥ OFF (Hints 不应退化) |
| 页空间利用率 | avg row per page | ON 不应低于 OFF |

### 5.3 回归测试

每次修改后运行：

```bash
cd ~/code/mysql
rm -rf build && mkdir build && cd build
cmake .. -DWITH_UNIT_TESTS=ON -DCMAKE_BUILD_TYPE=Debug
make -j$(nproc) innodb_page_test && ./runtime_output_directory/innodb_page_test
```

## 6. 调试技巧

### 6.1 启用 Heads/Hints 日志

```cpp
// 在 page0cur.cc page_cur_search_with_match 中插入
#ifdef UNIV_BTREE_OPT_DEBUG
  static ulonglong heads_hits = 0, heads_total = 0;
  if (has_heads) {
    heads_total++;
    if (tuple_head < slot_head || tuple_head > slot_head) heads_hits++;
    if (heads_total % 1000 == 0)
      fprintf(stderr, "Heads: %llu/%llu hit (%.1f%%)\n",
              heads_hits, heads_total,
              100.0 * heads_hits / heads_total);
  }
#endif
```

### 6.2 验证 slot 格式

```bash
# 用 gdb 或 InnoDB Page Viewer
cd /tmp && python3 -c "
import struct
with open('/tmp/page_dump.bin', 'rb') as f:
    page = f.read(16384)
level = struct.unpack('>H', page[64:66])[0]
fmt = (level >> 8) & 0xFF
print(f'Level={level & 0xFF}, Format={fmt}')
if fmt == 1:
    slot_size = 6
    flags = struct.unpack('<I', page[94:98])[0]
    print(f'BTREE_OPT: flags=0x{flags:08x}')
    hints = [struct.unpack('>I', page[98+i*4:102+i*4])[0] for i in range(16)]
    print(f'Hints: {[hex(h) for h in hints]}')
else:
    slot_size = 2
    print(f'ORIG format, slot_size=2')
"
```

## 7. 测试数据生成器

`gen_test_data.py` — 生成各种 key 分布的测试数据集：

```python
#!/usr/bin/env python3
"""Generate test data for B-Tree optimization benchmarks."""
import uuid, random, string, csv, sys

def gen_sequential_ints(n):
    """顺序整数 key（Fully-Dense 的最佳场景）"""
    return [(i, i * 2) for i in range(n)]

def gen_random_uuid(n):
    """随机 UUID 字符串 key"""
    return [(str(uuid.uuid4()), i) for i in range(n)]

def gen_same_domain_email(n):
    """同域名邮箱（高公共前缀，Prefix Truncation 最佳场景）"""
    return [(f'user{i:05d}@company.com', i) for i in range(n)]

def gen_zipf_int(n, alpha=1.5):
    """Zipf 分布整数（模拟真实访问模式）"""
    from numpy.random import zipf
    keys = zipf(alpha, n)
    return [(int(k), i) for i, k in enumerate(keys)]

if __name__ == '__main__':
    mode = sys.argv[1] if len(sys.argv) > 1 else 'uuid'
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 10000
    generators = {
        'seq': gen_sequential_ints,
        'uuid': gen_random_uuid,
        'email': gen_same_domain_email,
        'zipf': gen_zipf_int,
    }
    data = generators[mode](n)
    writer = csv.writer(sys.stdout)
    for k, v in data:
        writer.writerow([k, v])
```

## 8. 预期性能模型

基于论文数据（AMD Ryzen 9 7950X, 300MB 数据集）和 MySQL 适配估算：

| 场景 | 预期 ON vs OFF 收益 | 关键优化 |
|------|--------------------|---------|
| 整数 PK 点查 | **快 10-40%** | Heads + Semi-Dense |
| 整数 PK 范围扫描 | **快 5-15%** | Hints |
| UUID 二级索引点查 | **快 25-60%** | Heads + Hints |
| UUID 二级索引插入 | **相当或略慢 <5%** | Heads 额外写开销 |
| 邮箱索引点查 | **快 15-30%** | Prefix Truncation |
| 混合 OLTP QPS | **提升 10-30%** | 自适应整体 |
| 空间使用率 | **降低 5-15%** | Prefix Truncation |

## 参考资料

1. Müller, M., Benson, L., & Leis, V. (2025). *B-Trees Are Back* SIGMOD 2025.
2. MySQL 手册: `mysql-test-run.pl` — https://dev.mysql.com/doc/mysql-test-run/
3. sysbench 文档: https://github.com/akopytov/sysbench
4. 本适配文章: `31-btrees-are-back.md`
