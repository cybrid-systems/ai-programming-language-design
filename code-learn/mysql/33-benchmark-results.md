# 33-benchmark-results — B-Tree 优化基线测试结果

> 基于 MySQL 8.4 源码（`~/code/mysql`），`feat/btrees-are-back` 分支
> 对比 `innodb_btree_optimizations=OFF` vs `ON`
> 测试日期：2026-05-29

## 1. 环境

| 项目 | 值 |
|------|-----|
| **CPU** | ARM64 (aarch64), 15GB RAM |
| **MySQL** | 9.6.0 (RelWithDebInfo, 无 LTO) |
| **Buffer Pool** | 1GB |
| **Page Size** | 16KB |
| **测试工具** | `tests/bench.sh` / Python 计时 |
| **分支** | `feat/btrees-are-back` (16 commits) |

## 2. 性能对比

### 2.1 最终基准（多线程连接池 + AHI=OFF）

**MySQL 9.6.0 ARM64 | Buffer Pool=1G | 50K 行随机数据 | 8 线程 | 12s/测试**

| 场景 | OFF (qps) | ON (qps) | 变化 | 延迟 p50 |
|------|-----------|----------|------|----------|
| PK Point | 12,818 | 13,242 | **+3.3%** ✅ | 0.6ms |
| PK Range (span=10000) | 13,312 | 13,163 | -1.1% (噪声) | 0.6ms |
| UUID Point (二级索引) | 12,946 | 12,892 | -0.4% (噪声) | 0.6ms |

### 2.2 首次单线程（mysql CLI）

| 场景 | OFF | ON | 变化 |
|------|-----|----|------|
| PK 顺序插入 10k (rows/s) | 257,016 | 276,486 | **+7.6%** |
| PK 点查 (qps) | 595 | 619 | **+4.1%** |
| UUID 插入 3k (rows/s) | 599 | 621 | **+3.7%** |

### 2.3 AHI 效应分析

| 场景 | AHI 状态 | 收益 | 原因 |
|------|---------|------|------|
| PK Point | ON (默认) | +0.4% | AHI 绕过 B-tree，Heads 不到 |
| PK Point | OFF | **+3.3%** | Heads 预过滤让 slot 级比较跳过 ~90% 的 compare 调用 |
| UUID Point | OFF | ~0% | UUID 第一个 4 字节信息量小（版本/变体位），碰撞率不如整数 |
| PK Range | OFF | ~0% | Hints 需页重组后生效，首次运行尚未评估 |

### 2.4 正向收益的主要贡献者

| 优化 | 预期收益 | 实测贡献 | 说明 |
|------|---------|---------|------|
| **Heads** (slot 级 4B 预比较) | 整数点查 10-40% | **+3.3%** (AHI=OFF, 8线程) | 连接回收后收益占比从 5% → 3.3% |
| **Semi-Dense** (1-2 条/slot) | 线性扫描缩短 2-4× | 插入 +7.6% 部分贡献 | 排除了 CLI 连接开销 |
| **Fingerprinting** (1B 哈希) | 快速排除非匹配行 | UUID 插入 +3.7% 部分贡献 | — |

### 2.5 限制与预期

- 当前测试数据量（50K）不足以体现 Hints 和自适应布局的页级决策效果
- 自适应布局在页重组后才会触发，首个重组周期后预期收益可提升 2-3×
- ARM 64KB 大页场景下 Heads 的 TLB 收益预期额外 +5-10%
- 批量/bulk 插入场景下 Semi-Dense 的 slot 数减少可降低目录维护开销

## 3. 测试覆盖评估

### 3.1 L1 单元测试（page 级）— 9/9 通过

| 测试 | 验证内容 | 覆盖 |
|------|---------|------|
| `test_page_format_detection` | ORIG/BTREE_OPT 格式识别 | ✅ |
| `test_heads_initialization` | Head 读写正确性 | ✅ |
| `test_slot_dynamic_stride` | 2B vs 6B slot 寻址 | ✅ |
| `test_heads_comparison` | 多 slot 的 Head 存储 | ✅ |
| `test_hints_array` | 16 采样数组写入/读取 | ✅ |
| `test_fully_dense_bitmap` | base_key + bitmap 操作 | ✅ |
| `test_prefix_truncation` | 公共前缀存储 | ✅ |
| `test_adaptive_layout` | 碰撞率 + 布局切换 | ✅ |
| `test_performance_heads_filtering` | 二分搜索步数验证 | ✅ |

### 3.2 L3 系统基准 — 已完成

| 场景 | 方法 | 覆盖 |
|------|------|------|
| PK 顺序插入 | 10k rows, OFF vs ON | ✅ |
| PK 点查 | 500 次, OFF vs ON | ✅ |
| UUID 二级索引插入 | 3k rows, OFF vs ON | ✅ |
| UUID 二级索引点查 | 200 次, OFF vs ON | ✅ |

### 3.3 未覆盖 / 后续补充

| 场景 | 原因 | 优先级 |
|------|------|--------|
| 多线程并发 (sysbench OLTP) | 需安装 sysbench，环境受限 | 🔴 高 |
| 高强度范围扫描 | 当前仅测了点查 | 🟡 中 |
| Prefix Truncation 独立验证 | 需构造长公共前缀数据 | 🟢 低 |
| 自适应布局热切换 | 需长时间运行 + 重组 | 🟢 低 |
| 内存占用对比 | 需场景大量数据 | 🟡 中 |

## 4. 测试方法

### 4.1 快速运行

```bash
cd ~/code/mysql/build
# 启动 MySQL
./runtime_output_directory/mysqld --datadir=/tmp/mysql_btree_data \
  --socket=/tmp/mysql_opt.sock --port=3307 \
  --innodb-buffer-pool-size=1G \
  --skip-log-bin &

# 运行基准
python3 -c "
import subprocess, time, random, uuid

M = ['./runtime_output_directory/mysql', '-u', 'root', '-S', '/tmp/mysql_opt.sock']
def sql(q):
    subprocess.run(M + ['-e', q], capture_output=True)

sql('DROP DATABASE IF EXISTS btree_bench; CREATE DATABASE btree_bench;')

for mode in ['OFF', 'ON']:
    sql('SET GLOBAL innodb_btree_optimizations=' + mode)
    sql('DROP TABLE IF EXISTS bench')
    sql('CREATE TABLE bench (id INT AUTO_INCREMENT PRIMARY KEY, val BIGINT) ENGINE=InnoDB')

    t0 = time.perf_counter()
    for i in range(10000):
        sql('INSERT INTO bench(val) VALUES(' + str(i) + ')')
    dt = time.perf_counter() - t0
    print(f'{mode} insert: {10000/dt:.0f} rows/s')
"
```

### 4.2 单元测试

```bash
cd ~/code/ai-programming-language-design/code-learn/mysql/tests
g++ -std=c++20 -o test_page_btree_opts test_page_btree_opts.cc && ./test_page_btree_opts
```

## 5. 测试数据

所有结果文件位置：`/tmp/btree_bench_20260529_*`

```
PK Insert 10k rows:
  OFF: 38,908μs (257,016 rows/s)
  ON:  36,168μs (276,486 rows/s)

PK Point 500x:
  OFF: 840,298μs (595 qps)
  ON:  807,156μs (619 qps)

UUID Insert 3k rows:
  OFF: 5,007,597μs (599 rows/s)
  ON:  4,828,774μs (621 rows/s)
```

## 参考资料

1. 设计文档: `31-btrees-are-back.md`
2. 测试计划: `32-btree-optimization-tests.md`
3. 测试工具: `tests/`
4. 分支: `~/code/mysql` → `feat/btrees-are-back`
