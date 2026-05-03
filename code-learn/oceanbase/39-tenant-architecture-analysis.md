# 39 — Tenant 架构与资源隔离 — 租户创建、资源管理与线程池

> 基于 OceanBase CE 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

前 38 篇文章覆盖了整个引擎栈——从 SQL 解析到存储引擎，从并发控制到选举共识。现在我们来分析 OceanBase 最重要但最容易被忽视的架构特性：**多租户（Multi-Tenant）**。

多租户是 OceanBase 的根基。每一张表、每一条 SQL、每一笔事务都归属于某个租户。租户不仅是逻辑上的命名空间，更是一等资源隔离单元——CPU、内存、IO、线程、存储全部以租户为单位进行分配和隔离。

OceanBase 的多租户子系统由 **OMT（Observer Multi-Tenant）** 模块实现，核心文件位于 `src/observer/omt/`：

```
ObMultiTenant             ← 多租户管理器（入口）
    ├── ObTenant          ← 租户对象（资源 + 线程池 + 队列）
    ├── ObThWorker        ← 工作线程（每个租户独立拥有）
    ├── ObMultiLevelQueue ← 多级优先级队列
    ├── ObTenantConfig    ← 租户配置项
    ├── ObTenantConfigMgr ← 租户配置管理器
    └── ObTenantNodeBalancer ← 节点间租户均衡
```

### 多租户架构全景

```
┌─────────────────────────────────────────────────────────────────┐
│                        OBServer 进程                             │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │  ObMultiTenant（OMT 管理器）                                 ││
│  │  - 生命周期：create / drop / get / for_each                  ││
│  │  - 线程池调度：run1() 每 10ms 检查所有租户                   ││
│  │  - 资源协调：CPU / 内存 / IO 的分配与回收                   ││
│  │  - 配置同步：每个租户的配置项在线更新                        ││
│  └──────────┬──────────┬──────────┬──────────┬──────────────────┘│
│             │          │          │          │                   │
│             ▼          ▼          ▼          ▼                   │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐            │
│  │ 租户 1   │ │ 租户 2   │ │ 租户 3   │ │ 租户 N   │            │
│  │ sys      │ │ MySQL   │ │ Oracle   │ │ ...      │            │
│  ├──────────┤ ├──────────┤ ├──────────┤ ├──────────┤            │
│  │ 线程池   │ │ 线程池   │ │ 线程池   │ │ 线程池   │            │
│  │ 内存限流 │ │ 内存限流 │ │ 内存限流 │ │ 内存限流 │            │
│  │ 请求队列 │ │ 请求队列 │ │ 请求队列 │ │ 请求队列 │            │
│  │ Schema   │ │ Schema   │ │ Schema   │ │ Schema   │            │
│  │ 日志流   │ │ 日志流   │ │ 日志流   │ │ 日志流   │            │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘            │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │  底层资源                                                     ││
│  │  CPU cores  │  RAM  │  Disk  │  Network  │  CGroup          ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

---

## 1. 租户模型与类型

### 1.1 租户 ID 体系

OceanBase 使用 `uint64_t` 作为租户唯一标识。关键 ID 定义在 `deps/oblib/src/lib/ob_define.h`：

| 常量 | 值 | 说明 |
|------|-----|------|
| `OB_INVALID_TENANT_ID` | 0 | 非法 ID |
| `OB_SYS_TENANT_ID` | 1 | 系统租户（__system） |
| `OB_SERVER_TENANT_ID` | 500 | 服务器内部租户 |
| `OB_DTL_TENANT_ID` | 508 | DTL（Data Table Lookup）租户 |
| `OB_DATA_TENANT_ID` | 509 | DATA（内部数据）租户 |
| `OB_MAX_RESERVED_TENANT_ID` | 1000 | 保留 ID 上限 |
| `OB_USER_TENANT_ID` | 1000 | 用户租户起始 ID |

辅助函数（同文件）：
- `is_sys_tenant(id)`：判断是否为 sys 租户（id == 1）
- `is_virtual_tenant_id(id)`：判断是否为内部虚拟租户（id ∈ (1, 1000]）
- `is_meta_tenant(id)`：功能备用

### 1.2 三种租户类型

OceanBase 支持三类租户，创建时通过 compat_mode 区分：

**系统租户（__system）** — id 固定为 1
- 管理集群元数据（RootServer）
- 存放系统表（`__all_*` 系列）
- 始终存在，不可删除

**用户 MySQL 租户** — id ≥ 1000
- 兼容 MySQL 协议和 SQL 方言
- 每个 MySQL 租户有独立的系统变量、用户权限、Schema 空间

**用户 Oracle 租户** — id ≥ 1000
- 兼容 Oracle 协议和 SQL 方言
- 共享系统表结构但数据完全隔离

### 1.3 租户元数据（ObTenantMeta）

OMT 模块内部用 `ObTenantMeta`（`ob_tenant_meta.h`）描述租户的核心信息：

```cpp
// ob_tenant_meta.h:9-41
struct ObTenantMeta final {
  share::ObUnitInfoGetter::ObTenantConfig unit_;  // Unit 配置（CPU/内存/磁盘）
  storage::ObTenantSuperBlock super_block_;        // 超级块（存储元数据）
  storage::ObTenantCreateStatus create_status_;    // 创建状态
  int64_t epoch_;                                  // 版本戳（乐观并发控制）
};
```

---

## 2. ObMultiTenant — 多租户管理器

`ObMultiTenant`（`ob_multi_tenant.h/cpp`）是整个 OMT 模块的入口类。

### 2.1 类结构

```cpp
// ob_multi_tenant.h:36-41
class ObMultiTenant : public share::ObThreadPool {
  static const int64_t TIME_SLICE_PERIOD = 10000;  // 10ms

  // 核心数据结构
  mutable common::SpinRWLock lock_;       // 保护租户列表
  TenantList tenants_;                    // ObSortedVector<ObTenant*>
  ObTenantNodeBalancer *balancer_;        // 节点均衡器
  ObBucketLock bucket_lock_;              // 并发创建/删除的桶锁

  // 共享资源限制器
  lib::ObShareTenantLimiter *tenant_limiter_head_;
  lib::ObMutex limiter_mutex_;
};
```

`TenantList` 是 `ObSortedVector<ObTenant*>`——一个按 `tenant_id` 排序的有序容器，支持高效的二分查找。

### 2.2 初始化（`init`，L456）

`init()` 在 OBServer 启动时调用（参见文章 30），完成两件关键工作：

1. **初始化桶锁**：使用 `OB_TENANT_LOCK_BUCKET_NUM` 个桶的 `ObBucketLock`，减少租户创建/删除时对全局锁的竞争
2. **注册所有 MTL 模块**：调用大量 `MTL_BIND2` 宏将各个子系统（Transaction、LogService、SchemaService、Backup、Restore 等）注册为 Tenant MTL（Module Template Library）——每个租户创建时会自动实例化这些模块

### 2.3 背景线程（`run1`，L2793）

`ObMultiTenant` 继承自 `ObThreadPool`，启动后运行 `run1()` 作为周期性监控线程：

```cpp
// ob_multi_tenant.cpp:2803-2825
void ObMultiTenant::run1() {
  while (!has_set_stop()) {
    {
      ObTimeGuard timeguard("multi_tenant_timeup", 100 * 1000);
      SpinRLockGuard guard(lock_);
      // 每 1 秒检查 CGroup 状态
      if (REACH_TIME_INTERVAL(1 * 1000 * 1000L)) {
        need_regist_cgroup = GCTX.cgroup_ctrl_->check_cgroup_status();
      }
      // 遍历所有租户
      for (TenantList::iterator it = tenants_.begin(); ...) {
        if (need_regist_cgroup) (*it)->regist_threads_to_cgroup();
        (*it)->timeup();  // 每个租户的定期检查
      }
    }
    ob_usleep(TIME_SLICE_PERIOD);  // 10ms 一次

    // 每 10 秒 dump 租户信息到日志
    if (REACH_TIME_INTERVAL(10000000L)) {
      // dump tenant info
    }
  }
}
```

每隔 10ms，OMT 主线程对所有活跃租户调用 `timeup()`，触发：
- `check_worker_count()` — 检查工作线程数是否需要调整
- `update_token_usage()` — 更新 CPU token 使用率
- `handle_retry_req()` — 处理重试队列中的请求
- `update_queue_size()` — 更新队列状态
- `update_lq_cpu_limit()` — 更新大查询 CPU 限制

### 2.4 租户创建（`create_tenant`，L1038）

创建租户是一个**多步骤原子操作**，每个步骤有明确的回滚逻辑：

```cpp
// 步骤状态机（ob_multi_tenant.h:204-214）
enum class ObTenantCreateStep {
  STEP_BEGIN = 0,
  STEP_CTX_MEM_CONFIG_SETTED = 1,  // 设置上下文内存配置
  STEP_LOG_DISK_SIZE_PINNED = 2,   // 锁定日志磁盘空间
  STEP_DATA_DISK_ALLOCATED = 3,    // 分配数据磁盘空间（共享存储模式）
  STEP_CREATION_PREPARED = 4,      // 写入 prepare slog
  STEP_TENANT_NEWED = 5,           // 创建 ObTenant 对象
  STEP_FINISH,
};
```

完整创建流程：

1. **加桶锁**：`bucket_lock_.wrlock()`，防止并发创建/删除同一租户
2. **创建分配器**：`malloc_allocator->create_and_add_tenant_allocator()` — 为租户创建独立的内存分配器
3. **设置共享限制器**：`create_share_tenant_limiter_unsafe()` — 创建租户级资源限制器，挂接为分配器的 parent limiter
4. **设置内存限制**：`update_tenant_memory()` — 按 Unit 配置计算内存上限
5. **设置上下文内存**：`set_tenant_ctx_idle()` / `set_ctx_limit()` — 为每个 CTX（Memory Context）设置空闲阈值和硬限制
6. **锁定日志磁盘**：`GCTX.log_block_mgr_->create_tenant()` — 在日志块管理器中预留磁盘空间
7. **写入 prepare slog**：`SERVER_STORAGE_META_SERVICE.prepare_create_tenant()` — 持久化创建准备日志（可恢复）
8. **创建 ObTenant**：`OB_NEW(ObTenant, ...)` — 实例化租户对象
9. **初始化 MTL**：`tenant->init(meta)` — 启动所有租户级模块
10. **写入 commit slog**：`SERVER_STORAGE_META_SERVICE.commit_create_tenant()` — 提交创建
11. **加入租户列表**：`tenants_.insert(tenant, iter)`

每一步失败都有对应的回滚逻辑（`do { retry } while` 风格），保证资源不会泄漏。

### 2.5 租户删除（`del_tenant`，L2303）

删除流程同样严谨：

1. **try_wrlock 桶锁**：不阻塞，失败则返回（让调用方重试）
2. **标记 UNIT_DELETING_IN_OBSERVER**：防止并发重复删除
3. **写入 prepare_delete_tenant slog**：持久化删除准备
4. **remove_tenant**：从租户列表中移除、停止工作线程、释放 IO 资源
5. **clear_tenant_log_dir**：清理磁盘上的日志目录
6. **commit_delete_tenant**：提交删除日志
7. **回收分配器**：`recycle_tenant_allocator()`

### 2.6 请求路由（`recv_request`，L2568）

当网络层收到 RPC 请求时，通过 `ObMultiTenant::recv_request()` 分发到对应租户：

```cpp
int ObMultiTenant::recv_request(const uint64_t tenant_id, ObRequest &req) {
  SpinRLockGuard guard(lock_);
  ObTenant *tenant = NULL;
  get_tenant_unsafe(tenant_id, tenant);
  tenant->recv_request(req);  // 推入租户的请求队列
}
```

---

## 3. ObTenant — 租户对象

`ObTenant`（`ob_tenant.h/cpp`，约 2453 行）继承自 `share::ObTenantBase`，是每个租户的完整资源容器。

### 3.1 核心成员

```cpp
class ObTenant : public share::ObTenantBase {
  // 基础属性
  uint64_t id_;                              // 租户 ID
  ObTenantMeta tenant_meta_;                 // 租户元数据

  // CPU 资源
  double unit_min_cpu_;                      // 最低 CPU 配额
  double unit_max_cpu_;                      // 最高 CPU 配额
  double token_usage_;                       // 当前 CPU 使用率
  int64_t cpu_time_us_ CACHE_ALIGNED;        // CPU 时间累计

  // 内存资源
  share::ObTenantSpace *ctx_;                // 租户内存上下文空间
  int64_t worker_us_;                        // 工作线程时间累计

  // 请求队列（三层架构）
  ReqQueue req_queue_;                       // 主请求队列（QuickQueue + NormalQueue）
  ObMultiLevelQueue *multi_level_queue_;     // 多级嵌套请求队列
  ObRetryQueue retry_queue_;                 // 重试队列

  // 线程池管理
  WList workers_;                            // 活跃工作线程列表
  WList nesting_workers_;                    // 嵌套工作线程列表
  GroupMap group_map_;                       // 资源组映射表
  volatile int64_t total_worker_cnt_;        // 工作线程总数

  // 锁
  common::ObLDLatch lock_;                    // 租户锁（RD/WR）
  lib::ObMutex workers_lock_;                // 工作线程列表锁

  // CGroup
  share::ObCgroupCtrl &cgroup_ctrl_;         // CGroup 控制器引用
};
```

### 3.2 工作线程管理

每个租户拥有独立的工作线程池。线程数由 CPU 配额动态决定：

```cpp
// ob_tenant.h 内联函数
int64_t ObTenant::cpu_quota_concurrency() const;
// 返回 GCONF.workers_per_cpu_quota（默认 10）

int64_t ObTenant::min_worker_cnt() const;
// min(min_cpu * cpu_quota_concurrency, 1)

int64_t ObTenant::max_worker_cnt() const;
// max_cpu * cpu_quota_concurrency
```

线程创建由 `create_worker()`（`ob_th_worker.cpp:38`）完成：

- 先检查 `total_worker_cnt >= max_worker_cnt()`，超出则返回 `OB_RESOURCE_OUT`
- 分配 `ObThWorker` 对象，设置 `tenant`、`group_id`、`level`
- 调用 `worker->start()` 启动线程
- 递增 `tenant->total_worker_cnt_`

线程销毁由 `destroy_worker()`（`ob_th_worker.cpp:83`）执行：`stop()` → `wait()` → `destroy()` → `ob_delete()` → 递减计数。

### 3.3 请求入队（`recv_request`，L1495）

请求按类型和优先级进入不同队列：

```
RPC 请求
  ├─ High priority（0-4）     → QQ_HIGH（QuickQueue 高优先级）
  ├─ Retry on lock            → QQ_NORMAL
  ├─ KV request               → RQ_NORMAL（RequestQueue 普通优先级）
  ├─ Normal/Low prio（5-9）   → QQ_LOW
  ├─ Level ≥ MULTI_LEVEL_THRESHOLD  → MultiLevelQueue[level]
  └─ Warmup                   → RQ_LOW

MySQL 请求
  ├─ Retry on lock            → RQ_HIGH
  └─ Normal                   → RQ_NORMAL

Task 请求（内部任务、事务提交） → RQ_HIGH
```

### 3.4 请求出队（`get_new_request`，L1294）

工作线程从队列取请求的优先级策略：

```cpp
// ob_tenant.cpp:1294
int ObTenant::get_new_request(ObThWorker &w, int64_t timeout, rpc::ObRequest *&req) {
  if (w.is_level_worker()) {
    // Level worker 只从 MultiLevelQueue[level] 取
    ret = multi_level_queue_->pop(task, wk_level, timeout);
  } else {
    // 默认 worker：先尝试 MultiLevelQueue 的高 level，再降级到主队列
    for (int level = MAX-1; level >= 1; level--) {
      try_pop(multi_level_queue_, task, level);
      if (task) return;
    }
    // 主队列：high_prio → normal_prio → low_prio
    req_queue_.pop_high/pop_normal/pop(task, timeout);
  }
}
```

优先级调度策略简称为 **work-conserving**：低优先级 worker 在看到自身队列为空时，会从高一级队列偷取任务，保证 CPU 不空转。

---

## 4. ObThWorker — 工作线程

`ObThWorker`（`ob_th_worker.h/cpp`）继承自 `lib::Worker` 和 `lib::Threads`，是实际执行请求的线程。

### 4.1 线程生命周期

```
[create_worker]
    ↓
init()       → 初始化条件变量 run_cond_
start()      → 启动线程（pthread_create）
    ↓
run(idx)     → run(id) → worker()
    ↓
worker()     → 主循环：
                1. get_new_request() — 取请求
                2. process_request(req) — 处理请求
                3. check_worker_count — 检查线程数
    ↓
stop/wait/destroy → destroy_worker()
```

### 4.2 主循环（`worker`，L344）

```cpp
void ObThWorker::worker(..) {
  CREATE_WITH_TEMP_ENTITY(RESOURCE_OWNER, owner_id) {
    WITH_ENTITY(&tenant_->ctx()) {
      while (!has_set_stop()) {
        // 设置线程名
        set_th_worker_thread_name();
        // 取请求
        ret = tenant_->get_new_request(*this, timeout, req);
        if (OB_SUCC(ret) && req != nullptr) {
          query_start_time_ = wait_end_time;
          process_request(*req);               // 处理请求
        }
        // 检查是否需要缩减/增加线程
        if (!is_group_worker()) {
          tenant_->check_worker_count(*this);
        } else {
          group->check_worker_count(*this);
        }
      }
    }
  }
}
```

### 4.3 请求处理（`process_request`，L238）

```cpp
inline void ObThWorker::process_request(rpc::ObRequest &req) {
  can_retry_ = true; need_retry_ = false;
  set_req_flag(&req);
  // 处理请求
  ret = procor_.process(req);
  // 重试逻辑
  if (need_retry_) {
    if (req.large_retry_flag()) {
      tenant_->recv_large_request(req);     // 转大查询队列
    } else {
      tenant_->recv_request(req);           // 重新入队
    }
  }
}
```

### 4.4 流控机制（`check_wait` / `check_throttle` / `check_rate_limiter`）

Worker 在处理请求间隙执行流控检查：

- **时间阈值**：执行时间超过 `large_query_threshold` 时，`lq_yield()` 将查询移交到大查询组（OBCG_LQ）
- **RT 控制**：`check_throttle()` 按配置的 `priority_` 和 `rt_` 阈值限流
- **队列等待时间控制**：`check_qtime_throttle()` 按 `queue_time_` 阈值限流
- **速率限制器**：`check_rate_limiter()` 使用 Token Bucket 算法进行 QPS 限流

---

## 5. 多级队列调度

### 5.1 ObMultiLevelQueue（`ob_multi_level_queue.h`）

```cpp
class ObMultiLevelQueue {
  static const int MULTI_LEVEL_QUEUE_SIZE = 10;
  common::ObPriorityQueue<1> queue_[MULTI_LEVEL_QUEUE_SIZE];
};
```

10 个优先级队列，每个队列是一个 `ObPriorityQueue<1>`（单优先级队列，FIFO）。Level 0-9：Level 越高优先级越低（但深度优先；nesting request 的 level 表示嵌套深度）。

### 5.2 资源组（ObResourceGroup）

每个租户内部通过 `GroupMap` 管理多个 `ObResourceGroup`。每个 Group 有自己的请求队列、MultiLevelQueue 和工作线程列表：

最小线程数（`ObResourceGroup::min_worker_cnt()`，`ob_tenant.h` 内联实现）：
```cpp
// CLOG 组：ceil(min_cpu) * worker_concurrency，至少 8
// WR 组：固定 2（1 个 snapshot + 1 个 purge）
// HB_SERVICE 组：固定 1
// LQ 组：至少 8
// 其他组（DEFAULT）：ceil(min_cpu) * worker_concurrency，至少 1
```

资源组通过 `ObResourceGroupNode` 哈希到 `GroupHash` 表，每个 group_id 唯一确定一个 Group。

---

## 6. 资源隔离

### 6.1 CPU 隔离

CPU 隔离有三种模式，按优先级依次尝试：

**模式 1: CGroup**（首选）
- OMT 主线程每 1 秒检查 CGroup 状态
- `regist_threads_to_cgroup()` 将租户的所有线程注册到 CGroup 控制组
- CGroup 的 `cpu.shares` / `cpu.cfs_quota_us` 保证 CPU 使用不超限
- 代码路径：`share/resource_manager/ob_cgroup_ctrl.h`

**模式 2: 线程池比例分配**（CGroup 不可用时的回退）
- `cpu_quota_concurrency` 是每个 CPU 核分配的工作线程数（默认 10）
- 租户最小线程数 = `ceil(unit_min_cpu) × cpu_quota_concurrency`
- 租户最大线程数 = `ceil(unit_max_cpu) × cpu_quota_concurrency`
- 通过限制线程数间接控制 CPU 使用

**模式 3: 异步 /proc 采样**（无 CGroup + 大量租户）
- 当租户数 ≥ 20 且 CGroup 不可用时，启动 `OMTProcCpuSampler` 线程
- 每秒通过 `/proc` 采样所有租户的 CPU 时间
- `update_tenants_cpu_time()` → `sample_cpu_time_from_proc_once()`
- 用于监控和调度决策

**Token 机制**（所有模式共通）：
- 每次 `timeup()` 调用 `update_token_usage()` 更新 `token_usage_`（CPU 使用率）
- `cpu_time_us_` 记录每个租户累计 CPU 时间
- 用于决策是否需要增减线程

### 6.2 内存隔离

租户内存隔离通过三层结构实现：

```
ObMallocAllocator（全局分配器）
    ├── Tenant 分配器（per-tenant）
    │   ├── CTX 0 分配器（SQL）
    │   ├── CTX 1 分配器（事务）
    │   ├── CTX 2 分配器（存储）
    │   └── ...
    └── ShareTenantLimiter（共享限制器，可选）
```

关键机制（`ob_multi_tenant.cpp:1038` 创建流程中设置）：
1. `create_and_add_tenant_allocator()` — 创建租户级分配器
2. `create_share_tenant_limiter_unsafe()` — 创建共享限制器（限制集群内租户总内存）
3. 限制器成为分配器的 `parent_limiter`，形成父子递进限流
4. `set_tenant_ctx_idle()` — 设置每个 CTX 的空闲阈值（超过则触发回收到全局池）
5. `set_ctx_limit()` — 设置每个 CTX 的硬上限

每个 `ObMemAttr` 都携带 `tenant_id`（文章 25），分配时自动路由到对应租户的分配器。

### 6.3 IO 隔离

IO 隔离通过多级队列优先级实现：
- 高优先级 RPC（如 Paxos 日志写入）→ QQ_HIGH → 优先处理
- 后台任务（合并、GC）→ RQ_LOW → 低优先级
- CLOG 组（`OBCG_CLOG`）保证至少 8 个工作线程
- IO 调度配合 CGroup 的 `blkio` 控制组

### 6.4 存储隔离

每个租户独立的存储资源：
- **独立 Schema**：`ObTenantSchemaService`（MTL 模块）
- **独立 Tablet**：`ObLSService` 按 tenant_id 隔离 LogStream
- **独立 Tablet 空间**：`ObTenantSpace`（`ctx_`）管理内存分配
- **独立 Meta 租户**：用于存储系统元数据

---

## 7. 租户配置管理

### 7.1 ObTenantConfig（`ob_tenant_config.h`）

每个租户有自己的配置参数，通过宏 `OB_TENANT_PARAMETER` 在 `ob_parameter_seed.ipp` 中定义。`ObTenantConfig` 继承自 `ObCommonConfig`，包含数百个可在线修改的参数。

### 7.2 ObTenantConfigMgr（`ob_tenant_config_mgr.h`）

全局配置管理器（单例），管理所有租户的配置：

- **存储结构**：`TenantConfigMap`（固定大小数组，最大 `OB_MAX_SERVER_TENANT_CNT` 个租户）
- **版本控制**：`TenantConfigVersionMap` 追踪每个租户的配置版本
- **更新流程**：
  1. `add_tenant_config(tenant_id)` — 创建配置
  2. `got_version(tenant_id, version)` — 通知有新版本
  3. `update_local(tenant_id, expected_version)` — 同步变更
  4. `notify_tenant_config_changed()` — 触发回调（如 `update_tenant_config()`）
- **线程安全**：`DRWLock rwlock_` 保护读写

`TenantConfigUpdateTask` 是一个定时任务，定期从 `__all_tenant_parameter` 表拉取最新配置并应用到内存。

---

## 8. 设计决策

### 8.1 为什么选择进程内租户，而不是容器化隔离？

OceanBase 选择在单个 OBServer 进程内实现多租户（in-process multitenancy），而非为每个租户启动独立进程或容器。理由：

1. **共享缓存**：多个租户共享 Block Cache、Row Cache 等全局缓存，内存利用率更高。容器隔离会导致缓存重复，内存浪费
2. **零拷贝通信**：跨租户访问（如系统租户访问用户租户的元数据）通过函数调用而非 RPC，延迟低一个数量级
3. **批量运维**：建租户/删租户无需起停进程，毫秒级完成
4. **共享计算**：合并（Compaction）、GC 等后台任务可以跨租户共享线程池

代价是更强的隔离保证需要软隔离机制（CGroup + 线程池比例），但设计者认为这个 trade-off 值得。

### 8.2 CPU 隔离实现选择

| 方式 | 精度 | 开销 | OceanBase 使用 |
|------|------|------|---------------|
| CGroup cpu.shares | 按权重 | 低 | 首选 |
| CGroup cpu.cfs_quota | 精确配额 | 中 | 可选 |
| 线程池比例 | 粗粒度 | 极低 | 回退方案 |
| /proc 采样 | 监控级 | 高 | 诊断用 |

CGroup 不可用的场景（如容器内无 cgroup 权限、测试环境），回退到线程池比例调度。

### 8.3 内存超卖策略

- 每个租户有 `unit.config.memory_size()` 作为配置内存
- `allowed_mem_limit` 由 OMT 根据服务器剩余内存动态调整
- 当内存紧张时，Freezer 模块（`ObTenantFreezer`）冻结低优先级租户的内存释放
- 每个 CTX 的 `idle_size` 控制何时回收空闲内存到全局池

### 8.4 Meta 租户设计

系统租户（__system，id=1）承担 Meta 租户的职责：
- 管理所有用户的 Schema 元数据
- 保存 RootServer 的路由信息
- 响应 DDL 操作的元数据查询

创建用户租户时，系统租户的 `extra_memory` 会相应增加。

---

## 9. 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 文章 25（Memory） | `ObMemAttr` 的 `tenant_id_` 字段是内存隔离的基石 |
| 文章 27（RootServer） | RootServer 通过 `__all_unit_config` / `__all_unit` 表下发 Unit 配置，OMT 按 Unit 创建/更新租户 |
| 文章 30（Startup） | OBServer 启动时调用 `ObMultiTenant::init()` 和 `create_hidden_sys_tenant()` |
| 文章 31（DML） | DML 请求通过 `ObMultiTenant::recv_request()` 路由到正确租户 |
| 文章 37（Location） | Location Cache 按 tenant_id 缓存 Tablet → LS 映射 |

---

## 10. 源码索引

| 文件 | 路径 | 说明 |
|------|------|------|
| `ob_multi_tenant.h` | `src/observer/omt/ob_multi_tenant.h` | OMT 管理器定义 |
| `ob_multi_tenant.cpp` | `src/observer/omt/ob_multi_tenant.cpp` | 3203 行，完整实现 |
| `ob_tenant.h` | `src/observer/omt/ob_tenant.h` | 770 行，租户对象定义 |
| `ob_tenant.cpp` | `src/observer/omt/ob_tenant.cpp` | 2453 行，租户实现（队列/线程管理） |
| `ob_th_worker.h` | `src/observer/omt/ob_th_worker.h` | 工作线程定义 |
| `ob_th_worker.cpp` | `src/observer/omt/ob_th_worker.cpp` | 550+ 行，线程循环/请求处理 |
| `ob_multi_level_queue.h` | `src/observer/omt/ob_multi_level_queue.h` | 多级优先级队列 |
| `ob_tenant_config.h` | `src/observer/omt/ob_tenant_config.h` | 115 行，租户配置 |
| `ob_tenant_config_mgr.h` | `src/observer/omt/ob_tenant_config_mgr.h` | 234 行，配置管理器 |
| `ob_tenant_meta.h` | `src/observer/omt/ob_tenant_meta.h` | 41 行，租户元数据 |
| `ob_tenant_node_balancer.h` | `src/observer/omt/ob_tenant_node_balancer.h` | 节点间均衡 |
| `ob_tenant_base.h` | `share/rc/ob_tenant_base.h` | MTL 模块基础设施 |
| `ob_define.h` | `deps/oblib/src/lib/ob_define.h` | 租户 ID 常量定义 |
| `ob_tenant_mgr.h` | `src/share/ob_tenant_mgr.h` | 虚拟租户管理器 |

### 关键方法行号

| 方法 | 文件 | 行号 | 说明 |
|------|------|------|------|
| `ObMultiTenant::init` | ob_multi_tenant.cpp | 456 | 初始化 MTL 绑定 |
| `ObMultiTenant::create_tenant` | ob_multi_tenant.cpp | 1038 | 创建租户（6 步状态机） |
| `ObMultiTenant::create_hidden_sys_tenant` | ob_multi_tenant.cpp | 852 | 创建隐藏系统租户 |
| `ObMultiTenant::mark_del_tenant` | ob_multi_tenant.cpp | 2116 | 标记删除 |
| `ObMultiTenant::remove_tenant` | ob_multi_tenant.cpp | 2143 | 移除租户（从列表摘除） |
| `ObMultiTenant::del_tenant` | ob_multi_tenant.cpp | 2303 | 删除租户（完整流程） |
| `ObMultiTenant::recv_request` | ob_multi_tenant.cpp | 2568 | 请求路由入口 |
| `ObMultiTenant::run1` | ob_multi_tenant.cpp | 2793 | 后台监控主循环 |
| `ObTenant::get_new_request` | ob_tenant.cpp | 1294 | 请求出队调度 |
| `ObTenant::recv_request` | ob_tenant.cpp | 1495 | 请求入队分类 |
| `ObTenant::timeup` | ob_tenant.cpp | 1675 | 周期性检查（worker count/token） |
| `create_worker` | ob_th_worker.cpp | 38 | 创建工作线程 |
| `destroy_worker` | ob_th_worker.cpp | 83 | 销毁工作线程 |
| `ObThWorker::process_request` | ob_th_worker.cpp | 238 | 请求处理 + 重试逻辑 |
| `ObThWorker::worker` | ob_th_worker.cpp | 344 | 线程主循环 |

---

> **下一篇预告**：40 — 数据压缩与编码 — 从宏块到行的压缩链
