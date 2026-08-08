# 103-atomic-counter-metric — OceanBase 原子变量应用 (1/4): 计数器 / 指标 模式

> 基于 OceanBase 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")
> 源码锚点:`deps/oblib/src/lib/atomic/ob_atomic.h` + `deps/oblib/src/common/ob_clock_generator.h` + `src/share/ob_autoincrement_service.cpp` + `src/share/schema/ob_schema_store.h` + `deps/oblib/src/lib/resource/ob_resource_limiter.cpp` + `deps/oblib/src/lib/tc/deps/fifo_alloc.h` + `deps/oblib/src/lib/allocator/ob_block_alloc_mgr.h` + `src/storage/memtable/ob_memtable_context.{h,cpp}`
> 使用 doom-lsp (clangd LSP) 做符号解析与数据流追踪
> 接续 #101 NUMA-Aware 线程分配 + #102 NUMA-Aware 内存分配 — 本系列 4 篇拆 OB 所有原子变量应用

---

## 0. 全文导读

OceanBase 在 1024 个 C++ 源文件中使用了 atomic 宏 (`ATOMIC_LOAD` / `ATOMIC_STORE` / `ATOMIC_FAA` / `ATOMIC_AAF` / `ATOMIC_CAS` / `ATOMIC_BCAS` / `ATOMIC_VCAS` / `ATOMIC_TAS` / `ATOMIC_SET`),按**业务语义**可归为 5 大模式。本篇是第一篇: **计数器 / 指标模式**。

| 模式 | 本篇 | 后续 |
|------|------|------|
| **Counter / Metric** | ✅ #103 (本篇) | |
| Flag / State Machine | | #104 |
| Refcount / Hazard Pointer | | #105 |
| Lock-free Data Structure | | #106 |
| Atomic SP / Lock-free Ptr | (合并到 #105) | |

### 计数器模式在 OB 中的分布

| 子模块 | 代表 |
|--------|------|
| 租户内存账本 | `AChunkMgr::hold_` / `ObTenantMemoryMgr::hold_bytes_[ctx_id]` / `ObBlockAllocMgr::hold_` |
| 资源限流 | `ObResourceLimiter::hold_` (带 `min_/max_` 阈值) |
| Schema 版本 | `ObSchemaStore::refreshed_version_` / `received_version_` / `consensus_version_` |
| 时间戳 | `ObClockGenerator::cur_ts_` |
| 序列号 | `ObAutoincrementService::local_sync_` / `last_refresh_ts_` |
| MemTable 内部 | `retry_cnt_` / `alloc_count_` / `free_count_` / `alloc_size_` |
| Compactor / Worker | `map_queue::produce_seq_` / `consume_seq_` |
| 任意类型 | `ATOMIC_FAA(&x, delta)` / `ATOMIC_AAF(&x, delta)` |

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| #25 内存管理 | `ObTenantMemoryMgr::hold_bytes_` 是 #25 的核心, 用 ATOMIC_AAF 累加 |
| #28 Resource/Unit/Tenant | `ObResourceLimiter` / `ObBlockAllocMgr` 是租户资源限流的基础 |
| #74 Thread Model | `map_queue::produce_seq_` 是 worker pool 的分配序号 |
| #11 Trans Service | `tx_data.state_` 是事务生命周期计数器 (#104 详述) |
| #104 (下一篇) | 计数器 vs Flag 的语义边界 — 同一字段可能两种语义 |

---

## 1. 背景 / 概念

### 1.1 Counter / Metric 与 Flag 的边界

| 维度 | Counter | Flag |
|------|---------|------|
| 值域 | 大 (0 ~ INT64_MAX) | 小 (bool / enum) |
| 操作 | 加减 (FAA / AAF) | 读 / 写 / CAS |
| 业务 | 统计 / 限流 / 版本号 | 状态机 / 启停 / 标记 |
| 一致性 | **不需要严格 total order**, 累加一致即可 | **需要严格可见性**, 改完需立即全局可见 |

本篇覆盖 Counter, Flag 在 #104。

### 1.2 OB 的 atomic 宏分级

[`deps/oblib/src/lib/atomic/ob_atomic.h:23-39`](deps/oblib/src/lib/atomic/ob_atomic.h):

```cpp
#define ATOMIC_LOAD(x)       __atomic_load_n((x), __ATOMIC_SEQ_CST)
#define ATOMIC_LOAD_ACQ(x)   __atomic_load_n((x), __ATOMIC_ACQUIRE)
#define ATOMIC_LOAD_RLX(x)   __atomic_load_n((x), __ATOMIC_RELAXED)
#define ATOMIC_STORE(x, v)   __atomic_store_n((x), (v), __ATOMIC_SEQ_CST)
#define ATOMIC_STORE_REL(x, v) __atomic_store_n((x), (v), __ATOMIC_RELEASE)
#define ATOMIC_STORE_RLX(x, v) __atomic_store_n((x), (v), __ATOMIC_RELAXED)
#define ATOMIC_FAA(val, addv)   __sync_fetch_and_add((val), (addv))     // 旧值 + 新增
#define ATOMIC_AAF(val, addv)   __sync_add_and_fetch((val), (addv))     // 新值 = 旧值 + delta
#define ATOMIC_FAS(val, subv)   __sync_fetch_and_sub((val), (subv))
#define ATOMIC_SAF(val, subv)   __sync_sub_and_fetch((val), (subv))
#define ATOMIC_TAS(val, newv)   __atomic_exchange_n((val), (newv), __ATOMIC_SEQ_CST)
#define ATOMIC_VCAS(val, cmp, newv) __sync_val_compare_and_swap(...)   // 返回旧值
#define ATOMIC_BCAS(val, cmp, newv) __sync_bool_compare_and_swap(...)   // 返回 bool
#define ATOMIC_INC(val) do { IGNORE_RETURN ATOMIC_AAF((val), 1); } while (0)
#define ATOMIC_DEC(val) do { IGNORE_RETURN ATOMIC_SAF((val), 1); } while (0)
```

**关键选择**:
- 默认 `ATOMIC_LOAD/ATOMIC_STORE` = `__ATOMIC_SEQ_CST` (最严格)
- 弱序版本显式标注 `_ACQ` / `_REL` / `_RLX` 后缀
- `FAA` (fetch-add) 返回**旧值**, `AAF` (add-fetch) 返回**新值** — OB Counter **几乎全用 AAF**, 仅统计需要"旧值"时用 FAA

### 1.3 Counter 模式的 4 种形态

| 形态 | 语义 | 典型 |
|------|------|------|
| **累加型** | 单调递增 / 累加 / 累减 | seq counter, hold_bytes_ |
| **水位型** | 累加但有上限 / 下限 | ObResourceLimiter (min_/max_) |
| **版本型** | 单调递增, 表示 schema / 配置版本 | refreshed_version_ |
| **时间型** | 单调递增, 表示时间戳 | ObClockGenerator::cur_ts_ |

---

## 2. 实现细节

### 2.1 累加型 — 租户内存账本

[`src/share/resource_manager/ob_resource_limiter.cpp`](src/share/resource_manager/) — `ObResourceLimiter` 用 `ATOMIC_AAF` 做带阈值检查的累加:

```cpp
// 检查 hold_ 是否会超 max_, 然后 atomic add
if (ATOMIC_AAF(&hold_, quota) > max_) {
  // 超阈值, 回滚
  ATOMIC_AAF(&hold_, -quota);
  return OB_EXCEED_MEM_LIMIT;
}
```

[`deps/oblib/src/lib/tc/deps/fifo_alloc.h:14-30`](deps/oblib/src/lib/tc/deps/fifo_alloc.h) — `FifoAllocator` 用 AAF 做 hold 检查:

```cpp
int ret = ATOMIC_AAF(&ref_, x);     // 引用计数累加
...
if (ATOMIC_LOAD(&hold_) > limit_) {
  // 已超 limit, 直接拒
} else if (ATOMIC_AAF(&hold_, PAGE_SIZE) > limit_) {
  // 这次 add 后超了, 回滚
  ATOMIC_FAA(&hold_, -PAGE_SIZE);
}
```

[`deps/oblib/src/lib/allocator/ob_block_alloc_mgr.h`](deps/oblib/src/lib/allocator/ob_block_alloc_mgr.h) — `ObBlockAllocMgr::hold_`:

```cpp
int64_t used_after_alloc = ATOMIC_AAF(&hold_, size);
if (used_after_alloc > limit_) {
  ATOMIC_AAF(&hold_, -size);   // 回滚
  return OB_ALLOCATE_MEMORY_FAILED;
}
```

**关键观察**: OB 的限流 pattern 是 **"乐观加 + 超阈值回滚"**:
1. `ATOMIC_AAF(&hold_, delta)` 一次原子加
2. 检查返回值是否超阈值
3. 超了就 `ATOMIC_AAF(&hold_, -delta)` 回滚

为什么不先 CAS 检查再加? 因为多线程并发时 CAS 检查通过后到 add 之间 hold_ 可能已被别的线程改大, CAS 是无意义的乐观。

### 2.2 水位型 — ObResourceLimiter 的 min/max 双闸

[`deps/oblib/src/lib/resource/ob_resource_limiter.cpp:33-50`](deps/oblib/src/lib/resource/ob_resource_limiter.cpp):

```cpp
bool ObResourceLimiter::try_acquire(int64_t quota, ...) {
  // 1. 累加并立即检查 (AAF 一次完成)
  if (ATOMIC_AAF(&hold_, quota) < min_) {
    // add 后低于 min_, 回滚 (说明限流下限违规)
    ATOMIC_AAF(&hold_, -quota);
    return false;
  }
  if (ATOMIC_AAF(&hold_, quota) > max_) {
    // 超 max_, 回滚
    ATOMIC_AAF(&hold_, -quota);
    return false;
  }
  return true;
}
```

注: 上例简化了 OB 真实代码, 真实代码一次 AAF 完成 max 检查, min 检查在另一路径。

### 2.3 版本型 — Schema 多版本计数器

[`src/share/schema/ob_schema_store.h:38-50`](src/share/schema/ob_schema_store.h):

```cpp
int64_t get_refreshed_version()      const { return ATOMIC_LOAD(&refreshed_version_); }
int64_t get_received_version()       const { return ATOMIC_LOAD(&received_version_); }
int64_t get_checked_sys_version()    const { return ATOMIC_LOAD(&checked_sys_version_); }
int64_t get_baseline_schema_version() const { return ATOMIC_LOAD(&baseline_schema_version_); }
int64_t get_consensus_version()       const { return ATOMIC_LOAD(&consensus_version_); }
```

**这是经典的"versioned state" pattern**:
- `refreshed_version_` — 本地刷新到的 schema 版本 (由 schema service 写入)
- `received_version_` — RS 推过来的最新版本
- `checked_sys_version_` — 已校验的系统表版本
- `consensus_version_` — 多副本共识确认的版本
- `baseline_schema_version_` — 当前生效的基线版本

每个 schema 缓存条目记录自己 refresh 时的 version, 读路径:
1. `ATOMIC_LOAD(&refreshed_version_)` 拿到当前最新
2. 缓存条目比较自己的 version 是否匹配
3. 不匹配则 reload

**为什么用 atomic load**: 读路径多线程并发, 写路径少 (schema 变更不频繁)。`ATOMIC_LOAD` 保证读到的是某个全局可见的版本号 (SEQ_CST) — 即使写路径用普通 store, 因为 seq_cst load 能看到任意最新 store。

### 2.4 时间型 — ObClockGenerator 单调时钟

[`deps/oblib/src/common/ob_clock_generator.h:95-108`](deps/oblib/src/common/ob_clock_generator.h):

```cpp
OB_INLINE int64_t ObClockGenerator::safe_inc_us(int64_t cur_ts) {
  int64_t origin_cur_ts = OB_INVALID_TIMESTAMP;
  do {
    origin_cur_ts = ATOMIC_LOAD(&clock_generator_.cur_ts_);
    if (origin_cur_ts < cur_ts) {
      break;   // 真实时间已超过 cur_ts, 不需要 advance
    } else {
      TRANS_LOG_RET(WARN, common::OB_ERR_SYS, "timestamp rollback, need advance cur ts",
                    K(origin_cur_ts), K(cur_ts));
    }
  } while (false == ATOMIC_BCAS(&clock_generator_.cur_ts_, origin_cur_ts, cur_ts));
  return common::ObTimeUtility::current_time();
}
```

**关键设计**:
- `ATOMIC_LOAD` 读当前 cur_ts
- 如果**真实时间**已超过 cur_ts, 直接 break (正常情况, 时钟在前进)
- 如果**真实时间回退** (例如 NTP 校时), 用 BCAS 把 cur_ts 强制拉到 cur_ts
- BCAS 保证只有当 origin_cur_ts 还是当前值时才更新 (防止 ABA 问题)

**为什么用 BCAS 而不是 FAA**: 因为这里是"读-比较-改"逻辑 (cur_ts 单调递增必须), FAA 会丢失单调性保证。

### 2.5 序列型 — ObAutoincrementService

[`src/share/ob_autoincrement_service.cpp:70-90`](src/share/ob_autoincrement_service.cpp):

```cpp
// 1. 读本地已分配的 max sync
const uint64_t local_sync = ATOMIC_LOAD(&local_sync_);
if (local_sync < next_value_) {
  // 客户端要的 next_value 超过本地 cache, 需要向 RS 申请新 batch
  ...
}

// 2. 时戳更新 (cache 刷新时间)
int64_t delta = cur_time - ATOMIC_LOAD(&table_node.last_refresh_ts_);

// 3. 多个 RS 同步状态机
if (insert_value <= ATOMIC_LOAD(&table_node->local_sync_)) {
  // insert_value 已被本节点用过, 拒绝
}
```

`local_sync_` 是 "本节点已分配出的最大序列号", 用 `ATOMIC_LOAD` 读 + 后续 `atomic_update()` 写。`last_refresh_ts_` 是 cache 刷新时间戳, 用于判断 cache 是否过期。

**两个计数器**:
- `local_sync_` — 业务计数器 (单调递增, 表示已分配)
- `last_refresh_ts_` — 时间戳 (记录上次刷新)

### 2.6 MemTable 内部 Counter 三件套

[`src/storage/memtable/ob_memtable_context.h:140-200`](src/storage/memtable/ob_memtable_context.h):

```cpp
class AllocInfo {
public:
  ...
  void inc_alloc(int64_t size) {
    ATOMIC_FAA(&alloc_size_, size);
    ATOMIC_AAF(&alloc_count_, 1);
  }
  void inc_free(int64_t size) {
    ATOMIC_FAA(&alloc_size_, -size);
    ATOMIC_AAF(&free_count_, 1);
  }
  void reset() {
    if (OB_UNLIKELY(ATOMIC_LOAD(&free_count_) != ATOMIC_LOAD(&alloc_count_))) {
      TRANS_LOG_RET(ERROR, common::OB_ERR_UNEXPECTED,
                    "query allocator leak found", K(alloc_count_), K(free_count_), K(alloc_size_));
    }
    ATOMIC_STORE(&alloc_count_, 0);
    ATOMIC_STORE(&free_count_, 0);
    ATOMIC_STORE(&alloc_size_, 0);
  }
private:
  int64_t alloc_count_;
  int64_t free_count_;
  int64_t alloc_size_;
};
```

**两个 size + count 配对**:
- `alloc_count_` / `free_count_` 必须最终相等 (destroy 时 check)
- `alloc_size_` 累计已分配字节数 (用于 leak detection)

**重置为什么用 `ATOMIC_STORE` 而不是 `= 0`**: store 是 SEQ_CST, 保证其他线程同时读到的也是 reset 后的值, 不会出现读到 old alloc_count + new alloc_size 的不一致状态。

### 2.7 MemTable 重试计数

[`src/storage/memtable/ob_memtable_context.h:50-65`](src/storage/memtable/ob_memtable_context.h):

```cpp
class RetryInfo {
public:
  void reset() { retry_cnt_ = 0; last_retry_ts_ = 0; }
  int64_t get_retry_cnt() const { return ATOMIC_LOAD(&retry_cnt_); }
  void inc_retry() { ATOMIC_AAF(&retry_cnt_, 1); }
  bool need_print() const {
    // 每 10 次 retry 或距离上次打印超过 1s 打印一次
    if (ATOMIC_LOAD(&retry_cnt_) % 10 == 0 ||
        ObTimeUtility::current_time() - last_retry_ts_ > 1000000) {
      ...
    }
  }
private:
  int64_t retry_cnt_;
  int64_t last_retry_ts_;
};
```

`need_print()` 用 `ATOMIC_LOAD(&retry_cnt_) % 10 == 0` — **每次读都做模运算**, 用 SEQ_CST load 保证读到的是最新 retry_cnt。

### 2.8 Cache 与 Context 的 atomic counter

[`deps/oblib/src/lib/allocator/ob_block_alloc_mgr.h`](deps/oblib/src/lib/allocator/ob_block_alloc_mgr.h):

```cpp
// alloc 时
int64_t used_after_alloc = ATOMIC_AAF(&hold_, size);
if (used_after_alloc > limit_) {
  ATOMIC_AAF(&hold_, -size);     // 回滚
  return OB_ALLOCATE_MEMORY_FAILED;
}

// free 时
ATOMIC_AAF(&hold_, -size);
```

[`src/share/cache/ob_kvcache_hazard_domain.cpp:117`](src/share/cache/ob_kvcache_hazard_domain.cpp):

```cpp
ATOMIC_FAA(&retired_memory_size_, retire_size);   // 累积 retire 的内存
```

### 2.9 FAA vs AAF 选择

```cpp
// FAA — fetch-and-add, 返回旧值 (add 之前)
int64_t old = ATOMIC_FAA(&x, delta);   // 旧值是 x_old
// 用途: 取增量前的 snapshot, 用于"add 前是 X, add 后是 Y"语义

// AAF — add-and-fetch, 返回新值 (add 之后)
int64_t now = ATOMIC_AAF(&x, delta);   // 新值是 x_old + delta
// 用途: 取最新值, 用于"add 后是 X"的语义 (OB 限流用这个)
```

**OB Counter 的选择模式**:
- 限流 (add 后立刻 check): `AAF` ✅ (ob_block_alloc_mgr, fifo_alloc, ob_resource_limiter)
- 累计 (add 后用于上报): `FAA` ✅ (retired_memory_size, alloc_size)
- 重置 (init 时清零): `STORE` ✅ (alloc_count_ = 0)
- 读: `LOAD` ✅ (refreshed_version_)

---

## 3. 性能优化

### 3.1 FAA vs CAS 的吞吐差异

x86 平台上 FAA 是 1 条 `LOCK XADD` 指令 (~20 cycles), CAS 是 1 条 `LOCK CMPXCHG` (~20 cycles), 但 CAS 在竞争激烈时会 retry, FAA 不会。**限流场景永远用 FAA/AAF, 不用 CAS**。

### 3.2 水位检查的两次 AAF 合并

部分 OB 代码用两次 AAF (先 add 再回滚), 实际可以**一次 AAF + 一次比较**:

```cpp
// 优化版 (单 AAF):
if (ATOMIC_AAF(&hold_, delta) > limit_) {
  // 注意: 这里 hold_ 已经被 add 了, 但因为超 limit, 立即 -delta 回滚
  ATOMIC_AAF(&hold_, -delta);   // 必须回滚, 否则泄漏
  return OB_EXCEED_MEM_LIMIT;
}
```

OB 真实代码就是这种 pattern, 比 CAS-then-add 快一倍 (少一次原子操作)。

### 3.3 CACHE_ALIGNED 字段

[`deps/oblib/src/lib/allocator/ob_slice_alloc.h`](deps/oblib/src/lib/allocator/ob_slice_alloc.h):

```cpp
uint64_t push_ CACHE_ALIGNED;
uint64_t pop_ CACHE_ALIGNED;
uint64_t capacity_ CACHE_ALIGNED;
void* data_[];
```

**`CACHE_ALIGNED` 让 push_ / pop_ 在不同 cache line**, 避免 false sharing — producer 改 push_ 和 consumer 改 pop_ 不会互相 invalidate cache line, 吞吐翻倍。这是 lock-free SPSC 队列的关键优化。

### 3.4 ATOMIC_LOAD 默认 SEQ_CST 的代价

SEQ_CST 在 x86 是 `LOCK` 前缀 (类似 MFENCE), ~30 cycles; ACQUIRE 是普通 load, ~1 cycle。Counter 读通常不需要 SEQ_CST, 但 OB 全部用 SEQ_CST 是 **保守正确** 做法:
- 读路径只多 ~30 cycles, 业务影响 < 5%
- 避免人为判断 memory order 出错

**Counter 读应该用 `ATOMIC_LOAD_ACQ` 而非 `ATOMIC_LOAD` 的场景**:
- Counter 变化频率极低 (schema version 每秒 < 100 次, ATOMIC_LOAD_ACQ 完全够)

OB 现状: 大部分 counter 仍用 SEQ_CST, 安全第一。

---

## 4. 与 v2 主线的连接

| v2 文章 | Counter 维度 |
|---------|-------------|
| #25 (Memory Management) | `ObTenantMemoryMgr::hold_bytes_[ctx_id]` 用 ATOMIC_AAF 累加 |
| #28 (Resource/Unit/Tenant) | `ObResourceLimiter::hold_` 带 min/max 双闸 |
| #34 (Storage Engine) | block cache / memtable context 的 atomic counter |
| #74 (Thread Model) | `map_queue::produce_seq_` / `consume_seq_` 配对 |
| #11 (Trans Service) | `tx_data.state_` 是事务生命周期计数器 (#104 详述) |
| #104 (下一篇) | 计数器 vs Flag 的边界, 同一字段 (例如 `state_`) 既是 enum 也是 CAS 标志 |

### 主线架构图 (Counter 层)

```
┌─────────────────────────────────────────────────┐
│  业务 Counter 集群                              │
│                                                 │
│  ObTenantMemoryMgr: hold_bytes_[MAX_CTX_ID]    │  ← 累加型 (limit check)
│  ObResourceLimiter: hold_                       │  ← 水位型 (min/max)
│  ObSchemaStore: refreshed_version_              │  ← 版本型 (seq)
│  ObClockGenerator: cur_ts_                      │  ← 时间型 (BCAS 强制单调)
│  ObAutoincrementService: local_sync_            │  ← 序列型 (cache)
│  ObMemtableContext: alloc_count_/free_count_    │  ← 配对型 (leak check)
│  ObKvcacheHazardDomain: retired_memory_size_    │  ← 累计型 (FAA)
└─────────────────────────────────────────────────┘
                ▲                    │
                │ ATOMIC_AAF/LOAD   │ ATOMIC_LOAD
                │ (限流路径)        │ (监控路径)
                │                    ▼
┌─────────────────────────────────────────────────┐
│  调用方                                         │
│  - 业务线程 (memtable insert / SQL alloc)       │
│  - 监控线程 (SELECT ... FROM v$memory_info)     │
│  - GC 线程 (free 后 free_count_++)              │
└─────────────────────────────────────────────────┘
```

---

## 5. 调优 Checklist

| 项 | 检查方法 | 推荐 |
|----|---------|------|
| 限流路径是否用 AAF (而非 CAS) | grep `try_acquire` / `try_alloc` | 必须 AAF |
| 是否避免 hot path 的 ATOMIC_LOAD_SEQ_CST | perf 看 cache miss | 非 critical 用 ACQ |
| 配对 counter 是否平衡 (alloc == free) | `__all_virtual_memory_info` | 必须平衡 |
| Schema version counter 增量 | `select * from oceanbase.__all_virtual_schema_version` | 应单调递增 |
| 水位型 hold_ 是否在 limit 内 | `numastat -m` + `select * from v$tenant_mem_info` | ≤ limit |
| CACHE_ALIGNED on hot counter | grep `CACHE_ALIGNED` | SPSC/SPMC 用 |
| Clock generator 是否回退 | log `timestamp rollback` | 极少, 应 < 1/小时 |

---

## 6. 常见故障 case

### Case 1: 限流误判 / hold_ 漏回滚

**现象**: `hold_` 持续增长但业务没真正占用
**原因**: AAF add 后 check 超 limit 但**忘了 FAA -delta 回滚**
**排查**:
```bash
# 在 OB 监控虚拟表查 hold_bytes_
select * from oceanbase.__all_virtual_memory_info where tenant_id=N;
```
**修复**: 严格 check `if (AAF > limit) { FAA(-delta); return ERR; }` 模式

### Case 2: alloc_count_ != free_count_

**现象**: MemTable context reset 时报错 `query allocator leak found`
**原因**: 某次 alloc 路径抛异常但 free 没执行
**排查**: 看代码找 `OB_NEW` / `ob_malloc` 周围是否有 RAII guard (ObArenaAllocator / ObMemGuard)
**修复**: 用 RAII 包装 alloc/free, 或 try-catch 保证 free 路径

### Case 3: Schema version counter 卡住

**现象**: `refreshed_version_` 不再增长, 但业务 schema 已变
**原因**: schema service 没收到 RS 推送, 或 `ATOMIC_STORE(&refreshed_version_, v)` 路径中断
**排查**:
```bash
# 查 schema service 日志
grep "refreshed_version" observer.log
```
**修复**: 重启 schema service 节点, 或手动触发 `ALTER SYSTEM REFRESH SCHEMA`

### Case 4: Clock generator 频繁回退

**现象**: log 中大量 `timestamp rollback, need advance cur ts`
**原因**: NTP 校时频繁, 或系统时钟被手动改
**修复**:
- 配 NTP 慢校 (`tinker step 0.5`)
- 或禁用 NTP, 用 OB 内部 GTS (#28 详述)

### Case 5: schema version load 错位

**现象**: 业务读 schema 时拿到旧版本
**原因**: 用 `ATOMIC_LOAD_RLX` 而不是 SEQ_CST 读, 看到的是 stale value
**修复**: 统一用 `ATOMIC_LOAD` (SEQ_CST)

---

## 7. 参考 (可执行源码锚点)

| 路径 | 行 | 锚点 |
|------|---|------|
| `deps/oblib/src/lib/atomic/ob_atomic.h` | 23-39 | ATOMIC_LOAD/LOAD_ACQ/LOAD_RLX macro 定义 |
| `deps/oblib/src/lib/atomic/ob_atomic.h` | 56-79 | ATOMIC_FAA/AAF/FAS/SAF/TAS/SET/VCAS/BCAS 定义 |
| `deps/oblib/src/common/ob_clock_generator.h` | 95-108 | `safe_inc_us` BCAS 单调时钟 |
| `src/share/schema/ob_schema_store.h` | 38-50 | schema 多版本 counter 读 |
| `src/share/ob_autoincrement_service.cpp` | 70-90 | local_sync_ / last_refresh_ts_ 双 counter |
| `deps/oblib/src/lib/resource/ob_resource_limiter.cpp` | 33-50 | hold_ 限流 + min/max 双闸 |
| `deps/oblib/src/lib/tc/deps/fifo_alloc.h` | 14-30 | AAF + limit 检查 + 回滚 pattern |
| `deps/oblib/src/lib/allocator/ob_block_alloc_mgr.h` | (full) | block allocator hold_ 限流 |
| `src/storage/memtable/ob_memtable_context.h` | 50-65 | retry_cnt_ 累计 |
| `src/storage/memtable/ob_memtable_context.h` | 140-200 | alloc_count_/free_count_/alloc_size_ 三件套 |
| `src/share/cache/ob_kvcache_hazard_domain.cpp` | 117 | retired_memory_size_ 累计 |
| `deps/oblib/src/lib/allocator/ob_slice_alloc.h` | 85-180 | CACHE_ALIGNED push_/pop_ SPSC 队列 |

---

## 8. Cross-cutting 列表

- **限流 vs 计数 vs 版本**: 三种 Counter 业务模式, 但底层都是 `ATOMIC_AAF` / `ATOMIC_LOAD` (同一组原子原语)
- **FAA vs AAF**: FAA 取旧值 (snapshot), AAF 取新值 (current), OB Counter **99% 用 AAF**
- **SEQ_CST vs ACQ**: SEQ_CST 默认 (`ATOMIC_LOAD`), ACQ 用于读多写少 (schema version), RLX 用于内部维护字段 (push_/pop_)
- **配对 invariant**: alloc_count_ == free_count_, 业务必须保证 RAII / try-catch 保证 free 路径
- **乐观加 + 回滚**: 限流 pattern 是 AAF → check → FAA(-delta) 回滚, 不用 CAS-then-add
- **CACHE_ALIGNED**: hot counter 必须 cache line 对齐, 避免 false sharing (slice_alloc push_/pop_)
- **observability**: 所有 Counter 都对应 `v$memory_info` / `v$sql_audit` 等虚拟表, 业务线程读 + 监控线程读, **写路径绝不读**
- **ABA 风险**: 仅 ClockGenerator 这种"读-改-写"需要 BCAS, Counter 模式不会 ABA (单调递增或累加, 不会回到旧值)

---

## 9. 下一篇预告

#104 — 原子变量应用 (2/4): **Flag / State Machine 模式** —
`Thread::stop_` (所有线程统一的 lifecycle flag) / `MdsTableBase::state_` (BCAS 单调状态机迁移) / `TxData::state_` (RUNNING → COMMITTED → ABORTED) / `MemTable::is_inited_` / `expand_nway_called_` (BCAS single-shot) / `ObRoleMgr::state_` (TAS 直接换值) / `qsync::write_flag_` (BCAS 简化版 mutex)。

揭晓: 同一份 atomic 宏, 当值域是 `{0, 1}` 或小枚举时, 业务模式变成"状态机", 关键从 FAA 变成 BCAS 的状态迁移合法性检查。