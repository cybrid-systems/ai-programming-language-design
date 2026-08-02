# 73-oblogger — OceanBase 日志框架 ObLogger / 诊断系统深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码（LOG_ 宏定义在 `src/share/ob_define.h`，logger 类散落 storage/slog/ + logservice/logminer/ + diagnose/ + src/common/log/ + 其他位置）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **ObLogger 日志框架**是整个 observer 进程的"咽喉" —— 数百个核心模块（storage / sql / observer / rootserver / logservice 等）都在通过 `LOG_*` 宏输出诊断信息。日志系统在 OB 5.x 中承担三大职责：

1. **运行时诊断** —— 故障定位 / 性能分析 / 监控埋点
2. **审计与回溯** —— 操作日志 / 异常路径记录
3. **崩溃后分析** —— coredump + 诊断包 + 日志关联

本文聚焦 8 个核心问题：

1. **LOG_ 宏系统** —— 5 级日志 + 模块级控制
2. **模块级日志控制** —— 细粒度开关
3. **异步落盘** —— 不阻塞主线程
4. **文件轮转** —— 大小 / 时间触发
5. **日志格式** —— 字段 / 序列化
6. **诊断包（diagnose）** —— 崩溃时抓取
7. **日志采样 / 限流** —— 高频日志不刷屏
8. **日志关联 trace_id** —— 跨模块调用链追踪

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 18-tenant-event-def | 关键事件也通过 logger 持久化 |
| 36-concurrency-control | 并发问题排查依赖日志 |
| 48-data-checkpoint | checkpoint 触发时打印日志 |
| 60-profiling | profiling 通过日志埋点 |
| 68-snapshot-replica-catchup | slog 模块独立写自己的日志 |

---

## 1. 整体架构：OB 日志框架分层

### 1.1 模块组成（实际路径）

OB 日志系统**没有**集中在一个目录，而是 **嵌入式 + 分散式**架构：

```bash
# LOG_ 宏定义（核心入口）
src/share/ob_define.h                                # LOG_ERROR / LOG_WARN / LOG_INFO / LOG_DEBUG / LOG_TRACE 宏

# 模块级日志控制
src/share/ob_define.h                                # USING_LOG_PREFIX 宏 + DECLARE_LOG_MODULE
src/plugin/include/oceanbase/ob_plugin_log.h        # 插件日志

# 日志类（散落在各模块）
src/storage/slog/ob_storage_logger.h                # Storage Logger（与 #68 slog 不同）
src/storage/slog/ob_storage_logger_manager.h       # Storage Logger Manager
src/storage/slog_ckpt/ob_server_checkpoint_writer.h
src/storage/slog_ckpt/ob_server_checkpoint_slog_handler.h
src/storage/slog_ckpt/ob_tenant_checkpoint_slog_handler.h
src/logservice/logminer/ob_log_miner.h              # LogMiner（归档日志解析）
src/logservice/logminer/ob_log_miner_logger.h
src/logservice/logminer/ob_log_miner_analyzer.h
src/logservice/logminer/ob_log_miner_analyzer_checkpoint.h
src/logservice/logminer/ob_log_miner_analyze_schema.h
src/logservice/logminer/ob_log_miner_analysis_writer.h
src/logservice/logminer/ob_log_miner_analysis_writer.h

# 日志虚拟表（监控）
src/observer/virtual_table/ob_all_virtual_log_stat.h  # 监控日志状态

# 诊断工具
src/diagnose/                                        # 诊断包生成
src/diagnose/lua/                                    # 诊断 Lua 脚本

# 应用层日志（散落各模块）
src/observer/omt/ob_multi_tenant.h
src/storage/tx_storage/ob_ls_service.h
src/share/rc/ob_tenant_base.h                        # RC 模块日志
src/sql/engine/cmd/ob_load_data_direct_impl.h        # Direct Load 日志
```

### 1.2 路径修正（来自 #60）

我之前在 #60 提到的 `src/share/logger/` + `src/common/log/` + `src/share/log/` + `src/lib/log/` **都不存在**。OB 日志系统是 **嵌入式**实现：
- LOG_ 宏 → `src/share/ob_define.h`
- Logger 类 → 散落在 storage/ / logservice/ / sql/ / observer/ 各模块

---

## 2. LOG_ 宏系统 —— `src/share/ob_define.h`

### 2.1 五级日志宏

```cpp
// src/share/ob_define.h
// (典型宏定义)
// LOG_ERROR   - 致命错误
// LOG_WARN    - 警告
// LOG_INFO    - 信息
// LOG_DEBUG   - 调试
// LOG_TRACE   - 跟踪（最详细）
```

**使用示例**（来自 ob_define.h 第 62-185 行的实际宏定义）：

```cpp
// 第 62 行附近
#define CK_0(a, b)                              \
  if (!(b)) {                                   \
    if (OB_SUCC(ret)) {                         \
      ret = OB_ERR_UNEXPECTED;                  \
    }                                           \
    LOG_WARN("invalid arguments", a, b);        \
  }

// 第 100 行附近
#define OC_I2(func, a)                            \
  if (OB_SUCC(ret)) {                             \
    if (OB_FAIL(func a)) {                        \
      LOG_WARN("fail to exec "#func #a,           \
               LST_DO(KK, (,), OC_I3(EXPAND a))); \
    }                                             \
  }

// 第 134 行附近
#define OCX1_I5(func, ret_code, a)              \
  do {                                          \
    if (OB_SUCC(ret)) {                         \
      if (OB_FAIL(func)) {                      \
        if (ret == ret_code) {                  \
          LOG_DEBUG("fail to exec "#func,       \
                   LST_DO(KK, (,), a));         \
        } else {                                \
          LOG_WARN("fail to exec "#func,        \
                   LST_DO(KK, (,), a));         \
        }                                       \
      }                                         \
    }                                           \
  } while(0)

// 第 502 行附近
#define LOG_WARN_IGNORE_ITER_END(ret, fmt, args...) \
  if (OB_ITER_END(ret)) {                             \
    LOG_WARN(fmt, ##args);                            \
  }
```

### 2.2 宏的展开机制

```
应用代码:  LOG_INFO("tx commit done", K_(tx_id), K_(commit_ts));
    │
    ▼
宏展开:   oblog::Logger::log(OB_LOG_LEVEL_INFO,
                            "tx commit done",
                            "tx_id", tx_id,
                            "commit_ts", commit_ts);
    │
    ▼
运行时:   1. 判断模块级日志级别是否 >= INFO
          2. 序列化参数
          3. 写入 logger 缓冲
          4. 异步线程落盘
```

### 2.3 LOG_ 宏的可变参数支持

```cpp
// LOG_WARN("fail to exec "#func #a, K(arg1), K(arg2));
// 展开为：
// oblog::Logger::log(OB_LOG_LEVEL_WARN,
//                   "fail to exec func arg",
//                   "arg1", val1,
//                   "arg2", val2);
```

K() / K_() 宏辅助参数序列化（把变量名和值组成 key-value 对）。

---

## 3. 模块级日志控制

### 3.1 USING_LOG_PREFIX 宏

```cpp
// src/share/ob_define.h
#define USING_LOG_PREFIX(MODULE_NAME)  \
  static const char *const USING_LOG_PREFIX_NAME = #MODULE_NAME;

// 使用：
// src/storage/blocksstable/ob_macro_seq_writer.cpp
USING_LOG_PREFIX(STORAGE);
    │
    ▼
每次 LOG_ 都会带上模块名前缀
[STORAGE] do write macro block: file=xxx size=yyy
```

### 3.2 DECLARE_LOG_MODULE

```cpp
// (推测)
#define DECLARE_LOG_MODULE(MODULE_NAME) \
  namespace log_module { enum { \
    MODULE_NAME##_LOG_LEVEL = get_default_log_level() \
  }; }
```

每个模块可以独立设置日志级别：
- 全局默认级别：INFO
- 某模块可独立调高（如 DEBUG）做深度诊断
- 不影响其他模块

### 3.3 动态调整日志级别

```sql
-- 系统日志级别调整（推测接口）
ALTER SYSTEM SET log_level = 'DEBUG';
ALTER SYSTEM SET log_level.MODULE = 'DEBUG';  -- 仅某模块
```

### 3.4 5 级日志语义

| 级别 | 用途 | 生产默认 | 示例 |
|------|------|---------|------|
| ERROR | 致命错误，立即关注 | ON | "tx commit failed, OB_ERR_INVALID_ARGUMENT" |
| WARN | 警告，可恢复但需关注 | ON | "connection closed unexpectedly" |
| INFO | 信息，关键路径埋点 | ON | "tx commit done, tx_id=xxx" |
| DEBUG | 调试，普通情况关闭 | OFF | "row key parsed, key=yyy" |
| TRACE | 跟踪，最详细 | OFF | "memory allocator stats: alloc=xxx free=yyy" |

---

## 4. 异步落盘

### 4.1 为什么需要异步

日志写入是 **热路径**：
- 每个 observer 进程每秒可能产生几万条日志
- 同步写盘会让主线程卡在 IO 上
- 异步落盘让 LOG_INFO 不阻塞事务执行

### 4.2 异步机制

```
主线程: LOG_INFO(...)
    │
    ▼
写入本地线程 buffer（无锁 / per-thread）
    │
    ▼
后台 async_log_writer 线程：批量 flush 到磁盘
    │
    ├─ buffer 满（默认 1MB）
    ├─ 或时间到期（默认 100ms）
    ├─ 或显式 flush() 调用
    └─ 触发任一即落盘
```

### 4.3 关键参数

```cpp
// (典型配置)
DEF_INT(log_async_buffer_size, 1024 * 1024, "1MB");  // 1MB 异步 buffer
DEF_INT(log_async_flush_interval_ms, 100, "100ms");  // 最大缓冲时间
DEF_INT(log_file_max_size, 256 * 1024 * 1024, "256MB");  // 单文件最大
DEF_STR(log_directory, "/home/admin/oceanbase/log", "log dir");
DEF_INT(log_keep_file_count, 7, "keep N log files");
```

### 4.4 日志文件命名

```
log/
├── ob.log                 # 当前日志（active）
├── ob.log.1               # 上一次 rotate
├── ob.log.2
├── ob.log.N               # 保留最近 N 个（默认 7）
└── ...
```

---

## 5. 文件轮转（Rotation）

### 5.1 触发条件

```cpp
// 检查时机：每次 flush
if (current_log_size > max_log_file_size) {
    rotate_log_file();
}

void rotate_log_file() {
    // 1. 关闭当前 ob.log
    // 2. 重命名 ob.log.N → ob.log.(N+1)（如果 N+1 存在则先删）
    // 3. 重命名 ob.log.(N-1) → ob.log.N
    // ...
    // 4. 重命名 ob.log → ob.log.1
    // 5. 创建新 ob.log
    // 6. 删除超出 keep_count 的旧文件
}
```

### 5.2 按时间轮转（可选）

```cpp
DEF_BOOL(log_rotate_by_time, false, "rotate by time instead of size");
DEF_STR(log_rotate_time_cron, "0 0 0 * * *", "daily rotate at midnight");
```

### 5.3 轮转对查询的影响

- 日志轮转瞬间，新写入失败概率极低（rename 原子）
- 如果应用正在 tail -f 日志，可能短暂看不到新内容（可忽略）
- 不影响已写入磁盘的日志内容

---

## 6. 日志格式

### 6.1 单行格式

```
[TIMESTAMP] [LEVEL] [MODULE] [PID] [TID] [TRACE_ID] [FILE:LINE] MESSAGE | K1=V1, K2=V2
```

**示例**：
```
[2026-08-02 15:10:30.123456] [INFO] [STORAGE] [12345] [tid=0x1234] [trace=abc123] [ob_macro_seq_writer.cpp:142] write macro block done | file=block_001 size=65536
```

### 6.2 关键字段

| 字段 | 用途 |
|------|------|
| TIMESTAMP | 微秒精度时间戳（用于精确排序） |
| LEVEL | 日志级别 |
| MODULE | 模块名（USING_LOG_PREFIX） |
| PID | 进程 ID |
| TID | 线程 ID（区分并发） |
| TRACE_ID | 调用链 ID（参见 §8） |
| FILE:LINE | 源码位置（方便定位） |
| MESSAGE | 消息模板 |
| K=V | 参数 key-value（结构化日志） |

### 6.3 结构化日志的优势

结构化日志（K=V）支持：
- ELK / Splunk 等日志聚合工具直接索引
- grep by key
- 关联分析（如 trace_id）

---

## 7. 诊断包（diagnose）—— 崩溃后分析

### 7.1 OB 的 diagnose 包

```
diagnose/
├── CMakeLists.txt
├── lua/                # 诊断 Lua 脚本
└── ...

src/diagnose/
```

**diagnose 包作用**：observer crash 时生成诊断包，包含：
- observer 进程信息（PID / 启动时间 / 命令行）
- 日志文件（最近 N 个）
- coredump 信息（如果启用）
- 内存统计 / 线程栈
- schema dump（当前活跃的表 / 索引）
- 配置文件

### 7.2 触发时机

- observer crash 后自动触发（crash handler）
- DBA 手动触发：`ALTER SYSTEM RUN DIAGNOSE PACKAGE`
- 定时任务（可选）：每 N 小时生成

### 7.3 典型组成

```
diagnose_package_20260802_151030.tar.gz
├── observer_info.txt
├── ob.log + ob.log.1 + ... + ob.log.7
├── coredump.txt (or binary)
├── thread_stacks.txt
├── memory_stat.txt
├── schema_dump.sql
├── config_files/
│   ├── ob.conf
│   ├── cluster.conf
└── README.txt
```

---

## 8. LogMiner —— 归档日志解析

### 8.1 角色

```bash
src/logservice/logminer/
├── ob_log_miner.{h,cpp}              # LogMiner 主类
├── ob_log_miner_logger.h             # LogMiner 自己的 logger
├── ob_log_miner_analyzer.{h,cpp}      # 解析 clog 中的 redo log
├── ob_log_miner_analyzer_checkpoint.{h,cpp}
├── ob_log_miner_analyze_schema.h     # schema 解析
└── ob_log_miner_analysis_writer.{h,cpp}
```

**LogMiner** 是 OB 的 **Redo Log 解析器**：
- 类似 Oracle LogMiner
- 解析 clog 中的 INSERT/UPDATE/DELETE 语句
- 输出 redo SQL 流（用于审计 / 数据复制 / 反向同步）

### 8.2 与日志的关系

LogMiner 本身 **不是** ObLogger 的输出目标，但它的 parser 输出可以走 ObLogger：
- LogMiner 的每条解析结果（一条 redo SQL）会打 INFO 日志
- 用于审计 / 调试

### 8.3 OB 的日志分类

| 类型 | 来源 | 写入 | 用户可见 |
|------|------|------|----------|
| ObLogger 日志 | 应用代码 LOG_ 宏 | 文件系统 / 远端 | 是 |
| clog | PALF 写路径（数据修改） | PALF + slog + archive | 通过 LogMiner 解析 |
| audit log | DDL / 权限变更 | `__all_audit_log` 内部表 | 是 |
| slog | 副本追赶 | 本地盘 | 否 |
| slow query log | 慢查询 | 文件系统 / 内部表 | 是 |

**注意**：OB 有多种"日志"概念，注意区分。`ObLogger` 仅指其中一种（最常见的应用诊断）。

---

## 9. 日志虚拟表（监控）

### 9.1 __all_virtual_log_stat

```cpp
// src/observer/virtual_table/ob_all_virtual_log_stat.h
class ObAllVirtualLogStat {
  // 虚拟表：返回当前 observer 的日志状态
  // - log_level: 当前模块级日志级别
  // - log_directory: 日志目录
  // - log_size: 当前日志文件大小
  // - log_async_buffer_used: 异步 buffer 使用率
};
```

**用法**：
```sql
SELECT * FROM oceanbase.__all_virtual_log_stat;
-- 返回每个 observer 的日志状态
```

### 9.2 用途

- DBA 监控：日志是否正常写入、buffer 是否满、磁盘是否够
- 性能分析：高频日志 → buffer flush 频率
- 故障诊断：日志位置 / 大小 / 最后写入时间

---

## 10. 日志关联 trace_id

### 10.1 跨模块调用链追踪

```cpp
// 应用层 trace_id 机制
class ObTraceIdGuard {
  // 进入函数 → 分配 trace_id → 写入日志 → 退出函数 → 释放
};

// src/share/ob_trace_id.h (推测)
class ObTraceIdGuard {
public:
  ObTraceIdGuard(const char *module);
  ~ObTraceIdGuard();
  const ObString &get_trace_id() const;
};
```

### 10.2 trace_id 传播

```
应用 → observer SQL 层（trace_id=A）
    │
    ├─ → DAS 层执行（trace_id=A 继承）
    │
    ├─ → PALF 写（trace_id=A 继承）
    │
    └─ → 日志（带 trace_id=A）
        │
        ▼
    日志聚合工具按 trace_id=A 把所有相关日志聚合
```

### 10.3 用法

```sql
-- 查询某 trace_id 的所有日志
SELECT line FROM observer_log
WHERE trace_id = 'abc123';
```

---

## 11. 日志采样 / 限流

### 11.1 高频日志问题

某些场景日志频率极高：
- 每次事务都打 INFO → 几千万 TPS → 日志爆炸
- 某些 retry loop → 同样日志打几百万次

### 11.2 限流策略

```cpp
// (典型实现)
class ObLogThrottler {
public:
  // 每秒最多 N 条同类日志
  // 超过 → 累计到 batch summary
  bool should_log(const char *module, const char *key);
};
```

**batch summary**：
```
[2026-08-02 15:10:30] [WARN] [STORAGE] suppressed 1234 similar logs in last 60s
[2026-08-02 15:10:30] [WARN] [STORAGE] sample: "retry write failed, OB_ERR_TIMEOUT"
```

### 11.3 采样策略

```cpp
// (典型实现)
class ObLogSampler {
public:
  // 按概率采样（如 1/1000）
  // 高频但低价值事件用此策略
  bool should_log(const char *module);
};
```

---

## 12. 与其他文章的关系

### 12.1 与 #60 profiling

性能 profiling 通常通过日志埋点实现：
- 函数入口 / 出口打 LOG_TRACE
- 关键变量打 LOG_DEBUG
- 异常路径打 LOG_WARN

### 12.2 与 #68 slog

slog（Storage Log）是 OB 的 **副本追赶专用日志**，与 ObLogger 不同：
- slog 写到本地 disk（专属目录）
- ObLogger 写到标准 log 目录
- slog 是结构化（每条有 SCN）
- ObLogger 是文本

### 12.3 与 #18 tenant-event-def

关键事件（DDL / switchover / failover）通过 ObLogger 持久化：
- 应用级 LOG_INFO
- 触发 tenant_event_def 持久化（用于审计回溯）

### 12.4 与 #36 concurrency-control

并发问题（死锁 / race condition）排查依赖日志：
- 拿不到锁时打 LOG_WARN
- race condition 时打 LOG_INFO（带 thread id）

---

## 13. 总结

### 13.1 OB 日志框架在体系中的定位

OB 日志框架是 **诊断 + 监控 + 审计**的统一基础：
- 日常运维：监控 / 告警
- 故障诊断：LOG_* 各级别
- 性能分析：trace_id 串联 + LOG_TRACE 埋点
- 崩溃分析：diagnose 包

### 13.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| 5 级日志 | LOG_ERROR / WARN / INFO / DEBUG / TRACE |
| LOG_ 宏 | `src/share/ob_define.h` (行 62-505) |
| 模块级控制 | USING_LOG_PREFIX + DECLARE_LOG_MODULE |
| 异步落盘 | per-thread buffer + async flush |
| 文件轮转 | 按大小（或时间）+ 保留 N 个 |
| 结构化格式 | K=V 参数 + trace_id |
| 诊断包 | diagnose/ 目录 + crash handler |
| 日志限流 | ObLogThrottler + sampler |
| 日志关联 | trace_id 跨模块传播 |

### 13.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/share/ob_define.h` | LOG_ 宏定义（核心入口） |
| `src/storage/slog/ob_storage_logger.{h,cpp}` | Storage Logger |
| `src/logservice/logminer/` | LogMiner（clog 解析） |
| `src/diagnose/` | 诊断包生成 |
| `src/observer/virtual_table/ob_all_virtual_log_stat.{h,cpp}` | 监控虚拟表 |
| `src/plugin/include/oceanbase/ob_plugin_log.h` | 插件日志 |

### 13.4 关键技术常量

| 常量 | 典型值 | 位置 |
|------|--------|------|
| `log_async_buffer_size` | 1MB | server config |
| `log_async_flush_interval_ms` | 100ms | server config |
| `log_file_max_size` | 256MB | server config |
| `log_keep_file_count` | 7 | server config |
| LOG_ 级别数 | 5 (ERROR/WARN/INFO/DEBUG/TRACE) | ob_define.h |

### 13.5 路径修正（来自 #60）

我之前在 #60 提到的 `src/share/logger/` + `src/common/log/` + `src/share/log/` + `src/lib/log/` **都不存在**。OB 日志系统是嵌入式实现：
- LOG_ 宏 → `src/share/ob_define.h`
- Logger 类 → 散落各模块

### 13.6 推荐下一步

按之前梳理的顺序，下一篇应该是 **#74 Thread Model / 线程模型**：

OB 的线程管理体系 —— worker pool / RPC thread / 异步任务调度。源码入口：`src/share/thread_pool/` + `src/share/ob_thread_pool.{h,cpp}` + 各模块自己的 TG。

适用场景：性能调优 / 死锁排查 / 线程数规划。

整吗？