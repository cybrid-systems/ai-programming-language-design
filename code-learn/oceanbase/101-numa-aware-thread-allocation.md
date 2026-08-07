# 101-numa-aware-thread — OceanBase NUMA-Aware 线程分配深度源码分析

> 基于 OceanBase 主线源码 (commit `f2e437ea62` 之后)
> 源码锚点:`deps/oblib/src/lib/resource/ob_affinity_ctrl.{h,cpp}` + `deps/oblib/src/lib/thread/{thread,threads}.{h,cpp}` + `src/observer/omt/ob_th_worker.cpp` + `src/observer/omt/ob_tenant.cpp` + `src/observer/ob_srv_network_frame.cpp` + `src/observer/ob_server.cpp`
> 使用 doom-lsp (clangd LSP) 做符号解析与数据流追踪

---

## 0. 全文导读

接续 #25 (内存管理) 和 #74 (线程模型),OceanBase 在多 NUMA 系统上的**线程分配**由三个抽象协同完成:

| 抽象 | 职责 | 关键 API |
|------|------|---------|
| `ObAffinityCtrl` | NUMA 拓扑发现 + 系统调用封装 | `init` / `thread_bind_to_node` / `run_on_node` |
| `Threads::NumaInfo` | TG 级别的 NUMA hint 状态 | `numa_node_` / `num_nodes_` / `interleave_` |
| `ObNumaNodeGuard` | 线程入口期的 NUMA 上下文保存 | RAII save/restore |

OB 的 NUMA-aware 策略核心是**全链路零跨 NUMA**:

```
MySQL 协议层 → NUMA_X 的 net thread → NUMA_X 的 request queue
   → NUMA_X 的 worker thread → memtable / row cache / sql arena (都在 NUMA_X)
```

### 内容地图

1. **拓扑检测** — ObAffinityCtrl::init 读 `/sys/devices/system/node/` + offline CPU 校验
2. **CPU 亲和度** — `sched_setaffinity` 调用与 TLS 状态 (`get_tls_node`)
3. **RAII guard** — `ObNumaNodeGuard` 在线程入口期记录原 NUMA
4. **TG hint** — `Threads::set_numa_info(group_index)` 决定 TG 绑单 NUMA 还是 interleave
5. **实际绑核** — `Thread::run` 调 `AFFINITY_CTRL.thread_bind_to_node`
6. **Worker** — `ObThWorker::set_numa_info` 注入 NUMA hint
7. **Tenant 维度** — `min/max_worker_cnt` `upper_align(num_nodes)`
8. **网络维度** — `net_thread_count` `upper_align(num_nodes)`
9. **Request queue** — 每 NUMA 一个 request queue
10. **总开关** — `_enable_numa_aware` + `AFFINITY_CTRL.init`

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| #25 内存管理 | `get_numa_id()` 是 ObMallocAllocator 的 NUMA 维度来源, 本篇是它的镜像 |
| #28 Resource / Unit / Tenant | tenant × NUMA 是资源矩阵的二维 |
| #35 SQL Engine Entry | net thread count upper_align 在 SQL engine 启动链 |
| #71 CGroup Resource Isolation | CGroup 隔离 CPU 时间片, NUMA 隔离跨 socket 流量 — 正交 |
| #74 Thread Model | TG / Threads / Worker 抽象基础, 本篇是其 NUMA 维度扩展 |
| #102 (下一篇) | thread 绑 NUMA, memory 也绑 NUMA — 全链路零跨 NUMA |

---

## 1. 背景 / 概念

### 1.1 NUMA 拓扑与延迟

在多 socket 服务器上, 内存访问不是 uniform 的:

```
node 0 ──┐                ┌── node 1
│        │   QPI/UPI      │        │
CPU0..3  ├────────────────┤  CPU4..7
│        │   ~140-200 ns  │        │
DDR0 ────┘                └── DDR1

本地访问: ~100 ns (LLC miss 走 DDR)
跨 node:  ~140-200 ns (走 QPI)
```

跨 NUMA 不只慢, 还**共享 QPI 带宽** — 一个 socket 上的跨 NUMA 流量会和另一个 socket 的争抢。

### 1.2 OB 的策略分层

| 层 | 决策 | 关键函数 |
|----|------|---------|
| **进程级** | 是否启用 NUMA-aware | `_enable_numa_aware` (default false) |
| **TG 级** | TG 内的 thread 绑哪个 NUMA | `Threads::set_numa_info(group_index)` |
| **Worker 级** | 每 worker 的实际 hint | `ObThWorker::set_numa_info(tenant_id, enable, group_index)` |
| **线程入口级** | `pthread_create` 后第一次 bind | `Thread::run` + `ObNumaNodeGuard` |
| **运行时级** | tenant 的 worker 数能否覆盖所有 NUMA | `min/max_worker_cnt upper_align(num_nodes)` |
| **网络级** | net thread 能否覆盖所有 NUMA | `net_thread_count upper_align(num_nodes)` |

### 1.3 默认值与开关

| 参数 | 默认 | 含义 |
|------|------|------|
| `_enable_numa_aware` | `false` | 全局开关 |
| `strict_check_os_params` | `true` | offline CPU 时是否 abort |
| `OB_NUMA_SHARED_INDEX` | `-1` | 共享路径 (不绑 NUMA) |
| `OB_MAX_NUMA_NUM` | `8` | 最大支持 NUMA 数 (硬编码) |
| `OB_ALL_NUMA_NODEMASK` | `(1<<OB_MAX_NUMA_NUM)-1` | 全 NUMA mask |

---

## 2. 实现细节

### 2.1 ObAffinityCtrl::init 拓扑发现

[`deps/oblib/src/lib/resource/ob_affinity_ctrl.cpp:88-150`](deps/oblib/src/lib/resource/ob_affinity_ctrl.cpp):

```cpp
int ObAffinityCtrl::init(const bool strict_check_os_params)
{
  int ret = OB_SUCCESS;

  // 1. 检查 offline CPU — sched_setaffinity 在有 offline CPU 时行为诡异
  if (OB_FAIL(check_all_cpu_online())) { ... }

  // 2. 枚举 /sys/devices/system/node/nodeN/ 算出 num_nodes
  dir = opendir("/sys/devices/system/node");
  while ((de = readdir(dir)) != NULL) {
    if (strncmp(de->d_name, "node", 4) == 0) {
      node_idx = strtoul(de->d_name + 4, NULL, 0);
      if (num_nodes_ < node_idx) num_nodes_ = node_idx;
    }
  }
  num_nodes_ += 1;

  // 3. 每 node 读 /sys/devices/system/node/nodeN/cpuM symlink → CPU 集合
  for (int node = 0; node < num_nodes_; node++) {
    snprintf(path, ..., "/sys/devices/system/node/node%d", node);
    CPU_ZERO(&nodes_[node].cpu_set_mask);
    while ((de = readdir(node_dir))) {
      if (DT_LNK == de->d_type && strncmp(de->d_name, "cpu", 3) == 0) {
        sscanf(de->d_name + 3, "%d", &cpu);
        CPU_SET(cpu, &nodes_[node].cpu_set_mask);
      }
    }
  }

  // 4. 失败时若 !strict_check_os_params, 则 inited_=false, 后续 no-op (而非 abort)
  if (ret != OB_SUCCESS && !strict_check_os_params) {
    inited_ = false;
    ret = OB_SUCCESS;
  }
}
```

**offline CPU 检测细节** ([`check_all_cpu_online`](deps/oblib/src/lib/resource/ob_affinity_ctrl.cpp:23-72)):

```cpp
FILE *online_file = fopen("/sys/devices/system/cpu/online", "r");
FILE *possible_file = fopen("/sys/devices/system/cpu/possible", "r");
// 对比两个文件内容, 不一致 → 有 offline CPU
// → "AFFINITY_CTRL doesn't support environments with offline CPUs,
//    please consider disable the _enable_numa_aware option"
```

### 2.2 sched_setaffinity 与 TLS 状态

[`ob_affinity_ctrl.cpp:163-186`](deps/oblib/src/lib/resource/ob_affinity_ctrl.cpp):

```cpp
int ObAffinityCtrl::run_on_node(const int node) {
  if (!inited_ || node >= num_nodes_ || node < 0) return OB_INVALID_ARGUMENT;
  if (-1 == ::sched_setaffinity(0, sizeof(cpu_set_t), &nodes_[node].cpu_set_mask)) {
    return OB_ERR_UNEXPECTED;
  }
  get_tls_node() = node;   // ← TLS 记录当前位置
  return OB_SUCCESS;
}

int ObAffinityCtrl::thread_bind_to_node(const int node_hint) {
  // hint 是逻辑 ID (group_index), 取模映射到物理 NUMA
  int to_bind_node = node_hint % num_nodes_;
  return run_on_node(to_bind_node);
}
```

**`sched_setaffinity(0, ...)` 第一个参数 0** 表示**当前 thread** (不是 pid, 是 LWP / tid)。

[`ob_affinity_ctrl.h:43-52`](deps/oblib/src/lib/resource/ob_affinity_ctrl.h):

```cpp
static int &get_tls_node() {
  static thread_local int node_ = OB_NUMA_SHARED_INDEX;  // 每个 thread 独立初始值
  return node_;
}

int32_t get_numa_id() {
  int32_t numa_id = 0;
  if (inited_) {
    numa_id = get_tls_node();
    if (OB_NUMA_SHARED_INDEX == numa_id) {
      numa_id = GETTID() % num_nodes_;   // TLS 未设 → fallback
    }
  }
  return numa_id;
}
```

**关键**: `get_numa_id()` 是 **OB 所有内存分配器获取 NUMA hint 的统一入口** (`ob_malloc_allocator.cpp:117`), 零 syscall, 仅 TLS 读取。

### 2.3 ObNumaNodeGuard RAII

[`ob_affinity_ctrl.h:62-73`](deps/oblib/src/lib/resource/ob_affinity_ctrl.h):

```cpp
class ObNumaNodeGuard {
public:
  explicit ObNumaNodeGuard(int numa_node)
    : prev_numa_node_(ObAffinityCtrl::get_tls_node()) {
    ObAffinityCtrl::get_tls_node() = numa_node;
  }
  ~ObNumaNodeGuard() {
    ObAffinityCtrl::get_tls_node() = prev_numa_node_;
  }
};
```

⚠️ 注意: 只保存/恢复 **TLS 变量**, **不**保存/恢复 `sched_setaffinity` — 真正的 CPU 亲和度已经设置了, 不能 rollback。

调用位置 [`thread.cpp:128-131`](deps/oblib/src/lib/thread/thread.cpp):

```cpp
int Thread::start() {
  ...
  ObNumaNodeGuard numa_guard(numa_node_);   // ← entry-time TLS 记录
  ...
  pthread_create(&pth_, &attr, __th_start, this);  // 子线程继承 TLS
}
```

这里 `ObNumaNodeGuard` 在**主线程**(创建者) 上设 TLS, 然后 `pthread_create` 出来的子线程会继承这个 TLS 变量。

### 2.4 Threads::NumaInfo 与 set_numa_info

[`threads.h:74-85`](deps/oblib/src/lib/thread/threads.h):

```cpp
struct NumaInfo {
  NumaInfo()
    : numa_node_(OB_NUMA_SHARED_INDEX),   // 默认 shared (-1)
      num_nodes_(UINT32_MAX),
      interleave_(false) {}
  ~NumaInfo() {
    numa_node_ = OB_NUMA_SHARED_INDEX;
    interleave_ = false;
    num_nodes_ = UINT32_MAX;
  }
  int32_t  numa_node_;     // 目标 NUMA node hint
  uint32_t num_nodes_;     // 系统 NUMA node 数量
  bool     interleave_;    // 是否 round-robin
};
```

[`threads.cpp:313-330`](deps/oblib/src/lib/thread/threads.cpp):

```cpp
void Threads::set_numa_info(uint64_t tenant_id, bool enable_numa_aware,
                            int32_t group_index) {
  UNUSED(tenant_id);
  if (false == enable_numa_aware) {
    // 不开 NUMA-aware, numa_info_ 保持 default (OB_NUMA_SHARED_INDEX)
  } else {
    int num_nodes = AFFINITY_CTRL.get_num_nodes();
    if (num_nodes > 0) {
      if (group_index != -1) {
        if (group_index >= 0 && group_index < INT32_MAX) {
          // Case A: 单一 NUMA hint, TG 内第 group_index 个 worker 绑 NUMA (group_index % N)
          numa_info_.numa_node_  = group_index % num_nodes;
          numa_info_.num_nodes_ = num_nodes;
          numa_info_.interleave_ = false;
        } else {
          // Case B: group_index == INT32_MAX → 强制 interleave 模式
          numa_info_.num_nodes_ = num_nodes;
          numa_info_.numa_node_ = INT32_MAX;
          numa_info_.interleave_ = true;
        }
      }
    }
  }
}
```

**三种 mode** 决策表:

| `enable_numa_aware` | `group_index` | `numa_info_.numa_node_` | `interleave_` | 行为 |
|:-:|:-:|:-:|:-:|---|
| `false` | any | `OB_NUMA_SHARED_INDEX` (-1) | `false` | 所有 thread 走 shared, 不绑 NUMA |
| `true` | `[-1, INT32_MAX)` | `group_index % num_nodes` | `false` | 单一 NUMA, group 内 thread 全绑该 NUMA |
| `true` | `INT32_MAX` | `INT32_MAX` | `true` | 强制 interleave, 每个 thread round-robin |

### 2.5 Threads::do_set_thread_count 实际 NUMA 分配

[`threads.cpp:57-66`](deps/oblib/src/lib/thread/threads.cpp) (扩增线程时):

```cpp
for (auto i = n_threads_; i < n_threads; i++) {
  int32_t numa_node = OB_NUMA_SHARED_INDEX;
  if (OB_NUMA_SHARED_INDEX != numa_info_.numa_node_) {       // ← 单一 NUMA 或 interleave 都 != -1
    if (numa_info_.interleave_) {
      numa_node = i % numa_info_.num_nodes_;                // interleave: round-robin
    } else {
      numa_node = numa_info_.numa_node_;                    // 单一 NUMA
    }
  }
  ret = create_thread(thread, i, numa_node);
}
```

[`threads.cpp:211-218`](deps/oblib/src/lib/thread/threads.cpp) (start 时初始分配):

```cpp
for (int64_t i = 0; i < init_threads_; i++) {
  int32_t numa_node = OB_NUMA_SHARED_INDEX;
  if (OB_NUMA_SHARED_INDEX != numa_info_.numa_node_) {
    numa_node = numa_info_.interleave_ ? (i % numa_info_.num_nodes_)
                                       : numa_info_.numa_node_;
  }
  create_thread(threads_[i], i, numa_node);
}
```

**`OB_NUMA_SHARED_INDEX != numa_info_.numa_node_` 这个判断**很重要:
- `numa_node_ == -1` (默认) → 跳过, `numa_node = -1`
- `numa_node_ == INT32_MAX` (interleave) → 进入分支
- `numa_node_ >= 0` (单一 NUMA) → 进入分支

`create_thread(thread, i, numa_node)` 把 `numa_node` 传给 `Thread` 构造器, 存在 `Thread::numa_node_`。

### 2.6 Thread::run 实际绑核

[`thread.cpp:161-169`](deps/oblib/src/lib/thread/thread.cpp):

```cpp
void Thread::run() {
  if (OB_NUMA_SHARED_INDEX != numa_node_) {
    AFFINITY_CTRL.thread_bind_to_node(numa_node_);   // ← 真正执行 sched_setaffinity
  }
  IRunWrapper *run_wrapper_ = threads_->get_run_wrapper();
  if (OB_NOT_NULL(run_wrapper_)) {
    ObDisableDiagnoseGuard disable_guard;
    run_wrapper_->pre_run();
    threads_->run(idx_);
    run_wrapper_->end_run();
  } else {
    threads_->run(idx_);
  }
}
```

只有 `numa_node_ != OB_NUMA_SHARED_INDEX` 时才真正调 syscall, 否则由内核默认调度。

### 2.7 Worker::set_numa_info 调用点

[`src/observer/omt/ob_th_worker.cpp:48-57`](src/observer/omt/ob_th_worker.cpp):

```cpp
} else if (OB_FAIL(worker->init())) {
  ...
} else {
  worker->reset();
  worker->set_tenant(tenant);
  worker->set_group_id_(group_id);
  worker->set_worker_level(level);
  worker->set_group(group);
  worker->set_numa_info(tenant->id(), GCONF._enable_numa_aware, group_index);
  ...
}
```

`group_index` 是 worker 在当前 TG 内的 index (从 0 开始), 所以同一个 TG 的 worker 自然 round-robin 到不同 NUMA — 无需额外 round-robin 调度。

### 2.8 Tenant: min/max worker count upper_align

[`src/observer/omt/ob_tenant.cpp:1443-1462`](src/observer/omt/ob_tenant.cpp):

```cpp
int64_t ObTenant::min_worker_cnt() const {
  ObTenantConfigGuard tenant_config(TENANT_CONF(id_));
  int64_t cnt = priority_worker_cnt()
                  + std::max(1L, static_cast<int64_t>(
                        unit_min_cpu() * (tenant_config.is_valid()
                                          ? tenant_config->cpu_quota_concurrency
                                          : 4)));
  if (GCONF._enable_numa_aware) {
    int numa_node_count = AFFINITY_CTRL.get_num_nodes();
    if (cnt < numa_node_count) {
      cnt = common::upper_align(cnt, numa_node_count);   // 至少每 NUMA 1 个 worker
    }
  }
  return cnt;
}
```

`max_worker_cnt` (line 1467-1474) 同样逻辑。

**设计意图**: 即使租户 CPU quota 很小 (例如 0.5 CPU), 也要保证 NUMA-aware 时**每个 NUMA 至少 1 个 worker**, 否则该 NUMA 上的请求 queue 永远没人消费, 队列积压。

### 2.9 网络: net_thread_count upper_align

[`src/observer/ob_srv_network_frame.cpp:215-225`](src/observer/ob_srv_network_frame.cpp):

```cpp
if (GCONF._enable_numa_aware) {
  int numa_node_count = AFFINITY_CTRL.get_num_nodes();
  if (sql_net_thread_count < numa_node_count) {
    sql_net_thread_count = common::upper_align(sql_net_thread_count, numa_node_count);
    LOG_INFO("sql nio net thread count adjusted", K(sql_net_thread_count));
  }
}
if (OB_FAIL(obmysql::global_sql_nio_server->start(
        GCONF.mysql_port, &deliver_, sql_net_thread_count,
        GCONF._enable_numa_aware))) {
```

`_enable_numa_aware` 传给 `obmysql::start`, 让 NIO server 内部也按 NUMA 分配 thread。

### 2.10 Request queue per NUMA

[`src/observer/omt/ob_tenant.cpp:972-975`](src/observer/omt/ob_tenant.cpp):

```cpp
} else if (OB_FAIL(req_queue_.init(AFFINITY_CTRL.get_num_nodes()))) {
  // For now only the enable_numa_aware mode can ensure the number of worker threads
  // is at least the number of NUMA node, so fallback to single-queue if enabel_numa_aware
  // is disabled, otherwise some of the queues will never be consumed if the worker thread
  // number is small.
  LOG_WARN("fail to init tenant request queues", K(ret));
}
```

**为什么 fallback 单 queue**: NUMA-aware 下 `min_worker_cnt` 保证每 NUMA 一个 worker, 所以多 queue 都能被消费; 非 NUMA-aware 下 worker 数可能 < NUMA 数, 多 queue 会**有的 queue 永远没人收**。

请求 queue 的 NUMA 路由在 `ObThWorker::dispatch` 中:
- worker 绑 NUMA_X, 只从 queue[X] 取任务
- 入队时按 client 入口的 NUMA 分发

### 2.11 总入口 ob_server.cpp

[`src/observer/ob_server.cpp:325-330`](src/observer/ob_server.cpp):

```cpp
} else if (GCONF._enable_numa_aware
           && OB_FAIL(AFFINITY_CTRL.init(GCONF.strict_check_os_params))) {
  LOG_WARN("init affinity ctrl failed");
  ret = OB_ERR_UNEXPECTED;
}
```

`strict_check_os_params` 在 init 失败 (offline CPU 等) 时:
- `true`: 整个 observer 启动失败
- `false`: 仅 warn, `inited_=false`, 后续 `AFFINITY_CTRL.*` 调用全部 no-op, 系统退化成非 NUMA-aware

---

## 3. 性能优化

### 3.1 TLS 加速 get_numa_id

[`ob_affinity_ctrl.h:43-52`](deps/oblib/src/lib/resource/ob_affinity_ctrl.h):

```cpp
static int &get_tls_node() {
  static thread_local int node_ = OB_NUMA_SHARED_INDEX;
  return node_;
}
```

- TLS 访问 ≈ 1 cycle (`%fs:0x...` 段寄存器相对寻址)
- `sched_getaffinity` syscall ≈ 200 ns (走 vDSO 后 ~50 ns, 但还是要进 vDSO)
- 在每次 `ob_malloc` 时省 ~50-200 ns

### 3.2 单一 NUMA vs Interleave 选择

| 场景 | 推荐 |
|------|------|
| TP, 强 latency 要求 | 单一 NUMA hint (`group_index % num_nodes`), 让请求全链路 0 跨 NUMA |
| AP / throughput, 不在意 tail latency | interleave 模式 (`group_index == INT32_MAX`), 内存均匀分布避免单 NUMA OOM |
| 默认 OB ThWorker (SQL worker) | 用 `group_index` 自然 round-robin, 既覆盖又均匀 |

### 3.3 offline CPU 检查开销

init() 一次性 open + read + strcmp 两个文件 (~KB 级), 在启动期忽略不计。生产环境确保 online == possible。

### 3.4 OB_NUMA_SHARED_INDEX 的设计哲学

`OB_NUMA_SHARED_INDEX = -1` 既是一个值也是一个 sentinel:
- `numa_node_ == -1` 时 `Thread::run` 不调 `sched_setaffinity`, CPU 由内核调度器决定
- `AChunkMgr` 拿到 `numa_id == -1` 时**不会**走 NUMA 路由 (实际代码里通常被 default 0 替换)

含义: **NUMA-aware 是 opt-in 的, 默认共享**。即使开了 `_enable_numa_aware`, 单独的不需要绑 NUMA 的组件 (如 sys tenant) 仍可走 shared 路径。

---

## 4. 与 v2 主线的连接

| v2 文章 | NUMA-aware thread 维度 |
|---------|----------------------|
| #25 (Memory Management) | thread 绑 NUMA 是 alloc 路径的前提 |
| #28 (Resource/Unit/Tenant) | `upper_align(num_nodes)` 是 tenant × NUMA 二维资源约束 |
| #35 (SQL Engine Entry) | net thread count `upper_align(num_nodes)` 在 SQL entry 启动链 |
| #71 (CGroup Resource Isolation) | cgroup 限制 CPU 时间, NUMA hint 限制跨 socket 流量, 正交 |
| #74 (Thread Model) | TG / Threads / Worker 基础, 本篇是其 NUMA 维度扩展 |
| #102 (下一篇) | thread 绑 NUMA, memory 绑 NUMA — 全链路零跨 NUMA |

### 主线架构图 (NUMA 层)

```
Client Application
    │
    ▼
OBProxy (#37)
    │
    ▼
┌────────────────────────────────────────────────────┐
│  SQL Engine Entry (NUMA-aware 入口 #35 + #101)     │
│  net_thread_count upper_align(num_nodes)            │
│  per-NUMA request queue                             │
└────────────────────────────────────────────────────┘
    │
    ▼ (request 落到 NUMA_X)
┌────────────────────────────────────────────────────┐
│  Worker Pool (NUMA-aware TG #74 + #101)            │
│  ObThWorker::set_numa_info(group_index)             │
│  Threads::NumaInfo: numa_node / interleave          │
│  Thread::run: AFFINITY_CTRL.thread_bind_to_node     │
└────────────────────────────────────────────────────┘
    │
    ▼ (memory 落到 NUMA_X via #102)
┌────────────────────────────────────────────────────┐
│  Memory Allocator (per-NUMA slots #25 + #102)      │
│  slots_[numa_id][size_idx] free list                │
│  memory_bind_to_node (mbind PREFERRED)              │
└────────────────────────────────────────────────────┘
```

---

## 5. 调优 Checklist

| 项 | 检查方法 | 推荐值 |
|----|---------|--------|
| `_enable_numa_aware` | `SHOW PARAMETERS LIKE '%numa%'` | `true` (生产) |
| `strict_check_os_params` | 同上 | `true` (防止 offline CPU 诡异) |
| NUMA 拓扑 | `lscpu \| grep NUMA` | 与预期一致 |
| offline CPU | `cat /sys/devices/system/cpu/online` == `cat /sys/devices/system/cpu/possible` | 必须一致 |
| worker count ≥ NUMA 数 | `SHOW PARAMETERS LIKE '%worker%'` 看 min/max | `min ≥ numa_count`, `max ≥ numa_count` |
| net thread count ≥ NUMA 数 | `SHOW PARAMETERS LIKE 'net_thread%'` | ≥ numa_count |
| 进程 NUMA 分布 | `ps -o pid,psr,comm -C observer` | 分布在所有 NUMA 上 |
| 跨 NUMA 流量 | `perf stat -e node-loads,node-load-misses -p $(pidof observer) sleep 10` | `misses/loads < 5%` |
| per-NUMA 内存 | `numastat -p $(pidof observer)` | 各 NUMA 内存相近 |

---

## 6. 常见故障 case

### Case 1: init 失败 — offline CPU

**现象**:
```
[AFFINITY_CTRL] AFFINITY_CTRL doesn't support environments with offline CPUs,
please consider disable the _enable_numa_aware option, online=0-71, possible=0-95
```
**原因**: BIOS 关闭了部分核 (常见于 power management / c-state)
**解决**:
1. BIOS 开启所有核 (`Advanced → CPU Configuration → Active Processor Cores = All`)
2. 或 OS 层 `echo 1 > /sys/devices/system/cpu/cpuN/online` 全部上线
3. 或临时设 `strict_check_os_params=false` 跳过

### Case 2: worker 全挤在 NUMA 0

**现象**: `ps -o pid,psr` 看 observer 的 psr 字段全是 0-7
**原因**:
- `_enable_numa_aware=false` (默认)
- 或 `ObThWorker::set_numa_info` 没被调用 (代码路径问题)
**解决**: 设 `_enable_numa_aware=true` 后重启

### Case 3: 跨 NUMA 流量高

**现象**: `perf stat -e node-load-misses` 比例 > 30%
**原因**: OB 已经按 NUMA 分配, 但业务访问的数据不在本 NUMA
**排查**:
```bash
# 看是否有 partition 副本迁移导致访问跨 NUMA
select * from oceanbase.__all_virtual_tablet_replica_status;

# 看 plan 是否走 DAS 还是 PX (跨 NUMA 风险)
select * from oceanbase.__all_virtual_sql_audit where sql_id='...';
```
**解决**: 调副本均匀分布, 或调小 worker 数降低单 worker QPS

### Case 4: 启动后 net thread 数被调整

**现象**: log 中
```
[OBSERVER] sql nio net thread count adjusted, sql_net_thread_count=N
```
**含义**: `net_thread_count < numa_count`, 被自动 `upper_align` 到 `numa_count` 的倍数 — 这是预期行为, 不是 error

### Case 5: tenant worker 数 < numa 数

**现象**: log 中
```
[OMT] fail to init tenant request queues
```
**原因**: `_enable_numa_aware=true` 但 `min_worker_cnt` 算出来 < `numa_count` (理论上应自动 upper_align, 但如果优先级配置 < numa_count 仍可能)
**解决**: 调大 `cpu_quota_concurrency` 或检查 `unit_min_cpu`

---

## 7. 参考 (可执行源码锚点)

| 路径 | 行 | 锚点 |
|------|---|------|
| `deps/oblib/src/lib/resource/ob_affinity_ctrl.h` | 26-85 | `ObAffinityCtrl` / `ObNumaNodeGuard` / `NumaInfo` 结构 |
| `deps/oblib/src/lib/resource/ob_affinity_ctrl.cpp` | 23-72 | `check_all_cpu_online` offline CPU 校验 |
| `deps/oblib/src/lib/resource/ob_affinity_ctrl.cpp` | 88-150 | `init()` 拓扑发现 (readdir + CPU_SET) |
| `deps/oblib/src/lib/resource/ob_affinity_ctrl.cpp` | 163-186 | `run_on_node` / `thread_bind_to_node` |
| `deps/oblib/src/lib/thread/thread.cpp` | 128-131 | `Thread::start` ObNumaNodeGuard 入口 |
| `deps/oblib/src/lib/thread/thread.cpp` | 161-169 | `Thread::run` AFFINITY_CTRL.thread_bind_to_node |
| `deps/oblib/src/lib/thread/threads.cpp` | 57-66 | `do_set_thread_count` NUMA 分配 (扩增) |
| `deps/oblib/src/lib/thread/threads.cpp` | 211-218 | `Threads::start` NUMA 分配 (init) |
| `deps/oblib/src/lib/thread/threads.cpp` | 313-330 | `Threads::set_numa_info` 三态决策 |
| `deps/oblib/src/lib/thread/threads.h` | 74-85 | `NumaInfo` 结构 + reset |
| `src/observer/omt/ob_th_worker.cpp` | 48-57 | `worker->set_numa_info(...)` 调用点 |
| `src/observer/omt/ob_tenant.cpp` | 972-975 | `req_queue_.init(AFFINITY_CTRL.get_num_nodes())` |
| `src/observer/omt/ob_tenant.cpp` | 1443-1474 | `min/max_worker_cnt upper_align(num_nodes)` |
| `src/observer/ob_srv_network_frame.cpp` | 215-225 | `net_thread_count upper_align(num_nodes)` |
| `src/observer/ob_server.cpp` | 325-330 | `_enable_numa_aware` + `AFFINITY_CTRL.init` 入口 |
| `deps/oblib/unittest/lib/resource/test_affinity_ctrl.cpp` | 25-55 | TLS + 参数校验单元测试 |

---

## 8. Cross-cutting 列表

- **TG 链路**: `ObThWorker::set_numa_info` → `Threads::set_numa_info` → `Thread::run` 三级注入, 每级职责分明
- **TLS 一致性**: `ObNumaNodeGuard` 在 `Thread::start` 入口记录, `pthread_create` 后子线程继承, `Thread::run` 调 `thread_bind_to_node` 真正绑核
- **NUMA hint 选择策略**: `group_index` 自然 round-robin, 单一 NUMA 还是 interleave 由 `group_index` 边界判断 (`>= INT32_MAX`)
- **维度对齐**: tenant worker 数 / net thread 数 / request queue 数 / ObTenantCtxAllocator 维度 (见 #102) 都对齐到 `num_nodes`
- **运行时约束**: `min_worker_cnt upper_align(num_nodes)` 是 OMT 的硬约束, 不能配低于 numa 数
- **失败模式**: `inited_=false` 后续 no-op, 退化到非 NUMA-aware, 不 crash
- **测试覆盖**: `test_affinity_ctrl.cpp` 验证 TLS 初始值 + 参数校验 + `run_on_node` 行为

---

## 9. 下一篇预告

#102 — NUMA-Aware 内存分配: `AChunkMgr` 的 per-NUMA slot 矩阵 (`slots_[OB_MAX_NUMA_NUM][HUGE_ACHUNK_INDEX+1]`)、`direct_alloc` 的 mbind 路径、`ObMallocAllocator → ObTenantCtxAllocator` 的 (tenant × ctx × numa_id) 三维路由、`alloc_chunk` 的本地优先 + 全局 round-robin recycling 策略。

将揭晓: 同样的 `_enable_numa_aware` 开关, 在内存分配侧如何通过 `attr.numa_id_ = AFFINITY_CTRL.get_numa_id()` 实现 thread 与 memory 的 NUMA 对齐。