# GTS & 时间模型 — 全局时间戳与分布式授时

> 分析版本：OceanBase CE 4.x  
> 分析工具：doom-lsp + 源码阅读

---

## 1. 概述

在分布式数据库中，时间戳是一切的根本。MVCC 的可见性判断、2PC 的提交协调、Paxos 日志的排序——所有这些都依赖一个全局有序、单调递增的时间戳。

OceanBase 的时间模型围绕三个核心概念展开：

- **SCN（Stamped Commit Number）**—— 通用时间戳类型，贯穿整个引擎
- **GTS（Global Timestamp Service）**—— 全局时间戳生成服务，保证单调递增
- **MonotonicTs** —— 单调时钟，用于 GTS 内部的 RPC 请求排序

整个架构的精髓在于：**GTS 基于机器时钟（ns 级精度）生成时间戳，通过本地缓存减少 RPC 开销，用任务队列处理异步等待，最终通过 SCN 统一所有的时间语义。**

```
┌─────────────────────────────────────────────────────────────┐
│                    GTS 整体架构                              │
│                                                             │
│  ┌──────────────┐    ┌──────────────────────────┐           │
│  │  ObTsMgr     │───▶│  ObTsSourceInfoMap       │           │
│  │  (全局入口)   │    │  ├── tenant1 → ObGtsSource│           │
│  └──────┬───────┘    │  ├── tenant2 → ObGtsSource│           │
│         │            │  └── tenantN → ObGtsSource│           │
│         │            └──────────────┬────────────┘           │
│         ▼                           ▼                        │
│  ┌──────────────┐    ┌──────────────────────────┐           │
│  │ ObGtsSource  │    │    ObGTSLocalCache       │           │
│  │ (每租户)      │───▶│  ┌──────────────────────┐│           │
│  │              │    │  │ srr_ (send req ts)    ││           │
│  │  ┌──────────┐│    │  │ gts_ (cached value)  ││           │
│  │  │GET_GTS   ││    │  │ latest_srr_           ││           │
│  │  │queue_[0] ││    │  │ receive_gts_ts_       ││           │
│  │  ├──────────┤│    │  └──────────────────────┘│           │
│  │  │WAIT_GTS  ││    └──────────────────────────┘           │
│  │  │queue_[1] ││                                            │
│  │  └──────────┘│           ▼                               │
│  └──────┬───────┘    ┌────────────────┐                     │
│         │            │ ObTimestampService│                   │
│         │            │ (GTS Leader)    │                     │
│         │            │ ┌──────────────┐│                     │
│         └───────────▶│ │ ObIDService  ││──▶ 写日志持久化     │
│                      │ │ (分配 SCN)   ││                     │
│                      │ └──────────────┘│                     │
│                      └────────────────┘                     │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. SCN 类型设计

### 2.1 定义位置

`src/share/scn.h` — `SCN` 类是 OceanBase 的统一时间戳类型。

### 2.2 数据结构

```cpp
// src/share/scn.h, line 54-69
class SCN
{
private:
  // 62-bit timestamp (ns) + 2-bit version
  union {
    uint64_t val_;              // 完整 64-bit 值
    struct {
      uint64_t ts_ns_ : 62;     // 纳秒时间戳，62 bits
      uint64_t v_ : 2;          // 版本号，固定为 0
    };
  };
  static const uint64_t SCN_VERSION = 0;
};
```

关键设计点：

- **62 位纳秒**：`OB_MAX_SCN_TS_NS = (1UL << 62) - 1 ≈ 4.6 × 10¹⁸ ns`，约 146 年，足够使用
- **2 位版本**：预留扩展，当前固定 `SCN_VERSION = 0`
- **union 布局**：`val_` 可以直接做原子操作，`ts_ns_` + `v_` 用于位域访问

### 2.3 常量定义

```cpp
// src/share/scn.h, line 18-21
const uint64_t OB_INVALID_SCN_VAL = UINT64_MAX;   // 无效值
const uint64_t OB_MIN_SCN_TS_NS   = 0;            // 最小值
const uint64_t OB_BASE_SCN_TS_NS  = 1;            // 基准值
const uint64_t OB_MAX_SCN_TS_NS   = (1UL << 62) - 1;  // 最大值
```

### 2.4 转换函数

SCN 与多种子系统对接，每种场景有独立的 `convert_*` 函数：

| 函数 | 来源 | 用途 |
|------|------|------|
| `convert_for_gts(int64_t ts_ns)` | GTS 服务 | GTS 生成的纳秒时间戳写入 SCN |
| `convert_from_ts(uint64_t ts_us)` | 用户/系统 | 微秒时间戳转换 |
| `convert_to_ts()` | 任意 | SCN → 微秒时间戳 |
| `convert_for_tx(int64_t commit_trans_version)` | 事务模块 | 事务提交版本 → SCN |
| `convert_for_logservice(uint64_t scn_val)` | PALF 日志 | 日志 LSN 分配的 ID → SCN |
| `convert_for_sql(uint64_t scn_val)` | SQL 层 | 外部传入 SCN 值 |

其中 `convert_for_gts` 是最核心的路径：GTS Source 生成的 ns 级时间戳直接填充 SCN 的 `ts_ns_` 字段。

### 2.5 原子操作

SCN 提供完整的无锁原子操作：

- `atomic_load / atomic_store` — 基于 `ATOMIC_LOAD / ATOMIC_STORE`
- `atomic_bcas / atomic_vcas` — Compare-And-Swap，用于无锁更新
- `inc_update / dec_update` — 基于 CAS 循环的单调更新，确保 `>=` / `<=` 语义

```cpp
// src/share/scn.h, line 44-49
SCN inc_update(const SCN &ref_scn);   // SCN = max(SCN, ref_scn)
SCN dec_update(const SCN &ref_scn);   // SCN = min(SCN, ref_scn)
```

---

## 3. GTS Source 实现

### 3.1 定义位置

`src/storage/tx/ob_gts_source.h/cpp` — `ObGtsSource` 类

### 3.2 核心职责

`ObGtsSource` 是每个租户的 GTS 访问入口。它管理：

1. **GTS 本地缓存**（`ObGTSLocalCache`）
2. **RPC 通信**（向 GTS Leader 请求最新时间戳）
3. **任务队列**（等待 GTS 的异步回调任务）

### 3.3 初始化

```cpp
// src/storage/tx/ob_gts_source.cpp, line 70-112
int ObGtsSource::init(
    const uint64_t tenant_id,
    const ObAddr &server,
    ObIGtsRequestRpc *gts_request_rpc,
    ObILocationAdapter *location_adapter)
```

初始化时创建两个队列：
- `GET_GTS` 队列（索引 0）—— 等待获取 GTS 的 task
- `WAIT_GTS_ELAPSING` 队列（索引 1）—— 等待 GTS 越过某个时间点的 task

### 3.4 GTS 获取流程

```
┌─────────────────────────────────────────────────────────┐
│                   GTS 获取流程                            │
│                                                         │
│  调用方: get_gts(stc, task, gts, receive_gts_ts)        │
│                                                         │
│  1. 查本地缓存: gts_local_cache_.get_gts(stc, ...)      │
│     ├── 缓存命中 → 返回 gts                             │
│     └── 缓存未命中                                      │
│         ├── 本地是 Leader → 直接调用 timestamp_service   │
│         └── 远程 Leader →                              │
│             ├── 发 RPC: query_gts_(leader)              │
│             └── Task 入队等待回调                        │
│                                                         │
│  2. RPC 回调: handle_gts_result()                       │
│     ├── 更新本地缓存: update_gts(srr, gts, recv_ts)     │
│     └── 遍历任务队列: foreach_task(srr, gts, recv_ts)   │
│         ├── GET_GTS 队列: get_gts_callback()            │
│         └── WAIT_GTS 队列: gts_elapse_callback()        │
└─────────────────────────────────────────────────────────┘
```

### 3.5 带 STC（Send Time Clock）的 GTS 获取

```cpp
// src/storage/tx/ob_gts_source.cpp, line 148-230
int ObGtsSource::get_gts(const MonotonicTs stc,
                         ObTsCbTask *task,
                         int64_t &gts,
                         MonotonicTs &receive_gts_ts)
```

`stc`（Send Time Clock）是调用方发出请求时的单调时间。GTS Source 保证返回的 gts ≥ 所有 stc < gts 的请求所期望的值。这个机制用于：

- **事务读**：确保 snapshot version ≥ 所有已提交事务的 commit version
- **写后读一致性**：同一个租户的事务 B 能看到事务 A 的写入

### 3.6 GTS 的单调性保证

GTS 的单调递增基于机器时钟，但不是简单的时钟值。`ObTimestampService` 继承 `ObIDService`，使用预分配机制：

```cpp
// src/storage/tx/ob_timestamp_service.h, line 37
static const int64_t TIMESTAMP_PREALLOCATED_RANGE = palf::election::MAX_LEASE_TIME * 1000;
```

GTS Leader 切换时，新 Leader 会预分配一大段时间戳范围，避免时钟回拨：

```cpp
// src/storage/tx/ob_timestamp_service.h, line 38
static const int64_t PREALLOCATE_RANGE_FOR_SWITHOVER = 2 * TIMESTAMP_PREALLOCATED_RANGE;
```

当预分配导致 GTS 快于实际时钟时，GTS 会"降速"等待时钟追上；但如果请求率过低导致 GTS 增长太慢，又会主动"加速"：

```cpp
// src/storage/tx/ob_timestamp_service.cpp, line 59-100
// 每 100ms 检查一次 GTS 增速
// 如果 time_delta - gts_delta > time_delta / 2
// 说明 GTS 增速远慢于时钟，补偿 time_delta / 10
```

### 3.7 本地调用优化

如果当前节点就是 GTS Leader，不走网络 RPC，直接本地调用：

```cpp
// src/storage/tx/ob_gts_source.cpp, line 235-275
int ObGtsSource::get_gts_from_local_timestamp_service_(
    ObAddr &leader, int64_t &gts, MonotonicTs &receive_gts_ts)
{
  ObTimestampAccess *timestamp_access = MTL(ObTimestampAccess *);
  if (OB_FAIL(timestamp_access->get_number(tmp_gts, is_sslog_gts_()))) {
    ...
  } else {
    gts_local_cache_.update_gts_and_check_barrier(cur_ts, tmp_gts, cur_ts);
    gts = tmp_gts;
    receive_gts_ts = cur_ts;
  }
}
```

---

## 4. GTS 本地缓存

### 4.1 定义位置

`src/storage/tx/ob_gts_local_cache.h/cpp` — `ObGTSLocalCache` 类

### 4.2 缓存数据结构

```cpp
// src/storage/tx/ob_gts_local_cache.h, line 46-51
class ObGTSLocalCache {
  MonotonicTs srr_;            // send rpc request timestamp
  int64_t gts_;                // latest local gts value (≤ gts leader)
  MonotonicTs latest_srr_;     // latest srr sent
  MonotonicTs receive_gts_ts_; // timestamp when gts response received
};
```

### 4.3 缓存命中逻辑

```cpp
// src/storage/tx/ob_gts_local_cache.cpp, line 82-108
int ObGTSLocalCache::get_gts(
    const MonotonicTs stc,
    int64_t &gts,
    MonotonicTs &receive_gts_ts,
    bool &need_send_rpc) const
{
  const int64_t srr = ATOMIC_LOAD(&srr_.mts_);
  const int64_t tmp_gts = ATOMIC_LOAD(&gts_);
  const int64_t tmp_receive_gts_ts = ATOMIC_LOAD(&receive_gts_ts_.mts_);

  if (0 == tmp_gts) {
    ret = OB_EAGAIN;           // 没有缓存值
    need_send_rpc = true;
  } else if (stc.mts_ > srr) {
    ret = OB_EAGAIN;           // stc 超过了已发送的 srr
    need_send_rpc = (stc.mts_ > ATOMIC_LOAD(&latest_srr_.mts_));
  } else {
    gts = tmp_gts;             // 缓存命中!
    need_send_rpc = false;
  }
}
```

关键逻辑：
- **`srr_`**：上次发送 RPC 请求的时间戳。任何 stc ≤ srr 的请求都可以安全使用当前缓存值
- **`latest_srr_`**：最新发送的 RPC 请求。如果 stc > latest_srr_，需要发新的 RPC
- **`gts_`**：缓存的最新 GTS 值，单调递增

### 4.4 缓存更新

```cpp
// src/storage/tx/ob_gts_local_cache.cpp, line 27-43
int ObGTSLocalCache::update_gts(const MonotonicTs srr,
                                const int64_t gts,
                                const MonotonicTs receive_gts_ts,
                                bool &update)
{
  // 更新顺序：receive_gts_ts → gts → srr
  (void)atomic_update(&receive_gts_ts_.mts_, receive_gts_ts.mts_);
  (void)atomic_update(&gts_, gts);
  update = atomic_update(&srr_.mts_, srr.mts_);
}
```

更新顺序保证：先写 `receive_gts_ts` 和 `gts`，最后写 `srr_`。这样读者看到 srr 更新时，gts 值一定已经就绪。

### 4.5 MSS（Monotonic Sequence Service）关系

GTS 本地缓存本质上是一种 MSS 实现——它通过缓存 GTS Leader 的时间戳，为本地提供单调递增的序列号服务。缓存的三个核心参数（srr、gts、latest_srr）构成了一个"滑动窗口"：

- **srr** ≤ **gts** 对应的 srr：缓存覆盖的时间范围
- **latest_srr** > **srr**：有正在路途中的 RPC

---

## 5. 时间戳服务

### 5.1 定义位置

`src/storage/tx/ob_timestamp_service.h/cpp` — `ObTimestampService` 类

### 5.2 继承关系

```
ObIDService  (src/storage/tx/ob_id_service.h)
  └── ObTimestampService
```

`ObIDService` 提供通用的 ID/时间戳预分配机制：
- `get_number(range, base_id, start_id, end_id)` — 分配一段连续 ID
- 通过写 PALF 日志持久化 `limited_id`
- Leader 切换时恢复 `last_id` 和 `limited_id`

### 5.3 GTS Leader 的时间戳分配

```cpp
// src/storage/tx/ob_timestamp_service.cpp, line 48-100
int ObTimestampService::get_timestamp(int64_t &gts)
{
  ret = get_number(1, current_time, gts, unused_id);
  // 周期性检查 GTS 增速，必要时补偿
  if (time_delta > CHECK_INTERVAL) {
    if (time_delta - gts_delta > compensation_threshold) {
      ret = get_number(compensation_value, current_time, gts, unused_id);
    }
  }
}
```

`get_number` 的第二个参数 `base_id` 是关键：传入 `current_time` 作为基准，确保 gts ≥ `current_time`。如果机器时钟前进慢了，GTS 也自动降速；如果 Leader 切换导致预分配时间戳 > 实际时钟，`last_id_` 从预分配范围中分配，自动"借未来时间"。

### 5.4 RPC 请求处理

```cpp
// src/storage/tx/ob_timestamp_service.cpp, line 135-195
int ObTimestampService::handle_request(const ObGtsRequest &request,
                                       ObGtsRpcResult &result)
{
  if (requester == self_) {
    // 本地调用，不走网络
    ret = handle_local_request_(request, result);
  } else if (OB_FAIL(get_timestamp(gts))) {
    // 获取失败，回送错误响应
    rpc_.post(tenant_id, requester, err_response);
  } else {
    // 成功，返回 gts (gts_start == gts_end，每次只分配 1 个)
    result.init(tenant_id, ret, srr, gts, gts);
  }
}
```

---

## 6. GTS RPC 通信

### 6.1 定义位置

`src/storage/tx/ob_gts_rpc.h/cpp`

### 6.2 消息结构

```cpp
// src/storage/tx/ob_gts_msg.h, line 23-43
class ObGtsRequest {
  uint64_t tenant_id_;     // 租户 ID（高位标记是否为 sslog）
  MonotonicTs srr_;        // 发送时间戳
  int64_t range_size_;     // 请求范围（通常为 1）
  common::ObAddr sender_;  // 发送者地址
};

class ObGtsErrResponse {
  uint64_t tenant_id_;
  MonotonicTs srr_;
  int status_;             // 错误码
  common::ObAddr sender_;
};
```

`ObGtsRpcResult` 是响应：

```cpp
// src/storage/tx/ob_gts_rpc.h, line 31-50
class ObGtsRpcResult {
  uint64_t tenant_id_;
  int status_;                   // OB_SUCCESS 或错误码
  transaction::MonotonicTs srr_; // 对应的发送时间戳
  int64_t gts_start_;            // GTS 起始
  int64_t gts_end_;              // GTS 结束（通常 == gts_start_）
};
```

### 6.3 RPC 流程

```
┌──────────────┐          ┌──────────────────┐
│ ObGtsSource  │          │ ObTimestampService│
│ (Follower)   │          │ (Leader)         │
├──────────────┤          ├──────────────────┤
│ query_gts_() │──RPC────▶│ handle_request() │
│   ↑           │          │   ↓              │
│  ObGtsRPCCB  │◀───resp──│ get_timestamp()  │
│   ↓           │          │   ↓              │
│ update_gts() │          │ result.init()    │
│   ↓           │          └──────────────────┘
│ foreach_task()│
└──────────────┘
```

- RPC Codec：`OB_GET_GTS_REQUEST`
- 回调处理在 `ObGtsRPCCB::process_()` — 更新本地缓存 + 推送任务到 `ObTsWorker`
- 超时处理的 `on_timeout()` — 刷新 GTS 位置信息

### 6.4 GTS 位置发现

ObGtsSource 通过 `ObILocationAdapter` 发现 GTS Leader：

```
GTS 的日志流 ID: GTS_LS = ObLSID(ID_LS_ID)
                 = sys 租户的特定 LS
```

查询流程：`get_gts_leader_()` → `location_adapter_->nonblock_get_leader()`

失败时走 `refresh_gts_location_()` → `nonblock_renew()`，间隔 100ms（`refresh_location_interval_`）。

---

## 7. GTS 任务队列

### 7.1 定义位置

`src/storage/tx/ob_gts_task_queue.h`

### 7.2 队列类型

```cpp
// src/storage/tx/ob_gts_define.h, line 22-27
enum ObGTSCacheTaskType {
  GET_GTS = 0,          // 等待 GTS 值
  WAIT_GTS_ELAPSING,    // 等待 GTS 越过某个时间点
};
```

### 7.3 任务队列结构

```cpp
// src/storage/tx/ob_gts_task_queue.h, line 26-40
class ObGTSTaskQueue {
  ObGTSCacheTaskType task_type_;
  common::ObLinkQueue queue_;    // 无锁链接队列
  static const int64_t TOTAL_WAIT_TASK_NUM = 500 * 1000;  // 50 万任务容量
};
```

任务入队：`push(ObTsCbTask *task)` → 放入 `ObLinkQueue`  
任务派发：`foreach_task(srr, gts, receive_gts_ts)` → 遍历队列，对每个 task 调用回调

### 7.4 回调接口

```cpp
// src/storage/tx/ob_ts_mgr.h, line 60-70
class ObTsCbTask : public common::ObLink {
  virtual int get_gts_callback(const MonotonicTs srr,
                               const share::SCN &gts,
                               const MonotonicTs receive_gts_ts) = 0;
  virtual int gts_elapse_callback(const MonotonicTs srr,
                                  const share::SCN &gts) = 0;
  virtual int gts_callback_interrupted(const int errcode,
                                       const share::ObLSID ls_id) = 0;
};
```

`foreach_task()` 遍历队列，对每个 task 调用对应类型的回调。如果回调返回 `OB_EAGAIN`（说明 gts 还不够大），task 重新留在队列中，下次再触发。

---

## 8. ObTimeWheel 时间轮

### 8.1 定义位置

`src/storage/tx/ob_time_wheel.h/cpp`

### 8.2 设计动机

事务系统中大量超时任务（事务锁等待超时、2PC 超时），需要一个高效的时间管理结构。时间轮相比传统定时器（timerfd、最小堆）的优势：

- **O(1) 调度/取消**：hash 到 bucket，链表操作
- **批量到期处理**：一次 scan 处理一个 slot 的所有到期任务
- **无锁并发**：每个 bucket 有独立自旋锁

### 8.3 层次结构

```
ObTimeWheel (对外接口)
  ├── TimeWheelBase[0]    ── 线程 0
  ├── TimeWheelBase[1]    ── 线程 1
  ├── ...
  └── TimeWheelBase[N-1]  ── 线程 N-1 (N ≤ 64)

每个 TimeWheelBase:
  ├── precision_          ── 精度（us 粒度）
  ├── buckets_[10000]     ── 10,000 个 bucket
  ├── scan_ticket_        ── 当前扫描位置
  └── run1()              ── 线程主循环: scan() → sleep
```

### 8.4 调度算法

```cpp
// src/storage/tx/ob_time_wheel.cpp, line 127-180
int TimeWheelBase::schedule(ObTimeWheelTask *task, const int64_t delay)
{
  // run_ticket = (当前时间 + delay) / precision
  run_ticket = (ObClockGenerator::getRealClock() + delay + precision_ - 1) / precision_;

  // idx = (run_ticket - start_ticket) % MAX_BUCKET (MAX_BUCKET = 10000)
  const int64_t idx = (tmp_run_ticket - start_ticket_) % MAX_BUCKET;
  bucket->list_.add_last(task);
  // scan 线程到达 idx 时，执行所有在 idx 中的任务
}
```

超时任务 (`ObTimeWheelTask`) 的核心接口：
- `runTimerTask()` — 超时执行的纯虚函数
- `cancel()` — 取消已调度的任务
- `is_scheduled_` — 防止重复调度

### 8.5 scan 过程

`scan()` 每 `precision_` us 唤醒一次，扫描当前 `scan_ticket_` 的 bucket，逐个执行 `task->runTask()`。

最大睡眠时间：`1000000us = 1s`（当没有任务时不会无限沉睡）。

### 8.6 事务超时检测

事务的超时检测通过时间轮调度 `ObTimeWheelTask` 实现。当事务启动时，调度一个延迟为 `tx_timeout` 的任务；如果任务在超时前被 `cancel()`（事务正常结束）则无事发生；否则 `runTimerTask()` 触发事务回滚。

```
事务开始 ──▶ schedule(任务, timeout_delay)
                  │
          timeout_delay 后 ──▶ scan() 触发
                  │              │
            正常结束？            ├── runTimerTask() → 回滚
                  │              └── 事务已结束 → ignore
             cancel()
```

---

## 9. GTS 在事务中的使用

### 9.1 事务读 — 获取 snapshot_version

```cpp
// src/storage/tx/ob_trans_service_v4.cpp, line 1964
if (OB_FAIL(ts_mgr_->get_gts_sync(
    gts_tenant_id, request_time, timeout_us, snapshot, receive_gts_ts))) {
```

事务开始时，通过 `get_gts_sync()` 获取全局一致的 snapshot version。这个版本号用于 MVCC 可见性判断——事务只能看到 version ≤ snapshot 的数据行。

### 9.2 事务提交 — 获取 commit_version

2PC 提交过程中，Pre-Commit 阶段使用 GTS 作为 commit version：

```cpp
// src/storage/tx/ob_tx_2pc_msg_handler.cpp, line 314
if (OB_FAIL(ts_mgr->get_ts_sync(MTL_ID(), 1000000, scn, unused))) {
  clear_req.max_commit_log_scn_ = scn;
}
```

### 9.3 2PC Clear 阶段

LS 删除时，Clear 请求需要携带当前 GTS 作为 `max_commit_log_scn_`，确保所有 follower 知道"不会再有比这个 SCN 更大的事务"。

### 9.4 Weak Read 场景

Weak Read 服务使用 GTS 判断读一致性边界：

```cpp
// src/storage/tx/wrs/ob_weak_read_util.cpp, line 77
if (OB_FAIL(OB_TS_MGR.get_gts(tenant_id, NULL, tmp_scn))) {
```

### 9.5 事务状态判断

`wait_gts_elapse(ts)` 等待 GTS 越过指定时间点，用于"等待某个事务绝对结束"的场景：

```cpp
// src/storage/tx/ob_gts_source.cpp, line 315-360
int ObGtsSource::wait_gts_elapse(const int64_t ts, ObTsCbTask *task, bool &need_wait)
{
  if (ts > gts) {
    // gts 还没超过 ts，需要等待
    task 入 WAIT_GTS_ELAPSING 队列
  }
}
```

---

## 10. 与前面文章的关联

### 10.1 文章 01 — MVCC Row (`01-mvcc-row-analysis.md`)

MVCC 行的 `trans_version`（事务版本号）直接由 GTS 分配。`SCN::convert_for_tx()` 将 GTS 的 ns 时间戳转为事务版本，写入 MemTable 的 Row Header。MVCC 的可见性判断本质上是：
```
SCN(snapshot_version) >= SCN(trans_version)  → 可见
```

### 10.2 文章 10 — 2PC 事务 (`10-ob-transaction-analysis.md`)

2PC 的 Prepare → Pre-Commit → Commit 状态变更中，commit version 通过 GTS 分配。GTS 保证：
- `commit_version` 全局单调递增
- 所有节点的 `commit_version` 严格有序
- 用于解决 2PC 的"全局顺序"问题

### 10.3 文章 11 — PALF (`11-palf-analysis.md`)

PALF（Paxos Log）的每条日志都有对应的 SCN。GTS 为日志 SCN 提供了全局唯一的时间戳：

```
PALF Log Entry:
  ┌──────────────────────┐
  │ LSN (物理位置)        │
  │ SCN (逻辑时间戳 ← GTS) │
  │ Log Body              │
  └──────────────────────┘
```

GTS 保证 PALF 日志排序的全局一致性——即使跨不同的日志流，SCN 也是严格递增的。

### 10.4 文章 25 — 内存管理 (`25-memory-management-analysis.md`)

GTS 的 `ObGtsSource`、任务队列、缓存等内存结构是每租户独立的，通过 `MTL()` 框架管理生命周期。

### 10.5 文章 27 — RootServer (`27-rootserver-analysis.md`)

RootServer 负责 GTS 的分布和迁移。GTS 所在的日志流（`GTS_LS`）跟随 RootServer 的 partition 调度策略。

---

## 11. 设计决策

### 11.1 为什么需要全局单调递增的时间戳？

分布式数据库没有统一的物理时钟。每个节点的本地时钟存在差异。GTS 提供了**逻辑时钟**，解决：

- **MVCC 可见性**：跨节点事务需要全局一致的"快照时间"
- **2PC 提交顺序**：全局有序的 commit version 避免提交冲突
- **日志复制**：Paxos 日志的全局顺序保证数据一致性

### 11.2 GTS 单点瓶颈的缓解

GTS Leader 理论上是一个单点。缓解策略：

1. **本地缓存**（`ObGTSLocalCache`）：`srr_ - gts_` 窗口内的时间戳请求全部命中本地，无需 RPC。缓存命中率 ≈ 100% 在正常工作负载下
2. **异步回调**：缓存未命中时，task 入队等待，不阻塞调用线程
3. **本地调用优化**：Follower 节点与 Leader 同节点时，走本地函数调用而非网络 RPC
4. **统计监控**：`ObGtsStatistics` 每 5s 输出命中率统计，辅助调优

```
GTS 获取的四种模式:
┌──────────────────────────────────────────────────┐
│  模式           │   RPC?  │  同步? │  延迟         │
├──────────────────────────────────────────────────┤
│  本地缓存命中    │   否    │  是   │  纳秒级        │
│  本地 Leader    │   否    │  是   │  微秒级        │
│  远程 RPC 同步  │   是    │  是   │  毫秒级        │
│  远程 RPC 异步  │   是    │  否   │  取决于调度     │
└──────────────────────────────────────────────────┘
```

### 11.3 时钟同步方案

OceanBase 的 GTS 依赖机器时钟的单调性（通过 `MonotonicTs` + `ObClockGenerator`）。几种硬件方案：

- **RDTSC**（x86 TSC）：高精度，低延迟，但虚拟机环境下不可靠
- **HPET/ACPI**：精度较低
- **PTP/NTP**：网络时间同步，保证节点间时钟偏差可控

OceanBase 在 4.x 优先保证**软件层的单调性**而非硬件时钟同步。如果发生时钟回拨，`ObIDService` 的预分配机制保证 GTS 不倒退。

### 11.4 SCN 的精度选择

选择 **62 位纳秒**而非 64 位整数的原因：

```
62 位 max: ~4.6 × 10¹⁸ ns ≈ 146 年 ✓ 足够覆盖数据库寿命
剩余 2 位：版本号，支持未来扩展
```

如果使用 64 位整数（无符号），范围约 584 年，但失去了版本号的扩展性。OceanBase 选择"够用即可"。

对比其他系统：

| 系统 | 时间戳类型 | 精度 | 范围 |
|------|-----------|------|------|
| OceanBase | SCN (62-bit ns + 2-bit ver) | 1ns | ~146年 |
| CockroachDB | HLC (hybrid logical clock) | 逻辑时钟 | 无上限 |
| Spanner | TrueTime | ~1-7ms 窗口 | 无上限 |
| TiDB | TSO (Timestamp Oracle) | 逻辑时钟 | 128-bit |

### 11.5 GTS 缓存的一致性保证

本地缓存的设计保证**读一致性**（Read-Your-Writes）：

1. 事务 A 写入，获得 commit_version = GV₁
2. 事务 A 的 commit 日志同步到 GTS Leader
3. GTS @ Leader ≥ GV₁
4. 事务 B（与 A 同节点）读取 GTS 缓存，保证 ≥ GV₁

但跨节点需要协议保证：`stc` 参数在 RPC 请求中传递，使 GTS Source 知道"我请求的时刻"，GTS 保证返回的时间戳 ≥ 该时刻。

### 11.6 ObTimeWheel vs 其他定时器方案

| 维度 | ObTimeWheel | Linux timerfd | 最小堆 |
|------|------------|---------------|--------|
| 调度复杂度 | O(1) | O(log n) | O(log n) |
| 取消复杂度 | O(1) | O(log n) | O(log n) (需 lazy) |
| 精度 | bucket 粒度 | 高精度 | 高精度 |
| 适用场景 | 大量超时任务 | 通用 | 通用 |

OceanBase 选择时间轮是因为事务系统有大量超时任务（每个事务一个），但对精度要求不高（毫秒级）。时间轮的 batch processing 特性使其在 10K+ 任务场景下性能优异。

---

## 12. 源码索引

| 文件 | 行数 | 说明 |
|------|------|------|
| `src/share/scn.h` | ~151 | SCN 类型定义，union 布局，转换函数声明 |
| `src/share/scn.cpp` | ~487 | SCN 实现，原子操作，各 convert_* 函数 |
| `src/storage/tx/ob_gts_source.h` | ~120 | ObGtsSource 定义，两个任务队列 + 本地缓存 |
| `src/storage/tx/ob_gts_source.cpp` | ~700+ | GTS 获取/等待/回调核心逻辑 |
| `src/storage/tx/ob_gts_define.h` | ~38 | GTS 枚举定义、atomic_update 工具函数 |
| `src/storage/tx/ob_gts_local_cache.h` | ~53 | ObGTSLocalCache 结构（srr_/gts_/latest_srr_） |
| `src/storage/tx/ob_gts_local_cache.cpp` | ~140 | 缓存读写、更新顺序保证 |
| `src/storage/tx/ob_gts_msg.h` | ~80 | GTS RPC 消息结构（Request/ErrResponse） |
| `src/storage/tx/ob_gts_rpc.h` | ~350 | RPC Proxy/Processor/Callback 定义 |
| `src/storage/tx/ob_gts_task_queue.h` | ~40 | ObGTSTaskQueue 定义（GET_GTS / WAIT_GTS） |
| `src/storage/tx/ob_timestamp_service.h` | ~50 | ObTimestampService 定义 |
| `src/storage/tx/ob_timestamp_service.cpp` | ~290 | GTS Leader 时间戳分配、RPC 处理 |
| `src/storage/tx/ob_id_service.h` | ~200 | ID 预分配基础类，PALF 持久化 |
| `src/storage/tx/ob_time_wheel.h` | ~150 | TimeWheelBase + ObTimeWheel 定义 |
| `src/storage/tx/ob_time_wheel.cpp` | ~550 | 时间轮调度/取消/scan 实现 |
| `src/storage/tx/ob_ts_mgr.h` | ~400 | ObTsMgr 全局 GTS 入口，ObTsCbTask 回调接口 |
| `src/storage/tx/ob_ts_mgr.cpp` | ~500+ | get_gts/get_gts_sync/wait_gts_elapse 实现 |
| `src/storage/tx/ob_ts_worker.h` | ~50 | GTS RPC 响应的工作线程 |
| `src/storage/tx/ob_ts_response_handler.h` | ~50 | GTS 响应处理 |
| `src/storage/tx/ob_i_ts_source.h` | ~50 | 时间戳源接口定义 |
| `src/storage/tx/ob_timestamp_access.h` | ~85 | 每租户 GTS 访问入口 |
| `src/storage/tx/ob_trans_define.h` | ~1911 | MonotonicTs 别名，GTS 租户掩码定义 |
| `deps/oblib/src/lib/time/ob_time_utility.h` | ~110 | ObMonotonicTs 结构定义 |

---

## 13. 总结

OceanBase 的 GTS 和时间模型是分布式数据库的时间基石。核心设计哲学：

1. **SCN 统一时间语义**：从 MVCC 到 PALF 日志，所有时间戳都用 SCN 类型表达
2. **GTS 基于机器时钟**：利用 TSC/clock_gettime 提供纳秒级精度，不依赖外部授时服务
3. **本地缓存消除瓶颈**：大多数场景下 GTS 获取是本地操作，不产生网络开销
4. **预分配保证单调性**：Leader 切换时通过预分配避免时钟回拨
5. **异步回调处理延迟**：缓存未命中时 task 入队，不阻塞调用线程

这套设计让 OceanBase 能在高并发分布式事务中提供严格的时间序保证，同时又避免了集中式时间戳服务的瓶颈。
