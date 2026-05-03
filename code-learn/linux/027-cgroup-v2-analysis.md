# 27-cgroup-v2 — Linux 控制组 v2 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**cgroup（Control Group）** 是 Linux 内核的资源隔离和管理机制。它将进程分组并统一管理各组对 CPU、内存、IO 等资源的使用。cgroup v2（自 Linux 4.5 稳定）统一了层次结构，改进了接口一致性。

**doom-lsp 确认**：核心实现在 `kernel/cgroup/cgroup.c`。`struct cgroup` 在 `include/linux/cgroup-defs.h`。关键控制器有 `cpu`、`memory`、`io`、`pids` 等。

---

## 1. cgroup v2 vs v1

| 特性 | v1 | v2 |
|------|----|----|
| 层次结构 | 每控制器独立树 | 单一统一树 |
| 线程模式 | 仅进程 | 进程 + 线程 |
| 内部进程 | 允许 | 禁止（非叶子节点不能有进程）|
| 控制器管理 | 自动挂载 | cgroup.controllers 动态控制 |

---

## 2. 核心数据结构

```c
// include/linux/cgroup-defs.h:474
struct cgroup {
    struct cgroup_subsys_state self;       // self css with NULL ->ss
    unsigned long flags;                   // CGRP_* 状态标志
    int level;                             // 层次深度
    struct kernfs_node *kn;                // sysfs 文件系统节点
    struct cgroup_file procs_file;         // cgroup.procs 接口文件
    struct cgroup_file events_file;        // cgroup.events 接口文件
    struct cgroup_file psi_files[NR_PSI_RESOURCES]; // psi 压力指标文件
    u32 subtree_control;                   // 子 cgroup 启用控制器
    struct cgroup_subsys_state __rcu *subsys[CGROUP_SUBSYS_COUNT];
    struct cgroup_root *root;
    struct list_head cset_links;
    struct list_head e_csets[CGROUP_SUBSYS_COUNT];
};

// include/linux/cgroup-defs.h:181
struct cgroup_subsys_state {
    struct cgroup *cgroup;                // 所属 cgroup
    struct cgroup_subsys *ss;             // 所属子系统（控制器）
    struct percpu_ref refcnt;
    struct css_rstat_cpu __percpu *rstat_cpu; // per-CPU rstat 数据
    struct list_head sibling;
    struct list_head children;
    int id;
    unsigned int flags;
};

// include/linux/cgroup-defs.h:777
struct cgroup_subsys {
    struct cgroup_subsys_state *(*css_alloc)(struct cgroup_subsys_state *);
    int (*css_online)(struct cgroup_subsys_state *);
    void (*css_offline)(struct cgroup_subsys_state *);
    void (*css_free)(struct cgroup_subsys_state *);
    bool early_init;
    int id;
    const char *name;  // cpu, memory, io, pids, cpuset
};
```

---

## 3. 控制器详解

### 3.1 CPU 控制器

限制和权重分配 CPU 时间：

```
/sys/fs/cgroup/mygroup/
├── cpu.weight        # 权重 1-10000（相对分配）
├── cpu.max           # 配额：max $period
│                     # "100000 100000" = 1 核
│                     # "50000 100000"  = 0.5 核
├── cpu.stat          # 使用统计
└── cpu.pressure      # 压力指标
```

实现：CFS 调度器通过 `task_group` 结构实现 cgroup 的 CPU 带宽控制。`cpu.max` 使用 `cfs_bandwidth` 机制——每个周期 `cfs_period_us` 内最多使用 `cfs_quota_us` 时间。

### 3.2 Memory 控制器

限制内存使用上限和保障：

```
/sys/fs/cgroup/mygroup/
├── memory.max         # 硬上限（OOM 触发）
├── memory.high        # 软上限（触发回收）
├── memory.current     # 当前使用量
├── memory.min         # 硬保障
├── memory.low         # 软保障
├── memory.swap.max    # swap 上限
├── memory.stat        # 详细统计
└── memory.pressure    # 压力指标
```

实现：`mem_cgroup` 结构记录每 cgroup 的内存使用。通过 `page_counter` 跟踪上限。缺页路径中检查 `memcg->memory.max`，超出则触发回收或 OOM。

### 3.3 IO 控制器

限制块设备 I/O 带宽：

```
/sys/fs/cgroup/mygroup/
├── io.max            # 8:16 rbps=1000000 wbps=500000
├── io.weight         # 权重
├── io.stat
└── io.pressure
```

实现：blk-throttle 驱动（`block/blk-throttle.c`），在 `blk_mq_submit_bio` 路径中对 BIO 进行限速。

### 3.4 PIDs 控制器

限制进程数：

```
/sys/fs/cgroup/mygroup/
└── pids.max
```

### 3.5 cpuset 控制器

绑定 CPU 和内存节点：

```
/sys/fs/cgroup/mygroup/
├── cpuset.cpus        # 允许的 CPU
└── cpuset.mems        # 允许的内存节点
```

---

## 4. 核心操作

### 4.1 创建和加入

```bash
# 创建控制组
mkdir /sys/fs/cgroup/my_cgroup

# 移动进程到 cgroup
echo 1234 > /sys/fs/cgroup/my_cgroup/cgroup.procs

# 移动线程到 cgroup
echo 1234 > /sys/fs/cgroup/my_cgroup/cgroup.threads

# 查看控制器
cat /sys/fs/cgroup/my_cgroup/cgroup.controllers
cat /sys/fs/cgroup/my_cgroup/cgroup.subtree_control
```

### 4.2 接口文件

| 文件 | 作用 | 示例 |
|------|------|------|
| cgroup.procs | 进程列表（写=加入） | echo $$ > cgroup.procs |
| cgroup.threads | 线程列表 | echo $tid > cgroup.threads |
| cgroup.controllers | 可用控制器 | cpu memory io |
| cgroup.subtree_control | 子 cgroup 启用的控制器 | +cpu +memory |
| cgroup.type | 类型 | domain / threaded |

---

## 5. 线程模式

cgroup v2 支持两种线程模式：

| 模式 | cgroup.type | 说明 |
|------|------------|------|
| domain | domain | 标准模式，进程级资源控制 |
| threaded | threaded | 线程级资源控制，子 cgroup 可包含线程 |

```bash
# 将 cgroup 标记为 threaded
echo threaded > /sys/fs/cgroup/my_cgroup/cgroup.type
```

---

## 6. 内部进程约束

```
v2 核心规则：只有叶子 cgroup 可以包含进程。
非叶子节点只能有子 cgroup，不能有进程。

合法结构：
  /sys/fs/cgroup/          ← 无进程（根）
    ├── system.slice/      ← 无进程
    │   ├── sshd.service/  ← 有进程 ✅
    │   └── httpd.service/ ← 有进程 ✅
    └── user.slice/        ← 无进程
        └── user-1000.slice/ ← 有进程 ✅
```

---

## 7. 内核实现——进程迁移

进程移入 cgroup 时内核的处理：

```
echo 1234 > /sys/fs/cgroup/my_cgroup/cgroup.procs
  → cgroup_file_write → cgroup_procs_write
    → cgroup_attach_task(cgrp, task, threadgroup)
      → cgroup_migrate(dst_cgrp, task, threadgroup)
        → for each 控制器：
             ss->css_online(css)  ← 通知控制器
        → 将 task 加入 dst_cgrp 的链表
        → 检查资源限制（pids 控制器计数）
```

---

## 8. 源码文件索引

| 文件 | 内容 |
|------|------|
| `kernel/cgroup/cgroup.c` | cgroup 核心框架 |
| `kernel/cgroup/rstat.c` | per-CPU 资源统计 |
| `kernel/cgroup/cpuset.c` | cpuset 控制器 |
| `mm/memcontrol.c` | memory 控制器 |
| `block/blk-throttle.c` | IO 控制器 |
| `kernel/cgroup/pids.c` | pids 控制器 |
| `kernel/sched/core.c` | CPU 控制器 |
| `include/linux/cgroup.h` | API 声明 |
| `include/linux/cgroup-defs.h` | 核心结构体 |

---

## 9. 关联文章

- **135-cgroup-v1-v2**：v1 vs v2 详细对比
- **136-memcg**：memory cgroup 深度分析
- **37-CFS调度器**：CPU 控制器的 CFS 实现

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 10. 资源统计（rstat）

cgroup v2 使用 per-CPU 统计避免锁竞争：

```c
// kernel/cgroup/rstat.c (Linux 7.0-rc1 改用 css 级别的 API)
void css_rstat_updated(struct cgroup_subsys_state *css, int cpu);
// 标记某 CPU 的 css 统计已更新（replaces cgroup_rstat_updated）

void css_rstat_flush(struct cgroup_subsys_state *css);
// 刷新所有 CPU 的统计到全局值（replaces cgroup_rstat_flush）

static void cgroup_base_stat_flush(struct cgroup *cgrp, int cpu);
// 带锁的 flush（遍历 cgroup 树）
```

**读取统计的流程**：
```
cat memory.current
  → mem_cgroup_read_stat(memcg, MEMCG_RSS)
    → for_each_possible_cpu(cpu):
        val += per_cpu_ptr(memcg->vmstats, cpu)->stat[idx]
    → 返回汇总值
```

---

## 11. 压力指标（PSI）

每个 cgroup 暴露三个压力指标文件：

| 文件 | 监控资源 |
|------|---------|
| cpu.pressure | CPU 平均负载 |
| memory.pressure | 内存回收等待 |
| io.pressure | 块设备 IO 等待 |

```bash
$ cat /sys/fs/cgroup/mygroup/cpu.pressure
some avg10=2.34 avg60=1.56 avg300=0.78 total=123456
full avg10=1.23 avg60=0.89 avg300=0.45 total=98765
```

- `some`：至少有一个线程在等待该资源
- `full`：所有线程都在等待该资源
- `avg10/60/300`：过去 10/60/300 秒的平均等待比例

---

## 12. 使用示例——限制一个程序的资源

```bash
#!/bin/bash
# 创建分组
CG=/sys/fs/cgroup/myapp
mkdir -p $CG

# 限制 CPU 为 0.5 核
echo "50000 100000" > $CG/cpu.max

# 限制内存 100MB
echo 100000000 > $CG/memory.max

# 限制 IO 带宽
echo "8:0 rbps=1000000 wbps=500000" > $CG/io.max

# 启动程序
./my_program &
echo $! > $CG/cgroup.procs
```

---

## 13. 总结

cgroup v2 提供了统一的资源控制框架。单一层次树简化了管理，per-CPU 统计保证了大规模场景的性能，psi 压力指标提供了资源竞争的可见性。内核中的每个控制器（cpu/memory/io/pids/cpuset）通过 `cgroup_subsys` 接口集成到框架中。


## 14. cgroup 与调度器集成——CPU 带宽控制

cgroup v2 的 CPU 控制实现依赖 CFS 调度器的带宽控制机制：

### 14.1 数据结构

```c
// kernel/sched/sched.h
struct cfs_bandwidth {
    ktime_t             period;          // 周期（默认 100ms）
    u64                 quota;           // 每周期配额（默认无限制）
    s64                 hierarchical_quota; // 树形配额
    u64                 runtime;         // 当前周期已用时间
    s64                 hierarchical_runtime;
    struct hrtimer      period_timer;    // 周期定时器
    struct hrtimer      slack_timer;     // 松弛定时器
    struct list_head    throttled_cfs_rq; // 被限制的 cfs_rq 队列
    int                 nr_periods;      // 统计
    int                 nr_throttled;    // 被限制次数
};
```

### 14.2 带宽控制流程

```
更新线程 vruntime 时（update_curr）：
  │
  ├─ if (cfs_bandwidth_used()) {
  │      cfs_rq->runtime_remaining -= delta_exec;
  │      if (cfs_rq->runtime_remaining <= 0) {
  │          // 配额用尽！限制此 cfs_rq
  │          throttle_cfs_rq(cfs_rq);
  │          // → cfs_rq 被移出运行队列
  │          // → 此 cgroup 的所有线程停止运行
  │      }
  │   }
  │
  └─ 下一个周期开始（period_timer 回调）：
       refill_cfs_bandwidth_runtime(cfs_rq);
       // → cfs_rq->runtime_remaining += quota
       // → unthrottle_cfs_rq(cfs_rq)
       // → cfs_rq 重新加入运行队列
       // → 线程恢复运行
```

### 14.3 权重分配

```c
// cpu.weight (1-10000) 决定 cgroup 间的 CPU 分配比例
// 内核转换为 CFS 调度权重：
// weight = clamp_t(int, 1 + (cgroup_weight - 1) * 1024 / 10000, 1, 10000)

// 例：
// cgroup A: cpu.weight = 2048
// cgroup B: cpu.weight = 1024
// → A 获得 2/3 的 CPU 时间
// → B 获得 1/3 的 CPU 时间
```

---

## 15. cgroup 与内存回收

memory cgroup 在内存不足时的回收流程：

```
内存分配时检查 memcg->memory.max：
  │
  ├─ try_charge(memcg, gfp_mask, nr_pages)
  │   │
  │   ├─ page_counter_try_charge(&memcg->memory, nr_pages, &counter)
  │   │   如果成功 → 分配内存
  │   │
  │   ├─ 如果超出 memory.max：
  │   │   try_to_free_mem_cgroup_pages(memcg, nr_pages, gfp_mask, ...)
  │   │   → 只在当前 cgroup 内部回收页面
  │   │   → 不回收其他 cgroup 的页面！
  │   │
  │   └─ 如果回收后仍然超出：
  │       mem_cgroup_out_of_memory(memcg, gfp_mask, order)
  │       → 只杀死当前 cgroup 内的进程（container OOM）
  │       → 不影响其他 cgroup！
  │
  └─ memory.high（软上限）：
      触发异步回收，不阻塞分配进程
```

**关键特性**：cgroup 的内存隔离确保一个 cgroup 的 OOM 不会影响其他 cgroup。

---

## 16. 与 cgroup v1 的关键差异

| 特性 | v1 | v2 |
|------|----|----|
| 树结构 | 多树（每控制器独立） | 单树 |
| 线程支持 | 仅进程 | 进程 + 线程 |
| 内部进程 | 允许 | 禁止（leaf-only）|
| 控制器启用 | 自动 | cgroup.subtree_control |
| cpu 控制器 | cpu.cfs_quota_us | cpu.max |
| memory 控制器 | memory.limit_in_bytes | memory.max |
| io 控制器 | blkio.throttle.* | io.max |
| cgroup.controllers | 无 | 列出可用控制器 |
| cgroup.type | 无 | domain/threaded |

---

## 17. 性能影响

| 场景 | 延迟影响 | 说明 |
|------|---------|------|
| 无 cgroup | 0 | 不启用控制器时无影响 |
| memory cgroup | ~5-10ns/分配 | page_counter 检查 |
| cpu cgroup | ~1-5ns/调度 | tg_weight 计算 |
| io cgroup | ~10-50ns/BIO | blk-throttle 检查 |
| 大量 cgroup（>1000）| ~5-10% | 调度器遍历开销 |

---

## 18. 调试命令

```bash
# 查看 cgroup 层次
$ ls /sys/fs/cgroup/
cgroup.controllers  cgroup.subtree_control  system.slice/  user.slice/

# 查看当前进程所在 cgroup
$ cat /proc/self/cgroup
0::/system.slice/sshd.service

# 查看 cgroup 的内存使用
$ cat /sys/fs/cgroup/system.slice/memory.current
123456789

# 查看 cgroup 的 CPU 使用
$ cat /sys/fs/cgroup/system.slice/cpu.stat
usage_usec 123456789
user_usec 100000000
system_usec 23456789
```


## 19. 嵌套与控制器的继承

```
/sys/fs/cgroup/
├── cgroup.subtree_control = "+cpu +memory"
│
├── system.slice/ ← 继承 cpu + memory
│   ├── cgroup.subtree_control = "+io"
│   │
│   ├── sshd.service/ ← 继承 cpu + memory + io
│   │
│   └── httpd.service/ ← 继承 cpu + memory + io
│
└── user.slice/ ← 继承 cpu + memory
```

- 子 cgroup 继承父 cgroup 的控制器
- 父 cgroup 的 `cgroup.subtree_control` 控制子 cgroup 可用的控制器
- `cgroup.controllers` 列出当前 cgroup 实际激活的控制器

---

## 20. 冻结（cgroup.freeze）

```bash
# 冻结 cgroup 中的所有进程
echo 1 > /sys/fs/cgroup/mygroup/cgroup.freeze
# → 所有进程变为 TASK_FROZEN 状态
# → 不会被调度运行

# 解冻
echo 0 > /sys/fs/cgroup/mygroup/cgroup.freeze
# → 进程恢复运行
```

用于容器暂停、系统快照等场景。

---

## 21. 源码文件索引

| 文件 | 作用 |
|------|------|
| kernel/cgroup/cgroup.c | cgroup 核心框架（5000+ 行）|
| kernel/cgroup/rstat.c | per-CPU 资源统计 |
| kernel/cgroup/cpuset.c | cpuset 控制器 |
| mm/memcontrol.c | memory 控制器（8000+ 行）|
| block/blk-throttle.c | IO 控制器 |
| kernel/sched/core.c | CPU 控制器 |
| kernel/cgroup/pids.c | pids 控制器 |
| include/linux/cgroup-defs.h | 核心结构体定义 |

---
---

## 22. 参考文章

- **135-cgroup-v1-v2**：v1 vs v2 完整对比
- **136-memcg**：memory cgroup 深度分析
- **37-CFS调度器**：CPU 控制器的 CFS 实现

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 日常使用命令集

```bash
# 查看当前 shell 所在 cgroup
cat /proc/self/cgroup

# 递归查看 cgroup 树
find /sys/fs/cgroup -name cgroup.procs -exec sh -c 'echo "$1:"; cat "$1"' _ {} \;

# 统计每个 cgroup 的进程数
for d in /sys/fs/cgroup/*/; do
    count=$(cat "$d/cgroup.procs" 2>/dev/null | wc -l)
    echo "$(basename $d): $count processes"
done

# 实时监控 cgroup 内存使用
watch -n1 'cat /sys/fs/cgroup/system.slice/memory.current'

# 创建临时 cgroup 限制命令
mkdir -p /sys/fs/cgroup/temp
echo "50000 100000" > /sys/fs/cgroup/temp/cpu.max
echo $$ > /sys/fs/cgroup/temp/cgroup.procs
stress --cpu 4 --timeout 10
echo $$ > /sys/fs/cgroup/cgroup.procs
rmdir /sys/fs/cgroup/temp
```
