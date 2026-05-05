# OceanBase CPU 满载优化方案：cgroup 隔离 + 参数调优

> 环境: OB 4.2.5.6 | 单租户 10 核 CPU / 40GB 内存 | 70:30 读写比 | 高 QPS | CPU 打满
> 问题: freeze 耗时 60s+, 不断触写限流, QPS 断崖下降

---

## 目录

1. [根因分析：LSM-Tree CPU 自锁](#1-根因分析lsm-tree-cpu-自锁)
2. [源码层面的证明](#2-源码层面的证明)
3. [方案全景](#3-方案全景)
4. [步骤一：内存参数调整（立即生效）](#4-步骤一内存参数调整立即生效)
5. [步骤二：Compaction 线程优先级调整（立即生效）](#5-步骤二compaction-线程优先级调整立即生效)
6. [步骤三：cgroup 全局后台隔离（需重启）](#6-步骤三cgroup-全局后台隔离需重启)
7. [步骤四：cgroup cpuset 绑核（物理核隔离）](#7-步骤四cgroup-cpuset-绑核物理核隔离)
8. [步骤五：DBMS_RESOURCE_MANAGER 精细隔离](#8-步骤五dbms_resource_manager-精细隔离)
9. [步骤六：监控与验证](#9-步骤六监控与验证)
10. [量化分析：CPU 压榨的数学依据](#10-量化分析cpu-压榨的数学依据)
11. [决策矩阵](#11-决策矩阵什么时候该做什么)
12. [推荐参数总结](#12-推荐参数总结)

---

## 1. 根因分析：LSM-Tree CPU 自锁

### 1.1 核心问题链路

```
freeze 触发 (memstore = freeze_trigger_percentage × memstore_limit)
  → 需要 CPU 做 flush + 写 SSTable
  → 但 CPU 已经被 100% 占满 (compaction + SQL 等分)
  → flush 线程抢不到 CPU → SQL 响应变慢
  → write_ref_cnt 降不下来

等待 write_ref_cnt == 0 (08-memtable-freezer.md: §2.5)
  → freeze 卡在 ready_for_flush
  → memstore 在等待期间还在接收写入数据
  → 撞 writing_throttling → QPS 断崖 ↓
```

### 1.2 核心矛盾

```text
write rate > flush rate 的本质:
  CPU 是一个 finite resource → SQL 和 compaction 都在抢
  compaction 越抢 CPU → SQL 越慢 → write_ref_cnt 越难清空
  → freeze 越慢 → memstore 涨越快 → 限流

这跟 freeze_trigger 调到多少无关 —— 只要 CPU 满载,
compaction 和 SQL 就必然互相争抢, 触发自锁。
```

### 1.3 cgroup 为何能打破

```text
cgroup 不优化 CFS 公平性, 而是主动制造不公平:
  
  ┌── 没有 cgroup ──────────────────┐
  │  SQL threads     ████████░░░░   │  ← CFS 公平平分
  │  compaction      ████████░░░░   │     各占 ~50%
  │  互相拖慢                       │
  └──────────────────────────────────┘

  ┌── 有 cgroup (background=70%) ───┐
  │  SQL threads     ██████████████ │  ← 独占剩余 CPU
  │  ─── cgroup limit line ─────────│  ← 30% 留给 foreground
  │  compaction      ██████████     │  ← 最多 70%
  │  SQL 不受影响 ✓                │
  └──────────────────────────────────┘

效果链:
  SQL 拿到保证的 CPU → 请求快速完成 → write_ref_cnt 快速归零
  → freeze 条件快速满足 → memtable 快速 flush
  → 不限流 → QPS 稳定
```

---

## 2. 源码层面的证明

### 2.1 Compaction 线程的完整 cgroup 链路

从源码 tracing 出来的完整路径:

```
ObTenantDagScheduler::process_task()          ← ob_tenant_dag_scheduler.cpp
  │
  ├─ DAG_PRIO_COMPACTION_HIGH = Mini Merge    ← dag_scheduler_config.h:62
  ├─ DAG_PRIO_COMPACTION_MID  = Minor Merge   ← dag_scheduler_config.h:64
  └─ DAG_PRIO_COMPACTION_LOW  = Major/Medium  ← dag_scheduler_config.h:66
         │
         ▼
  ret_worker->set_function_type(
      OB_DAG_PRIOS[priority].function_type_)   ← ob_tenant_dag_scheduler.cpp:5374
         │
         ▼
  CONSUMER_GROUP_FUNC_GUARD(function_type_)    ← ob_tenant_dag_scheduler.cpp:2259
         │
         ▼
  CONVERT_FUNCTION_TYPE_TO_GROUP_ID()          ← ob_cgroup_ctrl.cpp
   → get_group_id_by_function_type()           ← ob_resource_mapping_rule_manager.h:152
   → get_group_id_by_function()
         │
         ▼
  SET_GROUP_ID(group_id)                       ← ob_cgroup_ctrl.cpp:38
   → add_self_to_cgroup_(tenant_id, group_id, is_background)
         │                          │
         ▼                          ▼
  write TID → /sys/fs/cgroup/cpu/       ← 当 enable_global_background_
    cgroup/[background]/tenant_1004/          resource_isolation=true 时
    OBCG_STORAGE/tasks                        写 background 路径
```

### 2.2 ready_for_flush 的三个前置条件

06-memtable-freezer-analysis.md §2.5:

```cpp
bool ObMemtable::ready_for_flush_()
{
  bool bool_ret = is_frozen &&               // ① 已冻结
                  0 == write_ref_cnt &&       // ② 无正在写入 ← CPU 满载下最慢
                  0 == unsubmitted_cnt;       // ③ 无未提交日志
```

**write_ref_cnt 只有在 SQL 请求实际完成后才会递减。**
CPU 被 compaction 抢走 → SQL 慢 → write_ref_cnt 不降 → 这就是自锁点。

### 2.3 三档 Compaction 优先级

34-sstable-merge-analysis.md + 源码:

```
DAG_PRIO_COMPACTION_HIGH → compaction_high_thread_score → Mini Merge (最紧急)
DAG_PRIO_COMPACTION_MID  → compaction_mid_thread_score  → Minor Merge
DAG_PRIO_COMPACTION_LOW  → compaction_low_thread_score  → Major/Medium Merge (可推迟)
```

每个优先级的 `function_type_` 会被 `CONSUMER_GROUP_FUNC_GUARD` 捕获,
最终通过 `SET_GROUP_ID` 将当前线程写入对应的 cgroup。

### 2.4 cgroup 目录结构

```
enable_global_background_resource_isolation = true 时:

/sys/fs/cgroup/cpu/cgroup/
├── other/                        ← 系统租户 (500)
├── background/                   ← 后台任务 (global_background_cpu_quota)
│   └── tenant_1004/
│       ├── OBCG_STORAGE/tasks    ← compaction 线程在此
│       ├── OBCG_CLOG/tasks       ← CLOG 后台
│       └── OBCG_LQ/tasks         ← 大查询
│
└── tenant_1004/                  ← 前台任务 (剩下的 CPU)
    ├── OBCG_ID_SQL_REQ_LEVEL1/   ← SQL concurrency=4
    ├── OBCG_ID_SQL_REQ_LEVEL2/   ← SQL concurrency=4
    ├── OBCG_WR/tasks             ← 写请求 (CRITICAL)
    └── OBCG_DEFAULT/tasks        ← 默认组
```

---

## 3. 方案全景

五层递进，每层解决不同维度的问题：

```
层 1: 内存参数                    立即生效   → 扩大 memstore 安全窗口
层 2: Compaction 线程分权         立即生效   → 降低 compaction CPU 争抢
层 3: cgroup 全局后台隔离         需重启     → 从 OS 级别限制 compaction CPU
层 4: cgroup cpuset 绑核          需重启     → 物理核隔离, 消除 L2/L3 缓存争抢
层 5: DBMS_RESOURCE_MANAGER      无重启     → 精细到用户/query 级别的隔离
```

---

## 4. 步骤一：内存参数调整（立即生效）

```sql
-- 1. 扩大 memstore 空间 (30% 写需要更多 buffer)
ALTER SYSTEM SET memstore_limit_percentage = 75;

-- 2. 提前触发 freeze, 给 throttling 留足够窗口
ALTER SYSTEM SET freeze_trigger_percentage = 50;

-- 3. 放开写限流阈值, 让 freeze 自行调节
ALTER SYSTEM SET writing_throttling_trigger_percentage = 100;

-- 4. 立即触发一次 minor freeze, 降低当前水位
ALTER SYSTEM MINOR FREEZE;
```

**为什么这组参数？**  
10核 × 40GB：memstore_limit = 75% → 30GB。  
freeze_trigger = 50% → freeze 在 15GB 触发。  
throttling = 100% → 不限流。  

freeze 到 memstore 满之间的 **15GB buffer** 是安全窗口。  
以之前观测的 60s freeze 耗时计算, 只要写入速率 < 250MB/s
就不会撞限流。如果还撞 → 说明根本问题是 CPU, 往下走。

---

## 5. 步骤二：Compaction 线程优先级调整（立即生效）

OB 4.x 内部有三档 compaction 优先级：

```text
compaction_high_thread_score → Mini Merge     ← freeze flush 后的合并
compaction_mid_thread_score  → Minor Merge    ← L0→L1 合并
compaction_low_thread_score  → Major/Medium   ← 全局合并 (可推迟)
```

**思路：压缩 low 和 mid 的线程数, 给 SQL 让路。**

```sql
ALTER SYSTEM SET compaction_high_thread_score = 6;   -- Mini Merge: 保持 6 线程
ALTER SYSTEM SET compaction_mid_thread_score  = 4;   -- Minor Merge: 减到 4
ALTER SYSTEM SET compaction_low_thread_score  = 2;   -- Major: 减到 2 (合并期间可临时放开)
```

> 注意: `compaction_*_thread_score` 不是固定线程数,
> 而是 DAG 调度器根据当前负载和 score 计算的权重。
> 降低 score 会让这些类型的 compaction 任务**排队更久**。

### 量化影响

```text
原始: 高=6, 中=6, 低=6  → 最多 18 个 compaction 线程抢 CPU
调整: 高=6, 中=4, 低=2  → 最多 12 个 compaction 线程
节省: 6 个线程 ≈ 0.6 核 × 2 hyperthread = 对 10 核约 6% CPU
```

---

## 6. 步骤三：cgroup 全局后台隔离（需重启）

### 6.1 配置

```sql
-- enable_cgroup 默认=True, 确认一下
SHOW PARAMETERS LIKE 'enable_cgroup';
-- 应该为 True

-- 开启全局后台隔离 (需要重启 observer)
ALTER SYSTEM SET enable_global_background_resource_isolation = True;

-- 设置后台任务最多使用 70% CPU (10核 = 7核留给 compaction, 3核留给 SQL)
ALTER SYSTEM SET global_background_cpu_quota = 7;  -- 单位: vCPU
```

### 6.2 重启后验证

```bash
# 检查 cgroup 目录
ls -la /sys/fs/cgroup/cpu/cgroup/
# 应该有: background/  tenant_1004/  other/

# 查看 background CPU 配额
cat /sys/fs/cgroup/cpu/cgroup/background/cpu.cfs_quota_us
cat /sys/fs/cgroup/cpu/cgroup/background/cpu.cfs_period_us
# quota / period = 核数  → 确认 7 核

# 查看 compaction 线程是否被正确归入 background
cat /sys/fs/cgroup/cpu/cgroup/background/tenant_1004/OBCG_STORAGE/tasks

# 查 tenant 默认组的 CPU (SQL 在这里)
cat /sys/fs/cgroup/cpu/cgroup/tenant_1004/OBCG_DEFAULT/tasks
```

### 6.3 原理

`enable_global_background_resource_isolation` 为 true 时:

```text
ob_cgroup_ctrl.cpp:add_thread_to_cgroup_():
  写 TID 到 /sys/fs/cgroup/cpu/cgroup/[background/]<tenant>/<group>/tasks
                                ↑
                      is_background=true 时插入 background 路径

resource_manager_plan.cpp:refresh_global_background_cpu():
  设置 cgroup/background/ 的 cpu.cfs_quota_us = global_background_cpu_quota × period
```

这意味着所有标记为 is_background=true 的任务线程 (包括 compaction 的
OBCG_STORAGE group) 都会受到 **cpu.cfs_quota_us** 的硬限制,
最多使用 `global_background_cpu_quota` 个 vCPU。

---

## 7. 步骤四：cgroup cpuset 绑核（物理核隔离）

### 7.1 解决的问题

前面三步只解决了 **CPU 时间片争抢**, 但没有解决 **缓存争抢**:

```
┌─────────────── 物理 CPU 芯片 ───────────────┐
│  ┌──── L2 $ ────┐    ┌──── L2 $ ────┐       │
│  │  Core 0      │    │  Core 1      │       │
│  │  SQL ████    │    │  compaction  │       │
│  │  compaction █│    │  ██████      │       │
│  └──────────────┘    └──────────────┘       │
│  ┌──── L2 $ ────┐    ┌──── L2 $ ────┐       │
│  │  Core 2      │    │  Core 3      │       │
│  │  SQL ████    │    │  SQL ████    │       │
│  │              │    │              │       │
│  └──────────────┘    └──────────────┘       │
│        共享 L3 $ (Last Level Cache)          │
│  compaction 大量扫描 → 撑爆 L3 → SQL miss↑  │
└─────────────────────────────────────────────┘
```

compaction (尤其是 major merge) 是 **全表扫描**, 会:
- 把 L3 cache 全部污染
- 导致 SQL 的 hot data 被逐出
- 增加 SQL 的 cache miss → latency 飙升

cpuset 绑核 = 让 compaction 和 SQL **使用不同的物理核**,
从物理上隔离 L2 和 L3 缓存的争抢。

### 7.2 OB 的 NUMA 亲和性支持

OB 4.2.5.6 已有 NUMA-aware 绑定能力, 但只到 NUMA node 级别,
不是单个 CPU core:

```cpp
// ob_affinity_ctrl.h - OB 内置的 NUMA 亲和性控制
class ObAffinityCtrl {
  int run_on_node(const int node);                    // 线程迁移到指定 NUMA node
  int thread_bind_to_node(const int node_hint);       // 线程绑定到 node
  int memory_bind_to_node(void *addr, size_t, int);   // 内存绑定到 node
  int memory_move_to_node(void *addr, size_t, int);   // 内存迁移
};
```

```sql
-- NUMA aware 开关 (需重启)
ALTER SYSTEM SET _enable_numa_aware = True;
```

启用后, OB 内部按 `GETTID() % num_nodes_` 做 round-robin 分配,
但细到单核绑定的能力需要 OS 层 cpuset 来配合。

### 7.3 手动 cpuset 绑核方案

> ⚠️ 这是 OS 级操作, OB 本身不管理 cpuset。需要确保
> `enable_global_background_resource_isolation = True` 已经生效。

#### 准备

```bash
# 确认 cpuset cgroup 子系统已挂载
ls /sys/fs/cgroup/cpuset/
# 如果没有, 手动挂载:
# mount -t cgroup -o cpuset cpuset /sys/fs/cgroup/cpuset

# 确认 OB 的 cgroup 目录存在 (从步骤三继承)
ls /sys/fs/cgroup/cpu/cgroup/background/tenant_1004/
ls /sys/fs/cgroup/cpu/cgroup/tenant_1004/
```

#### 方案 A: 在 OB 的 cpu cgroup 上叠加 cpuset (推荐)

对 10 核系统: SQL 用 core 0-5, compaction 用 core 6-9

```bash
#!/bin/bash
# save as /opt/ob_bind_cpuset.sh

OBCPU=/sys/fs/cgroup/cpu/cgroup
OBCSET=/sys/fs/cgroup/cpuset

# --- 创建 cpuset 镜像目录结构 ---
mkdir -p $OBCSET/cgroup/background/tenant_1004/OBCG_STORAGE
mkdir -p $OBCSET/cgroup/tenant_1004/OBCG_DEFAULT

# --- 设置 memory nodes (单 socket 设为 0) ---
echo 0 > $OBCSET/cpuset.mems

# --- 为 foreground SQL 组分配物理核: 0-5 ---
echo "0-5" > $OBCSET/cgroup/tenant_1004/OBCG_DEFAULT/cpuset.cpus
echo 0 > $OBCSET/cgroup/tenant_1004/OBCG_DEFAULT/cpuset.mems

# --- 为 compaction 组分配物理核: 6-9 ---
echo "6-9" > $OBCSET/cgroup/background/tenant_1004/OBCG_STORAGE/cpuset.cpus
echo 0 > $OBCSET/cgroup/background/tenant_1004/OBCG_STORAGE/cpuset.mems

# --- 将线程从 cpu cgroup 的 tasks 复制到 cpuset tasks ---
# 这会把所有线程同时加入到 cpuset cgroup, 实现绑核
for f in $(cat $OBCPU/cgroup/tenant_1004/OBCG_DEFAULT/tasks); do
  echo $f > $OBCSET/cgroup/tenant_1004/OBCG_DEFAULT/tasks 2>/dev/null
done

for f in $(cat $OBCPU/cgroup/background/tenant_1004/OBCG_STORAGE/tasks); do
  echo $f > $OBCSET/cgroup/background/tenant_1004/OBCG_STORAGE/tasks 2>/dev/null
done
```

#### 方案 B: systemd service 自动绑核

```ini
# /etc/systemd/system/ob_cpuset_bind.service
[Unit]
Description=Bind OB threads to specific CPU cores via cpuset
After=network.target

[Service]
Type=oneshot
ExecStart=/opt/ob_bind_cpuset.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

```bash
systemctl enable ob_cpuset_bind
systemctl start ob_cpuset_bind
```

### 7.4 周期性刷新 (线程会动态创建)

OB 的 compaction 线程是**动态创建/销毁**的 (DAG scheduler,
`ObDynamicThreadPool`)。每次新线程出现, 都需要加入 cpuset。

```bash
#!/bin/bash
# /opt/ob_cpuset_watch.sh — 每 30s 刷新一次绑定

OBCPU=/sys/fs/cgroup/cpu/cgroup
OBCSET=/sys/fs/cgroup/cpuset

while true; do
  # 刷新 foreground SQL
  for tid in $(cat ${OBCPU}/cgroup/tenant_1004/OBCG_DEFAULT/tasks); do
    if [ ! -f ${OBCSET}/cgroup/tenant_1004/OBCG_DEFAULT/tasks ] || \
       ! grep -q $tid ${OBCSET}/cgroup/tenant_1004/OBCG_DEFAULT/tasks 2>/dev/null; then
      echo $tid 2>/dev/null > ${OBCSET}/cgroup/tenant_1004/OBCG_DEFAULT/tasks
    fi
  done

  # 刷新 compaction background
  for tid in $(cat ${OBCPU}/cgroup/background/tenant_1004/OBCG_STORAGE/tasks); do
    if [ ! -f ${OBCSET}/cgroup/background/tenant_1004/OBCG_STORAGE/tasks ] || \
       ! grep -q $tid ${OBCSET}/cgroup/background/tenant_1004/OBCG_STORAGE/tasks 2>/dev/null; then
      echo $tid 2>/dev/null > ${OBCSET}/cgroup/background/tenant_1004/OBCG_STORAGE/tasks
    fi
  done

  sleep 30
done &
```

### 7.5 验证绑核效果

```bash
# 看 compaction 线程跑在哪些核上
ps -eLo pid,tid,comm,psr | grep observer | awk '{print $4}' | sort | uniq -c
# Expected: core 6-9 是 compaction, core 0-5 是 SQL

# 看 L3 cache miss 变化 (perf stat)
perf stat -e cache-misses,cache-references -p $(pidof observer) sleep 10

# 对比绑核前后的 SQL 延迟
# Before: avg_queue_time 可能很高 (CPU 争抢)
# After:  avg_queue_time 应显著下降
SELECT ROUND(AVG(QUEUE_TIME) / 1000, 1) AS avg_queue_ms,
       ROUND(AVG(ELAPSED_TIME) / 1000, 1) AS avg_elapsed_ms
FROM oceanbase.GV$OB_SQL_AUDIT
WHERE request_time > DATE_SUB(NOW(), INTERVAL 1 MINUTE);
```

### 7.6 cpuset 绑核 vs cpu.shares/quota 对比

| 机制 | 粒度 | 解决 | 不解决 | 代价 |
|------|------|------|--------|------|
| `cpu.shares` | 权重 | 时间片比例 | 满载时无保证 | 核浪费很少 |
| `cpu.cfs_quota_us` | 硬限制 | 上限保护 | 缓存争抢 | 配额内空闲不能超用 |
| **cpuset 绑核** | **物理核** | **缓存争抢** | 核利用率低 | 空闲核不能被其他组用 |

**建议组合**:

```text
cpu.shares + cpu.cfs_quota_us  → 控制时间片 (步骤三)
cpuset.cpus                    → 控制物理核 + 缓存隔离 (步骤四)

两者一起用: cpuset 保证隔离边界, cfs_quota 在边界内做精细控制
```

### 7.7 什么时候需要绑核

- **必须绑**: 10 核以下 + major merge + 高 QPS (你的场景)
- **建议绑**: 任何有 compaction 扫描 > SQL working set 的场景
- **不需要**: 纯 OLTP 点查 + 小表 (working set 全在内存)
- **不需要**: 有大量空闲 CPU (没必要牺牲弹性)

---

## 8. 步骤五：DBMS_RESOURCE_MANAGER 精细隔离

如果你要精细化到不同用户/不同 query 类型, 用资源计划。

### 7.1 创建资源计划

```sql
-- 创建计划
BEGIN
  DBMS_RESOURCE_MANAGER.CREATE_PLAN(
    PLAN    => 'PROD_PLAN',
    COMMENT => '70:30 workload - SQL high, compaction low'
  );

  -- 组 1: 在线事务 (High)
  DBMS_RESOURCE_MANAGER.CREATE_CONSUMER_GROUP(
    CONSUMER_GROUP => 'OLTP_HIGH',
    COMMENT        => 'OLTP foreground',
    MGMT_MTH       => 'cpu',
    CPU_WEIGHT     => 7
  );

  -- 组 2: 后台 + compaction (Low)
  DBMS_RESOURCE_MANAGER.CREATE_CONSUMER_GROUP(
    CONSUMER_GROUP => 'BATCH_LOW',
    COMMENT        => 'Batch/Compaction background',
    MGMT_MTH       => 'cpu',
    CPU_WEIGHT     => 3
  );
END;
/

-- 创建计划指令 (将组分配给计划)
BEGIN
  DBMS_RESOURCE_MANAGER.CREATE_PLAN_DIRECTIVE(
    PLAN              => 'PROD_PLAN',
    GROUP_OR_SUBPLAN  => 'OLTP_HIGH',
    COMMENT           => 'OLTP has 70% CPU weight',
    CPU_WEIGHT        => 7,
    MIN_IOPS          => 100,
    MAX_IOPS          => 10000,
    WEIGHT_IOPS       => 700
  );

  DBMS_RESOURCE_MANAGER.CREATE_PLAN_DIRECTIVE(
    PLAN              => 'PROD_PLAN',
    GROUP_OR_SUBPLAN  => 'BATCH_LOW',
    COMMENT           => 'Background has 30% CPU weight',
    CPU_WEIGHT        => 3,
    MIN_IOPS          => 10,
    MAX_IOPS          => 5000,
    WEIGHT_IOPS       => 300
  );
END;
/
```

### 7.2 将用户映射到组

```sql
-- 业务用户 → OLTP_HIGH
BEGIN
  DBMS_RESOURCE_MANAGER.SET_CONSUMER_GROUP(
    USER  => 'app_user',
    GROUP => 'OLTP_HIGH'
  );
END;
/

-- 只读报表 → BATCH_LOW
BEGIN
  DBMS_RESOURCE_MANAGER.SET_CONSUMER_GROUP(
    USER  => 'report_user',
    GROUP => 'BATCH_LOW'
  );
END;
/

-- 激活计划
SET GLOBAL resource_manager_plan = 'PROD_PLAN';

-- 验证
SHOW VARIABLES LIKE 'resource_manager_plan';
```

---

## 9. 步骤六：监控与验证

### 8.1 cgroup 级别监控

```bash
# 实时查看 cgroup CPU 使用
cat /sys/fs/cgroup/cpu/cgroup/background/cpuacct.usage
# vs
cat /sys/fs/cgroup/cpu/cgroup/tenant_1004/OBCG_DEFAULT/cpuacct.usage

# 看是否被 throttled (限流)
cat /sys/fs/cgroup/cpu/cgroup/background/tenant_1004/OBCG_STORAGE/cpu.stat
# nr_periods, nr_throttled, throttled_time
# nr_throttled > 0 说明 compaction 被 cgroup 限制过

# 查 cgroup 目录创建情况
find /sys/fs/cgroup/cpu/cgroup -name "tasks" -exec echo "=== {} ===" \; -exec cat {} \;
```

### 9.1 诊断 SQL

```sql
-- 1. 定位最吃 CPU 的 SQL (TOP 10)
SELECT SQL_ID, 
       ROUND(AVG(ELAPSED_TIME) / 1000, 1) AS avg_ms,
       COUNT(*) AS executions,
       ROUND(SUM(ELAPSED_TIME) / 1000000, 1) AS total_cpu_sec
FROM oceanbase.GV$OB_SQL_AUDIT
WHERE request_time > DATE_SUB(NOW(), INTERVAL 5 MINUTE)
  AND TENANT_ID = <tenant_id>
GROUP BY SQL_ID
ORDER BY total_cpu_sec DESC
LIMIT 10;

-- 2. 写入量最大的 SQL
SELECT SQL_ID, 
       ROUND(AVG(ROW_COUNT), 1) AS avg_rows,
       ROUND(AVG(ELAPSED_TIME) / 1000, 1) AS avg_ms,
       COUNT(*) AS executions
FROM oceanbase.GV$OB_SQL_AUDIT
WHERE request_time > DATE_SUB(NOW(), INTERVAL 5 MINUTE)
  AND TENANT_ID = <tenant_id>
  AND IS_EXECUTOR_RPC = 0
  AND (LOWER(QUERY_SQL) LIKE 'insert%' 
    OR LOWER(QUERY_SQL) LIKE 'update%' 
    OR LOWER(QUERY_SQL) LIKE 'delete%')
GROUP BY SQL_ID
ORDER BY executions DESC
LIMIT 10;

-- 3. 当前参数审计
SELECT NAME, VALUE FROM oceanbase.__all_tenant_parameter
WHERE NAME IN ('freeze_trigger_percentage',
               'writing_throttling_trigger_percentage',
               'memstore_limit_percentage',
               'compaction_high_thread_score',
               'compaction_mid_thread_score',
               'compaction_low_thread_score',
               'minor_merge_concurrency',
               'cpu_quota_concurrency');
```

### 9.2 OB 级别监控

```sql
-- 1. Memstore 水位
SELECT TENANT_ID,
       ROUND(ACTIVE_MEMSTORE_USED / 1024 / 1024, 1) AS active_mb,
       ROUND(TOTAL_MEMSTORE_USED / MEMSTORE_LIMIT * 100, 1) AS memstore_pct,
       ROUND(FREEZE_TRIGGER_MEMSTORE_USED / 1024 / 1024, 1) AS freeze_trigger_mb
FROM oceanbase.GV$OB_MEMSTORE;

-- 2. 是否有写限流
SELECT COUNT(*) FROM oceanbase.GV$OB_SQL_AUDIT
WHERE request_time > DATE_SUB(NOW(), INTERVAL 1 MINUTE)
  AND ret_code = -4038;

-- 3. Freeze 历史
SELECT FROM_UNIXTIME(FREEZE_TIME / 1000000) AS freeze_at,
       IS_FREEZE, RETCODE
FROM oceanbase.__all_virtual_freeze_info
ORDER BY FREEZE_TIME DESC LIMIT 5;

-- 4. cgroup 配置状态
SELECT * FROM oceanbase.GV$OB_CGROUP_CONFIG;

-- 5. Compaction 进展
SELECT * FROM oceanbase.GV$OB_COMPACTION_PROGRESS
WHERE STATUS IN ('COMPACTING', 'SCHEDULING');

-- 6. 限流详情
SELECT * FROM oceanbase.__all_virtual_memstore_throttle;

-- 7. 当前参数确认
SELECT NAME, VALUE FROM oceanbase.__all_tenant_parameter
WHERE NAME IN ('freeze_trigger_percentage',
               'writing_throttling_trigger_percentage',
               'memstore_limit_percentage',
               'compaction_high_thread_score',
               'compaction_mid_thread_score',
               'compaction_low_thread_score');
```

### 8.3 SQL 性能对比

```sql
-- 调整前后的 SQL 延迟对比
SELECT ROUND(AVG(ELAPSED_TIME) / 1000, 1) AS avg_elapsed_ms,
       ROUND(AVG(QUEUE_TIME) / 1000, 1) AS avg_queue_ms,
       ROUND(AVG(EXECUTE_TIME) / 1000, 1) AS avg_exec_ms,
       COUNT(*) AS executions,
       ROUND(SUM(ELAPSED_TIME) / 1000000, 1) AS total_cpu_sec
FROM oceanbase.GV$OB_SQL_AUDIT
WHERE request_time > DATE_SUB(NOW(), INTERVAL 5 MINUTE)
  AND TENANT_ID = 1004;
```

---

## 10. 量化分析：CPU 压榨的数学依据

### 9.1 怎么设 global_background_cpu_quota

公式:

```text
memstore_write_rate = QPS_write × avg_row_size

freeze_consume_time = memstore_limit × (throttling_pct - freeze_pct) / 100
                      ──────────────────────────────────────────────
                                  memstore_write_rate

需要的 CPU 预算:
  SQL:     必须保证的 CPU = (100% - write_pct) × total_CPU
  freeze:  需要的 CPU   = freeze_concurrency (≈4 线程)
  compaction: 剩下的    = total - SQL - freeze
```

**单租户 10 核 × 40GB 场景计算:**

```
写入占 30% QPS → SQL 至少需要 3 核
freeze flush 需要 ~2 核 (保守)
compaction 最多    = 10 - 3 - 2 = 5 核

→ global_background_cpu_quota = 5  (留给 compaction + 后台)
→ 前台 SQL 实际拿到 10 - 5 = 5 核 (含 2 核 freeze buffer)
```

**你现在是 32u 物理机, 3 个租户各 10 核:**

```text
每个租户 unit_max_cpu = 10 → 前台 cgroup 硬限制 10 核/租户
3 个租户前台并发峰值 = 30 核
物理机共 32 核

计算逻辑:
  当 3 个租户同时满载:
    总前台占用 + 总后台占用 ≤ 32
    后台(compaction 跨租户) 设 X 核
    前台可用 = 32 - X, 分 3 个租户 ≈ (32-X)/3 核/租户

  如果要每个租户的前台都接近 10 核:
    (32 - X) / 3 ≥ 10 → X ≤ 2  ← 过于保守, compaction 不够

  折中: 每个租户前台拿 ~8 核, 剩下给 compaction:
    X = 32 - 3 × 8 = 8  ← 推荐起点
```

**多租户推荐:**

```text
平衡型:  global_background_cpu_quota = 8   ← 推荐起点
         → 前台共享 24 核, 每租户 ~8 核 (接近 unit limit)
         → 后台 compaction 跨 3 个租户共享 8 核

激进型:  global_background_cpu_quota = 12
         → 前台共享 20 核, 每租户 ~6.7 核
         → compaction 更快, 但前台受限明显

保守型:  global_background_cpu_quota = 5
         → 前台共享 27 核, 每租户 ~9 核
         → compaction 受限, 可能读放大
```

**多租户的核心差异:**

单租户场景 compaction 只服务一个租户的写入。
3 个租户各 30% 写入 → compaction 负载 ×3。
所以 `global_background_cpu_quota` 不能太低 (否则 compaction 完全跟不上),
也不能太高 (否则 3 个前台 SQL 一起吃 CPU)。

**建议你先设为 8, 然后观察:**

```bash
# compaction 是否积压
SELECT * FROM oceanbase.GV$OB_COMPACTION_PROGRESS
WHERE STATUS IN ('COMPACTING', 'SCHEDULING');
# 如果积压很多 → 逐步提高到 10~12

# 前台 SQL 延迟是否可接受
SELECT ROUND(AVG(ELAPSED_TIME) / 1000, 1) AS avg_elapsed_ms
FROM oceanbase.GV$OB_SQL_AUDIT
WHERE request_time > DATE_SUB(NOW(), INTERVAL 1 MINUTE);
# 如果延迟飙升 → 降低到 6~5
```

**关于 3 个租户的类型**: 它们都是 **用户租户 (USER tenant)**。

```
oceanbase.DBA_OB_TENANTS 查到的 TENANT_TYPE:
  三个都是 'USER'  ← 那就是纯业务租户
  如果有 'META' 租户, 那是自动生成的元数据租户 (不计入你的 10 核配置)
```

sys 租户 (ID=500) 在 cgroup 中被设为 `cpu.cfs_quota = -1` (不限), 走 `cgroup/other/` 路径, 不受 `global_background_cpu_quota` 影响。

**观察指标：**

```
分配后观察:
  1. QPS 是否稳定 (不再断崖)
  2. freeze 耗时 是否从 60s 降回 30s+
  3. compaction 进度是否停滞 → 读放大是否上升

如果 compaction 停滞:
  → 调大 compaction_low_thread_score
  → 或建计划窗口: 低峰期调大 global_background_cpu_quota
```

### 9.2 为什么 CPU 还能被"压榨"

cgroup 的硬限制 (`cpu.cfs_quota_us`) 只限制 compaction 在 CPU 满载时的上限。
如果 SQL 侧没有把 CPU 吃完:

- compaction 仍然可以用剩余的 CPU 空转
- 只有 SQL 全满载时, cgroup 才会把 compaction 压下去

**这就是"弹性隔离"——平时不浪费, 争抢时保 SQL。**

---

## 11. 决策矩阵：什么时候该做什么

```
QPS 回落 + 不限流 → 仅调 freeze_trigger ✓ (层 1 足够)
限流但 CPU 没满   → 层 1 + 调高 memstore_limit
限流 + CPU 打满   → 层 1+2+3+4 (完整方案)  ← 你在这里
QPS 抖动 + cache miss 高 → 加层 4 cpuset 绑核
```

## 12. 推荐参数总结

### 集群参数

| 参数 | 推荐值 | 生效方式 | 说明 |
|------|--------|---------|------|
| `enable_cgroup` | True | DYNAMIC | 默认就是 True |
| `enable_global_background_resource_isolation` | True | **需要重启** | 开启后台隔离 |
| `global_background_cpu_quota` | 8 | DYNAMIC | 32u 物理机, 3×10 核租户 (从 8 开始调) |
| `writing_throttling_trigger_percentage` | 100 | DYNAMIC | 放开限流 |

### 租户参数

| 参数 | 推荐值 | 说明 |
|------|--------|------|
| `memstore_limit_percentage` | 75 | 30% 写入需要大 memstore |
| `freeze_trigger_percentage` | 50 | 提前触发, 留 buffer |
| `compaction_high_thread_score` | 6 | Mini Merge (保持) |
| `compaction_mid_thread_score` | 4 | Minor Merge (降低) |
| `compaction_low_thread_score` | 2 | Major (大幅降低) |
| `resource_manager_plan` | PROD_PLAN | 可选精细隔离 |

### 部署后验证 checklist

- [ ] `cat /sys/fs/cgroup/cpu/cgroup/background/cpu.cfs_quota_us` = 预期
- [ ] SQL CPU 使用维持在预期范围内 (pidstat -p <observer_pid> 1)
- [ ] `GV$OB_SQL_AUDIT` 中 `ret_code = -4038` 归零
- [ ] freeze 耗时 < 30s
- [ ] QPS 不再断崖下降

---

## 参考文献

- `25-memory-management-analysis.md` — 内存管理, ObMemAttr, 租户内存隔离
- `06-memtable-freezer-analysis.md` — freeze 机制, ready_for_flush 条件
- `34-sstable-merge-analysis.md` — Mini/Minor/Major/Medium 合并路径
- `51-block-cache-analysis.md` — 缓存体系, Row Cache / Bloom Filter / Micro Block Cache
- `58-thread-model-analysis.md` — 线程池, TGMgr, NUMA 感知
- `ob_cgroup_ctrl.cpp` — cgroup 控制: init, add_thread_to_cgroup_, get_group_path
- `ob_resource_plan_manager.cpp` — 资源计划刷新, background CPU 隔离
- `ob_tenant_dag_scheduler.cpp` — DAG 调度, function_type, CONSUMER_GROUP_FUNC_GUARD
- `ob_affinity_ctrl.h` — OB NUMA 亲和性控制, thread_bind_to_node, memory_bind_to_node
- `ob_cgroup_ctrl.cpp` — get_group_path, cgroup 目录层级 (foreground/background 分离)
- Linux cgroup v1 cpuset — `/sys/fs/cgroup/cpuset/cpuset.cpus` 物理核绑定
