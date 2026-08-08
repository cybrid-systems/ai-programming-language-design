# 104-atomic-flag-state — OceanBase 原子变量应用 (2/4): Flag / State Machine 模式

> 基于 OceanBase 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")
> 源码锚点:`deps/oblib/src/lib/atomic/ob_atomic.h` + `deps/oblib/src/lib/thread/thread.h` + `src/storage/multi_data_source/mds_table_base.cpp` + `src/storage/tx_table/ob_tx_table.h` + `src/storage/memtable/ob_memtable_context.h` + `deps/oblib/src/common/ob_role_mgr.h` + `deps/oblib/src/lib/lock/ob_qsync_lock.cpp`
> 使用 doom-lsp (clangd LSP) 做符号解析与数据流追踪
> 接续 #103 Counter / Metric — 本系列 4 篇拆 OB 所有原子变量应用

---

## 0. 全文导读

OB 1024 个 atomic 文件中, **Flag / State Machine 模式** 是第二大类 (仅次于 counter)。值域小 (`{0, 1}` 或小枚举), 操作是 "读 / 写 / CAS", 业务是 "状态机 / 启停 / 标记"。

| 模式 | 本系列 | 状态 |
|------|--------|------|
| Counter / Metric | #103 | ✅ 已发布 |
| **Flag / State Machine** | **#104 (本篇)** | 📝 |
| Refcount / Hazard Pointer | #105 | 待 |
| Lock-free Data Structure | #106 | 待 |

### Flag / State 在 OB 中的分布

| 子模块 | 代表 |
|--------|------|
| 线程生命周期 | `Thread::stop_` / `ReentrantThread::stop_` / `ob_tc::is_stop_` |
| 任务状态机 | `DagScheduler::finish_flag_` / `exit_flag_` |
| 资源状态机 | `MdsTableBase::state_` (BCAS 单调迁移) / `TxTable::state_` / `TxData::state_` |
| ELR 状态机 | `ObMemtableContext::elr_state_` (INIT → DONE) |
| MemTable 一次性 | `is_inited_` / `expand_nway_called_` (BCAS single-shot) |
| 用户会话 | `ObTableSessPool::is_user_locked_` |
| 角色管理 | `ObRoleMgr::state_` (TAS 强写) |
| 简化 mutex | `qsync::write_flag_` / `darray::write_uid` |
| Schema 快照 | `stop_repost_node_` / `stop_request_retry_` |

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| #74 Thread Model | `Thread::stop_` 是所有线程的 lifecycle flag |
| #11 Trans Service | `TxData::state_` 是事务状态机核心 |
| #16 MDS / Multi-Data-Source | `MdsTableBase::state_` 是 MDS 表生命周期 |
| #103 (上一篇) | Counter vs Flag 的边界 — 同一字段可能是 Counter 或 Flag |

---

## 1. 背景 / 概念

### 1.1 Counter vs Flag

| 维度 | Counter | Flag |
|------|---------|------|
| 值域 | 大 (0 ~ INT64_MAX) | 小 (`{0, 1}` 或 4-8 个枚举) |
| 操作 | `AAF` / `FAA` | `LOAD` / `STORE` / `BCAS` |
| 一致性 | **不需要严格 total order**, 累加一致即可 | **需要严格可见性** + **状态机迁移合法性** |
| 业务 | 统计 / 限流 / 版本号 | 状态机 / 启停 / 标记 |

### 1.2 Flag / State 的 5 种形态

| 形态 | 语义 | 典型 |
|------|------|------|
| **单 bool** | true / false, 单调不可逆 | `is_stopped_` / `is_user_locked_` |
| **BCAS single-shot** | "一次性"标志, 由 false→true, 永不回退 | `expand_nway_called_` / `is_inited_` (init 路径) |
| **枚举状态机** | N 个状态, BCAS 保证迁移只能向前 / 特定路径 | `MdsTableBase::state_` / `TxData::state_` |
| **TAS 强写** | 任何写都直接覆盖, 不读旧值 | `ObRoleMgr::state_` |
| **TAS 简化 mutex** | BCAS 取锁, 退化为 0/1 互斥 | `qsync::write_flag_` / `darray::write_uid` |

### 1.3 OB 的 atomic flag 操作

| 模式 | 用途 | 示例 |
|------|------|------|
| `ATOMIC_LOAD(&flag)` | 读 flag (SEQ_CST 保证最新) | `Thread::has_set_stop()` |
| `ATOMIC_STORE(&flag, v)` | 直接写 flag | `Thread::stop()` 写 stop_=true |
| `ATOMIC_TAS(&flag, newv)` | **强写** + 返回旧值 | `ObRoleMgr::set_state` |
| `ATOMIC_BCAS(&flag, old, new)` | "如果当前是 old, 才改成 new" | `expand_nway_called_` 单次触发 |
| `while (!ATOMIC_BCAS(...))` | 自旋直到成功 | `qsync::wrlock` |

---

## 2. 实现细节

### 2.1 单 bool — Thread::stop_ 生命周期

[`deps/oblib/src/lib/thread/thread.h:215-218`](deps/oblib/src/lib/thread/thread.h):

```cpp
void set_stop(bool stop = true) {
  // ATOMIC_STORE(&stop_, stop) — 整个进程通知该 thread 退出
  ...
}
bool has_set_stop() const {
  // Thread 主循环自检: ATOMIC_LOAD(&stop_) 决定是否退出
  ...
}
private:
  bool stop_;   // ★ 标志性 flag
```

[`deps/oblib/src/lib/thread/thread.h` / `deps/oblib/src/lib/thread/threads.h`](deps/oblib/src/lib/thread/threads.h):

```cpp
bool has_set_stop() const {
  IGNORE_RETURN lib::Thread::update_loop_ts();
  return ATOMIC_LOAD(&stop_);     // ← 线程主循环自检
}
```

**所有线程抽象** (ReentrantThread / MultiFixedQueueThread / DDL Scheduler / DDL Task / LockWaitMgr 等) 都遵循这个 pattern:

| 文件 | flag 字段 |
|------|----------|
| `deps/oblib/src/lib/thread/ob_reentrant_thread.h` | `stop_` (ATL) |
| `deps/oblib/src/lib/thread/ob_multi_fixed_queue_thread.h` | `stop_flag_` |
| `deps/oblib/src/lib/thread/thread_mgr_interface.h` | `stop_` |
| `src/rootserver/ddl_task/ob_ddl_scheduler.h` | `stop_` |
| `src/rootserver/ob_rs_reentrant_thread.h` | `stop_` |
| `src/storage/tx/ob_lock_wait_mgr.cpp` | `stop_repost_node_` / `stop_request_retry_` |

**pattern**:
1. 外部线程调 `stop()` → `ATOMIC_STORE(&stop_, true)`
2. 工作线程主循环 `while (!ATOMIC_LOAD(&stop_)) { ... }` 自检退出
3. 退出时调 `wait()` join 清理

### 2.2 BCAS single-shot — MemTable expand 一次性触发

[`src/storage/memtable/ob_memtable_context.h:152-165`](src/storage/memtable/ob_memtable_context.h):

```cpp
// MemTable context 扩容: 多线程并发, 但只能扩容一次
int ObMemtableContext::expand_nway(ObIMemtableContext*& new_ctx) {
  ...
  if (ATOMIC_BCAS(&expand_nway_called_, false, true)) {   // ★ 只有第一个调用者能进
    // 真的扩容
    ...
    new_ctx = ...;
  } else {
    // 其他并发调用者跳过
  }
  ...
}
```

**为什么 BCAS**:
- 多线程并发调 `expand_nway()`, 但只能扩容**一次**
- BCAS `false→true` 保证只有第一个调用者拿到 true, 后面的全拿到 false → 跳过
- 这是"first-writer-wins" pattern

### 2.3 BCAS single-shot — is_inited_ 懒初始化

[`src/storage/memtable/ob_memtable_context.h:170-200`](src/storage/memtable/ob_memtable_context.h):

```cpp
// init 路径
int ObMemtableContext::init() {
  ...
  if (OB_FAIL(init_inner())) {
    ATOMIC_STORE(&is_inited_, false);
  } else {
    ATOMIC_STORE(&is_inited_, true);
  }
  return ret;
}

// destroy 路径
void ObMemtableContext::destroy() {
  if (ATOMIC_LOAD(&is_inited_)) {
    ATOMIC_STORE(&is_inited_, false);
    ...
  }
}

// 检查是否已 init
bool is_inited() const { return ATOMIC_LOAD(&is_inited_); }
```

这里**没用 BCAS**, 因为 init/destroy 是**有外部同步**的 (init 由 creator 调, destroy 由 destroyer 调)。但 `is_inited_` 用 `ATOMIC_LOAD` 是因为其他线程可能正在 read it (查询"是否可用")。

**关键**: 是否用 BCAS 取决于**是否真有并发竞争**。
- `expand_nway_called_` — 多线程并发, 必须 BCAS
- `is_inited_` — 单线程 write + 多线程 read, **只需要 SEQ_CST LOAD/STORE**

### 2.4 枚举状态机 — MdsTableBase

[`src/storage/multi_data_source/mds_table_base.cpp:18-38`](src/storage/multi_data_source/mds_table_base.cpp):

```cpp
int MdsTableBase::set_state(const State new_state) {
  int ret = OB_SUCCESS;
  MDS_TG(1_ms);
  bool success = false;
  while (!success && OB_SUCC(ret)) {
    State old_state = ATOMIC_LOAD(&state_);     // 1. 读当前状态
    if (new_state < old_state) {                  // 2. 状态只能向前 (单调)
      break;   // 不需要 advance
    } else if (!StateChecker[old_state][new_state]) {   // 3. 状态机迁移合法性矩阵
      ret = OB_STATE_NOT_MATCH;
      MDS_LOG(WARN, "not allow switch mds table state", ...);
    } else {
      success = ATOMIC_BCAS(&state_, old_state, new_state);   // 4. BCAS 真正迁移
    }
  }
  return ret;
}
```

**OB MDS 表状态机** (典型):

```
INIT → WRITEABLE → COMMITTING → COMMITTED → FROZEN → DELETED
                                  ↓
                              ABORTED
```

**StateChecker[][] 是一个 2D bool 矩阵**, 标识 `old → new` 是否合法。例如:
- `WRITEABLE → COMMITTING` ✅
- `COMMITTED → WRITEABLE` ❌ (不能回退)
- `COMMITTED → FROZEN` ✅
- `FROZEN → DELETED` ✅

**关键设计**:
- 单调 (`new_state < old_state` 直接 break)
- 合法矩阵 (`StateChecker[][]`)
- BCAS 保证即使并发 `set_state()` 也只有一个能成功迁移

### 2.5 枚举状态机 — TxData::state_

[`src/storage/tx_table/ob_tx_data_hash_map.cpp:106-120`](src/storage/tx_table/ob_tx_data_hash_map.cpp):

```cpp
// 查找 TxData 时检查状态
if (ObTxData::RUNNING != ATOMIC_LOAD(&tmp_value->state_)) {
  // 已提交或已 abort, 不能用
  continue;
}
```

[`src/storage/tx/ob_tx_data_functor.cpp:69`](src/storage/tx/ob_tx_data_functor.cpp):

```cpp
const int32_t state = ATOMIC_LOAD(&tx_data.state_);
// functor 在不同 state 下做不同处理:
// RUNNING → 收集 commit_info
// COMMITTED → 收集 commit_log
// ABORTED → 清理
```

**TxData 状态机**:

```
INIT → RUNNING → COMMITTED
                → ABORTED
                → ELR_COMMITTED (early lock release)
```

**为什么纯 LOAD**: TxData 状态由 tx 自己写 (commit / abort), 其他线程 (GC / cleanup / read) 只读, 用 LOAD 即可。
**写路径用什么**: 写路径 (commit / abort) 用 `ATOMIC_STORE` 或 `ATOMIC_TAS` 一次性写完。

### 2.6 ELR 状态机 — MemTable context

[`src/storage/memtable/ob_memtable_context.cpp:481-495`](src/storage/memtable/ob_memtable_context.cpp):

```cpp
if (NULL != ATOMIC_LOAD(&ctx_) && OB_SUCCESS == end_code_ &&
    ATOMIC_LOAD(&elr_state_) == ELR_STATE_INIT) {       // 1. 检查 ELR 初始态
  // 触发 ELR (Early Lock Release)
  if (OB_SUCCESS == try_elr_prepare()) {
    if (ATOMIC_LOAD(&elr_state_) == ELR_STATE_DONE) {   // 2. 检查 ELR 完成
      // 提前返回成功
    }
  }
}
```

**ELR_STATE_INIT → ELR_STATE_DONE**: 简单两态, 用 BCAS 迁移 (保证只有一个线程能完成 ELR)。

### 2.7 TAS 强写 — ObRoleMgr

[`deps/oblib/src/common/ob_role_mgr.h:120-128`](deps/oblib/src/common/ob_role_mgr.h):

```cpp
void ObRoleMgr::set_state(const State state) {
  COMMON_LOG(INFO, "before", K(get_state_str()), K(get_role_str()));
  (void)ATOMIC_TAS(reinterpret_cast<volatile uint32_t *>(&state_), state);   // ★ TAS 强写
  COMMON_LOG(INFO, "after", K(get_state_str()), K(get_role_str()));
}
```

**为什么 TAS 而非 BCAS**: ObRoleMgr 描述的是 **server 级状态** (FOLLOWER / LEADER / CANDIDATE), 不存在"如果当前是 X 才改成 Y"的逻辑 — **新状态直接覆盖旧状态**, 即使中间丢失了一些状态也无所谓。
**为什么需要 atomic**: 多个 RPC handler 会并发读 `get_state_str()` (用于日志), 必须看到最新值。

### 2.8 TAS 简化 mutex — qsync

[`deps/oblib/src/lib/lock/ob_qsync_lock.cpp:40-95`](deps/oblib/src/lib/lock/ob_qsync_lock.cpp):

```cpp
// wrlock
int ObQSyncLock::wrlock() {
  ...
  while (!ATOMIC_BCAS(&write_flag_, 0, 1)) {     // ★ 自旋锁
    PAUSE();
  }
  return OB_SUCCESS;
}

// wrunlock
void ObQSyncLock::wrunlock() {
  ATOMIC_STORE(&write_flag_, 0);
}

// try_wrlock
int ObQSyncLock::try_wrlock() {
  if (!ATOMIC_BCAS(&write_flag_, 0, 1)) {
    return OB_EAGAIN;
  }
  return OB_SUCCESS;
}

// rdlock (简化版, 只看 write_flag_)
int ObQSyncLock::rdlock() {
  if (OB_UNLIKELY(0 != ATOMIC_LOAD(&write_flag_))) {
    return OB_EAGAIN;
  }
  ...
}
```

**qsync** 是一个超简化的 read-write lock:
- `write_flag_ = 0` → unlocked
- `write_flag_ = 1` → writer holding
- 没有 reader counter — 一旦有人 wrlock, 后续所有 reader/writer 都拒
- 比真正的 RWLock (有 reader count) 简单很多, 适合**短临界区**

### 2.9 user_state — Table session pool

[`src/observer/table/object_pool/ob_table_sess_pool.h:170-180`](src/observer/table/object_pool/ob_table_sess_pool.h):

```cpp
bool is_user_locked() const {
  return ATOMIC_LOAD(&user_state_.is_user_locked_);
}

void set_user_locked(bool locked) {
  ATOMIC_STORE(&user_state_.is_user_locked_, locked);
}
```

**user_state_ 是一个复合结构**:

```cpp
struct UserState {
  bool is_user_locked_;        // 用户被锁定 (e.g. 密码错误多次)
  int64_t user_lock_expire_ts_; // 锁定到期时间
  ...
};
```

`is_user_locked_` 是 bool flag, `user_lock_expire_ts_` 是 Counter 时间戳 — 同一结构同时有 Flag 和 Counter 模式。

### 2.10 TxTable 状态

[`src/storage/tx_table/ob_tx_table.h:391`](src/storage/tx_table/ob_tx_table.h):

```cpp
TxTableState get_state() const { return ATOMIC_LOAD(&state_); }
```

TxTable 状态机:
```
INIT → WORKING → STOPPING → STOPPED
```

`set_state()` 写路径 (通常在 lifecycle hook 中) 用 `ATOMIC_STORE` 或 `ATOMIC_TAS`。

### 2.11 DDL Scheduler stop_

[`src/rootserver/ddl_task/ob_ddl_scheduler.h`](src/rootserver/ddl_task/ob_ddl_scheduler.h):

```cpp
bool has_set_stop() const { return ATOMIC_LOAD(&stop_); }
void set_stop(bool stop) { ATOMIC_STORE(&stop_, stop); }
```

DDL scheduler 工作线程:
```cpp
while (!ATOMIC_LOAD(&stop_)) {
  // 处理一个 DDL 任务
  ...
}
```

**标准 Thread lifecycle pattern**, 与 Thread::stop_ 完全一致。

---

## 3. 性能优化

### 3.1 BCAS 自旋 vs OS mutex

| 维度 | BCAS 自旋锁 | OS mutex (futex) |
|------|------------|------------------|
| 取锁延迟 | < 100 ns (无 syscall) | ~1-5 μs (futex wake) |
| 释放延迟 | < 50 ns | ~1 μs |
| 适用场景 | 临界区 < 1 μs | 临界区 > 1 μs (可能 syscall) |
| CPU 占用 | 高 (自旋烧 CPU) | 低 (睡眠) |
| 公平性 | 不公平 (可能饿死) | 较公平 (futex 排队) |

OB 的 qsync / darray / multi_mod_ref_mgr 等都用 BCAS 自旋锁, 因为临界区都是纳秒级。

### 3.2 PAUSE() 指令的作用

[`deps/oblib/src/lib/atomic/ob_atomic.h:19-25`](deps/oblib/src/lib/atomic/ob_atomic.h):

```cpp
#if defined(__x86_64__)
#define PAUSE() ({OB_ATOMIC_EVENT(atomic_pause); asm("pause\n");})
#elif defined(__aarch64__)
#define PAUSE() ({OB_ATOMIC_EVENT(atomic_pause); asm("yield\n");})
```

`PAUSE()` 在 x86 上是 `pause` 指令 (~10 cycles):
1. **通知 CPU 这是自旋**, 触发 SMT 资源释放 (避免和兄弟 thread 抢流水线)
2. **降低功耗** (Skylake+ 在 pause 上省 50% 功耗)
3. **避免 memory order 流水线清空** (后续 load 不会被乱序)

OB 所有自旋锁 pattern 都有 `PAUSE()`:
```cpp
while (!ATOMIC_BCAS(...)) {
  PAUSE();   // ★ 必须
}
```

### 3.3 BCAS 退避策略

OB 没有指数退避 (不像 Java `BackOff`), 全部用 `PAUSE()` 简单延迟。在高度竞争场景下可能**浪费 CPU**, 但 OB 自旋锁多用于**临界区极短**的场景 (ns 级), 不会有严重问题。

### 3.4 TAS vs BCAS 选择

| 场景 | 选择 | 理由 |
|------|------|------|
| **强写** (新值直接覆盖) | `TAS` | ObRoleMgr, 不需要读旧值 |
| **条件写** (只有当前是 X 才写) | `BCAS` | expand_nway_called_, qsync write_flag_ |
| **读路径** | `LOAD` | Thread::stop_, TxTable state |
| **写路径, 无并发** | 普通 `STORE` | (但仍用 `ATOMIC_STORE` 保证 visibility) |

### 3.5 Flag 字段位置的影响

Flag 字段如果和 hot data 在同一 cache line, 写 flag 会让所有读 hot data 的 thread 重新 load cache line (false sharing)。OB 部分代码用 `CACHE_ALIGNED` 隔离:

```cpp
class ObQSyncLock {
  ...
private:
  uint32_t write_flag_ CACHE_ALIGNED;
  ...
};
```

---

## 4. 与 v2 主线的连接

| v2 文章 | Flag / State 维度 |
|---------|------------------|
| #11 (Trans Service) | `TxData::state_` / `TxTable::state_` 事务状态机 |
| #16 (MDS / Multi-Data-Source) | `MdsTableBase::state_` MDS 表状态机 |
| #74 (Thread Model) | `Thread::stop_` / `ReentrantThread::stop_` 线程 lifecycle |
| #75 (Latch System) | latch 内部状态 (详细 latch 状态在 #75) |
| #36 (Concurrency Control) | `ObMemtableContext::elr_state_` ELR 状态机 |
| #103 (上一篇) | Counter vs Flag 边界 — 同一字段可能是 Counter 或 Flag |
| #105 (下一篇) | Flag 模式 vs Refcount 模式 — 都用 BCAS 但语义不同 |

### 主线架构图 (Flag / State 层)

```
┌──────────────────────────────────────────────────────┐
│  Flag / State 集群                                   │
│                                                      │
│  Thread::stop_                                       │  ← bool flag (lifecycle)
│  MdsTableBase::state_ (INIT → WRITEABLE → COMMITTING)│  ← enum state machine (BCAS)
│  TxData::state_ (RUNNING → COMMITTED/ABORTED)        │  ← enum state machine (LOAD)
│  TxTable::state_ (INIT → WORKING → STOPPED)          │  ← enum state machine (LOAD)
│  ObMemtableContext::elr_state_ (INIT → DONE)         │  ← enum state machine (BCAS)
│  ObMemtableContext::is_inited_                        │  ← bool flag (RAII)
│  ObMemtableContext::expand_nway_called_               │  ← bool flag (single-shot BCAS)
│  ObRoleMgr::state_ (FOLLOWER/LEADER/CANDIDATE)        │  ← enum (TAS 强写)
│  qsync::write_flag_                                   │  ← simplified mutex
│  DDL Scheduler::stop_                                 │  ← bool flag (lifecycle)
└──────────────────────────────────────────────────────┘
                  ▲                       │
                  │ LOAD/BCAS/TAS         │ STORE/BCAS
                  │ (读路径)              │ (写路径)
                  ▼                       │
┌──────────────────────────────────────────────────────┐
│  调用方                                              │
│  - 线程主循环 (自检 stop_ 决定退出)                   │
│  - RPC handler (读 ObRoleMgr::state_ 用于日志)       │
│  - GC / cleanup (读 TxData::state_ 决定回收)         │
│  - 状态迁移 setter (BCAS 写新状态)                   │
└──────────────────────────────────────────────────────┘
```

---

## 5. 调优 Checklist

| 项 | 检查方法 | 推荐 |
|----|---------|------|
| 自旋锁临界区是否 < 1 μs | perf / ftrace | 是 (否则换 futex) |
| 自旋锁 pattern 是否有 PAUSE() | grep `while.*ATOMIC_BCAS` | 必须 PAUSE() |
| 状态机迁移是否有合法性检查 | grep `StateChecker` | 必须 |
| Flag 字段是否 CACHE_ALIGNED | grep `CACHE_ALIGNED` | hot flag 用 |
| BCAS 是否有 retry 限制 | 观察 retry 循环 | 必须有 break 条件 |
| State 字段是否 SEQ_CST load | grep `ATOMIC_LOAD.*state` | 默认 SEQ_CST |

---

## 6. 常见故障 case

### Case 1: BCAS 自旋死锁

**现象**: 进程 hang, `perf top` 显示 100% 在某自旋循环
**原因**:
1. 临界区内拿不到另一个锁 (lock order 反)
2. 临界区内调了 syscall 又回来重试
**排查**:
```bash
# 看栈, 确认 critical section 内的 call
gdb -p $(pidof observer) -batch -ex "bt"
```
**修复**: 拆锁, 或换 futex, 或加超时退出

### Case 2: 状态机迁移非法但被允许

**现象**: `set_state(COMMITTED → set_state(WRITEABLE))` 居然成功
**原因**: `StateChecker[][]` 没正确配置, 或 BCAS 没检查 old_state
**排查**: 看 set_state 代码, 确认有 `if (!StateChecker[old][new])` 检查
**修复**: 加 StateChecker 矩阵 + BCAS 双保险

### Case 3: stop_ 写了但 thread 不退出

**现象**: `set_stop(true)` 调了, 但工作线程继续运行
**原因**: 工作线程主循环没读 `stop_`, 或读了但用了普通 bool 而非 read
**排查**: grep 工作线程主循环, 确认有 `ATOMIC_LOAD(&stop_)` 或 `has_set_stop()`
**修复**: 工作线程主循环加 `if (ATOMIC_LOAD(&stop_)) break;`

### Case 4: ELR_STATE_DONE 被多次触发

**现象**: `elr_state_` 已是 DONE, 但又有线程触发 ELR
**原因**: BCAS 没在 `INIT → DONE` 迁移时检查 (或迁移后没阻止再次迁移)
**修复**:
```cpp
if (ATOMIC_LOAD(&elr_state_) == ELR_STATE_INIT) {
  if (ATOMIC_BCAS(&elr_state_, INIT, DONE)) {
    // 真的做了 ELR
  }
  // else: 其他线程已经做了, 跳过
}
```

### Case 5: ObRoleMgr 状态错乱

**现象**: server 状态显示 LEADER 但实际是 FOLLOWER, 或反之
**原因**: TAS 强写丢状态 (中间状态被覆盖), 或 election 状态机有问题
**排查**: 看 election log + `ATOMIC_TAS` 调用栈
**修复**: TAS 调用方必须保证 election 状态机逻辑正确, 否则改用 BCAS + 合法性检查

---

## 7. 参考 (可执行源码锚点)

| 路径 | 行 | 锚点 |
|------|---|------|
| `deps/oblib/src/lib/atomic/ob_atomic.h` | 23-39 | ATOMIC_LOAD/LOAD_ACQ/LOAD_RLX |
| `deps/oblib/src/lib/atomic/ob_atomic.h` | 56-79 | ATOMIC_FAA/AAF/BCAS/TAS/SET |
| `deps/oblib/src/lib/atomic/ob_atomic.h` | 19-25 | PAUSE() 指令 (x86/aarch64) |
| `deps/oblib/src/lib/thread/thread.h` | 215-218 | `Thread::set_stop` / `has_set_stop` |
| `deps/oblib/src/lib/thread/threads.h` | (full) | `Threads::has_set_stop` |
| `src/storage/multi_data_source/mds_table_base.cpp` | 18-38 | MdsTableBase::set_state BCAS 单调迁移 + StateChecker |
| `src/storage/tx_table/ob_tx_data_hash_map.cpp` | 106-120 | TxData::state_ LOAD |
| `src/storage/tx_table/ob_tx_table.h` | 391 | TxTable::state_ LOAD |
| `src/storage/tx/ob_tx_data_functor.cpp` | 69, 104, 177, 238, 391 | TxData state 多处读 |
| `src/storage/memtable/ob_memtable_context.h` | 50-65 | RetryInfo |
| `src/storage/memtable/ob_memtable_context.h` | 140-200 | alloc_count_/free_count_/is_inited_ |
| `src/storage/memtable/ob_memtable_context.cpp` | 481-495 | elr_state_ INIT → DONE |
| `deps/oblib/src/common/ob_role_mgr.h` | 120-128 | ObRoleMgr::set_state TAS |
| `deps/oblib/src/lib/lock/ob_qsync_lock.cpp` | 40-95 | qsync BCAS 简化 mutex |
| `src/observer/table/object_pool/ob_table_sess_pool.h` | 170-180 | user_state.is_user_locked_ |
| `src/rootserver/ddl_task/ob_ddl_scheduler.h` | (full) | DDL Scheduler stop_ |

---

## 8. Cross-cutting 列表

- **Counter vs Flag 边界**: 同一字段可能是 Counter (累加) 或 Flag (状态机) — `state_` 字段值域是 enum 时是 Flag, 是 int64_t 时是 Counter
- **TAS vs BCAS 选择**: TAS 强写 (新值覆盖), BCAS 条件写 (只有当前是 X 才写) — 业务必须有"读旧值决定写新值"的逻辑时才用 BCAS
- **StateChecker 矩阵**: 状态机迁移合法性检查, **OB MDS 的核心安全网** — 缺了它, 状态可以乱跳
- **PAUSE() 必须**: 所有自旋锁 pattern 必须 `while(!BCAS) { PAUSE(); }`, 否则烧 CPU + 拖慢兄弟 thread
- **CACHE_ALIGNED on hot flag**: hot flag 字段用 cache line 对齐避免 false sharing
- **LOAD vs BCAS 读**: 读 flag 用 LOAD (不需要 BCAS, 因为不需要条件修改), 写 flag 用 BCAS / STORE / TAS
- **single-shot 一次性**: `expand_nway_called_` 是 BCAS single-shot, 用于 "多线程并发但只能做一次" 的场景
- **lifecycle flag vs state machine**: lifecycle flag (stop_) 是简单的 bool 单调不可逆; state machine 是 enum 多状态 + 迁移合法性
- **qsync 简化 mutex**: BCAS on write_flag_ 是最简化的 spinlock, 适合临界区 < 1 μs 场景, 比 OS futex 快 10x
- **observability**: Flag 状态通常映射到 `v$role` / `v$mds_table_status` 等虚拟表

---

## 9. 下一篇预告

#105 — 原子变量应用 (3/4): **Refcount / Hazard Pointer 模式** —
`ObTenantCtxAllocator::ref_cnt_` (简单 FAA 累加) / `ob_link_hashmap uref_/href_` (BORN_REF 魔法值 + 原子化生命周期) / `ob_multi_mod_ref_mgr` (FAA + BCAS spinlock) / `drwlock::ref` (FAA reader 计数) / `KV cache HazardPointer + SharedHazptr` (完整 hazard pointer domain + retire list + scan)。

揭晓: 同一份 atomic 宏, 当业务是"对象生命周期"时, refcount 模式要解决 **ABA 问题** (refcount 从 1 减到 0 再加回 1), OB 用 **BORN_REF 魔法值** + **hazard pointer** 两种思路。