# 44 — IO 子系统 — IO 调度、预读、mClock 算法

> 基于 OceanBase CE 主线源码
> 分析范围：`src/share/io/`（IO 管理器 + 调度 + 校准）+ `deps/oblib/src/common/storage/ob_io_device.h`（设备抽象层）
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与代码结构分析

---

## 0. 概述

**IO 子系统是 OceanBase 最底层的基础设施。** 所有磁盘读写——SSTable 数据、Clog 日志、Macro Block、临时文件——最终都流经 IO 子系统。

从架构上看，IO 子系统位于存储引擎之下、操作系统之上：

```
┌──────────────────────────────────────────┐
│  SQL Layer / DAS / Transaction           │
├──────────────────────────────────────────┤
│  Storage Engine                          │
│  (SSTable Reader/Writer, Clog, Macro)    │
├──────────────────────────────────────────┤
│  ┌────────────────────────────────────┐  │
│  │  IO 子系统                          │  │
│  │  ├─ ObIOManager（入口）              │  │
│  │  ├─ IO Scheduler（mClock 调度）      │  │
│  │  ├─ IOSender（IO 发送线程）           │  │
│  │  ├─ DeviceChannel（设备通道）         │  │
│  │  ├─ IOChannel（异步/同步 IO）         │  │
│  │  └─ IO Calibration（校准）           │  │
│  └────────────────────────────────────┘  │
├──────────────────────────────────────────┤
│  ObIODevice（设备抽象层）                  │
│  ├─ 本地文件系统 (pread/pwrite)          │
│  ├─ 对象存储 (OSS/S3)                   │
│  └─ 本地缓存设备                         │
├──────────────────────────────────────────┤
│  操作系统 / 内核 AIO / io_uring          │
└──────────────────────────────────────────┘
```

核心模块分布：

| 模块 | 文件 | 作用 |
|------|------|------|
| **ObIOManager** | `ob_io_manager.h/cpp` | 全局 IO 管理器，入口点 |
| **IO 数据结构** | `ob_io_struct.h/cpp` | ObIOInfo、ObIORequest、ObIOHandle |
| **IO 定义** | `ob_io_define.h` | ObIOFlag、ObPhyQueue、ObMClockQueue、ObAtomIOClock |
| **IO 调度 V2** | `io_schedule/ob_io_schedule_v2.h/cpp` | 分层队列调度器（基于 OS qdisc） |
| **mClock** | `io_schedule/ob_io_mclock.h/cpp` | mClock 算法、ObMClock、ObTenantIOClock |
| **IO 校准** | `ob_io_calibration.h/cpp` | 自动磁盘 IOPS/延迟测量 |
| **设备抽象** | `deps/oblib/.../ob_io_device.h` | ObIODevice 虚基类 |

---

## 1. ObIOManager — 全局 IO 管理器

### 1.1 单例与初始化

`ObIOManager` 是一个**单例**（`get_instance()`），全局唯一，管理所有 IO 资源。定义在 `ob_io_manager.h:327`：

```cpp
class ObIOManager final
{
  static ObIOManager &get_instance();
  int init(const int64_t memory_limit = DEFAULT_MEMORY_LIMIT,  // 10GB
           const int32_t queue_depth = DEFAULT_QUEUE_DEPTH,    // 10000
           const int32_t schedule_thread_count = 0);
  void destroy();
  int start();
  void stop();
  void wait();
  // ...
};
```

其核心成员（`ob_io_manager.h:435-444`）：

```cpp
ObIOConfig io_config_;              // IO 配置（线程数、超时等）
ObConcurrentFIFOAllocator allocator_; // IO 内存分配器
hash::ObHashMap<int64_t, ObDeviceChannel *> channel_map_; // 设备通道映射
ObIOFaultDetector fault_detector_;  // 设备健康检测
ObIOScheduler io_scheduler_;        // IO 调度器（V1，mClock）
ObTrafficControl tc_;               // 流量控制（共享存储限流）
```

### 1.2 主要接口

ObIOManager 提供三组 IO 接口（`ob_io_manager.h:339-380`）：

**异步 IO：**
```cpp
int aio_read(const ObIOInfo &info, ObIOHandle &handle);
int aio_write(const ObIOInfo &info, ObIOHandle &handle);
```

**同步 IO：**
```cpp
int read(const ObIOInfo &info, ObIOHandle &handle);
int write(const ObIOInfo &info);
int pread(ObIOInfo &info, int64_t &read_size);
int pwrite(ObIOInfo &info, int64_t &write_size);
```

**工具 IO（对象存储）：**
```cpp
int exist() / stat() / unlink() / mkdir() / rmdir() / scan_dir() / ...
```

所有异步 IO 的核心路径：**调用方 → `ObTenantIOManager::inner_aio()` → 分配 ObIORequest → IO 调度器 → 入队 → 发送线程 → 设备通道 → 内核 AIO → 完成回调 → 唤醒等待者**。

### 1.3 ObTenantIOManager — 租户级 IO 管理

每个租户有自己的 `ObTenantIOManager`（`ob_io_manager.h:448`），管理：

```cpp
ObTenantIOConfig io_config_;          // 租户 IO 配置（min_iops、max_iops、weight）
ObTenantIOClock io_clock_;            // 租户 mClock 时钟
ObIOScheduler *io_scheduler_;         // 共享的 V1 调度器
ObTenantIOSchedulerV2 qsched_;        // V2 调度器（基于 OS qdisc）
ObIOCallbackManager callback_mgr_;    // 回调管理
ObIOUsage io_usage_;                  // IO 用量统计
ObIOTracer io_tracer_;                // IO 追踪
```

`inner_aio()`（`ob_io_manager.h:466`）是异步 IO 的入口，流程：

1. 分配 `ObIORequest` 和 `ObIOResult`
2. 设置回调、超时、trace
3. 调用 `schedule_request()` 入调度队列
4. 返回 `ObIOHandle` 给调用方

---

## 2. IO 数据结构

### 2.1 ObIOInfo — IO 请求信息

`ob_io_define.h:399`（通过 `ObSNIOInfo`），定义了完整的 IO 请求参数：

```cpp
struct ObSNIOInfo {
  uint64_t tenant_id_;       // 租户 ID
  ObIOFd fd_;                // 文件描述符
  int64_t offset_;           // 偏移
  int64_t size_;             // 大小
  int64_t timeout_us_;       // 超时
  ObIOFlag flag_;            // 标志（读写、优先级等）
  ObIOCallback *callback_;   // 完成回调
  const char *buf_;          // 数据缓冲区
  char *user_data_buf_;      // 用户数据缓冲区
  int64_t part_id_;          // 分片上传 ID
  ObString uri_;             // 对象存储 URI
};
```

在共享存储模式下，通过宏定义为 `ObSSIOInfo`，增加 `phy_block_handle_`、`fd_cache_handle_`、`write_strategy_` 等共享存储特有字段。

### 2.2 ObIOFlag — 标志位

`ob_io_define.h:133` 中的位域联合体，一个 64 位整数编码所有 IO 属性：

```
mode_ : 4        → READ/WRITE
read_mode_ : 4   → DEFAULT/EXIST/STAT/UNLINK/...
func_type_ : 8   → 功能类型
wait_event_id_ : 32 → 等待事件 ID
is_sync_ : 1     → 同步 IO
is_unlimited_ : 1 → 不限流
is_detect_ : 1   → 检测 IO
is_write_through_ : 1 → 直写模式（针对对象存储）
is_sealed_ : 1   → 已封存（可刷到对象存储）
is_buffered_read_ : 1 → 缓冲读
is_preread_ : 1  → 预读
is_upload_part_ : 1 → 分片上传
```

**优先级**（`ObIOPriority`，`ob_io_define.h:86`）：

| 优先级 | 值 | 场景 |
|--------|-----|------|
| EMERGENT | 0 | 预留 |
| HIGH | 1 | 转储写、中间层索引读取 |
| MIDDLE | 2 | 合并写、临时文件写 |
| LOW | 3 | 后台任务（CRC 校验等） |

### 2.3 ObIORequest — IO 请求

`ob_io_define.h:638`，继承 `ObDLinkBase`（可链表化）和 `TCRequestOwner`（与 qdisc 关联）：

```cpp
class ObIORequest {
  ObIOResult *io_result_;      // IO 结果
  TCRequest qsched_req_;       // qdisc 请求（V2 调度用）
  void *raw_buf_;              // 原始缓冲区
  int64_t align_size_;         // 对齐后大小
  int64_t align_offset_;       // 对齐后偏移
  ObIOCB *control_block_;      // AIO control block
  ObIOFd fd_;                  // 文件描述符
  int8_t retry_count_;         // 重试次数
};
```

完整的生命周期：**init → prepare → submit → complete → callback → free**。

### 2.4 ObIOHandle — 结果句柄

`ob_io_define.h:767`，对 `ObIOResult` 的引用封装，提供：

```cpp
class ObIOHandle {
  int wait(const int64_t wait_timeout_ms = UINT64_MAX);  // 等待完成
  const char *get_buffer();                               // 获取数据
  int64_t get_data_size();                                // 获取数据大小
  void cancel();                                          // 取消
};
```

### 2.5 ObIOResult — IO 结果

`ob_io_define.h:564`，持有一个 `ObThreadCond` 用于等待/通知，记录完整的时间线：

```cpp
struct ObIOTimeLog {  // ob_io_define.h:453
  int64_t begin_ts_;           // 起始时间
  int64_t enqueue_ts_;         // 入队时间
  int64_t dequeue_ts_;         // 出队时间
  int64_t submit_ts_;          // 提交到设备时间
  int64_t return_ts_;          // 返回时间
  int64_t callback_enqueue_ts_; // 回调入队时间
  int64_t callback_dequeue_ts_; // 回调出队时间
  int64_t callback_finish_ts_;  // 回调完成时间
  int64_t end_ts_;             // 结束时间
};
```

这 9 个时间戳精确记录了一次 IO 从发起到完成的每个阶段延迟。

---

## 3. IO 调度策略

OceanBase 实现了**两代 IO 调度器**：

- **V1（mClock 调度器）**：`ObIOScheduler` + `ObIOSender` + `ObMClockQueue`，用于本地磁盘 IO
- **V2（基于 OS qdisc）**：`ObIOManagerV2` + `ObTenantIOSchedulerV2`，用于共享存储和带宽控制

### 3.1 V1 调度器架构

```
┌─────────────────────────────────────────────────────┐
│                  ObIOScheduler                        │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐             │
│  │Sender 0 │  │Sender 1 │  │Sender 2 │  ...         │
│  └────┬────┘  └────┬────┘  └────┬────┘             │
│       │            │            │                    │
│  ┌────▼────┐  ┌────▼────┐  ┌────▼────┐             │
│  │ MClock  │  │ MClock  │  │ MClock  │             │
│  │ Queue   │  │ Queue   │  │ Queue   │             │
│  └─────────┘  └─────────┘  └─────────┘             │
└─────────────────────────────────────────────────────┘
         │                │                │
         ▼                ▼                ▼
  ┌───────────────────────────────────────────────┐
  │           ObIOSender::run1()                   │
  │  循环: pop → submit → 设备通道                   │
  └───────────────┬───────────────────────────────┘
                  ▼
         ┌─────────────────┐
         │  ObDeviceChannel │
         ├─────────────────┤
         │ AsyncChannel x N│──→ 内核 AIO (io_submit)
         │ SyncChannel  x M│──→ 同步线程池 (pread/pwrite)
         └─────────────────┘
```

**ObIOSender**（`ob_io_struct.h:325`）是核心的 IO 发送线程，每个 sender 持有一个 `ObMClockQueue`。

`pop_and_submit()` 的工作循环：

1. 从 `ObMClockQueue` 中 pop 出优先级最高的请求
2. 调用 `submit(req)` 提交到设备通道
3. 完成回调唤醒等待者

### 3.2 V2 调度器架构

`ObIOManagerV2`（`ob_io_schedule_v2.h:41`）是一个基于 OS qdisc（队列规则）的分层调度器：

```
                   root (qid: root_qid_)
                    │
        ┌───────────┼───────────┐
        │           │           │
    net_in       net_out      disk
   (READ BW)   (WRITE BW)  (DISK IOPS)
        │           │           │
    Tenant A    Tenant A    Tenant A
    WEIGHTED    WEIGHTED    WEIGHTED
        │           │           │
    ┌───┴───┐   ┌───┴───┐   ┌───┴───┐
    │Group1 │   │Group1 │   │Group1 │  ← BufferQueue
    │Group2 │   │Group2 │   │Group2 │
    │...    │   │...    │   │...    │
    └───────┘   └───────┘   └───────┘
```

`calc_bw()`（`ob_io_schedule_v2.cpp:134`）将 min_iops/max_iops 转换为带宽：
```cpp
int64_t unit_max_bw = mode == MAX_MODE ? 
  (max_iops * STANDARD_IOPS_SIZE) : max_net_bandwidth_;
```

三个子 root 分别对应：
- `ObIOMode::READ` → 网络入带宽（net_in）
- `ObIOMode::WRITE` → 网络出带宽（net_out）
- `ObIOMode::MAX_MODE` → 本地磁盘 IOPS（disk，用 `STANDARD_IOPS_SIZE=16KB` 归一化）

`ObTenantIOSchedulerV2::schedule_request()`（`ob_io_schedule_v2.cpp:211`）的流程：

1. `get_qindex(req)` → 根据 `ObIOGroupKey` 找到组索引
2. `get_qid(index, req, is_default_q)` → 找到对应的 qdisc 队列 ID
3. 流量控制注册 → `register_bucket(req, qid)`
4. `qsched_submit(root, &req.qsched_req_, chan_id)` → 提交到 OS qdisc

### 3.3 ObPhyQueue — 物理队列

`ob_io_define.h:733`，mClock 调度中的最小调度单元：

```cpp
class ObPhyQueue final {
  int64_t reservation_ts_;    // 标签 R：预留时间戳
  int64_t limitation_ts_;     // 标签 L：限制时间戳
  int64_t proportion_ts_;     // 标签 P：比例时间戳
  int64_t queue_index_;       // 队列索引
  IOReqList req_list_;        // 请求链表（FIFO）
};
```

每个 IO 组（Group，如 "HIGH"/"MIDDLE"/"LOW"）对应一个 `ObPhyQueue`。

---

## 4. mClock 算法深度分析

### 4.1 算法背景

mClock 是 **VMware 在 2010 年 USENIX FAST 提出的 IO 调度算法**，论文标题：*mClock: Handling Throughput Variability for Hypervisor IO Scheduling*。

核心思想：**用三个标签（tag）同时提供最小保证、上限限制和权重分配**。

### 4.2 三个标签

`ObMClock`（`ob_io_mclock.h:27`）包含三个原子时钟：

```cpp
struct ObMClock final {
  ObAtomIOClock limitation_clock_;    // L 标签：最大 IOPS 限制
  ObAtomIOClock reservation_clock_;  // R 标签：最小 IOPS 保证
  ObAtomIOClock proportion_clock_;   // P 标签：比例权重分配
  bool is_unlimited_;                // 是否不限流
};
```

**ObAtomIOClock**（`ob_io_define.h:885`）：

```cpp
struct ObAtomIOClock final {
  int64_t iops_;     // IOPS 值（或带宽值）
  int64_t last_ns_;  // 上次更新时间（纳秒）
};
```

三个标签的语义：

| 标签 | 含义 | 计算方式 |
|------|------|----------|
| **R（reservation）** | 最小保证 IOPS | 每个请求向前拨动 `1/(min_iops * iops_scale)` ns |
| **L（limitation）** | 最大 IOPS 上限 | `compare_and_update` 取最大值 |
| **P（proportion）** | 权重比例 | 每个请求向前拨动 `1/(weight * iops_scale)` ns |

### 4.3 调度过程

`ObTenantIOClock::calc_phyqueue_clock()`（`ob_io_mclock.cpp:105`）是核心计算函数：

```
calc_phyqueue_clock(phy_queue, req):
  1. 获取 mclock（根据 queue_index）
  2. 计算 iops_scale（通过 IO 校准）
  3. 计算三个标签的时间戳：
     a. reservation: mclock->reservation.atom_update_reserve(now, iops_scale) → phy_queue->reservation_ts_
        → 如果 min_iops=1000, iops_scale=0.5，每个请求增加 1/(1000*0.5) = 2ms
     b. proportion: mclock->proportion.atom_update(now, iops_scale) → phy_queue->proportion_ts_
        → 按权重均匀向前拨动
     c. limitation: mclock->limitation.compare_and_update(now, iops_scale) → phy_queue->limitation_ts_
        → 取 max(当前时间, 上次时间 + 1/(max_iops * iops_scale))，确保不超过上限
     d. unit limitation: unit_clocks[mode].compare_and_update(now, iops_scale) → phy_queue->limitation_ts_
        → 租户级上限
```

关键：**所有计算使用 `iops_scale` 将不同大小的 IO（4KB、16KB、1MB）归一化**。校准信息提供了不同 IO 大小的代价权重。

### 4.4 ObMClockQueue 的调度逻辑

`ObMClockQueue`（`ob_io_define.h:910`）管理多个 `ObPhyQueue`，通过**三个堆**实现多标签调度：

```cpp
class ObMClockQueue {
  ObRemovableHeap<ObPhyQueue*, R_cmp> r_heap_;   // 按 reservation_ts 排序
  ObRemovableHeap<ObPhyQueue*, L_cmp> l_heap_;   // 按 limitation_ts 排序
  ObRemovableHeap<ObPhyQueue*, P_cmp> ready_heap_; // 按 proportion_ts 排序
};
```

**`pop_phyqueue()` 逻辑**（简化）：

```
pop_phyqueue():
  1. 从 r_heap 取 top（最小 reservation_ts 的队列）
  2. 检查 limitation → 如果 limitation_ts > current_time，跳过（不能超过上限）
  3. 检查比例 → 设置 deadline_ts = max(reservation_ts, proportion_ts, limitation_ts)
  4. 从对应队列的 req_list_ 中 pop 一个请求
  5. 如果队列非空，重新计算并插入堆
```

调度策略：
- **确保最小保证**：reservation_ts 最小的队列优先服务
- **不超上限**：limitation_ts 还在未来的队列不能出队
- **权重分配**：reservation 满足后，proportion_ts 决定公平性
- **突发容忍**：`PHY_QUEUE_BURST_USEC=2ms` 的向前偏移允许短时突发

### 4.5 时钟同步

多租户场景下，不同 `ObTenantIOClock` 的 proportion clock 需要同步：

```cpp
int ObTenantIOClock::sync_clocks(ObIArray<ObTenantIOClock *> &io_clocks)
{
  // 找到所有时钟中最小的 proportion_ts
  int64_t min_proportion_ts = INT64_MAX;
  for (auto *cur_clock : io_clocks)
    min_proportion_ts = min(min_proportion_ts, cur_clock->get_min_proportion_ts());
  
  // 如果最小的 proportion_ts 在未来，所有时钟向前拨动
  int64_t delta_us = min_proportion_ts - fast_current_time();
  if (delta_us > 0) {
    for (auto *cur_clock : io_clocks)
      cur_clock->adjust_proportion_clock(delta_us);
  }
}
```

空闲检测阈值 `MAX_IDLE_TIME_US=100ms`（`ob_io_mclock.h:56`），超过此时间进入 `try_sync_tenant_clock()`。

---

## 5. IO 校准（IO Calibration）

### 5.1 为什么要校准？

**不同磁盘、不同 IO 大小的 IOPS 相差巨大。** 一个 4KB 随机读可能达到 100 万 IOPS，而 1MB 顺序读只有几千 IOPS。mClock 需要用统一的 IOPS 值来调度不同大小的 IO，这就需要知道每种 IO 大小的实际代价。

### 5.2 校准数据模型

`ObIOBenchResult`（`ob_io_calibration.h:43`）记录一次基准测试的测量结果：

```cpp
struct ObIOBenchResult {
  ObIOMode mode_;    // READ / WRITE
  int64_t size_;      // IO 大小
  double iops_;       // 实测 IOPS
  double rt_us_;      // 实测延迟（微秒）
};
```

`ObIOAbility`（`ob_io_calibration.h:51`）聚合所有测量结果，按 READ/WRITE 分两组，每组包含不同 IO 大小的条目。

### 5.3 校准流程

`ObIOCalibration`（`ob_io_calibration.h:125`）是单例，管理校准数据：

```
基准测试流程：
1. ObIOBenchRunner::do_benchmark(load, thread_count, result)
2. 多线程并发读写 benchmark 文件
3. 记录 IOPS 和延迟
4. 结果存入 ObIOAbility
5. 写入内部表 __all_disk_io_calibration
```

**`get_iops_scale()`**（`ob_io_calibration.h:136`）将不同大小的 IO 归一化到基准 IO（16KB READ）：
```cpp
void ObIOCalibration::get_iops_scale(mode, size, &iops_scale, &is_valid) {
  // iops_scale = baseline_iops / actual_iops
  // 如果 16KB READ = 10000 IOPS, 1MB READ = 500 IOPS
  // 则 iops_scale = 10000/500 = 20
  // 即 1MB 读 = 20 个标准 IO
}
```

此 `iops_scale` 被 mClock 用于 `calc_phyqueue_clock()` 中，将实际 IO 大小归一化为标准 IO 代价。参考 `ob_io_manager.cpp:37`：

```cpp
int64_t get_norm_iops(const int64_t size, const double iops, const ObIOMode mode)
{
  // 带宽 / STANDARD_IOPS_SIZE 或 iops / iops_scale
}
```

### 5.4 BASELINE 定义

`ob_io_calibration.h:148`：
```cpp
static const ObIOMode BASELINE_IO_MODE = ObIOMode::READ;
static const int64_t BASELINE_IO_SIZE = 16L * 1024L;  // 16KB
```

所有 IO 代价以 **16KB 随机读**的 IOPS 为基准 1.0。

---

## 6. IO 设备层

### 6.1 ObIODevice 虚基类

`ob_io_device.h:247` 定义了设备抽象，支持多种后端：

```cpp
class ObIODevice {
  ObStorageType device_type_;  // LOCAL / OSS / S3 / LOCAL_CACHE / ...
  int64_t media_id_;

  // 同步接口
  virtual int pread(const ObIOFd &fd, offset, size, buf, &read_size) = 0;
  virtual int pwrite(const ObIOFd &fd, offset, size, buf, &write_size) = 0;
  
  // 异步接口（基于 Linux AIO 或 io_uring）
  virtual int io_setup(max_events, &io_context) = 0;
  virtual int io_prepare_pread(fd, buf, count, offset, iocb, callback) = 0;
  virtual int io_submit(io_context, iocb) = 0;
  virtual int io_getevents(io_context, min_nr, events, timeout) = 0;
  
  // 文件管理
  virtual int open(pathname, flags, mode, &fd) = 0;
  virtual int close(fd) = 0;
  virtual int unlink(pathname) = 0;
  
  // 块设备管理
  virtual int alloc_block(&block_id) = 0;
  virtual void free_block(block_id) = 0;
};
```

### 6.2 ObIOFd — 文件描述符

`ob_io_device.h:20`，统一表示所有类型的存储文件：

```cpp
struct ObIOFd {
  int64_t first_id_;    // super block(0), normal file(NORMAL_FILE_ID=0xFF...), or block ID
  int64_t second_id_;   // 二级 ID
  int64_t third_id_;    // 三级 ID
  ObIODevice *device_handle_;  // 所属设备
  
  bool is_super_block() const { return 0 == first_id_ && 0 == second_id_; }
  bool is_normal_file() const { return NORMAL_FILE_ID == first_id_ && second_id_ > 0; }
  bool is_block_file() const { return first_id_ != NORMAL_FILE_ID; }
};
```

### 6.3 设备通道

`ObDeviceChannel`（`ob_io_struct.h:503`）每个设备有多个通道：

```
ObDeviceChannel {
  async_channels_: [ObAsyncIOChannel x N]  // 异步通道（内核 AIO）
  sync_channels_:  [ObSyncIOChannel  x M]  // 同步通道（线程池）
  max_io_depth_: 最大 IO 深度
}
```

**ObAsyncIOChannel**（`ob_io_struct.h:431`）：
- 基于 Linux AIO（`io_setup`/`io_submit`/`io_getevents`）
- 轮询超时 `AIO_POLLING_TIMEOUT_NS ≈ 1s`
- 最大事件数 `MAX_AIO_EVENT_CNT = 512`

**ObSyncIOChannel**（`ob_io_struct.h:472`）：
- 简单线程池，执行 `pread`/`pwrite`
- 用于同步 IO 和设备检测

---

## 7. 数据流：一次读 IO 的完整路径

```
SQL Query
  │
  ▼
DAS Scan / SSTable Reader
  │
  ├→ 构造 ObIOInfo（tenant_id, fd, offset, size, flag, callback）
  │   flag.set_read() / flag.set_priority(HIGH)
  │
  ▼
ObIOManager::aio_read(info, handle)
  │
  ▼
ObTenantIOManager::inner_aio(info, handle)
  │
  ├→ alloc_io_request() → ObIORequest::init(info, result)
  │   ├→ 复制参数
  │   ├→ calc_io_offset_and_size() → 对齐到 4K/512B
  │   └→ 设置 trace_id、timeout
  │
  ├→ alloc_io_result() → ObIOResult::init(info)
  │   └→ 记录 begin_ts_ 到 time_log_
  │
  ├→ 是否同步/异步/检测？
  │   └→ 异步走 schedule_request()
  │
  ▼
ObTenantIOSchedulerV2::schedule_request(req)
  │
  ├→ get_qindex(req) → 根据 group_id + mode 找到组索引
  │   └→ 如果是默认组 → default_qid_
  │
  ├→ get_qid(index, req, is_default_q) → qdisc qid
  │
  ├→ register_bucket(req, qid) → 流量控制注册
  │
  ├→ qsched_submit(root, &req.qsched_req_, chan_id)
  │   └→ OS qdisc 分发到子队列
  │
  ▼
QSchedCallback::handle(tc_req)  ← 从 qdisc 出队后的回调
  │
  ├→ req.prepare() → 分配对齐缓冲区
  ├→ get_device_channel(req, device_channel) → 选择设备通道
  └→ device_channel->submit(req)
  │
  ▼
ObDeviceChannel::submit(req)
  │
  ├→ 选择通道（随机）：async_channels_ 或 sync_channels_
  │
  ▼
ObAsyncIOChannel::submit(req)
  │
  ├→ io_prepare_pread(fd, buf, count, offset, iocb, callback)
  ├→ io_submit(io_context, iocb)  → 内核 AIO
  │
  ▼
内核：磁盘 DMA 读取
  │
  ▼
ObAsyncIOChannel::run1() 轮询线程
  │
  ├→ io_getevents(io_context, min_nr, events, timeout)
  ├→ on_full_return / on_partial_return / on_failed
  ├→ result->finish(ret_code, req) → 设置完成状态
  └→ cond_.broadcast() 唤醒等待者
  │
  ▼
ObIOHandle::wait() 返回
  │  (或 callback->process() 被 ObIORunner 执行)
  │
  ▼
调用方获取数据（SSTable Reader 等）
```

---

## 8. ASCII 图：IO 调度架构

```
                    ┌──────────────────────┐
                    │   ObIOManager          │
                    │  (全局单例)             │
                    └──────────┬───────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
         V1 Scheduler     V2 Scheduler      TrafficControl
              │                │                │
     ┌────────┴────────┐  ┌───┴────┐    ┌──────┴──────┐
     │  ObIOScheduler   │  │ qdisc  │    │ shared_device│
     │  + ObIOSender    │  │ tree   │    │  clocks      │
     └────────┬────────┘  └───┬────┘    └─────────────┘
              │                │
     ┌────────┴────────┐  ┌───┴──────────────┐
     │ ObMClockQueue    │  │ ObTenantIOSched  │
     │ ┌─ r_heap (R) ─┐│  │ ullerV2           │
     │ ├─ l_heap (L) ─┤│  │ ┌─ READ qdisc   ─┐│
     │ ├─ ready(P) ───┤│  │ ├─ WRITE qdisc  ─┤│
     │ └──────────────┘│  │ └─ DISK qdisc   ─┘│
     └────────┬────────┘  └────────────────────┘
              │
     ┌────────┴─────────────────────────┐
     │ ObPhyQueue (Group 级别)           │
     │ reservation_ts  |  limitation_ts  │
     │ proportion_ts   |  req_list_      │
     └──────────────────────────────────┘
              │
     ┌────────┴─────────────────────────┐
     │ ObDeviceChannel                   │
     │ ┌─ AsyncIOChannel ──┬─ AIO ──┐   │
     │ ├─ AsyncIOChannel ──┬─ AIO ──┤   │
     │ └─ SyncIOChannel  ──┬─ pread ┘   │
     └──────────────────────────────────┘
```

```
┌──────────────── MClock 调度工作流 ──────────────────┐
│                                                       │
│ 请求到达 → 获取 ObMClock (3个时钟)                    │
│                                                       │
│  reservation_clock  proportion_clock  limitation_clock│
│      │                    │                 │          │
│      ▼                    ▼                 ▼          │
│  atom_update_    atom_update      compare_and_update   │
│  reserve()                                           │
│      │                    │                 │          │
│      ▼                    ▼                 ▼          │
│  reservation_ts_   proportion_ts_   limitation_ts_    │
│   ↑ 1/(min×scale)   ↑ 1/(w×scale)    ↑ max(now, +)   │
│                                                       │
│  → 入堆 r_heap     → 入堆 ready_heap → 入堆 l_heap    │
│                                                       │
│ pop_phyqueue():                                       │
│   1. 取 r_heap top（最小 reservation_ts）              │
│   2. 检查 limitation_ts ≤ current_time → 否则跳过     │
│   3. deadline = max(reservation, proportion, limit)   │
│   4. 从 req_list_ pop 一个请求，提交                   │
│   5. 如果队列还有请求，重新计算时间戳，插回堆            │
│                                                       │
└─────────────────────────────────────────────────────┘
```

---

## 9. 设计决策

### 9.1 为什么自研 IO 调度，而非使用内核 cfq/bfq？

| 比较维度 | 内核 BFQ/cfq | OceanBase 自研 |
|----------|-------------|----------------|
| **多租户** | 不支持租户隔离 | ObMClock 支持多租户 IO 权重 |
| **IO 大小适配** | 不知道 IO 大小代价 | 通过校准（iops_scale）归一化 |
| **最小保证** | 不支持 | mClock R 标签提供最小 IOPS 保证 |
| **跨节点带宽控制** | 只控制本地磁盘 | V2 + TrafficControl 控制网络带宽 |
| **对象存储** | 不支持 | 设备抽象层支持 OSS/S3 |
| **可观测性** | 有限 | ObIOTimeLog 9 个时间戳 + ObIOUsage |

结论：**数据库场景需要更细粒度的 IO 控制**（租户级 IOPS、写带宽限制、读延迟保证），通用 OS 调度器无法满足。

### 9.2 mClock 的选型原因

为什么选择 mClock 而不是其他调度算法？

- **提供最小保证（R）**：关键写入（Clog）始终有 IOPS 保证，不会因后台任务饿死
- **精确上限控制（L）**：防止"请求激增"，保护磁盘和网络
- **权重分配（P）**：在多租户场景实现公平共享
- **三者独立**：不像 PI/CODEL 只解决延迟，也不像 DRR 只解决公平

参照 VMware 论文中的公式：

```
R 标签：deadline_R = max(current, clock_R + 1/(min_iops * scale))
L 标签：deadline_L = max(current, clock_L + 1/(max_iops * scale))
P 标签：deadline_P = max(current, clock_P + 1/(weight * scale))
调度选择：min(deadline_R)
约束：deadline_L > current → 跳过
最终 deadline = max(deadline_R, deadline_P, deadline_L)
```

### 9.3 IO 线程数和队列深度的自校准

- **磁盘 IO 线程数**：`ObIOConfig::disk_io_thread_count_`，默认最大 64 线程
- **同步 IO 线程数**：`ObIOConfig::sync_io_thread_count_`，最大 1024 线程
- **队列深度**：`DEFAULT_QUEUE_DEPTH = 10000`
- **memory limit**：`DEFAULT_MEMORY_LIMIT = 10GB`（全局 IO 缓冲区）

IO 校准动态提供 `iops_scale`，调度器据此自适应调整不同大小 IO 的排队行为。

### 9.4 预读策略（Read-Ahead）

OceanBase 通过 `ObIOFlag` 中的 `is_preread_` 标志支持预读：

```cpp
void ObIOFlag::set_preread();     // 设置预读标志
void ObIOFlag::set_no_preread();  // 取消预读
bool ObIOFlag::is_preread() const;
```

预读适用于：
- **SSTable 全表扫描**：按 macro block 预读
- **中间层索引遍历**：批量读取索引块
- **Clog 批量回放**：连续日志读取

预读的实现是由上层（存储引擎）发出的，IO 子系统提供**标志位机制**，不包含独立的预读模块。上层检查 `is_preread_` 后可以选择更大的 `size_` 来读取更多数据。

### 9.5 写合并（Write Coalescing）

OceanBase 的写 IO 通过 `ObStorageObjectWriteStrategy` 支持多种写策略（`ob_io_define.h:371`）：

```cpp
enum class ObStorageObjectWriteStrategy : uint8_t {
  WRITE_THROUGH = 0,         // 直写对象存储
  WRITE_BACK = 1,            // 写本地缓存
  WRITE_THROUGH_AND_TRY_WRITE_LCACHE = 2,  // 直写 + 尝试缓存
};
```

在 V2 调度器中，共享存储模式下通过 `TrafficControl` 的 7 个 `ObAtomIOClock`（ibw/obw/iobw/ips/ops/iops/tagps）控制对象存储的带宽和 IOPS。

### 9.6 设备健康检测

`ObIOFaultDetector`（`ob_io_struct.h:673`）监控设备状态：

```cpp
enum ObDeviceHealthStatus {
  DEVICE_HEALTH_NORMAL = 0,
  DEVICE_HEALTH_WARNING,  // 警告（连续读失败 > 10 次）
  DEVICE_HEALTH_ERROR     // 错误（连续读失败 > 100 次）
};
```

检测机制：
1. 记录每次 IO 失败到 `record_io_error()`
2. 周期性发送检测 IO（`send_sn_detect_task()`）
3. `MAX_DETECT_READ_WARN_TIMES = 10` → 触发警告
4. `MAX_DETECT_READ_ERROR_TIMES = 100` → 触发错误
5. 数据层根据健康状态切换备副本读取

### 9.7 IO 延迟追踪

`ObIOTracer`（`ob_io_struct.h:713`）记录每个 IO 请求的完整生命路径：

```
begin → enqueue → dequeue → submit → return → callback → end
     ↓        ↓        ↓        ↓        ↓           ↓
 prepare   queue    schedule   device   commit    callback
```

每个阶段的延迟被 `ObIOStat` 累积，可以通过 `ObIOUsage` 查询组的平均延迟：

```cpp
struct ObIOStat {
  uint64_t io_count_;                   // IO 计数
  uint64_t io_bytes_;                   // IO 字节
  uint64_t io_prepare_delay_us_;        // 准备延迟
  uint64_t io_schedule_delay_us_;       // 调度延迟
  uint64_t io_submit_delay_us_;         // 提交延迟
  uint64_t io_device_delay_us_;         // 设备延迟
  uint64_t io_total_delay_us_;          // 总延迟
};
```

**V2 调度路径的简化**：在 V2 调度器模式下，请求通过 `qsched_submit` 直接入 OS qdisc 队列，不再经过 `ObMClockQueue` 的堆排序。这使得路径更短，延迟更低，但需要 OS 支持。

---

## 10. 源码索引

| 文件 | 行数 | 内容 |
|------|------|------|
| `src/share/io/ob_io_manager.h` | 577 | ObIOManager、ObTenantIOManager、ObTrafficControl |
| `src/share/io/ob_io_manager.cpp` | 3166 | IO 管理器实现、norm_iops/bw 计算 |
| `src/share/io/ob_io_struct.h` | 827 | ObIOSender、ObIOScheduler、ObIOChannel、ObDeviceChannel、ObIOUsage |
| `src/share/io/ob_io_struct.cpp` | 4152 | 设备通道、IO 发送、回调管理 |
| `src/share/io/ob_io_define.h` | 964 | ObIOFlag、ObIORequest、ObIOResult、ObIOHandle、ObPhyQueue、ObMClockQueue、ObAtomIOClock、ObTenantIOConfig |
| `src/share/io/io_schedule/ob_io_schedule_v2.h` | 85 | ObIOManagerV2、ObTenantIOSchedulerV2 |
| `src/share/io/io_schedule/ob_io_schedule_v2.cpp` | 363 | V2 调度器实现、qdisc 操作 |
| `src/share/io/io_schedule/ob_io_mclock.h` | 100 | ObMClock、ObTenantIOClock |
| `src/share/io/io_schedule/ob_io_mclock.cpp` | 583 | mClock 计算、时钟同步 |
| `src/share/io/ob_io_calibration.h` | 160 | ObIOCalibration、ObIOAbility、ObIOBenchRunner |
| `src/share/io/ob_io_calibration.cpp` | 988 | 校准执行器、读写基准测试 |
| `deps/oblib/.../ob_io_device.h` | 562 | ObIODevice 虚基类、ObIOFd、ObIOCB、ObIOContext |

---

## 总结

OceanBase 的 IO 子系统是**一个完整的自研 IO 栈**，覆盖了从用户请求到磁盘 DMA 的全部路径：

1. **ObIOManager** 提供统一的 `read/write/aio_read/aio_write` 接口，隐藏了同步/异步、本地/对象存储的差异
2. **mClock 调度**（V1）提供三标签（R/L/P）的精细 IO 控制，支持租户级 IOPS 保证、上限限制和权重分配
3. **V2 调度器**基于 OS qdisc，更轻量，适用于共享存储场景的网络带宽控制
4. **IO 校准**自动测量磁盘能力，将不同大小 IO 归一化到标准代价
5. **双通道设计**（AsyncIOChannel + SyncIOChannel）分别处理高性能 AIO 和同步 IO
6. **9 级 IO 延迟追踪**提供从准备到回调的完整可观测性
7. **设备健康检测**自动识别慢盘，配合副本切换保持可用性

自研 IO 栈的代价是复杂度高（近万行代码），但在多租户 OLTP 场景下，mClock 提供的精细 IO 控制是内核调度器无法替代的。
