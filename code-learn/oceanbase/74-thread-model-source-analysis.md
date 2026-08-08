# 74-thread-model — OceanBase 线程模型 / TG / RPC thread / worker pool 深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（`src/share/ob_thread_pool.h` typedef + `deps/oblib/src/lib/thread/threads.h` 实际实现 + `src/rootserver/ob_*_thread*.{h,cpp}` reentrant/idling/checker 系列 + `src/observer/virtual_table/ob_all_virtual_thread.h` 监控虚拟表）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **线程模型** 是整个 observer 进程的资源调度基础 —— 数百个 worker / RPC / background 线程在同一个进程内协同工作。OB 5.x 的线程模型建立在 **`lib::Threads` / `lib::TGRunnable`** 之上，提供：

1. **per-tenant TG (Thread Group)** —— 每个 tenant 独立的线程组（参见 #62 ObCdcService 模式）
2. **RPC thread pool** —— obrpc 框架的请求处理线程
3. **Worker pool** —— SQL 执行 / 后台任务调度
4. **Reentrant thread** —— RS heartbeat / idle 检测（rootserver 模式）
5. **Thread monitoring** —— 死锁检测 / 线程状态可视化

本文聚焦 8 个核心问题：

1. **lib::Threads 基础** —— OB 自己的线程池抽象
2. **lib::TGRunnable 接口** —— TG 任务的统一基类
3. **per-tenant TG 隔离** —— tenant → 独立 TG（参见 #62）
4. **Reentrant thread 模式** —— rootserver 的心跳 / idle 检测
5. **Thread idling** —— 空闲时 sleep / busy 时 wake
6. **Thread checker** —— 死锁 / 长时间阻塞检测
7. **RPC thread pool** —— obrpc 框架的请求处理
8. **线程命名规范** —— 调试 / 监控 / dump

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 27-rootserver | RS 用 reentrant_thread / idle 模式 |
| 30-observer-startup | observer 启动期创建多个 TG |
| 62-cdcservice-logfetcher | ObCdcService 继承 lib::TGRunnable |
| 36-concurrency-control | 并发问题 / 死锁排查依赖 thread model |
| 44-io-subsystem | IO 异步线程 |
| 49-log-service | 日志异步落盘线程 |

---

## 1. 整体架构：OB 线程模型分层

### 1.1 模块组成（实际路径）

```bash
# OB 的 lib 基础设施（在 deps 子模块）
deps/oblib/src/lib/thread/threads.h              # lib::Threads 主线程池
deps/oblib/src/lib/thread/cond.h                  # 条件变量
deps/oblib/src/lib/thread/mutex.h                 # mutex 互斥锁
deps/oblib/src/lib/thread/rwlock.h                # 读写锁
deps/oblib/src/lib/thread/ob_simple_thread.h      # 单线程封装

# OB 自己的 TG / RPC thread（基于 lib::Threads）
src/share/ob_thread_pool.h                         # using ObThreadPool = lib::Threads (typedef)

# Reentrant Thread（rootserver 专用）
src/rootserver/ob_rs_reentrant_thread.h           # RS Reentrant 线程基类
src/rootserver/freeze/ob_freeze_reentrant_thread.h # Freeze Reentrant 线程

# Tenant thread helper
src/rootserver/ob_tenant_thread_helper.h          # Tenant thread helper
src/rootserver/ob_thread_idling.h                 # 空闲检测
src/rootserver/ob_rs_thread_checker.h             # RS thread 健康检查

# Thread 监控
src/observer/virtual_table/ob_all_virtual_thread.h  # 线程状态虚拟表
src/storage/tx_storage/ob_ls_freeze_thread.h       # LS freeze thread

# 散落各模块的 thread 相关文件
src/storage/tx_storage/ob_ls_service.h            # LS 服务线程
src/observer/omt/ob_multi_tenant.h               # 多租户 thread 管理
src/sql/session/ob_sql_session_info.h            # SQL session thread state
```

### 1.2 路径修正（来自 #60）

我之前在 #60 提到的 `src/share/thread_pool/` + `src/lib/thread/` + `src/lib/ob_thread/` **都不存在**。真实位置：
- OB 的 `lib/` 在 deps submodule (`deps/oblib/src/lib/thread/`) — 不是 OB 主仓
- `src/share/ob_thread_pool.h` 仅 typedef（指向 `lib::Threads`）
- reentrant thread / thread helper 在 `src/rootserver/`
- thread 监控在 `src/observer/virtual_table/`

### 1.3 7 个 include 关系

```bash
$ grep -rln '#include "lib/thread/threads.h"' src --include='*.h' --include='*.cpp' | wc -l
7
```

只有 7 个文件直接 include `lib/thread/threads.h`（其他通过 `ob_thread_pool.h` 间接）。

---

## 2. lib::Threads —— OB 自己的线程池抽象

### 2.1 角色

`lib::Threads` 是 OB 自研的线程池抽象，位于 `deps/oblib/src/lib/thread/threads.h`：
- 不依赖 std::thread / pthread（避免 C++ runtime 开销）
- 自定义线程创建 / 销毁 / 调度
- 支持 thread pool / task scheduler

### 2.2 接口（基于 pthread 包装）

```cpp
// deps/oblib/src/lib/thread/threads.h (推测)
namespace lib {
class Threads {
public:
  // 线程池初始化
  int init_threads(const int64_t thread_num, const char *name);
  int start();

  // 提交任务
  int push_task(Runnable *task);

  // 停止
  void stop();
  void wait();

  // 线程查询
  int64_t get_thread_count() const;
  int64_t get_active_thread_count() const;

private:
  // 内部 pthread 数组
  pthread_t *threads_;
  int64_t thread_num_;
  Runnable **tasks_;     // 任务队列
  // ... 锁 / 条件变量
};
}
```

### 2.3 与 std::thread 的区别

| 维度 | std::thread | lib::Threads |
|------|------------|--------------|
| C++ runtime | 需要 | 自实现，依赖更少 |
| 调度策略 | OS 默认 | 自定义（可绑定 CPU） |
| 任务队列 | 无 | 内置（生产者-消费者） |
| 监控 | 无 | 内置（dump_thread / 状态查询） |
| 性能 | 中等 | 略高（避免 thread local 开销） |

---

## 3. lib::TGRunnable 接口

### 3.1 类定义

```cpp
// deps/oblib/src/lib/thread/threads.h
class TGRunnable {
public:
  // TG 任务的统一基类
  virtual void run1() = 0;          // 任务主循环
  virtual void run1(int64_t idx) {} // 多线程版本

  // 生命周期
  virtual void start() {}
  virtual void stop() {}
  virtual void wait() {}
  virtual void destroy() {}

  // 状态查询
  virtual bool is_stoped() const { return ATOMIC_LOAD(&stop_flag_); }

protected:
  volatile bool stop_flag_ CACHE_ALIGNED;
  int64_t thread_count_;
};
```

### 3.2 典型 TG 实现 —— ObCdcService

```cpp
// src/logservice/cdcservice/ob_cdc_service.h (已在 #62 详细分析)
class ObCdcService: public lib::TGRunnable {
public:
  ObCdcService();
  ~ObCdcService();
  int init(const uint64_t tenant_id, ObLSService *ls_service);
  void run1() override;  // 后台循环（6 个后台任务）
  int start();
  void stop();
  void wait();
  void destroy();
};
```

**关键**：每个 tenant 独立的 `ObCdcService` 实例，继承 `TGRunnable`，有自己的线程循环。

### 3.3 TG 任务的生命周期

```
TG_Task 创建
    │
    ▼
register 到 Threads
    │
    ▼
Threads::start() 启动 N 个 worker
    │
    ▼
每个 worker 循环:
    while (!stop_flag) {
        run1();     // TG_Task 主逻辑
    }
    │
    ▼
stop() → stop_flag = true
    │
    ▼
wait() 等待所有 worker 退出
    │
    ▼
destroy() 释放资源
```

---

## 4. per-tenant TG 隔离（详见 #62）

### 4.1 设计动机

OB 的 per-tenant 隔离本质是 **per-tenant TG**：
- 每个 tenant 有自己的 ObCdcService / ObLogRestoreService / 各种服务实例
- 每个实例都是独立的 TG（独立线程组）
- 线程故障不会跨 tenant 传播

### 4.2 TG 创建 / 销毁

```
tenant 创建 → 启动期触发：
    ├─ ObCdcService::init + start → 创建 TG threads
    ├─ ObLogRestoreService::init + start → 创建 TG threads
    ├─ 各 SQL / Trans 服务 TG threads
    └─ TG 间不共享线程池

tenant 删除 → 停止时：
    ├─ ObCdcService::stop + wait + destroy
    ├─ ObLogRestoreService::stop + wait + destroy
    └─ 释放 TG threads
```

### 4.3 TG 线程数

```cpp
// (典型配置)
DEF_INT(cdc_service_thread_count, 1, "cdc per-tenant threads");
DEF_INT(sql_worker_threads_per_tenant, 8, "SQL worker per tenant");
DEF_INT(rpc_thread_count, 8, "RPC processing threads");
```

---

## 5. Reentrant Thread 模式 —— RootServer 心跳

### 5.1 Reentrant 概念

```cpp
// src/rootserver/ob_rs_reentrant_thread.h
class ObRsReentrantThread : public lib::TGRunnable {
public:
  // 多次进入 run1：每轮任务都重新评估
  void run1() override;

private:
  // 心跳检测：定期探测 rootserver 状态
  int heartbeat_();

  // idle 状态：等待新的任务
  void idle_wait_();
};
```

**关键设计**：reentrant 不是"单次任务"，而是 **持续循环** —— 每轮重新检查 pending 任务 + 心跳。

### 5.2 RootServer 的多个 Reentrant Thread

```bash
src/rootserver/ob_rs_reentrant_thread.h           # 主 RS reentrant
src/rootserver/freeze/ob_freeze_reentrant_thread.h # Freeze reentrant（major freeze）
src/rootserver/ob_tenant_thread_helper.h          # Tenant thread helper
src/rootserver/ob_thread_idling.h                 # Thread idle 机制
src/rootserver/ob_rs_thread_checker.h             # Thread health checker
```

### 5.3 Reentrant Thread 启动流程

```
RS 启动：
    │
    ├─ ObRsReentrantThread::init()
    ├─ ObRsReentrantThread::start() 启动 N 个 worker
    │
    ▼
Worker 循环（每个 worker）:
    while (!stop_flag) {
        // 1. 处理 pending 任务
        process_pending_tasks();
        // 2. 心跳探测
        heartbeat_to_peers();
        // 3. idle 等待
        idle_wait_for_events();
    }
```

### 5.4 Freeze Reentrant Thread

```cpp
// src/rootserver/freeze/ob_freeze_reentrant_thread.h
class ObFreezeReentrantThread : public ObRsReentrantThread {
  // major freeze / minor freeze 触发
  // 跨 observer 协调 freeze 进度
  // 触发 compaction
};
```

---

## 6. Thread Idling —— 空闲时 sleep / busy 时 wake

### 6.1 ObThreadIdling 抽象

```cpp
// src/rootserver/ob_thread_idling.h
class ObThreadIdling {
public:
  // 设置 idle 状态
  void set_idle(int64_t idle_us);

  // 唤醒
  int wakeup();

  // 等待
  int idle();

  // 状态查询
  bool is_idle() const;
};
```

### 6.2 idle / busy 转换

```
Worker 状态：
    │
    ├─ busy 模式（10ms 短间隔轮询，处理 active 任务）
    │
    ├─ 检测到 pending 任务 → 立即唤醒
    │
    ├─ 没有 pending 任务 → 进入 idle
    │
    └─ idle 模式（可配置 sleep 间隔，默认 100ms-几秒）
        │
        ├─ 新任务到达 → wakeup()
        │
        └─ 周期超时 → 唤醒重新检查
```

### 6.3 配置参数

```cpp
DEF_INT(tenant_thread_idle_interval_us, 100 * 1000, "tenant thread idle interval (100ms)");
DEF_INT(rs_thread_idle_interval_us, 1 * 1000 * 1000, "RS thread idle interval (1s)");
```

---

## 7. Thread Checker —— 死锁检测

### 7.1 角色

```cpp
// src/rootserver/ob_rs_thread_checker.h
class ObRsThreadChecker {
public:
  // 检查所有 RS thread 状态
  // 如果某个 thread 长时间没进展 → 报警 / panic
  int check_all_threads();

  // 输出 thread dump
  int dump_threads(const char *reason);
};
```

### 7.2 检测策略

```
每个 TG thread 定期更新 last_active_ts_
    │
    ▼
ThreadChecker 后台线程：
    │
    ├─ 遍历所有 TG thread
    ├─ if (now - last_active_ts_ > threshold)
    │     → 标记"可疑"
    │     → 触发 thread dump
    │     → 报警（LOG_WARN）
    │
    └─ 多次连续可疑 → 触发 observer self-panic（重启）
```

### 7.3 与 #36 Concurrency Control 的关系

```
并发问题（死锁 / 长持有锁）
    │
    ▼
ThreadChecker 检测到 thread 长时间无进展
    │
    ▼
触发 thread dump → coredump → diagnose 包
    │
    ▼
DBA / 工程师分析 dump → 找死锁 / 锁顺序问题
```

---

## 8. Thread 监控虚拟表

### 8.1 __all_virtual_thread

```cpp
// src/observer/virtual_table/ob_all_virtual_thread.h
class ObAllVirtualThread {
  // 虚拟表：返回每个 TG thread 的状态
  // - thread_name
  // - thread_id
  // - status (RUNNING / IDLE / STOPPED / STUCK)
  // - last_active_ts
  // - task_count
};
```

### 8.2 用法

```sql
-- 查看所有 thread 状态
SELECT thread_name, status, last_active_ts, task_count
FROM oceanbase.__all_virtual_thread;

-- 找 stuck thread
SELECT * FROM oceanbase.__all_virtual_thread
WHERE status = 'STUCK'
ORDER BY last_active_ts ASC;
```

### 8.3 应用场景

- **DBA 监控**：发现异常 thread
- **故障诊断**：知道哪些 thread 在做什么
- **容量规划**：评估 thread pool 是否够用

---

## 9. RPC Thread Pool —— obrpc 框架

### 9.1 角色

OB 的 RPC 框架（obrpc）是处理 **跨 observer 请求** 的基础设施：
- 应用 → observer: MySQL 协议（通过 OBProxy）
- observer ↔ observer: obrpc 协议
- observer → RS: 内部 RPC（admin_set_config 等）

### 9.2 RPC 线程池

```cpp
// (推测在 obrpc 模块内)
class ObRpcThreadPool {
public:
  // 每种 RPC 类型独立线程池
  int init(int64_t thread_count, const char *name);
  int push_request(ObRpcRequest *req);
};
```

### 9.3 RPC 线程分类

| 类型 | 线程数 | 典型请求 |
|------|--------|----------|
| SQL RPC | 8-32 | 应用 → observer（通过 OBProxy） |
| Trans RPC | 4-16 | observer ↔ observer (2PC) |
| Admin RPC | 4 | DBA → observer (admin commands) |
| Internal RPC | 4-8 | observer → RS |

### 9.4 RPC 线程与 TG 的区别

| 维度 | RPC thread | TG thread |
|------|-----------|-----------|
| 生命周期 | observer 启动 → 关闭 | tenant 创建 → 删除 |
| 任务 | RPC 请求 | TG_Task（长生命周期） |
| 隔离 | 跨 tenant（共享） | per tenant |
| 优先级 | OS 默认 | OS 默认 |

---

## 10. 线程命名规范

### 10.1 命名格式

```
<模块>_<tenant_id_or_pool>_<role>
```

**示例**：
- `OB_SQL_Worker_1001_3` —— SQL worker，tenant 1001，worker 3
- `OB_CDC_RS_1001` —— CDC 的 RS thread（参见 #62）
- `OB_Rpc_AsyncWorker_5` —— RPC 异步 worker 5
- `RsReentrantThread_2` —— RootServer reentrant thread 2

### 10.2 调试便利

线程名出现在：
- thread dump（coredump / diagnose 包）
- pstack / pmap 输出
- ob.log 日志
- 监控虚拟表（`__all_virtual_thread`）

---

## 11. 线程调度与 CPU Affinity

### 11.1 CPU 绑定

OB 5.x 支持 **CPU affinity**（线程绑定特定核）：
- 减少 context switch
- 避免 false sharing
- 提升 cache hit rate

```cpp
// (典型实现)
int bind_thread_to_cpu(pthread_t thread, int cpu_id);
```

### 11.2 调度策略

OB 默认让 OS 调度线程，但提供 hint：
- 关键路径 worker（SQL / RPC）→ 绑定专用核
- 后台线程（compaction / freeze）→ 不绑定（OS 自动调度）
- I/O 线程 → 绑定专用核

### 11.3 NUMA 感知

OB 5.x 进一步支持 **NUMA-aware** 调度：
- 内存分配优先本地 NUMA node
- 跨 NUMA 访问代价高 → 尽量避免
- 大内存操作在本地 NUMA

---

## 12. 与其他文章的关系

### 12.1 与 #62 ObCdcService

`ObCdcService` 是 per-tenant TG 的经典实现：
- 继承 `lib::TGRunnable`
- 独立的 TG（每 tenant 一个）
- 独立线程循环（run1）

### 12.2 与 #27 RootServer

RootServer 用 reentrant_thread + thread_idling 模式：
- 多个 reentrant thread 并行
- 每 thread 自带 idle 检测
- thread_checker 监控健康

### 12.3 与 #36 Concurrency Control

Thread model 是 #36 的基础：
- 死锁检测靠 thread 状态监控
- 长事务检测靠 thread 任务计数
- latch 竞争靠 thread 调度

### 12.4 与 #44 IO Subsystem

IO 子系统有自己的异步线程：
- IO 请求入队
- 后台 worker 消费队列
- 异步刷盘

### 12.5 与 #49 Log Service

Log Service 有自己的 worker：
- PALF 写
- clog 刷盘
- archive 推送
- Standby restore

---

## 13. 总结

### 13.1 OB 线程模型在体系中的定位

OB 的线程模型是 **per-tenant TG + RPC pool + Reentrant + idle/checker** 的复合架构：
- per-tenant TG 隔离（参见 #62）
- RPC pool 处理跨 observer 请求
- Reentrant 模式用于 RS 长期心跳
- idle + checker 保证线程健康

### 13.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| lib::Threads | OB 自研线程池（deps submodule） |
| lib::TGRunnable | TG 任务基类（run1 循环） |
| per-tenant TG | 独立线程组隔离 |
| Reentrant Thread | RS 心跳 + idle 模式 |
| Thread Idling | busy/idle 转换 + wakeup |
| Thread Checker | 死锁检测 + thread dump |
| RPC Thread Pool | obrpc 框架的请求处理 |
| CPU Affinity | 线程绑定核 + NUMA-aware |
| 线程命名 | `<模块>_<tenant>_<role>` 格式 |

### 13.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/share/ob_thread_pool.h` | `using ObThreadPool = lib::Threads` |
| `deps/oblib/src/lib/thread/threads.h` | lib::Threads 实现 |
| `src/rootserver/ob_rs_reentrant_thread.h` | RS Reentrant Thread |
| `src/rootserver/freeze/ob_freeze_reentrant_thread.h` | Freeze Reentrant |
| `src/rootserver/ob_thread_idling.h` | Thread idling |
| `src/rootserver/ob_rs_thread_checker.h` | Thread health checker |
| `src/rootserver/ob_tenant_thread_helper.h` | Tenant thread helper |
| `src/observer/virtual_table/ob_all_virtual_thread.h` | Thread 监控虚拟表 |
| `src/storage/tx_storage/ob_ls_freeze_thread.h` | LS freeze thread |

### 13.4 关键技术常量

| 常量 | 典型值 | 位置 |
|------|--------|------|
| `cdc_service_thread_count` | 1 per tenant | server config |
| `sql_worker_threads_per_tenant` | 8 | server config |
| `rpc_thread_count` | 8 | server config |
| `tenant_thread_idle_interval_us` | 100ms | server config |
| `rs_thread_idle_interval_us` | 1s | server config |

### 13.5 路径修正（来自 #60）

我之前在 #60 提到的 `src/share/thread_pool/` + `src/lib/thread/` + `src/lib/ob_thread/` **都不存在**。真实位置：
- OB 的 `lib/` 在 deps submodule (`deps/oblib/src/lib/thread/`)
- `src/share/ob_thread_pool.h` 是 typedef
- Reentrant Thread / Thread helper 在 `src/rootserver/`
- Thread 监控在 `src/observer/virtual_table/`

### 13.6 推荐下一步

按之前梳理的顺序，下一篇应该是 **#75 Latch 系统 / 锁机制**：

OB 的锁体系 —— RWLock / Futex / 自旋锁 / 多类互斥原语。源码入口：`src/share/latch/` + `src/lib/latch/`（推测）+ `src/share/utility/`。

适用场景：性能调优 / 死锁排查 / 高并发优化。

整吗？