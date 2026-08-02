# #30 v2 — Monitoring / Alerting (Metrics + ASH + Alert 完整实读)

> 接续 #29 v2 Slow Query + #11 v2 Trans Service / Lock + #22 v2 Clog:前面讲
> 了"慢查询怎么捕获、事务怎么运行、日志怎么落盘"。本文聚焦 **"这些怎么可
> 观测、出了问题怎么报警"** ——OB 的监控告警体系。这是 OB 运维的眼睛。

---

## 0. 全文导读

OB 监控告警三层:

```
Metrics     →  数值化指标(counter / gauge / histogram)
ASH         →  Active Session History(每秒采样)
Alert       →  阈值规则 + 通知渠道
```

本文按"架构 → Metrics → ASH → Alert → Dashboard → 性能开销 → 调优"展开。

---

## 1. 监控架构

### 1.1 三层结构

```
┌──────────────────────────────────────┐
│ Application (业务代码)                │
│   ↓ 调 metrics 记录                  │
├──────────────────────────────────────┤
│ Metrics Library (lib_oblog)          │
│   ↓ 周期刷                          │
├──────────────────────────────────────┤
│ Storage (内部 __all_virtual 表)      │
│   ↓ 用户查 / Alert 扫描              │
├──────────────────────────────────────┤
│ Alert Engine + Notify (告警引擎)    │
└──────────────────────────────────────┘
```

### 1.2 关键模块

```cpp
// src/share/ob_log_stat.h:50
// 统一 metrics 接口
class ObMetric {
public:
  void inc();           // 计数器 +1
  void inc_by(int64_t v);
  void set(int64_t v);  // gauge 设值
  void observe(int64_t v); // histogram 观察
};

// src/share/monitor/ash/ob_ash.h:80
// ASH 采样器
class ObAshSampler {
public:
  void sample_loop();   // 1Hz 采样所有 active session
};

// src/share/alert/ob_alert_engine.h:60
// 告警引擎
class ObAlertEngine {
public:
  void evaluate_rules();  // 每分钟评估所有告警规则
};
```

### 1.3 数据流

```
业务事件 (query / DML / DDL / txn)
    ↓
记录 metrics (轻量,~us 级)
    ↓
每 60s 刷盘到 __all_virtual_metric 表
    ↓
用户查 / Alert 引擎扫描
    ↓
触发通知(超阈值)
```

---

## 2. Metrics 体系

### 2.1 四种指标类型

```cpp
// src/share/ob_log_stat.h:100
// 1. Counter(单调递增)
class ObCounter {
  std::atomic<int64_t> value_;
public:
  void inc() { value_++; }
  int64_t get() const { return value_; }
};

// 2. Gauge(可增可减)
class ObGauge {
  std::atomic<int64_t> value_;
public:
  void set(int64_t v) { value_ = v; }
};

// 3. Histogram(分布)
class ObHistogram {
  std::vector<ObBucket> buckets_;  // 桶
public:
  void observe(int64_t v) {
    // 找 v 在哪个桶
    buckets_[find_bucket(v)].count_++;
  }
};

// 4. Summary(分位数)
class ObSummary {
  ObTDigest digest_;  // t-digest 算法
public:
  void observe(int64_t v) { digest_.add(v); }
  double quantile(double q) { return digest_.quantile(q); }
};
```

### 2.2 内置指标分类

| 类别 | 例子 |
|------|------|
| **查询** | `query_count_`, `query_time_us_`, `rows_examined_` |
| **事务** | `trans_count_`, `trans_abort_count_`, `lock_wait_count_` |
| **存储** | `memtable_used_bytes_`, `block_cache_hit_count_` |
| **Clog** | `clog_write_bytes_`, `clog_write_latency_us_` |
| **网络** | `rpc_in_bytes_`, `rpc_out_bytes_`, `rpc_latency_us_` |
| **资源** | `cpu_used_`, `memory_used_`, `disk_used_` |

### 2.3 指标标签

```cpp
// src/share/ob_log_stat.h:200
class ObMetricWithLabels {
public:
  // 标签:tenant_id / table_id / rpc_code / sql_id
  void inc_with_label(const std::string &label_key, const std::string &label_value);
  // 例子:query_count{tenant="t1"} += 1
};
```

标签让指标可按 tenant / table / RPC code 维度切片分析。

### 2.4 指标查看

```sql
-- 所有 metric 名称
SELECT * FROM oceanbase.__all_virtual_metric\G

-- 关键字段:
-- metric_name_: 指标名
-- metric_type_: COUNTER / GAUGE / HISTOGRAM
-- value_: 当前值
-- labels_: JSON 格式标签
-- tenant_id_: 所属 tenant
```

---

## 3. ASH 深入

### 3.1 ASH 概念

```
每秒采样一次所有 active session 的状态
  ↓
记录到 __all_virtual_ash 表
  ↓
可关联 SQL / plan / wait event
  ↓
用于:
  - 找出"现在卡在哪个事件"
  - 关联具体 query
  - 历史回放(过去 1 小时的瞬时状态)
```

### 3.2 ASH 实现

```cpp
// src/share/monitor/ash/ob_ash.cpp:80
class ObAshSampler {
public:
  // 1. 每秒采样
  void sample_loop() {
    while (running_) {
      auto now_us = now();
      // 1.1 遍历所有 active session
      for (auto &session : all_sessions_) {
        if (session.is_active_) {
          AshSample sample;
          sample.session_id_ = session.session_id_;
          sample.sql_id_ = session.current_sql_id_;
          sample.event_ = session.current_wait_event_;
          sample.wait_time_us_ = session.wait_time_;
          sample.sample_time_us_ = now_us;
          ash_buffer_.push_back(sample);
        }
      }
      // 1.2 刷盘到内部表
      flush_to_table();
      sleep(1s);
    }
  }
};
```

### 3.3 等待事件分类

```cpp
// src/share/monitor/ash/ob_wait_event.h:50
enum ObWaitEvent {
  // 1. CPU
  WAIT_EVENT_CPU,

  // 2. 锁等待
  WAIT_EVENT_LOCK_ROW,
  WAIT_EVENT_LOCK_TABLE,

  // 3. IO 等待
  WAIT_EVENT_IO_DATA,         // 数据文件读
  WAIT_EVENT_IO_CLOG,         // Clog 写
  WAIT_EVENT_IO_NET,          // 网络 IO

  // 4. 锁/Latch
  WAIT_EVENT_LATCH_POOL,
  WAIT_EVENT_MUTEX,

  // 5. 系统
  WAIT_EVENT_SCHEDULER,
  WAIT_EVENT_NETWORK,
  // ...
};
```

### 3.4 ASH 查询

```sql
-- 最近 10 分钟的等待事件聚合
SELECT event_, COUNT(*) cnt, AVG(wait_time_us) avg_wait
FROM oceanbase.__all_virtual_ash
WHERE sample_time > NOW() - INTERVAL 10 MINUTE
  AND event_ IS NOT NULL
GROUP BY event_
ORDER BY cnt DESC;
```

### 3.5 关联到具体 query

```sql
-- 找出"现在卡 IO 的 query"
SELECT sql_id_, COUNT(*) cnt, MAX(wait_time_us) max_wait
FROM oceanbase.__all_virtual_ash
WHERE event_ = 'WAIT_EVENT_IO_DATA'
  AND sample_time > NOW() - INTERVAL 1 MINUTE
GROUP BY sql_id_
ORDER BY max_wait DESC
LIMIT 10;
```

### 3.6 关联到执行计划

```sql
-- 拿 sql_id 的执行计划
SELECT plan_id_, plan_info_
FROM oceanbase.__all_virtual_plan_cache
WHERE sql_id_ = '<your_sql_id>';
```

---

## 4. Alert 引擎

### 4.1 告警规则

```sql
-- 创建告警规则
CREATE ALERT alert_slow_query
  ON __all_virtual_slow_query
  EVALUATE EVERY 1 MINUTE
  IF COUNT(*) WHERE exec_time > 5000000 > 10  -- 1s+,超过 10 次/分
  FOR 3 MINUTES                            -- 持续 3 分钟
  SEVERITY WARNING
  NOTIFY CHANNELS ('email', 'webhook');
```

### 4.2 告警规则结构

```cpp
// src/share/alert/ob_alert_rule.h:80
class ObAlertRule {
public:
  // 1. 规则名
  std::string rule_name_;

  // 2. 数据源(内部表)
  std::string source_table_;

  // 3. 触发条件
  std::string condition_;       // SQL WHERE 子句
  int64_t threshold_;            // 阈值
  std::string aggregate_;        // COUNT / AVG / MAX

  // 4. 评估周期
  int64_t evaluate_interval_s_; // 每 N 秒评估
  int64_t for_duration_s_;      // 持续 N 秒

  // 5. 严重程度
  enum Severity { INFO, WARNING, CRITICAL };
  Severity severity_;

  // 6. 通知渠道
  std::vector<ObNotifyChannel> channels_;
};
```

### 4.3 告警评估

```cpp
// src/share/alert/ob_alert_engine.cpp:100
class ObAlertEngine {
public:
  // 每分钟评估所有启用规则
  void evaluate_all_rules() {
    for (auto &rule : enabled_rules_) {
      // 1. 跑条件 SQL
      std::string query = "SELECT " + rule.aggregate_ + 
                          "(*) FROM " + rule.source_table_ +
                          " WHERE " + rule.condition_;
      auto result = exec_internal_sql(query);
      // 2. 比阈值
      if (result.value > rule.threshold_) {
        // 3. 持续时间检查
        if (++rule.consecutive_trigger_count_ * 
            rule.evaluate_interval_s_ >= rule.for_duration_s_) {
          // 4. 触发告警
          trigger_alert(rule, result.value);
        }
      } else {
        rule.consecutive_trigger_count_ = 0;  // 重置
      }
    }
  }
};
```

### 4.4 严重程度

```sql
-- 严重级别(由低到高)
SEVERITY INFO      -- 信息,无需处理
SEVERITY WARNING   -- 警告,需要关注
SEVERITY CRITICAL  -- 严重,需要立即处理
```

### 4.5 通知渠道

```cpp
// src/share/alert/ob_notify_channel.h:50
enum ObNotifyChannel {
  // 1. 邮件
  NOTIFY_EMAIL,

  // 2. 短信
  NOTIFY_SMS,

  // 3. Webhook (企业微信 / 钉钉 / Slack)
  NOTIFY_WEBHOOK,

  // 4. 系统表 (供其他系统轮询)
  NOTIFY_SYS_TABLE,
};

// 配置邮件
ALTER SYSTEM SET alert_email_smtp = 'smtp.example.com:587';
ALTER SYSTEM SET alert_email_to = 'ops@example.com';
```

### 4.6 告警去重

```cpp
// 同一告警在去重窗口内只发一次
class ObAlertDedup {
public:
  bool should_send(ObAlertRecord &record) {
    auto key = make_key(record.rule_name_, record.target_);
    auto last_sent = dedup_map_.get(key);
    if (last_sent && now() - last_sent < dedup_window_s_) {
      return false;  // 去重窗口内不发
    }
    dedup_map_.put(key, now());
    return true;
  }
};
```

---

## 5. 内置告警

OB 默认提供常见告警:

### 5.1 资源类

| 告警 | 阈值(默认) |
|------|------------|
| CPU 使用率 > 80% | WARNING |
| 内存使用率 > 90% | CRITICAL |
| 磁盘使用率 > 85% | WARNING |
| 磁盘使用率 > 95% | CRITICAL |

### 5.2 性能类

| 告警 | 阈值(默认) |
|------|------------|
| Slow query 数量 > 100/min | WARNING |
| QPS 突降 50% | WARNING |
| P99 延迟 > 1s | WARNING |

### 5.3 HA 类

| 告警 | 阈值 |
|------|------|
| 主备延迟 > 30s | WARNING |
| 副本失联 | CRITICAL |
| Failover 发生 | INFO |
| Backup 失败 | CRITICAL |

### 5.4 错误类

| 告警 | 阈值 |
|------|------|
| RPC 失败率 > 5% | WARNING |
| Lock timeout > 10/min | WARNING |
| Log disk full | CRITICAL |

---

## 6. 自定义告警

### 6.1 通过 SQL 表达式

```sql
-- 自定义告警:某 tenant 的 QPS 突降
CREATE ALERT alert_tenant_qps_drop
  ON __all_virtual_tenant_stat
  EVALUATE EVERY 1 MINUTE
  IF (cpu_used_ / cpu_limit_) > 0.9  -- CPU > 90%
  FOR 5 MINUTES
  SEVERITY WARNING
  NOTIFY CHANNELS ('webhook');
```

### 6.2 通过存储过程

```cpp
// src/share/alert/ob_alert_procedure.cpp:50
// 用户定义告警逻辑
class ObCustomAlertProc {
public:
  void run() {
    // 用户自定义逻辑
    if (some_condition()) {
      ObAlertRecord record;
      record.severity_ = WARNING;
      record.message_ = "Custom alert triggered";
      trigger(record);
    }
  }
};
```

### 6.3 抑制规则

```sql
-- 抑制规则:某些告警互斥(避免重复报警)
CREATE ALERT_SUPPRESS suppress_failover_during_backup
  IF alert_id_ IN ('alert_failover', 'alert_replica_lost')
  AND backup_running_ = true
  FOR 1 HOUR;  -- backup 期间不报 failover 告警
```

---

## 7. Dashboard 设计

### 7.1 Grafana 集成

OB 通过 Prometheus exporter 暴露 metrics:

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'oceanbase'
    static_configs:
      - targets: ['observer1:9090', 'observer2:9090']
    metrics_path: /metrics
```

### 7.2 关键面板

```
1. Cluster Overview Panel
   - 总 CPU / 内存 / 磁盘使用率
   - 总 QPS / 慢查询率
   - 主备延迟
   - 告警数量(按严重程度)

2. Tenant Panel
   - 各 tenant 的 CPU / 内存 / QPS
   - 各 tenant 的慢查询排行

3. Query Performance Panel
   - P50 / P99 延迟
   - Slow query 数量(按时间)
   - Top 10 慢 query

4. Storage Panel
   - MemTable 内存使用
   - Block Cache 命中率
   - Clog 写入延迟
   - SSTable 数量

5. HA Panel
   - 副本同步状态
   - Failover 事件
   - Backup 状态
```

### 7.3 关键指标公式

```promql
# QPS(query per second)
rate(ob_query_count_total[1m])

# P99 延迟
histogram_quantile(0.99, rate(ob_query_latency_us_bucket[5m]))

# 慢查询率
rate(ob_slow_query_count_total[5m]) / rate(ob_query_count_total[5m])

# Block Cache 命中率
rate(ob_block_cache_hit_total[5m]) / 
  (rate(ob_block_cache_hit_total[5m]) + rate(ob_block_cache_miss_total[5m]))
```

---

## 8. 监控的性能开销

### 8.1 Metrics 开销

```
单次 inc(): ~100ns(原子操作)
每秒 100K inc: ~10ms CPU 占用
```

可忽略,除非指标特别多。

### 8.2 ASH 开销

```
每秒扫所有 active session
  N session × ~1μs = N μs/秒
10K session × 1μs = 10ms/秒
```

可忽略。

### 8.3 Alert 开销

```
每分钟评估所有规则
  M rules × query_time
默认 50 rules × 10ms = 500ms/分钟
```

可忽略。

### 8.4 监控数据存储

```
内部 __all_virtual_metric 表:
  每 60s 刷盘 → ~10KB/分钟/OBServer
  1 天 ~ 14MB
  自动清理 7 天前(默认)
```

占用磁盘空间小。

---

## 9. 调优 Checklist

```
□ 关键 metrics 是否都记录?(query / txn / storage / clog)
□ ASH 采样间隔是否合理?(默认 1s,够细)
□ 告警规则是否覆盖常见故障?(资源 / 性能 / HA / 错误)
□ 告警阈值是否合理?(避免误报 / 漏报)
□ 告警通知渠道是否正常?(邮件 / 短信 / webhook)
□ 告警去重窗口是否合适?(默认 5min)
□ Grafana dashboard 是否覆盖关键指标?
□ 监控的存储开销是否合理?(自动清理 + 磁盘空间)
□ 监控自身的可用性?(监控挂了怎么发现 → meta-monitor)
```

---

## 10. 常见故障的告警 case

### 10.1 Slow query 突增

```
告警触发:alert_slow_query 触发
排查步骤:
  1. 查 __all_virtual_slow_query → 找 top 慢 query
  2. EXPLAIN 慢 query → 看 CBO 选择
  3. ANALYZE TABLE → 重收 stats
  4. 加 covering index → 修
```

### 10.2 主备延迟

```
告警触发:alert_replica_lag 触发
排查步骤:
  1. 查 ASH 看主备网络流量
  2. 查 __all_virtual_clog_stat → 看 Clog 写入延迟
  3. 查备机 CPU / IO 是否过载
  4. 修法:加带宽 / 减主写压力 / 升备机配置
```

### 10.3 内存爆满

```
告警触发:alert_memory_high 触发
排查步骤:
  1. 查 __all_virtual_tenant_stat → 找哪个 tenant
  2. 查 __all_virtual_memtable → 看 MemTable 大小
  3. 触发 minor freeze → 释放内存
  4. 修法:调 freeze 阈值 / 限写 / 加内存
```

---

## 11. v2 subseries 收官回顾

#14 v2 → #15 v2 → #16 v2 → #17 v2 → #18 v2 → #41 v2 → #51 v2 → #29 v2
→ #22 v2 → #11 v2 → #21 v2 → #24 v2 → #26 v2 → #33 v2 → #28 v2 → #19 
v2 → #20 v2 → #27 v2 → **#30 v2 (本文)** 是 OB **storage / index / CBO / 
join / cache / 调优 / 日志 / 事务 / schema / 并行 / HA / 容灾 / 多租户 / 
parser / compaction / RPC / 监控** 全主线:

| # | 主题 | 抽象层 | 关键 insight |
|---|------|--------|--------------|
| #14 v2 | MemTable Internals | 内存层 | key encoding + 跨结构事务边界 |
| #15 v2 | ObKeyBTree | B-tree 实现 | skiplist-like + MVCC 集成 |
| #16 v2 | ObKeyBTree | hash 实现 | 等值查询优化 + GC 集成 |
| #17 v2 | Query Optimizer | CBO 层 | cost model + join ordering + 谓词下推 |
| #18 v2 | Index Design | 索引系统 | clustered/secondary/functional + CBO 选择 |
| #41 v2 | Join Operators | 执行层 | NL/Hash/Merge + Hybrid Grace + Bloom RF + PX/DAS |
| #51 v2 | Block Cache | IO 层 | 三层 cache + LRU 变体 + bloom filter + DIO |
| #29 v2 | Slow Query | 运维层 | 捕获 + 分析 + 推荐 + 调优 |
| #22 v2 | Clog / Redo Log | 持久化层 | WAL + group commit + replica + recovery |
| #11 v2 | Trans Service / Lock | 事务层 | 全局事务 ID + 行锁 + 2PC + 死锁 + SI |
| #21 v2 | Schema / DDL | 元数据层 | schema_version + INSTANT/INPLACE + Online DDL |
| #24 v2 | PX Framework | 并行层 | Worker Pool + Task 调度 + Data Exchange + DAS |
| #26 v2 | Primary / Standby | HA 层 | Paxos + 选主 + failover + 副本同步 |
| #33 v2 | Backup / Recovery | 容灾层 | 全量+增量+archive log + PIT + 容灾策略 |
| #28 v2 | Resource / Unit / Tenant | 多租户层 | 3 层模型 + 隔离机制 + 资源调度 |
| #19 v2 | SQL Parser | 前端层 | Lexer + Parser + Resolver + Type Check + Fingerprint |
| #20 v2 | Compaction Strategy | 存储维护层 | Minor Freeze + Major Freeze + History Merge |
| #27 v2 | RPC / obrpc | 网络层 | 序列化 + 路由 + 重试 + epoll/io_uring |
| **#30 v2 (本文)** | **Monitoring / Alerting** | **可观测层** | **Metrics + ASH + Alert + Dashboard** |

十九篇连起来,读者能完整理解 OB 的"开发 → 运维"全链路:

- 开发层:#14-#24 (storage/index/optimizer/join/PX)
- 持久层:#22 (Clog) + #20 (Compaction)
- 事务层:#11 (Trans Service)
- 元数据:#21 (Schema)
- 多租户:#28 (Tenant)
- HA + DR:#26 + #33
- 网络:#27 (RPC)
- 运维:#29 (Slow Query) + #30 (本文:监控告警)

---

## 12. 下一篇预告

按 #1-#100 原系列顺序,接下来选项:

- **Partition Management** — rebalance / migration(接 #26)
- **Storage Engine Internals** — SSTable / macro_block / micro_block 深入(接 #51)
- **SQL Engine Entry** — 接收 / 派发 / 路由(接 #19 + #24)
- **#31-#40 / #42-#100 系列**（待确认具体编号）

继续哪一篇?

---

## 13. 参考(可执行的源码锚点)

- `src/share/ob_log_stat.h` — Metrics 接口
- `src/share/monitor/ash/ob_ash.cpp` — ASH 采样器
- `src/share/monitor/ash/ob_ash.h` — ASH 数据结构
- `src/share/monitor/ash/ob_wait_event.h` — 等待事件分类
- `src/share/alert/ob_alert_engine.cpp` — 告警引擎
- `src/share/alert/ob_alert_rule.h` — 告警规则
- `src/share/alert/ob_notify_channel.h` — 通知渠道
- `src/share/alert/ob_alert_procedure.cpp` — 自定义告警
- `src/share/backup/ob_metric.h` — 监控指标定义
- `src/share/backup/ob_ash_stat.h` — ASH 监控

---

#30 v2 完。