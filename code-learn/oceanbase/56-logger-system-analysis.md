# ObLogger 日志系统 — 日志框架、异步落盘、诊断

## 一、概述

OceanBase 的日志系统（`ObLogger`）是一套完整的、高性能的日志基础设施，位于 `deps/oblib/src/lib/oblog/` 目录下，共 26 个源文件。它不仅承担着传统日志的角色，还深度参与了在线诊断（Trace、Probe）、审计（DBA Event、Security Audit）、限流熔断等场景。

核心设计目标：
- **高性能异步落盘** — 日志产生方不做 I/O，通过无锁队列 + Group Commit 批量写入
- **精细化日志级别控制** — 支持按 Module/Sub-Module 级别独立控制打印级别
- **生产安全** — 日志限流防止日志风暴打垮系统
- **可诊断性** — 支持 Trace 日志、Probe 断点、Backtrace、EDIAG/WDIAG 诊断分级

---

## 二、日志级别体系

### 2.1 级别定义

[ob_log_level.h](ob_log_level.h) 定义了完整的日志级别枚举（第 27–56 行）：

| 宏 | 值 | 输出标记 | 用途 |
|---|---|---|---|
| `OB_LOG_LEVEL_NONE` | 7 | — | 不打印 |
| `OB_LOG_LEVEL_NP` | -1 | — | 强制不打印 |
| `OB_LOG_LEVEL_DBA_ERROR` | 0 | `ERROR` | DBA 错误 |
| `OB_LOG_LEVEL_DBA_WARN` | 1 | `WARN` | DBA 警告 |
| `OB_LOG_LEVEL_DBA_INFO` | 2 | `INFO` | DBA 信息 |
| `OB_LOG_LEVEL_ERROR / EDIAG` | 3 | `EDIAG` | 错误诊断 |
| `OB_LOG_LEVEL_WARN / WDIAG` | 4 | `WDIAG` | 警告诊断 |
| `OB_LOG_LEVEL_TRACE` | 5 | `TRACE` | 跟踪 |
| `OB_LOG_LEVEL_DEBUG` | 6 | `DEBUG` | 调试 |

值得注意的设计：

1. **DBA_ERROR/DBA_WARN/DBA_INFO (0–2)** — 比传统 ERROR 更严重，会输出到 alert.log，是运维监控的核心信号
2. **EDIAG / WDIAG (3–4)** — 诊断级别的错误和警告，用于 debug 场景（`USING_LOG_PREFIX` 宏体系下 `LOG_ERROR` 实际对应 `EDIAG` 级别）
3. **TRACE / DEBUG (5–6)** — 追踪日志，通常在 NDEBUG 下被编译期优化掉

### 2.2 线程级日志级别

[ob_log.h](ob_log.h) 第 142–171 行定义了 `ObThreadLogLevel` 和 `ObThreadLogLevelUtils`，允许**按 Session 粒度**动态调整日志级别。当客户端设置 `@@session.log_level` 时，级别信息通过 RPC 包头的 `ObThreadLogLevel` 传递到服务端线程，`ObThreadLogLevelUtils` 将其写入线程本地存储（`RLOCAL`），在日志打印时优先级高于全局级别。

---

## 三、ObLogger 主框架

### 3.1 单例模式

[ob_log.h](ob_log.h) 第 921 行：

```cpp
ObLogger &ObLogger::get_logger()
{
  static ObLogger logger;
  return logger;
}
```

全局通过 `OB_LOGGER` 宏引用该单例。

### 3.2 初始化流程

[ob_log.cpp](ob_log.cpp) 第 1518–1620 行的 `ObLogger::init()` 方法执行以下步骤：

1. **构造限流器** — 初始化 `per_log_limiters_` 数组（每个位置一个 `ObSyslogSampleRateLimiter`，初始速率 1000/秒，之后 100/秒）和 `per_error_log_limiters_`
2. **预分配日志条目池** — 根据 `memory_limit` 计算缓存容量。内存 <= 4G 分配 6MB 缓存（64 个正常条目 + 8 个大条目），最高内存 > 64G 分配 96MB 缓存（1024 + 128）
3. **初始化 BaseLogWriter** — 启动异步刷盘线程（thrad name: `OB_PLOG`），配置 Group Commit 参数

### 3.3 核心数据结构

**ObPLogItem** — 日志条目，包含：
- 缓冲区（`buf_`, `data_len_`, `buf_size_`）
- 元信息（`log_level_`, `timestamp_`, `fd_type_`, `tl_type_`, `force_allow_`）
- 文件类型标识（`is_supported_file()` 方法）

**LogItemPool** — 两层分配器：
- 正常池（`log_item_pool_`）— 条目大小 = `LOG_ITEM_SIZE + BASE_LOG_SIZE`
- 大日志池（`large_log_item_pool_`）— 条目大小 = `LOG_ITEM_SIZE + MAX_LOG_SIZE`
- 每条日志先尝试从小池分配，`OB_SIZE_OVERFLOW` 时回退到大池（见 `do_log_message` 第 1284–1306 行的循环）

---

## 四、异步日志写入 — ObBaseLogWriter

### 4.1 无锁环形队列

[ob_base_log_writer.h](ob_base_log_writer.h) 第 40–91 行：

```cpp
ObIBaseLogItem **log_items_;              // 环形缓冲区
int64_t log_item_push_idx_ CACHE_ALIGNED; // 写入游标（无锁递增）
int64_t log_item_pop_idx_ CACHE_ALIGNED;  // 读取游标
```

- 生产者通过 `ATOMIC_FAA` 无锁获取写入位置
- 消费者（刷盘线程）对比 `push_idx_` 和 `pop_idx_` 判断是否有待处理条目
- 队列满时（`get_queued_item_cnt() >= max_buffer_item_cnt_`），日志会被**静默丢弃**

### 4.2 刷盘流程

`ObBaseLogWriter::append_log()` 将日志写入环形队列后，通过 `SimpleCond` 唤醒刷盘线程。刷盘线程内：

```
[flush_log_thread] → [do_flush_log] → [process_log_items]
```

核心处理在 [ob_log.h](ob_log.h) 第 791 行 `async_flush_log_handler()`：
- **Group Commit** — 每次最多取 `GROUP_COMMIT_MAX_ITEM_COUNT` 条（默认 1024），最少取 `GROUP_COMMIT_MIN_ITEM_COUNT` 条组成一批
- **多路下发** — 按 `fd_type` 分拣到 `vec[MAX_FD_FILE][]` 数组（`iovcnt[fd_type]` 计数器），使用 `writev` 系统调用单次写入
- **WF 文件路径** — 级别 <= `wf_level_` 的日志同时写入 `.wf` 文件（第 1743–1770 行）

### 4.3 Group Commit 参数

[ob_log.h](ob_log.h) 第 280–282 行：

```cpp
GROUP_COMMIT_MAX_WAIT_US     // 最大等待时间
GROUP_COMMIT_MIN_ITEM_COUNT  // 最小凑批数量
GROUP_COMMIT_MAX_ITEM_COUNT  // 最大凑批数量
```

- 生产端写入时检查队列长度，满足 `GROUP_COMMIT_MIN_ITEM_COUNT` 则立即通知刷盘
- 否则刷盘线程等待最长 `GROUP_COMMIT_MAX_WAIT_US` 微秒

---

## 五、EasyLog 日志接口

[ob_easy_log.h](ob_easy_log.h) 第 21 行声明了 `ob_easy_log_format()` 函数，它是 OceanBase 为底层网络库 **libeasy** 定制的日志格式化入口。libeasy 默认日志输出没有模块、行号等结构化信息，通过此函数将 libeasy 的日志纳入 `ObLogger` 的格式化体系，统一输出格式。

---

## 六、日志宏体系

### 6.1 模块定义

[ob_log_module.h](ob_log_module.h) 通过 `LOG_MOD_BEGIN/END` 和 `DEFINE_LOG_SUB_MOD` 宏定义了完整的日志模块树。顶级模块包括：

```
ROOT → CLIENT, CLOG, COMMON, ELECT, LIB, OFS,
       RPC, RS, SHARE, SQL, PL, STORAGE, ...
```

每个模块下又有子模块（如 `LIB` 下有 `ALLOC`, `CONT`, `HASH`, `LOCK`, `STRING`, `TIME`, `UTIL` 等）。

### 6.2 使用方式

模块日志通过 `USING_LOG_PREFIX` 宏在 `.cpp` 文件顶部定义：

```cpp
#define USING_LOG_PREFIX STORAGE
LOG_ERROR("write failed", K(ret), K(lsn));
```

展开为：

```
→ STORAGE_LOG(ERROR, ...)
  → OB_MOD_LOG(STORAGE, ERROR, ...)
    → OB_LOGGER.log_message_fmt("[STORAGE] ", ...)
```

### 6.3 结构化日志

日志宏支持丰富的结构化打印：

- `K(x)` — 打印 `"x"=value`（非 C 字符串）
- `KCSTRING(x)` — 打印 C 字符串
- `K_(x)` — 打印成员变量 `"x"=x_`
- `KTIME(ts)` — 打印可读时间戳
- `KPC(ptr)` — 打印指针及指向对象内容
- `KPHEX(data, size)` — 十六进制打印

这些全通过 [ob_log_print_kv.h](ob_log_print_kv.h) 的模板类和 `logdata_printf` 实现，在 `fill_kv()` 中逐个序列化到日志缓冲区。

---

## 七、日志限流 — ObSyslogRateLimiter

### 7.1 三层限流器设计

[ob_syslog_rate_limiter.h](ob_syslog_rate_limiter.h) 定义了限流器层次：

```
ObRateLimiter (lib/utility)
  └─ ObISyslogRateLimiter ← 虚基类，支持 log_level/errcode 感知
        ├─ ObSyslogSimpleRateLimiter  — 简单速率限制（默认 100/秒）
        └─ ObSyslogSampleRateLimiter  — 采样限流（初始 N，之后 M/秒）
```

**ObSyslogSimpleRateLimiter**（第 106–129 行）：
- 对 `ERROR / DBA_WARN / DBA_ERROR` 级别**不做限流**（允许全部通过）
- 其他级别按 100/秒 的默认速率限流

**ObSyslogSampleRateLimiter**（第 132–146 行）：
- 每个限流周期内，前 `initial_` 条日志立即通过
- 之后每隔 `(1 / thereafter_) * duration_` 微秒允许一条
- 窗口重置时计数器归零

### 7.2 位置哈希驱动的限流

[ob_log.cpp](ob_log.cpp) 第 50 行定义了 `per_log_limiters_[N_LIMITER]` 数组。限流的核心依据是**日志源码位置的哈希值**（`location_hash_val`，在 [ob_log_module.h](ob_log_module.h) 由 `OB_LOG_LOCATION_HASH_VAL` 宏使用 `fnv_hash_for_logger` 计算）：

```
hash_val = fnv_hash(__FILE__ ":" __LINE__)
index = hash_val % N_LIMITER
```

这意味着**同一位置的日志共享同一个限流器**。当某个代码路径在短时间内产生大量日志时，该位置的 `ObSyslogSampleRateLimiter` 会率先触发限流，而其他代码位置不受影响。这是防止日志风暴的核心机制。

### 7.3 Force Allow 机制

限流器 `is_force_allows()` / `reset_force_allows()` 方法支持**强制放行**：当检测到关键错误时，允许短时间内突破限流输出日志，确保不丢失重要诊断信息。

---

## 八、Trace 日志

### 8.1 ObTraceLogConfig

[ob_trace_log.h](ob_trace_log.h) 第 65–80 行的 `ObTraceLogConfig` 通过环境变量设置 Trace 日志级别：

```cpp
class ObTraceLogConfig {
  static int32_t get_log_level() {
    if (!got_env_) {
      const char *log_level_str = getenv(LOG_LEVEL_ENV_KEY);
      set_log_level(log_level_str);
      got_env_ = true;
    }
    return log_level_;
  }
};
```

### 8.2 Trace 宏

```cpp
NG_TRACE_EXT(trace_id, event, args...)
NG_TRACE(trace_id, event)
PRINT_TRACE(log_buffer)        // 受日志级别控制
FORCE_PRINT_TRACE(log_buffer)  // 仅 ERROR 级别时不打印
```

- `NG_TRACE_EXT_TIMES(times, ...)` 限制同一 trace_id 的最多打印次数，防止同一请求反复产生大量 Trace 日志
- `CHECK_TRACE_TIMES`（第 10–33 行）使用 `RLOCAL` 数组追踪 `{trace_id1, trace_id2, count}`，超过 `times` 后静默

### 8.3 Trace 缓冲区

[ob_log.h](ob_log.h) 第 312–324 行的 `TraceBuffer` 是一个线程本地循环缓冲区，用于在产生大量 Trace 日志时暂存日志，待后续判断是否需要打印：

```cpp
struct TraceBuffer {
  int64_t pos_;
  char buffer_[TRACE_BUFFER_SIZE];
  void set_pos(int64_t pos) { pos_ = pos; }
  bool is_oversize() const;
};
```

---

## 九、Probe 断点机制

[ob_log.h](ob_log.h) 第 241–247 行定义了 `ProbeAction` 枚举，实现日志断点调试：

```cpp
enum ProbeAction {
  PROBE_NONE,    // 不处理
  PROBE_BT,      // 输出 Backtrace
  PROBE_ABORT,   // 触发 Abort
  PROBE_DISABLE, // 禁用当前日志
  PROBE_STACK    // 打印调用栈
};
```

通过 `OB_LOGGER.set_probe(file, line, action)` 在运行时动态设置。`check_probe()`（[ob_log.h](ob_log.h) 第 1176 行）在每个日志条目产生前检查是否需要执行 Probe 动作。

Probe 按 `(file, line, location_hash_val)` 三元组匹配，存储在 `probes_[MAX_PROBE_CNT]` 数组中，`probe_cnt_` 记录已注册的数量。

---

## 十、多文件流输出

### 10.1 输出目标

[ob_log.cpp](ob_log.cpp) 第 99–121 行的 `get_fd_type()` 函数根据模块名前缀决定日志输出到哪个文件：

| 文件类型 | 目标文件 | 触发条件 |
|---|---|---|
| `FD_SVR_FILE` | `observer.log`（默认） | 普通模块日志 |
| `FD_RS_FILE` | `rootservice.log` | 模块前缀 `[RS` 或 RS 线程 |
| `FD_ELEC_FILE` | `election.log` | 模块前缀 `[ELECT` |
| `FD_TRACE_FILE` | `trace.log` | 模块前缀 `[FLT` |
| `FD_ALERT_FILE` | `alert.log` | DBA_ERROR/DBA_WARN/DBA_INFO 级别且指定了 dba_event |

### 10.2 DBA 事件日志

[ob_log_dba_event.h](ob_log_dba_event.h) 定义了 DBA 事件枚举（如 `OB_SERVER_SYSLOG_SERVICE_INIT_BEGIN`），使用宏 `LOG_DBA_FORCE_PRINT`, `LOG_DBA_ERROR_V2`, `LOG_DBA_WARN_` 等输出：

- `LOG_DBA_ERROR_V2` — 同时写入 `alert.log` 和 `observer.log`
- `LOG_DBA_ERROR_` — 仅写入 `alert.log`
- `LOG_DBA_FORCE_PRINT` — 强制执行，不受采样限制

### 10.3 日志轮转

`rotate_log()`（[ob_log.h](ob_log.h) 第 773/783 行）在 `check_file()` 中触发，当文件超过 `max_file_size_` 时进行：

- 使用 `rename` 重命名 `.log.N` → `.log.N+1`
- 保留最多 `max_file_index_` 个历史文件
- 支持 `.wf` 文件的同步轮转

---

## 十一、关键业务路径总结

```
[生产线程]
  ↓
OB_LOG(ERROR, msg, K(v1), K(v2))
  ↓ 宏展开
fill_kv → fill_log_buffer → 序列化 K/V 到缓冲区
  ↓
need_to_print() // 检查模块级别 + 线程级别
  ↓
check_tl_log_limiter() // 按 location_hash 限流
  ↓ 通过
do_log_message()
  ├─ alloc_log_item()          // 从对象池分配
  ├─ log_head()                // 写时间戳、模块、行号等头部
  ├─ log_data_func()           // 写正文
  ├─ check_log_end()           // 追加换行符
  ├─ backtrace_if_needed()     // Probe 触发时追加 Backtrace
  └─ append_log()              // 写入无锁环形队列
  ↓
[OB_PLOG 刷盘线程]
  ↓
process_log_items()
  ├─ Group Commit 凑批
  ├─ 按 fd_type 分拣到 iovec
  ├─ writev() 批量写入
  ├─ free_log_item() 归还到对象池
  └─ check_file() 检查文件轮转
```

## 十二、文件清单

| 文件 | 用途 | 关键行号 |
|---|---|---|
| `ob_log.h` | ObLogger 主类声明、常量、内联方法 | 256–930 (class), 921 (get_logger) |
| `ob_log.cpp` | ObLogger 实现：init、do_log_message、flush | 1518 (init), 1681 (flush) |
| `ob_log_level.h` | 日志级别定义 | 27–56 |
| `ob_log_module.h` | 模块声明、所有日志宏 | 全局 |
| `ob_log_print_kv.h` | 结构化打印工具 (K/KCSTRING/KTIME) | 全局 |
| `ob_log_time_fmt.h/cpp` | 时间戳格式化 | 全局 |
| `ob_log_compressor.h/cpp` | 日志压缩 | 全局 |
| `ob_log_dba_event.h/cpp` | DBA 事件枚举 | 全局 |
| `ob_easy_log.h/cpp` | libeasy 日志适配 | 21 (decl) |
| `ob_base_log_writer.h/cpp` | 异步刷盘队列框架 | 40–91 |
| `ob_syslog_rate_limiter.h/cpp` | 日志限流器 | 106 (simple), 132 (sample) |
| `ob_trace_log.h/cpp` | Trace 日志 | 10 (CHECK_TRACE), 65 (config) |
| `ob_warning_buffer.h/cpp` | 用户警告缓冲区 | 全局 |
| `ob_async_log_struct.h/cpp` | 异步日志结构体 | 全局 |
| `ob_base_log_buffer.h/cpp` | 基础日志缓冲 | 全局 |

## 十三、设计要点总结

1. **分层异步架构**：生产线程不做 I/O，通过无锁环形队列解耦，刷盘线程使用 writev 批量落盘
2. **精细化限流**：按源码位置哈希分桶限流，避免单一日志位置打垮系统
3. **多级诊断能力**：DBA 事件 → 诊断日志 → Probe 断点 → Trace 日志，覆盖从运维告警到在线调试的全链路
4. **模块化管理**：通过 30+ 个父模块和 150+ 个子模块的日志树，支持按组件级别独立控制输出
5. **对象池优化**：预分配日志条目池，按内存容量动态调整池大小，避免高频分配开销
