# OceanBase 70:30 高 QPS 写入优化方案

> 场景: 40GB 租户, 70% 读 30% 写, CPU 打满, freeze 耗时 60s+, 出现写限流
> OB 4.2.5.6

---

## 阶段一：免重启应急（5 分钟见效）

```sql
-- 1. 提前触发 freeze, 缓解当前 memstore 压力
ALTER SYSTEM MINOR FREEZE;

-- 2. 调低 freeze_trigger, 提前开始冻结, 增加安全窗口
--    当前 80% → 降到 50~60%
--    原理: freeze 越早开始, 在撞 throttling 之前能 flush 的数据越多
ALTER SYSTEM SET freeze_trigger_percentage = 55;
ALTER SYSTEM SET writing_throttling_trigger_percentage = 100;  -- 放开限流

-- 3. 给 memstore 更多空间
ALTER SYSTEM SET memstore_limit_percentage = 70;

-- 4. 减少 compaction CPU 开销: 降低合并并行度
ALTER SYSTEM SET minor_merge_concurrency = 2;  -- 如果默认 > 2
ALTER SYSTEM SET compaction_low_thread_score = 1;
```

**验证效果：**
```sql
SELECT ROUND(TOTAL_MEMSTORE_USED / MEMSTORE_LIMIT * 100, 1) AS memstore_pct,
       ROUND(ACTIVE_MEMSTORE_USED / 1024 / 1024, 1) AS active_mb,
       ROUND(TOTAL_MEMSTORE_USED / 1024 / 1024, 1) AS total_mb,
       ROUND(MEMSTORE_LIMIT / 1024 / 1024, 1) AS limit_mb
FROM oceanbase.GV$OB_MEMSTORE
WHERE TENANT_ID = <your_tenant_id>;

-- 5 分钟后看 throttle 是否消失
SELECT COUNT(*) FROM oceanbase.GV$OB_SQL_AUDIT
WHERE ret_code = -4038
  AND request_time > DATE_SUB(NOW(), INTERVAL 1 MINUTE);
```

---

## 阶段二：cgroup 隔离（需要 root 权限 + 重启）

### 2.1 准备工作

**宿主机确认：**
```bash
# 检查 cgroup v1 是否挂载
mount | grep cgroup
# 应该看到 /sys/fs/cgroup/cpu,cpuacct

# 检查 OB 进程已经加入 cgroup
cat /sys/fs/cgroup/cpu/oceanbase/tasks | grep `pidof observer` | wc -l
```

**OB 配置：**
```sql
-- 启用全局后台资源隔离
ALTER SYSTEM SET enable_global_background_resource_isolation = true;
-- 设置后台 CPU 配额 (占物理 CPU 的百分比, 例如 70%)
ALTER SYSTEM SET global_background_cpu_quota = 70;
```

> ⚠️ `enable_global_background_resource_isolation` 需要重启 observer 生效。建议窗口期操作。

### 2.2 用 DBMS_RESOURCE_MANAGER 做精细隔离

```sql
-- 创建资源组: SQL 高优先级, compaction 低优先级
BEGIN
  DBMS_RESOURCE_MANAGER.CREATE_PLAN(
    PLAN    => 'OLTP_PLAN',
    COMMENT => '70:30 workload plan'
  );
  
  -- 组1: 在线业务 SQL -> CPU 权重高
  DBMS_RESOURCE_MANAGER.CREATE_GROUP(
    GROUP_ID => 1001,
    GROUP_NAME => 'OLTP_HIGH',
    COMMENT    => 'Online transaction queries',
    MGMT_MTH  => 'cpu',
    CPU_WEIGHT => 7   -- 权重 7 (70%)
  );
  
  -- 组2: 后台/大查询 -> CPU 权重低
  DBMS_RESOURCE_MANAGER.CREATE_GROUP(
    GROUP_ID => 1002,
    GROUP_NAME => 'BATCH_LOW',
    COMMENT    => 'Batch and background',
    MGMT_MTH  => 'cpu',
    CPU_WEIGHT => 3   -- 权重 3 (30%)
  );
  
  -- 分配: 业务用户 → 高优组
  DBMS_RESOURCE_MANAGER.SET_CONSUMER_GROUP(
    USER => 'app_user',
    GROUP => 'OLTP_HIGH'
  );
  
  -- 激活计划
  DBMS_RESOURCE_MANAGER.SWITCH_PLAN('OLTP_PLAN');
END;
/
```

### 2.3 验证 cgroup 生效

```sql
-- 查看当前 resource plan
SHOW VARIABLES LIKE 'resource_manager_plan';

-- 看各组的 CPU 使用
SELECT * FROM oceanbase.GV$OB_CGROUP_CONFIG;
```

---

## 阶段三：Deep Dive SQL 诊断

```sql
-- 1. 定位最吃 CPU 的 SQL
SELECT SQL_ID, 
       ROUND(AVG(ELAPSED_TIME) / 1000, 1) AS avg_ms,
       COUNT(*) AS executions,
       ROUND(SUM(ELAPSED_TIME) / 1000000, 1) AS total_cpu_sec
FROM oceanbase.GV$OB_SQL_AUDIT
WHERE request_time > DATE_SUB(NOW(), INTERVAL 5 MINUTE)
  AND TENANT_ID = <your_tenant_id>
GROUP BY SQL_ID
ORDER BY total_cpu_sec DESC
LIMIT 10;

-- 2. 看写入量大的 SQL
SELECT SQL_ID, 
       ROUND(AVG(ROW_COUNT), 1) AS avg_rows,
       ROUND(AVG(ELAPSED_TIME) / 1000, 1) AS avg_ms,
       COUNT(*) AS executions
FROM oceanbase.GV$OB_SQL_AUDIT
WHERE request_time > DATE_SUB(NOW(), INTERVAL 5 MINUTE)
  AND TENANT_ID = <your_tenant_id>
  AND IS_EXECUTOR_RPC = 0
  AND (LOWER(QUERY_SQL) LIKE 'insert%' OR LOWER(QUERY_SQL) LIKE 'update%' OR LOWER(QUERY_SQL) LIKE 'delete%')
GROUP BY SQL_ID
ORDER BY executions DESC
LIMIT 10;

-- 3. 检查合并进度
SELECT * FROM oceanbase.GV$OB_COMPACTION_PROGRESS
WHERE STATUS IN ('COMPACTING', 'SCHEDULING');

-- 4. 看 Memstore 限流详情
SELECT * FROM oceanbase.__all_virtual_memstore_throttle
WHERE TENANT_ID = <your_tenant_id>;

-- 5. 当前参数审计
SELECT NAME, VALUE
FROM oceanbase.__all_tenant_parameter
WHERE TENANT_ID = <your_tenant_id>
  AND NAME IN ('freeze_trigger_percentage',
               'writing_throttling_trigger_percentage',
               'memstore_limit_percentage',
               'minor_merge_concurrency',
               'cpu_quota_concurrency',
               'compaction_low_thread_score');
```

---

## 阶段四：自适应脚本部署

```bash
# 在前面给的 adaptive_tuner.py 基础上, 启动守护模式
python3 adaptive_tuner.py \
  -H 127.0.0.1 -P 2881 -u root@sys \
  -T <your_tenant_id> \
  --daemon --interval 15 \
  --state-file /tmp/ob_tuner.json

# 先用 dry-run 试跑
python3 adaptive_tuner.py \
  -H 127.0.0.1 -P 2881 -u root@sys \
  -T <your_tenant_id> \
  --daemon --dry-run
```

---

## 完整参数建议汇总

| 参数 | 当前(推测) | 建议 | 原理 |
|------|-----------|------|------|
| `freeze_trigger_percentage` | 80 | **50~60** | 提前触发 freeze, 给 throttling 留足 buffer |
| `writing_throttling_trigger_percentage` | 90 | **100** | 不主动限流, 让自适应 tuner 处理 |
| `memstore_limit_percentage` | 60 | **70~80** | 30% 写入需要更大的 memstore 空间 |
| `minor_merge_concurrency` | 默认 | **2~4** | 降低 compaction 的 CPU 争抢 |
| `compaction_low_thread_score` | 默认 | **1** | 降低 compaction 线程优先级 |
| `cpu_quota_concurrency` | 4 | **4~8** | 控制并发度, CPU 满载时不要太高 |
| `enable_global_background_resource_isolation` | false | **true** | 需要重启, 给 compaction 设置 CPU 上限 |
| `global_background_cpu_quota` | - | **70** | compaction 最多用 70% CPU |
| `resource_manager_plan` | - | **OLTP_PLAN** | 细粒度 SQL vs 后台分组隔离 |

---

## 什么时候该做什么

```
QPS 回落 + 不限流
    │
    ├── 仅调 freeze_trigger ✓
    │    → 阶段一足够
    │
    ├── 限流但 CPU 没满 ✓
    │    → 阶段一 + 调高 memstore_limit
    │
    └── 限流 + CPU 打满 ✓
         → 阶段一 + 阶段二(cgroup) ← 你在这里
         → 后续阶段三诊断, 阶段四自动化
```

**核心：cgroup 是打破 CPU 满载下 LSM-Tree 自锁的关键。没有它，不管怎么调 freeze_trigger，compaction 和 SQL 都在抢 CPU，最终还是会逼近 throttling。**
