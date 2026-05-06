# 13-innodb-performance-tuning — InnoDB 性能调优参数深度解析

## 0. 概述

InnoDB 存储引擎的性能调优参数分布在 MySQL 源码的多个模块中：
**srv0srv.h** 声明全局参数变量，**buf0buf.h** 定义缓冲池结构，**log0sys.h** 定义日志系统结构，
**srv0start.cc** / **srv0srv.cc** 实现启动初始化。理解这些参数不能只看文档——必须追踪到
内核源码中的数据结构、初始化路径和运行时控制流。

### 参数分类

```
内存类   → buf_pool_size, buf_pool_instances, log_buffer_size, change_buffer_max_size
日志类   → log_file_size, log_files_in_group, flush_log_at_trx_commit
IO类     → io_capacity, io_capacity_max, flush_method, use_native_aio, read/write_io_threads
并发类   → thread_concurrency, commit_concurrency, concurrency_tickets
后台类   → purge_threads, purge_batch_size, adaptive_hash_index, change_buffering
刷脏类   → max_dirty_pages_pct, adaptive_flushing, flush_neighbors
事务类   → lock_wait_timeout, rollback_on_timeout, autoinc_lock_mode
监控类   → monitor_enable, INNODB_METRICS
```

### 参数声明概览

```c
// srv0srv.h:559-561 缓冲池大小参数
extern ulint srv_buf_pool_size;
extern const ulint srv_buf_pool_min_size;
extern const ulint srv_buf_pool_def_size;
```

### 调优方法论

1. **建立基线** — 用 `SELECT * FROM information_schema.INNODB_METRICS` 记录当前状态
2. **单变量调整** — 每次只改一个参数，避免交互效应掩盖因果关系
3. **对照验证** — 修改后压测相同负载，对比吞吐（TPS/QPS）和延迟分布（P99/P999）
4. **度量驱动** — 重点监控：脏页比例、redo 生成速率、checkpoint 年龄、IO 利用率、锁等待频率

---

## 1. 内存参数

### 1.1 innodb_buffer_pool_size — 缓冲池大小

这是 InnoDB 最重要的内存参数，决定了数据页在内存中的缓存容量。
声明在 `srv0srv.h`，初始化在 `buf_pool_init()`。

```c
// srv0srv.h:559-568 缓冲池大小相关变量
extern ulint srv_buf_pool_size;
extern const ulint srv_buf_pool_min_size;
extern const ulint srv_buf_pool_def_size;
extern const longlong srv_buf_pool_max_size;
extern ulonglong srv_buf_pool_chunk_unit;
extern const ulonglong srv_buf_pool_chunk_unit_min;
extern const ulonglong srv_buf_pool_chunk_unit_blk_sz;
extern const ulonglong srv_buf_pool_chunk_unit_max;
```

`buf_pool_t::curr_pool_size` 保存每个缓冲池实例当前的实际字节大小，初始化时分配：

```c
// buf0buf.h:2293-2310 buf_pool_t 结构体关键字段
struct buf_pool_t {
  /** Array index of this buffer pool instance */
  ulint instance_no;

  /** Current pool size in bytes */
  ulint curr_pool_size;

  /** Reserve this much of the buffer pool for "old" blocks */
  ulint LRU_old_ratio;

  /** Number of buffer pool chunks */
  volatile ulint n_chunks;

  /** buffer pool chunks */
  buf_chunk_t *chunks;

  /** Current pool size in pages */
  ulint curr_size;

  /** Previous pool size in pages */
  ulint old_size;
```

`buf_pool_init()` 将总大小除以实例数，为每个实例分配等量内存：

```c
// buf0buf.cc:1506-1525 buf_pool_init — 缓冲池初始化
dberr_t buf_pool_init(ulint total_size, ulint n_instances) {
  ulint i;
  const ulint size = total_size / n_instances;

  ut_ad(n_instances > 0);
  ut_ad(n_instances <= MAX_BUFFER_POOLS);
  ut_ad(n_instances == srv_buf_pool_instances);

  NUMA_MEMPOLICY_INTERLEAVE_IN_SCOPE;

  buf_flush_list_added = Buf_flush_list_added_lsns::create();

  buf_pool_should_madvise = innobase_should_madvise_buf_pool();

  buf_pool_resizing = false;

  buf_pool_ptr = (buf_pool_t *)ut::zalloc_withkey(
      UT_NEW_THIS_FILE_PSI_KEY, n_instances * sizeof *buf_pool_ptr);
```

`curr_pool_size` 的读取通过内联函数完成：

```c
// buf0buf.h:295-296 获取当前缓冲池大小（内联）
static inline ulint buf_pool_get_curr_size(void);
static inline ulint buf_pool_get_n_pages(void);
```

**调优要点**：
- 专用服务器建议设置为物理内存的 70%-80%
- chunk 粒度由 `srv_buf_pool_chunk_unit` 控制（默认 128MB），在线扩容时按 chunk 粒度增减
- 运行时可通过 `SET GLOBAL innodb_buffer_pool_size=N` 动态调整，触发 `buf_pool_resize()` 路径

### 1.2 innodb_buffer_pool_instances — 缓冲池实例数

对于大容量缓冲池（>1GB）将缓冲池拆分为多个实例，减少锁竞争。
每个实例拥有独立的 LRU 链表、flush 链表和 page_hash，访问时通过 `buf_pool_get()` 路由：

```c
// buf0buf.h:979-980 根据 page_id 路由到缓冲池实例
static inline buf_pool_t *buf_pool_get(const page_id_t &page_id);
```

实例号保存在 `buf_pool_t::instance_no`：

```c
// buf0buf.cc:1351 初始化实例编号
    buf_pool->instance_no = instance_no;
```

实例数组指针：

```c
// buf0buf.h:117 缓冲池实例数组
extern buf_pool_t *buf_pool_ptr;
```

实例数的声明和默认值：

```c
// srv0srv.h:577-579 缓冲池实例参数
extern ulong srv_buf_pool_instances;
extern const ulong srv_buf_pool_instances_default;
```

**调优要点**：
- 当 `buf_pool_size >= 1GB` 时默认实例数为 8；小于 1GB 时实例数为 1
- 实例数应不超过 CPU 核数，最佳实践：每个实例 1-2GB
- 过多的实例会浪费内存（每个实例包含独立的数据结构如 watch 数组、page_hash 等）

### 1.3 innodb_log_buffer_size — 日志缓冲区

redo log 写入的中间缓冲区，事务提交时先写入此缓冲区，再由 log writer 线程刷入磁盘。
`log_t::buf` 是 aligned 的缓冲数组，`log_t::buf_size_sn` 记录数据字节大小（不包含 log block header/footer）：

```c
// log0sys.h:148-156 log 缓冲区字段
  /** Aligned log buffer. Committing mini-transactions write there
  redo records, and the log_writer thread writes the log buffer to
  disk in background.
  Protected by: locking sn not to add. */
  alignas(ut::INNODB_CACHE_LINE_SIZE)
      ut::aligned_array_pointer<byte, LOG_BUFFER_ALIGNMENT> buf;

  /** Size of the log buffer expressed in number of data bytes,
  that is excluding bytes for headers and footers of log blocks. */
  atomic_sn_t buf_size_sn;

  /** Size of the log buffer expressed in number of total bytes,
  that is including bytes for headers and footers of log blocks. */
  size_t buf_size;
```

```c
// log0sys.h:164-167 写入限制的 LSN 水位
  /** Maximum sn up to which there is free space in both the log buffer
  and the log files. This is limitation for the end of any write to the
  log buffer. Threads, which are limited need to wait, and possibly they
  hold latches of dirty pages making a deadlock possible.
  Protected by: writer_mutex (writes). */
  alignas(ut::INNODB_CACHE_LINE_SIZE) atomic_sn_t buf_limit_sn;
```

参数声明：

```c
// srv0srv.h:445-449 日志缓冲区大小
/** Space for log buffer, expressed in bytes. Note, that log buffer
will use only the largest power of two, which is not greater than
the assigned space. */
extern ulong srv_log_buffer_size;
```

**调优要点**：
- 默认 16MB，对大事务（如批量 INSERT/LOAD DATA）建议增大到 64-256MB
- 实际取小于设定值的最大 2 的幂（`largest power of two`）
- 过小会导致频繁的 `buf_limit_sn` 等待，阻塞 mtr 提交

### 1.4 innodb_additional_mem_pool_size / innodb_change_buffer_max_size

**additional_mem_pool_size**：在 MySQL 5.7 之前用于数据字典的内存分配，8.0 后已废弃。
**change_buffer_max_size**：控制 change buffer 占缓冲池的最大百分比。

```c
// srv0srv.h:606-607 change buffer 大小
extern uint srv_change_buffer_max_size;
```

change buffer 是 InnoDB 用于缓存二级索引变更（INSERT/UPDATE/DELETE）的结构。当目标
索引页不在缓冲池时，将变更记录到 change buffer，等页面被读入时合并。这减少
了随机 IO，但会延缓索引页的一致性。

**调优要点**：
- change_buffer_max_size 默认 25（即缓冲池的 25%）
- 写密集型负载可增大到 50，但会减少数据页缓存空间
- 对于 SSD，可以设置较小值（5-10），减少合并时的额外读取

---

## 2. 日志参数

### 2.1 innodb_redo_log_capacity — redo log 容量（替代早期的 innodb_log_file_size）

MySQL 8.0.30 引入 `innodb_redo_log_capacity` 替代 `innodb_log_file_size + innodb_log_files_in_group`。
redo log 总容量决定 checkpoint 频率，影响写入吞吐和崩溃恢复时间。

```c
// srv0srv.h:429-436 redo log 容量参数
/** Value of innodb_redo_log_capacity. Expressed in bytes. Might be set
during startup automatically when started in "dedicated server mode". */
extern ulonglong srv_redo_log_capacity;

/** Assumed value of innodb_redo_log_capacity's - value which is used.
Expressed in bytes. Might be set during startup automatically when
started in "dedicated server mode". Might also be set during startup
when old sysvar (innodb_log_file_size or innodb_log_files_in_group)
are configured and the new sysvar (innodb_redo_log_capacity) is not. */
extern ulonglong srv_redo_log_capacity_used;
```

内核中 redo log 文件容量通过 `Log_files_capacity` 管理，`log_t::m_capacity` 保存容量信息：

```c
// log0sys.h:404-406 redo log 文件容量管理
  /** Capacity limits for the redo log. Responsible for resize.
  Mutex protection is decided per each Log_files_capacity method. */
  Log_files_capacity m_capacity;
```

`log_compute_available_for_checkpoint_lsn()` 计算可用于 checkpoint 的 lsn 值，
确定当前 checkpoint 水位：

```c
// log0chkp.cc:181-195 计算可用于 checkpoint 的 LSN
static lsn_t log_compute_available_for_checkpoint_lsn(const log_t &log) {
  ut_ad(log_checkpointer_mutex_own(log));
  /* During recovery, there may be dirty pages not added to flush lists.
  We use smallest_dirty_page_lsn for that case. */
  const lsn_t dpa_lsn = buf_flush_list_added->smallest_not_added_lsn();
  lsn_t lsn = log_buffer_dirty_pages_get_oldest_lsn(log);

  /* ... dpa_lsn after we applied it in log_checkpoint() ... */
  lsn = std::min(lsn, dpa_lsn);
  lsn = std::min(lsn, log.transaction_serializer.get_consumed_lsn());

  /* We expect in recovery that checkpoint_lsn is within data area ... */
  lsn = std::max(lsn, log.last_checkpoint_lsn.load());
```

**调优要点**：
- 建议设为工作负载 1 小时的 redo 写入量（可以监控 `Innodb_redo_log_generated_bytes`）
- 典型值 1-8GB。过小 → 频繁 checkpoint → 额外 IO → 性能抖动
- 过大 → 崩溃恢复慢，但写入性能稳定

### 2.2 innodb_log_files_in_group — redo log 文件数（旧参数）

在 `innodb_redo_log_capacity` 之前，用 `log_file_size * log_files_in_group` 计算总容量。

```c
// srv0srv.h:338 redo log 文件相关
constexpr size_t SRV_N_LOG_FILES_CLONE_MAX = 1000;
```

在 8.0.30+ 中，redo log 文件变为动态管理，由 `Log_files_dict` 维护：

```c
// log0sys.h:396-398 log 文件字典
  /** The in-memory dictionary of log files.
  Protected by: m_files_mutex. */
  Log_files_dict m_files{m_files_ctx};
```

**调优要点**：直接使用 `innodb_redo_log_capacity`，避免同时设置旧参数。

### 2.3 innodb_flush_log_at_trx_commit — fsync 策略

这是决定事务持久性与性能权衡的核心参数。三个值：

- **1**（默认）：每次事务提交都 fsync（最安全，`group commit` 优化批处理）
- **0**：每秒一次写入 + fsync（崩溃可能丢失 1 秒数据）
- **2**：每次提交写入但不 fsync，每秒 fsync（OS 崩溃可能丢数据，MySQL 崩溃不丢）

```c
// srv0srv.h:545-547 flush 策略参数
extern ulong srv_flush_log_at_trx_commit;
extern ulong srv_log_write_ahead_size;
std::chrono::seconds get_srv_flush_log_at_timeout();
```

`log_write_up_to()` 根据 `flush_to_disk` 参数和 `srv_flush_log_at_trx_commit` 的值决定行为：

```c
// log0write.cc:1055-1120 log_write_up_to — flush 策略核心实现
Wait_stats log_write_up_to(log_t &log, lsn_t end_lsn, bool flush_to_disk) {
  ut_a(!srv_read_only_mode);

  if (recv_recovery_is_on()) {
    return Wait_stats{0};
  }

  log.write_to_file_requests_total.store(
      log.write_to_file_requests_total.load(std::memory_order_relaxed) + 1,
      std::memory_order_relaxed);

  /* ... LSN 范围检查 ... */

retry:
  if (log.writer_threads_paused.load(std::memory_order_acquire)) {
    /* 如果 log writer 线程已暂停，用户线程自己写自己刷 */
    wait_stats +=
        log_self_write_up_to(log, end_lsn, flush_to_disk, &interrupted);
    if (UNIV_UNLIKELY(interrupted)) { goto retry; }
    return wait_stats;
  }

  /* log writer 线程正在工作（高并发场景） */
  if (flush_to_disk) {
    if (log.flushed_to_disk_lsn.load() >= end_lsn) {
      return wait_stats;
    }

    if (srv_flush_log_at_trx_commit != 1) {
      /* flush_to_disk 为 true 但 srv_flush_log_at_trx_commit != 1，
      说明需要立刻 flush 但通知机制被禁用（trx_commit=0/2时不通知flusher）。
      必须手动确保 write_lsn >= end_lsn 后唤醒 flusher */
      if (log.write_lsn.load() < end_lsn) {
        wait_stats += log_wait_for_write(log, end_lsn, &interrupted);
      }
    }

    /* 等待 flush 到磁盘 */
    wait_stats += log_wait_for_flush(log, end_lsn, &interrupted);
    if (UNIV_UNLIKELY(interrupted)) { goto retry; }
  } else {
    /* flush_to_disk == false — 只等写入不刷盘（trx_commit=0/2 场景） */
    if (log.write_lsn.load() >= end_lsn) {
      return wait_stats;
    }
    wait_stats += log_wait_for_write(log, end_lsn, &interrupted);
    if (UNIV_UNLIKELY(interrupted)) { goto retry; }
  }

  return wait_stats;
}
```

`log.flushed_to_disk_lsn` 是持久化到磁盘的最高 LSN：

```c
// log0sys.h:224 已刷盘的最高 LSN
  /** Up to this lsn data has been flushed to disk (fsynced). */
  alignas(ut::INNODB_CACHE_LINE_SIZE) atomic_lsn_t flushed_to_disk_lsn;
```

**调优要点**：
- 对于金融/交易系统：trx_commit=1（严格 ACID，每次提交 fsync）
- 日志/评论/非关键写入：trx_commit=2（崩溃安全，性能更好）
- 性能压测 / 批量导入：trx_commit=0（最快，但可能丢 1 秒数据）
- `双 1 设置` 通常指 innodb_flush_log_at_trx_commit=1 + sync_binlog=1

### 2.4 innodb_flush_log_at_timeout — 定时刷盘间隔

当 `innodb_flush_log_at_trx_commit` 为 0 或 2 时，决定后台多长时间刷一次盘。

```c
// srv0srv.h:644 定时刷盘间隔（秒）
extern uint srv_flush_log_at_timeout;
// srv0srv.h:547
std::chrono::seconds get_srv_flush_log_at_timeout();
```

**调优要点**：
- 默认 1 秒，适用于大多数场景
- 增大到 2-3 秒可减少 fsync 频率，但增加数据丢失窗口

---

## 3. IO 参数

### 3.1 innodb_io_capacity — IO 吞吐上限

这是 page cleaner 线程计算刷脏速率的基础参数，代表 InnoDB 预期磁盘 IO 系统
每秒能处理的 IO 操作数（IOPS）。

```c
// srv0srv.h:614-616 IO 容量参数
extern ulong srv_io_capacity;
extern ulong srv_max_io_capacity;
```

```c
// srv0srv.h:622-625 IO 百分比计算内联函数
static inline ulong PCT_IO(ulong p) {
  return (ulong)(srv_io_capacity * ((double)(p) / 100.0));
}
```

`buf_flush_page_coordinator_thread()` 是负责协调刷脏的后台线程。
它根据脏页比例和 LSN 年龄计算目标刷脏量，IO 容量直接影响单次刷脏的页数：

```c
// buf0flu.cc:2235-2331 set_flush_target_by_lsn 中的 IO 容量应用
  ut_ad(srv_max_io_capacity >= srv_io_capacity);

  return (static_cast<ulint>(((srv_max_io_capacity / srv_io_capacity) *
                              (lsn_age_factor * sqrt(lsn_age_factor))) /
                             7.5));
```

```c
// buf0flu.cc:2276-2282 最大 IO 上限
  /* Cap the maximum IO capacity that we are going to use by
  max_io_capacity. Limit the value to avoid too quick increase */
  const ulint sum_pages_max = srv_max_io_capacity * 2;
```

```c
// buf0flu.cc:2325-2331 最小/最大刷脏页数
    if (n_pages < srv_io_capacity) {
      n_pages = srv_io_capacity;
    }
    if (n_pages > srv_max_io_capacity) {
      n_pages = srv_max_io_capacity;
    }
```

**调优要点**：
- HDD：200-400；SATA SSD：1000-2000；NVMe SSD：5000-10000+
- 设置为磁盘真实能承受的 IOPS 的 80%，避免刷脏击穿 IO 子系统
- `innodb_io_capacity_max` 应设为 `innodb_io_capacity` 的 2-3 倍

### 3.2 innodb_io_capacity_max — IO 峰值上限

当系统处于压力下或脏页超过阈值时，InnoDB 可以使用超过 `innodb_io_capacity` 的刷脏量，
但不能超过此值。

```c
// srv0srv.h:618-620 IO 峰值上限
extern ulong srv_max_io_capacity;
```

```c
// buf0flu.cc:2427-2429 最大容量限制
  if (n_pages > srv_max_io_capacity) {
    n_pages = srv_max_io_capacity;
  }
```

**调优要点**：
- 建议设为 `innodb_io_capacity` 的 2-3 倍
- 对于高 IOPS 的 NVMe SSD，可设置更高（20000+）

### 3.3 innodb_flush_method — fsync / O_DIRECT / O_DSYNC

控制 InnoDB 如何打开数据文件和 redo log 文件。不同模式影响内核 page cache 使用方式。

```c
// srv0srv.h:648 srv_use_fdatasync — 是否使用 fdatasync
extern bool srv_use_fdatasync;
```

flush method 在 `fil_io()` 中影响文件打开标志：

```c
// fil0fil.cc:7987-7996 flush 方法与 fsync 策略
    /* If we are here and the flush mode is O_DIRECT_NO_FSYNC, then
    ... 跳过 fsync (O_DIRECT 已经保证数据到达存储) */
```

各模式的 OS 打开标志分析：

- **fsync**（默认）：`open()` 无特殊标志，写入后 `fsync()` 刷盘。double buffer
- **O_DIRECT**：`open()` 带 `O_DIRECT`。绕过 OS page cache，减少 double buffering
  和 `fsync()` 开销。适合 xfs/ext4 文件系统
- **O_DSYNC**：`open()` 带 `O_DSYNC`。每次写入保证元数据同步，等效于每次 write + fsync
- **O_DIRECT_NO_FSYNC**：O_DIRECT + 跳过 `fsync()`（信任存储已持久化），性能最高

```c
// fil0fil.cc:10950 打开文件时的 O_DIRECT 标志
  /* Open the file with O_DIRECT flag for faster access */
```

**调优要点**：
- Linux + XFS/ext4 强烈推荐 `O_DIRECT`
- 避免 `O_DSYNC` — 性能差（每次写入都 fsync），且与 group commit 冲突
- 存储有电池备份缓存（BBU）时可考虑 `O_DIRECT_NO_FSYNC`

### 3.4 innodb_use_native_aio — 异步 IO

使用操作系统原生的异步 IO 接口（Linux 的 `io_submit` / `io_getevents`），
而非 InnoDB 模拟的 AIO 线程池。

```c
// srv0srv.h:390-391 原生 AIO 开关
/* Whether to use native aio of the OS (supported on Windows and Linux) */
extern bool srv_use_native_aio;
```

`os_aio_init()` 根据参数初始化 AIO 系统：

```c
// os0file.cc:6278-6290 os_aio_init — AIO 初始化
bool os_aio_init(ulint n_readers, ulint n_writers) {
  /* Maximum number of pending aio operations allowed per segment */
  ulint limit = 8 * OS_AIO_N_PENDING_IOS_PER_THREAD;

#ifdef _WIN32
  if (srv_use_native_aio) {
    limit = SRV_N_PENDING_IOS_PER_THREAD;
  }
#endif /* _WIN32 */
  return (AIO::start(limit, n_readers, n_writers));
}
```

在 `srv_start()` 中调用 `os_aio_init()` 初始化 IO 线程：

```c
// srv0start.cc:1468-1473 AIO 初始化
  if (!os_aio_init(srv_n_read_io_threads, srv_n_write_io_threads)) {
    ib::error(ER_IB_MSG_1129);
    return (srv_init_abort(DB_ERROR));
  }
```

**调优要点**：
- Linux 下默认启用（`libaio`），效果显著
- 若 `libaio` 不可用或存储不支持，退化为模拟 AIO
- 虚拟化环境（某些云主机）可能不支持原生 AIO，需禁用

### 3.5 innodb_read_io_threads / innodb_write_io_threads — IO 线程数

控制用于处理读/写异步 IO 请求的后台线程数。

```c
// srv0srv.h:603-604 IO 线程参数
extern ulong srv_n_read_io_threads;
extern ulong srv_n_write_io_threads;
```

```c
// srv0srv.cc:457-458 IO 线程定义
ulong srv_n_read_io_threads;
ulong srv_n_write_io_threads;
```

这些线程在 `os_aio_init()` 中创建，每个线程对应一个 IO 完成端口（completion port
或 io_getevents 循环）。

**调优要点**：
- 默认各 4，繁忙系统可设 8-16
- 非 NVMe 的单一磁盘路径，增加线程数不会提升吞吐
- 每个线程有独立的 IO 完成队列，适合多路存储路径

---

## 4. 并发参数

### 4.1 innodb_thread_concurrency — 最大并发线程

限制同时进入 InnoDB 内核的线程数，防止太多线程同时在内核内竞争资源导致
"concurrency thrashing"（并发颠簸）。

```c
// srv0conc.h:56-59 并发控制参数
/** The following controls how many threads we let inside InnoDB concurrently:
threads waiting for locks are not counted into the number because otherwise
we could get a deadlock. Value of 0 will disable the concurrency check. */
extern ulong srv_thread_concurrency;
```

```c
// srv0conc.cc:71 默认值 0（无限并发）
ulong srv_thread_concurrency = 0;
```

`srv_conc_t` 结构体跟踪活动线程和等待线程：

```c
// srv0conc.cc:74-86 并发控制状态结构
struct srv_conc_t {
  char pad[ut::INNODB_CACHE_LINE_SIZE];

  /** Number of transactions that have declared_to_be_inside_innodb set. */
  std::atomic<int32_t> n_active;

  /** Number of OS threads waiting in the FIFO for permission to
  enter InnoDB */
  std::atomic<int32_t> n_waiting;
};

static srv_conc_t srv_conc;
```

`srv_conc_enter_innodb_with_atomics()` 是核心的并发准入控制函数：

```c
// srv0conc.cc:112-215 srv_conc_enter_innodb_with_atomics 核心实现
static dberr_t srv_conc_enter_innodb_with_atomics(trx_t *trx) {
  ulint n_sleeps = 0;
  bool notified_mysql = false;

  ut_a(!trx->declared_to_be_inside_innodb);

  for (;;) {
    ulint sleep_in_us;

    if (srv_thread_concurrency == 0) {
      /* 无限并发：直接允许进入 */
      if (notified_mysql) {
        srv_conc.n_waiting.fetch_sub(1, std::memory_order_relaxed);
        thd_wait_end(trx->mysql_thd);
      }
      return DB_SUCCESS;
    }

    if (srv_conc.n_active.load(std::memory_order_relaxed) <
        (int32_t)srv_thread_concurrency) {
      const auto n_active =
          srv_conc.n_active.fetch_add(1, std::memory_order_acquire) + 1;

      if (n_active <= (int32_t)srv_thread_concurrency) {
        srv_enter_innodb_with_tickets(trx);

        if (notified_mysql) {
          srv_conc.n_waiting.fetch_sub(1, std::memory_order_relaxed);
          thd_wait_end(trx->mysql_thd);
        }

        /* 自适应睡眠调优 */
        if (srv_adaptive_max_sleep_delay > 0) {
          if (srv_thread_sleep_delay > 20 && n_sleeps == 1) {
            --srv_thread_sleep_delay;
          }
          if (srv_conc.n_waiting.load(std::memory_order_relaxed) == 0) {
            srv_thread_sleep_delay >>= 1;
          }
        }
        return DB_SUCCESS;
      }

      /* 超订：释放票据 */
      srv_conc.n_active.fetch_sub(1, std::memory_order_release);
    }

    /* 等待进入 InnoDB：加入 FIFO 队列 */
    if (!notified_mysql) {
      srv_conc.n_waiting.fetch_add(1, std::memory_order_relaxed);
      thd_wait_begin(trx->mysql_thd, THD_WAIT_USER_LOCK);
      notified_mysql = true;
    }

    trx->op_info = "sleeping before entering InnoDB";

    sleep_in_us = srv_thread_sleep_delay;

    if (srv_adaptive_max_sleep_delay > 0 &&
        sleep_in_us > srv_adaptive_max_sleep_delay) {
      sleep_in_us = srv_adaptive_max_sleep_delay;
      srv_thread_sleep_delay = static_cast<ulong>(sleep_in_us);
    }

    std::this_thread::sleep_for(std::chrono::microseconds(sleep_in_us));

    trx->op_info = "";

    ++n_sleeps;

    if (srv_adaptive_max_sleep_delay > 0 && n_sleeps > 1) {
      ++srv_thread_sleep_delay;
    }

    if (trx_is_interrupted(trx)) {
      if (notified_mysql) {
        srv_conc.n_waiting.fetch_sub(1, std::memory_order_relaxed);
        thd_wait_end(trx->mysql_thd);
      }
      return DB_INTERRUPTED;
    }
  }
}
```

睡眠参数控制 sleep 行为：

```c
// srv0conc.cc:60-65 睡眠和票据参数默认值
ulong srv_n_free_tickets_to_enter = 500;
ulong srv_adaptive_max_sleep_delay = 150000;
ulong srv_thread_sleep_delay = 10000;
```

```c
// srv0srv.h:709-712 自旋等待和票据参数
extern ulong srv_n_spin_wait_rounds;
extern ulong srv_n_free_tickets_to_enter;
extern ulong srv_spin_wait_delay;
extern bool srv_priority_boost;
```

进入时获得 `n_tickets_to_enter_innodb` 个"免检票"，用完需重新排队：

```c
// srv0conc.cc:92-99 发放免检票
static void srv_enter_innodb_with_tickets(trx_t *trx) {
  trx->declared_to_be_inside_innodb = true;
  trx->n_tickets_to_enter_innodb = srv_n_free_tickets_to_enter;
}
```

**调优要点**：
- 0（默认）= 不限并发，通常是最佳值（OS 调度已经足够好）
- 设置为 `2*CPU核数` 可防止过多线程导致的内核热锁竞争
- 设置过大（如 1000+）等于没限，太小则浪费 CPU

### 4.2 innodb_commit_concurrency — 提交并发数

控制允许并发提交的事务数，0 表示不限。

### 4.3 innodb_concurrency_tickets — 免检票数

线程在被重新排队前可进入 InnoDB 内核的次数，对应 `srv_n_free_tickets_to_enter`。

**调优要点**：
- 默认 500，大事务场景可增加
- 过小的值导致频繁的进出排队，增加上下文切换

---

## 5. 后台参数

### 5.1 innodb_purge_threads — purge 线程数

Purge 用于清理已提交事务的 undo 日志，释放历史记录。多个 purge 线程可以并行处理。

```c
// srv0srv.h:747 清理线程参数
/* the number of purge threads to use from the worker pool (currently 0 or 1) */
extern ulong srv_n_purge_threads;
```

```c
// srv0srv.cc:500 默认值
ulong srv_n_purge_threads = 4;
```

创建 purge worker 线程：

```c
// srv0srv.cc:1115-1122 purge 线程创建
  srv_threads.m_purge_workers_n = srv_n_purge_threads;
  // ...
    n_sys_threads = srv_n_purge_threads + 1;
```

实际 purge 调用：

```c
// srv0srv.cc:2904 purge 批量处理
        trx_purge(n_use_threads, srv_purge_batch_size, do_truncate);
```

**调优要点**：
- 默认 4（MySQL 8.0），旧版本默认 1
- DDL-heavy 或高并发 UPDATE/DELETE 负载建议 4-8
- undo 表空间 truncate 需要至少 2 个 purge 线程

### 5.2 innodb_purge_batch_size — purge 批量大小

每次 purge 操作处理多少 undo 日志页。

```c
// srv0srv.h:750 purge 批量大小
/* the number of pages to purge in one batch */
extern ulong srv_purge_batch_size;
```

```c
// srv0srv.cc:503 默认值
ulong srv_purge_batch_size = 20;
```

**调优要点**：
- 写密集型负载可增大（如 300-500），减少 purge 调度频率
- 过大会导致单次 purge CPU 耗时过长，影响前台查询

### 5.3 innodb_adaptive_hash_index — AHI 开关

自适应哈希索引（Adaptive Hash Index, AHI）通过缓存热索引页的哈希表加速等值查询。

```c
// srv0srv.h:642 AHI 启用开关
extern bool srv_btr_search_enabled;
```

AHI 在 `buf_pool_init()` 中初始化：

```c
// buf0buf.cc:1598 AHI 初始化
  btr_search_sys_create(buf_pool_get_curr_size() / sizeof(void *) / 64);
```

动态 resize：

```c
// buf0buf.cc:2633 AHI resize
    btr_search_sys_resize(buf_pool_get_curr_size() / sizeof(void *) / 64);
```

**调优要点**：
- 默认 ON。对等值查询大量、工作集小、访问模式固定的负载效果显著
- 若负载以范围扫描/排序为主，建议关闭（减少维护开销和锁竞争）
- 写密集型负载也建议关闭（AHI 维护影响写入性能）

### 5.4 innodb_change_buffering — change buffer 配置

控制 change buffer 的缓存范围：`inserts` / `deletes` / `purges` / `all` / `none`。

```c
// srv0srv.h:606
extern uint srv_change_buffer_max_size;
```

**调优要点**：
- 默认 `all`，典型场景保留默认
- 读密集型且二级索引多的负载：保留 `all`
- 工作集完全在内存时：设置 `none` 避免不必要的合并读取

### 5.5 innodb_old_blocks_time — LRU old 区域停留时间

InnoDB LRU 链表分为 young 和 old 两个区域。新读入的页首先放入 old 区，
只有在此区域停留超过 `innodb_old_blocks_time` 毫秒后才移入 young 区，
防止大表扫描"污染"热缓存。

```c
// srv0srv.h:643 old 区域停留时间（ms）
extern uint buf_LRU_old_threshold;
```

### 5.6 innodb_old_blocks_pct — LRU old 区域比例

```c
// buf0buf.h:2323-2324 LRU old 比例
  /** Reserve this much of the buffer pool for "old" blocks */
  ulint LRU_old_ratio;
```

**调优要点**：
- 默认值 37（即 37% 留给 old 区域）
- 表扫描频繁的负载可以增大到 50-60
- 点查询为主的负载可以减小到 20-30

---

## 6. Compaction / 刷脏参数（MySQL 类比 OB 的参数）

### 6.1 innodb_max_dirty_pages_pct — 脏页上限

当缓冲池中脏页百分比超过此值时，page cleaner 线程会加速刷脏。

```c
// srv0srv.h:660-661 脏页百分比控制
extern double srv_max_dirty_pages_pct;
extern double srv_max_dirty_pages_pct_lwm;
```

```c
// buf0flu.cc:2193 高水位脏页判断
  if (srv_max_dirty_pages_pct_lwm == 0) {
    if (dirty_pct >= srv_max_buf_pool_modified_pct) {
      return (100);  // 全速刷脏
    }
  } else if (dirty_pct >= srv_max_dirty_pages_pct_lwm) {
    return (static_cast<ulint>((dirty_pct * 100) /
                               (srv_max_buf_pool_modified_pct + 1)));
  }
```

`srv_max_dirty_pages_pct` 默认值 75.0，`srv_max_buf_pool_modified_pct` 也使用此值。

**调优要点**：
- 高并发写入场景且 IO 充足：可保持 75-90
- IO 受限或需要严格延迟控制：降低到 50-60
- 太低（<30）会导致频繁刷脏，浪费 IO

### 6.2 innodb_max_dirty_pages_pct_lwm — 脏页低水位

当脏页超过此值时启动提前预刷，避免冲到上限才加速导致的毛刺。

```c
// srv0srv.h:661-663 脏页低水位
extern double srv_max_dirty_pages_pct_lwm;
extern ulong srv_adaptive_flushing_lwm;
```

**调优要点**：
- 默认 0（禁用预刷）。设 10-20 可平滑刷脏曲线
- 对延迟敏感的负载建议设置

### 6.3 innodb_adaptive_flushing — 自适应刷脏

根据 redo log 生成速率（LSN 年龄）而非仅脏页百分比来自适应调整刷脏速度。

```c
// srv0srv.h:548 自适应刷脏开关
extern bool srv_adaptive_flushing;
```

`get_pct_for_lsn()` 计算基于 LSN 年龄的刷脏百分比：

```c
// buf0flu.cc:2214-2241 基于 LSN 年龄计算刷脏百分比
ulint get_pct_for_lsn(lsn_t age) {
  /* ... */
  lsn_t af_lwm = (srv_adaptive_flushing_lwm * limit_for_free_check) / 100;

  if (age < af_lwm) {
    return (0);  // 不需要自适应刷脏
  }

  if (age < limit_for_dirty_page_age && !srv_adaptive_flushing) {
    return (0);  // 用户禁用自适应刷脏且未到异步上限
  }

  lsn_age_factor = (age * 100.0) / limit_for_dirty_page_age;

  return (static_cast<ulint>(((srv_max_io_capacity / srv_io_capacity) *
                              (lsn_age_factor * sqrt(lsn_age_factor))) /
                             7.5));
}
```

`set_flush_target_by_lsn()` 综合脏页百分比和 LSN 年龄计算最终刷脏目标：

```c
// buf0flu.cc:2256-2265 联合计算刷脏目标
ulint set_flush_target_by_lsn(bool sync_flush, lsn_t sync_flush_limit_lsn) {
  lsn_t oldest_lsn = buf_pool_get_oldest_modification_approx();
  lsn_t age = cur_iter_lsn > oldest_lsn ? cur_iter_lsn - oldest_lsn : 0;

  ulint pct_for_dirty = get_pct_for_dirty();
  ulint pct_for_lsn = get_pct_for_lsn(age);
  ulint pct_total = std::max(pct_for_dirty, pct_for_lsn);
```

```c
// buf0flu.cc:2316-2331 最终刷脏页数决策
  /* 综合 LSN 和脏页的估计 */
  ulint n_pages;
  if (sync_flush) {
    n_pages = pages_for_lsn;
    if (n_pages < srv_io_capacity) {
      n_pages = srv_io_capacity;
    }
  } else {
    n_pages = (PCT_IO(pct_total) + page_avg_rate + pages_for_lsn) / 3;
    if (n_pages > srv_max_io_capacity) {
      n_pages = srv_max_io_capacity;
    }
  }
```

**调优要点**：
- 默认 ON，强烈建议保持
- `innodb_adaptive_flushing_lwm`（默认 10）表示 LSN 年龄低于此百分比时不触发自适应

### 6.4 innodb_flush_neighbors — 相邻页刷脏

刷脏时是否将目标页所在的 extent 中相邻的脏页一并刷出。HDD 时代（减少磁头寻道）非常有效，
但对 SSD 反而增加不必要的 IO。

```c
// srv0srv.h:589 相邻页刷脏
extern ulong srv_flush_neighbors;
```

```c
// buf0flu.cc:1231-1249 相邻页刷脏控制
      srv_flush_neighbors == 0) {
    // 不刷相邻页
  }
    if (srv_flush_neighbors == 1) {
      // 刷相同 extent 的相邻页
    }
```

**调优要点**：
- HDD：1（默认）或 2（刷同一 extent 中所有相邻页）
- SSD / NVMe：0（相邻页刷脏增加写放大，无收益）

---

## 7. 事务参数

### 7.1 innodb_lock_wait_timeout — 锁等待超时

事务等待行锁的最长时间。超时后 InnoDB 会回滚当前语句（非整个事务，除非设置
`innodb_rollback_on_timeout`）。

```c
// srv0srv.h:599 锁表大小
extern ulint srv_lock_table_size;
```

超时检测在后台的 `lock_wait_timeout_thread()` 中调用 `lock_wait_check_slots_for_timeouts()`：

```c
// lock0wait.cc:1432-1448 lock_wait_timeout_thread 线程
void lock_wait_timeout_thread() {
  // ...
  for (;;) {
    // 定期检查等待槽的超时
    lock_wait_check_slots_for_timeouts();
  }
}
```

具体的超时检测逻辑：

```c
// lock0wait.cc:541-557 超时槽扫描
static void lock_wait_check_slots_for_timeouts() {
  ut_ad(!lock_wait_mutex_own());
  lock_wait_mutex_enter();

  for (auto slot = lock_sys->waiting_threads; slot < lock_sys->last_slot;
       ++slot) {
    if (slot->in_use) {
      lock_wait_check_and_cancel(slot);
    }
  }

  lock_wait_mutex_exit();
}
```

```c
// lock0wait.cc:219-248 锁等待超时的获取和使用
  /* innodb_lock_wait_timeout 的值 */
  const auto lock_wait_timeout = trx_lock_wait_timeout_get(trx);
  // ...
  slot = lock_wait_table_reserve_slot(thr, lock_wait_timeout);
```

**调优要点**：
- 默认 50 秒，OLTP 建议 5-10 秒（快速失败释放锁资源）
- 长事务场景可适当增大
- 设置太短可能导致"误杀"正常等待

### 7.2 innodb_rollback_on_timeout — 超时回滚

默认 OFF：超时仅回滚当前语句。ON 则回滚整个事务。

**调优要点**：
- 绝大多数场景保持 OFF（默认行为）
- 使用 `explicit lock` 时考虑 ON，确保事务一致性

### 7.3 innodb_autoinc_lock_mode — 自增锁模式

控制 AUTO_INCREMENT 的锁粒度：
- 0（traditional）：每次 INSERT 都持有表级别的 AUTO-INC 锁
- 1（consecutive，默认）：预分配连续值，批量 INSERT 使用表锁，简单 INSERT 使用轻量级 mutex
- 2（interleaved）：所有 INSERT 均使用轻量级 mutex，值可能不连续但最高并发

```c
// row0mysql.h:804 自增锁标志
  bool no_autoinc_locking;
```

```c
// dict0mem.h:2347 自增锁字段
  lock_t *autoinc_lock;
```

```c
// dict0dict.h:195 自增锁函数
void dict_table_autoinc_lock(dict_table_t *table);
```

**调优要点**：
- MySQL 8.0 默认 2（interleaved），适合高并发 INSERT
- binlog 为 `statement` 格式时必须用 1
- 0 的性能最差，不推荐

---

## 8. 监控参数

### 8.1 innodb_monitor_enable — 监控计数器

InnoDB 内置了丰富的监控计数器，按模块组织。通过 `information_schema.INNODB_METRICS` 查询。

计数器定义在 `srv0mon.h` 的枚举中：

```c
// srv0mon.h:93-165 监控计数器和模块枚举
enum monitor_enum_t {
  MONITOR_NONE = 0,            /*!< No monitoring */
  MONITOR_MODULE = 1,          /*!< This is a monitor module type */
  MONITOR_EXISTING = 2,        /*!< The monitor carries information from
                               existing counter */
  MONITOR_NO_AVERAGE = 4,      /*!< Set this status if we don't want to
                               display calculated per second averages */
  MONITOR_DISPLAY_CURRENT = 8, /*!< Display current value of the
                               counter instead of per second average */
  MONITOR_GROUP_MODULE = 16,   /*!< Monitor can be turned on/off
                               as a module */
  MONITOR_DEFAULT_ON = 32,     /*!< Monitor will be turned on by default at
                               server startup */
  MONITOR_SET_OWNER = 64,      /*!< Owner of "monitor set" */
  MONITOR_SET_MEMBER = 128,    /*!< Being part of a "monitor set" */
  MONITOR_HIDDEN = 256,        /*!< Do not display this monitor in the
                               SHOW output */
  // ...
  MONITOR_MODULE_METADATA,
  MONITOR_TABLE_OPEN,
  MONITOR_TABLE_CLOSE,
  MONITOR_TABLE_REFERENCE,
  // ...
  MONITOR_MODULE_LOCK,
  MONITOR_DEADLOCK,
  MONITOR_DEADLOCK_FALSE_POSITIVES,
  MONITOR_DEADLOCK_ROUNDS,
  MONITOR_LOCK_THREADS_WAITING,
  MONITOR_TIMEOUT,
  MONITOR_LOCKREC_WAIT,
  MONITOR_TABLELOCK_WAIT,
  // ...
};
```

```c
// srv0mon.h:47-51 监控状态枚举
enum monitor_state_t {
  MONITOR_STARTED = 1,   /*!< Monitor has been turned on */
  MONITOR_STOPPED = 2    /*!< Monitor has been turned off */
};
```

### 8.2 information_schema.INNODB_METRICS

关键指标包括：
- `dml_reads` / `dml_inserts` / `dml_deletes` — DML 操作计数
- `lock_deadlocks` — 死锁次数
- `lock_row_lock_current_waits` — 当前行锁等待数
- `buffer_pool_read_requests` / `buffer_pool_reads` — 缓存命中率计算
- `log_lsn_checked` / `log_lsn_current` — redo 生成速率

```c
// srv0srv.h:1172-1178 锁等待监控统计
  ulint innodb_row_lock_waits;         /*!< srv_n_lock_wait_count */
  ulint innodb_row_lock_current_waits; /*!< srv_n_lock_wait_current_count */
  int64_t innodb_row_lock_time;        /*!< srv_n_lock_wait_time */
  ulint innodb_row_lock_time_avg;      /*!< srv_n_lock_wait_time
                                       / srv_n_lock_wait_count */
```

**调优要点**：
- 开启 `innodb_monitor_enable=all` 仅在调试时使用，生产环境根据需要开启特定计数器
- 常用的计数器组：`metadata`, `lock`, `buffer`, `log`, `dml`

---

## 9. 常用配置组合

### 9.1 OLTP 高并发

```
innodb_buffer_pool_size = 物理内存的 70-80%
innodb_buffer_pool_instances = 8 (缓冲池 > 8GB 时)
innodb_flush_log_at_trx_commit = 1
innodb_flush_method = O_DIRECT
innodb_io_capacity = 根据存储介质 (SSD: 2000+)
innodb_max_dirty_pages_pct = 75
innodb_adaptive_flushing = ON
innodb_flush_neighbors = 0
innodb_thread_concurrency = 0 (或 2*CPU)
innodb_autoinc_lock_mode = 2
innodb_change_buffering = all
innodb_log_buffer_size = 32M-64M
innodb_redo_log_capacity = 2G-4G
```

### 9.2 OLAP 大查询

```
innodb_buffer_pool_size = 物理内存的 60-70%
innodb_buffer_pool_instances = 4-8
innodb_flush_log_at_trx_commit = 2 (允许少量丢失)
innodb_flush_method = O_DIRECT
innodb_io_capacity = HDD 适当值 (200-400)
innodb_old_blocks_time = 1000 (1秒，防止扫描污染缓存)
innodb_old_blocks_pct = 50-60
innodb_adaptive_hash_index = OFF
innodb_change_buffering = none
innodb_sort_buffer_size = 4M-8M
```

### 9.3 读写分离从库

```
innodb_buffer_pool_size = 物理内存的 60-70% (主库更低，缓存热数据即可)
innodb_flush_log_at_trx_commit = 2 (从库可接受较少持久化)
innodb_flush_method = O_DIRECT
innodb_io_capacity = 可设置较高 (从库主要负责读取)
innodb_adaptive_hash_index = ON (从库读密集，AHI 收益大)
innodb_read_io_threads = 8-12 (从库需要更多读线程)
innodb_change_buffering = none (从库无写入)
```

---

## 10. 关键函数索引

以下是本文引用的 40+ 个内核函数及对应源码位置：

### 缓冲池
| 函数 | 文件 | 行号 | 说明 |
|------|------|------|------|
| `buf_pool_init()` | `buf0buf.cc` | 1506 | 缓冲池初始化 |
| `buf_pool_get()` | `buf0buf.h` | 979 | 按 page_id 路由到实例 |
| `buf_pool_from_array()` | `buf0buf.h` | 983 | 按索引获取实例 |
| `buf_pool_get_curr_size()` | `buf0buf.h` | 295 | 获取当前缓冲池字节数 |
| `buf_pool_get_n_pages()` | `buf0buf.h` | 298 | 获取缓冲池页数 |
| `buf_pool_get_oldest_modification_approx()` | `buf0buf.cc` | 435 | 获取最旧的脏页 LSN |
| `buf_pool_get_oldest_modification_lwm()` | `buf0buf.cc` | 488 | 获取脏页 LWM |

### 日志系统
| 函数 | 文件 | 行号 | 说明 |
|------|------|------|------|
| `log_write_up_to()` | `log0write.cc` | 1055 | 写入/刷盘核心函数 |
| `log_wait_for_write()` | `log0write.cc` | 调用于 line ~1120 | 等待写入完成 |
| `log_wait_for_flush()` | `log0write.cc` | 调用于 line ~1200 | 等待刷盘完成 |
| `log_compute_available_for_checkpoint_lsn()` | `log0chkp.cc` | 181 | 计算可 checkpoint 的 LSN |
| `log_update_available_for_checkpoint_lsn()` | `log0chkp.cc` | 270 | 更新 checkpoint LSN |
| `log_checkpoint()` | `log0chkp.cc` | 132 | 执行 checkpoint |
| `log_determine_checkpoint_lsn()` | `log0chkp.cc` | 316 | 确定 checkpoint LSN |
| `log_files_next_checkpoint()` | `log0chkp.cc` | 337 | 切换到下个日志文件进行 checkpoint |
| `log_get_lsn()` | `log0sys.h` | 通过 `log_sys` 获取 | 获取当前 LSN |
| `log_self_write_up_to()` | `log0write.cc` | 调用于 ~1058 | 用户线程自己写日志 |
| `log_wait_for_flush_notifier()` | `log0write.cc` | 调用于 ~1000 | 等待 flush 通知 |

### 并发控制
| 函数 | 文件 | 行号 | 说明 |
|------|------|------|------|
| `srv_conc_enter_innodb()` | `srv0conc.cc` | 218 | 并发准入入口 |
| `srv_conc_enter_innodb_with_atomics()` | `srv0conc.cc` | 112 | 原子操作实现的准入 |
| `srv_conc_force_enter_innodb()` | `srv0conc.cc` | 237 | 强制进入（用于锁等待恢复） |
| `srv_conc_force_exit_innodb()` | `srv0conc.cc` | 248 | 强制退出 |
| `srv_conc_get_waiting_threads()` | `srv0conc.h` | 80 | 获取等待线程数 |
| `srv_conc_get_active_threads()` | `srv0conc.h` | 83 | 获取活跃线程数 |
| `srv_enter_innodb_with_tickets()` | `srv0conc.cc` | 92 | 发放免检票 |

### 刷脏和页面清理
| 函数 | 文件 | 行号 | 说明 |
|------|------|------|------|
| `buf_flush_page_coordinator_thread()` | `buf0flu.cc` | 2875 | page cleaner 协调线程 |
| `buf_flush_page_cleaner_thread()` | `buf0flu.cc` | 调用于 ~2910 | page cleaner worker 线程 |
| `set_flush_target_by_lsn()` | `buf0flu.cc` | 2256 | 基于 LSN 计算刷脏目标 |
| `get_pct_for_dirty()` | `buf0flu.cc` | 2182 | 脏页百分比 -> 刷脏速率 |
| `get_pct_for_lsn()` | `buf0flu.cc` | 2216 | LSN 年龄 -> 刷脏速率 |
| `PCT_IO()` | `srv0srv.h` | 623 | IO 容量百分比计算 |

### 锁等待
| 函数 | 文件 | 行号 | 说明 |
|------|------|------|------|
| `lock_wait_check_slots_for_timeouts()` | `lock0wait.cc` | 541 | 超时槽扫描 |
| `lock_wait_check_and_cancel()` | `lock0wait.cc` | 调用于 ~555 | 检查和取消超时 |
| `lock_wait_timeout_thread()` | `lock0wait.cc` | 1432 | 超时检测后台线程 |
| `lock_wait_table_reserve_slot()` | `lock0wait.cc` | 138 | 预留等待槽 |
| `lock_wait_snapshot_waiting_threads()` | `lock0wait.cc` | 601 | 快照等待线程信息 |

### 初始化与系统
| 函数 | 文件 | 行号 | 说明 |
|------|------|------|------|
| `srv_boot()` | `srv0srv.cc` | 1270 | 引擎启动入口 |
| `srv_start()` | `srv0start.cc` | 1330 | 完整引擎启动 |
| `os_aio_init()` | `os0file.cc` | 6278 | AIO 子系统初始化 |
| `buf_pool_create()` | `buf0buf.cc` | 1251 | 创建单个缓冲池实例 |

### IO 与文件系统
| 函数 | 文件 | 行号 | 说明 |
|------|------|------|------|
| `fil_io()` | `fil0fil.cc` | 7898 | 文件 IO 统一入口 |
| `os_aio_start_threads()` | `os0file.cc` | 6307 | 启动 AIO 线程 |
| `os_aio_wake_all_threads_at_shutdown()` | `os0file.cc` | 6338 | 关闭时唤醒 IO 线程 |
| `AIO::start()` | `os0file.cc` | 调用于 ~6288 | AIO 子系统启动 |
| `fil_scan_for_tablespaces()` | `fil0fil.cc` | 调用于 srv_start | 扫描 tablespace |

### 清理（Purge）
| 函数 | 文件 | 行号 | 说明 |
|------|------|------|------|
| `trx_purge()` | `srv0srv.cc` | 2904, 3099 | 执行 purge |
| `srv_release_threads()` | `srv0srv.cc` | 3138 | 释放 purge worker 线程 |
| `srv_start_wait_for_purge_to_start()` | `srv0start.cc` | 1001 | 等待 purge 启动 |

### 监控
| 函数 | 文件 | 行号 | 说明 |
|------|------|------|------|
| `srv_refresh_innodb_monitor_stats()` | `srv0srv.cc` | 1278 | 刷新监控统计 |
| `srv_printf_innodb_monitor()` | `srv0srv.cc` | 1325 | 打印 INNODB MONITOR 输出 |
| `buf_refresh_io_stats_all()` | `buf0buf.cc` | 调用于 refresh | 刷新 IO 统计 |
| `log_refresh_stats()` | `log0log.cc` | 调用于 refresh | 刷新日志统计 |

---

## 总结

InnoDB 的性能调优参数映射到内核中具体的全局变量、数据结构和运行时函数。
理解每个参数对应的源码路径——从 `srv0srv.h` 的变量声明，到 `buf0buf.cc` / `log0write.cc` / `buf0flu.cc`
的执行逻辑——才能区分哪些参数是"调节杠杆"（如 `io_capacity`, `buf_pool_size`），
哪些是"安全阀门"（如 `max_dirty_pages_pct`, `log_file_size`）。

调优三原则：
1. **测量先行** — 用 `INNODB_METRICS` + Performance Schema 建立基准
2. **单变量递进** — 每次只改一个参数，评估效果后再改下一个
3. **关注瓶颈方向** — 不是配置越多越好，而是找到当前的瓶颈（CPU？IOPS？锁？Buffer？）
   并选择对应的参数调整
