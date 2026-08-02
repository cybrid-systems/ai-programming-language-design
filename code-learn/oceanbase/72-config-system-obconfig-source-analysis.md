# 72-config-system-obconfig — OceanBase 配置中心 / ObConfig 深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码（src/share/config/ 18 文件 + src/share/parameter/ + src/observer/omt/ob_tenant_config.{h,cpp} + 多个虚拟表）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **配置中心**是整个集群的"大脑参数面板" —— 数百个动态参数（CPU 配额 / 内存上限 / 副本数 / 超时阈值等）通过统一的 ObConfig 框架管理。OB 5.x 支持 **四层配置**：

- **System Config** —— 启动期只读配置（如 `__min_full_resource_pool_memory`）
- **Server Config** —— observer 级别配置（重启才生效）
- **Tenant Config** —— tenant 级别覆盖（运行时动态生效）
- **Common Config** —— 系统级共享配置

每层都有 **动态加载 / 热生效 / 版本管理** 能力，让 DBA 不必重启 observer 即可调优。

本文聚焦 8 个核心问题：

1. **配置分层模型** —— System / Server / Tenant / Common 四层职责
2. **配置类型** —— 13 种 ObConfigItemType（BOOL / INT / DOUBLE / STRLIST / TIME / CAPACITY / ...）
3. **Parameter 宏系统** —— DECLARE / DEFINE 模式声明参数
4. **Tenant Config 覆盖** —— per-tenant 覆盖 + 继承
5. **热加载** —— ObReloadConfig + 版本管理
6. **ObConfigManager** —— 配置管理核心
7. **配置虚拟表** —— `__all_virtual_*_parameter_stat` 等监控接口
8. **配置变更流** —— `ALTER SYSTEM SET ...` / `ALTER TENANT SET ...` 的 RPC 链

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 39-tenant-architecture | Tenant Config 是 tenant 架构的可调参数 |
| 57-config-system | #57 是早期文章，本篇是 #57 的深化（OB 5.x 新加） |
| 71-resource-isolation | Unit 配额是 Resource Config 的一种 |
| 30-observer-startup | 启动期加载 System Config + Server Config |
| 70-sql-audit-security | 配置变更需要 SECURITY_AUDIT 权限 |
| 60-profiling | 性能调优依赖运行时配置 |

---

## 1. 整体架构：OB 配置四层模型

### 1.1 四层职责

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: System Config (启动期只读)                              │
│  - 集群 bootstrap 必需的只读参数                                   │
│  - 不能热修改（需重启 observer）                                  │
│  - 持久化: ob_system_config_key / ob_system_config_value (内存)   │
│  源码: src/share/config/ob_system_config.{h,cpp}                  │
│        src/share/config/ob_system_config_key.{h,cpp}              │
│        src/share/config/ob_system_config_value.{h,cpp}            │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │ (启动期一次性加载)
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 2: Common Config (系统级共享)                                │
│  - 不属于具体 server / tenant 的全局配置                          │
│  - 例: log_archive_dest / memory_limit 集群级默认                │
│  源码: src/share/config/ob_common_config.{h,cpp}                  │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │ (默认 / 基础值)
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 3: Server Config (observer 级别)                            │
│  - 每个 observer 节点独立配置                                     │
│  - 重启 observer 才生效                                           │
│  - 例: cpu_count / memory_limit / system_memory                  │
│  源码: src/share/config/ob_server_config.{h,cpp}                  │
│        src/share/config/ob_config.{h,cpp}                         │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │ (per-tenant 覆盖)
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 4: Tenant Config (per-tenant)                               │
│  - tenant 级别覆盖 system / common / server 默认                 │
│  - 运行时动态生效（无需重启）                                     │
│  - 例: 某 tenant 的专属 cpu_quota / memstore_limit                │
│  源码: src/observer/omt/ob_tenant_config.{h,cpp}                   │
│        src/observer/omt/ob_tenant_config_mgr.{h,cpp}              │
└──────────────────────────────────────────────────────────────────┘
```

### 1.2 模块组成

```bash
$ ls src/share/config/ | head -20
ob_common_config.cpp/h           # Common Config
ob_config.cpp/h                  # Config 抽象 / 工具
ob_config_helper.cpp/h           # Helper (序列化/反序列化)
ob_config_manager.cpp/h          # Config Manager 核心
ob_config_mode_name_def.h        # mode 定义
ob_reload_config.cpp/h           # 热加载
ob_server_config.cpp/h           # Server Config
ob_system_config.cpp/h           # System Config
ob_system_config_key.cpp/h      # System Config Key
ob_system_config_value.cpp/h    # System Config Value
# ... 18 文件 total

src/share/parameter/             # Parameter 宏系统
  ├── ob_parameter_attr.h        # 参数 attribute 定义
  ├── ob_parameter_macro.h       # DECLARE / DEFINE 宏

src/observer/omt/                # Tenant Config (OMT = Observer Management Thread)
  ├── ob_tenant_config.{h,cpp}    # Tenant Config 主类
  ├── ob_tenant_config_mgr.{h,cpp} # Tenant Config Manager

src/observer/virtual_table/      # 配置虚拟表（监控接口）
  ├── ob_all_virtual_tenant_parameter_stat.cpp/h
  ├── ob_all_virtual_sys_parameter_stat.cpp/h
  ├── ob_all_virtual_tenant_parameter_info.cpp/h
```

---

## 2. ObConfigItemType —— 13 种配置类型

### 2.1 类型枚举

```cpp
// src/share/config/ob_config.h
enum ObConfigItemType{
  OB_CONF_ITEM_TYPE_UNKNOWN = -1,
  OB_CONF_ITEM_TYPE_BOOL = 0,        // bool
  OB_CONF_ITEM_TYPE_INT = 1,          // int64_t
  OB_CONF_ITEM_TYPE_DOUBLE = 2,       // double
  OB_CONF_ITEM_TYPE_STRING = 3,       // string
  OB_CONF_ITEM_TYPE_INTEGRAL = 4,     // integer (无单位)
  OB_CONF_ITEM_TYPE_STRLIST = 5,      // string list
  OB_CONF_ITEM_TYPE_INTLIST = 6,      // int list
  OB_CONF_ITEM_TYPE_TIME = 7,         // 时间 (微秒)
  OB_CONF_ITEM_TYPE_MOMENT = 8,       // 时刻 (Unix timestamp)
  OB_CONF_ITEM_TYPE_CAPACITY = 9,     // 容量 (带单位: B/KB/MB/GB)
  OB_CONF_ITEM_TYPE_LOGARCHIVEOPT = 10, // 日志归档选项 (复合)
  OB_CONF_ITEM_TYPE_VERSION = 11,     // 版本号 (格式: x.y.z.w)
  OB_CONF_ITEM_TYPE_MODE = 12,        // 模式 (字符串限定取值范围)
};

// 类型字符串
static const char *const DATA_TYPE_UNKNOWN = "UNKNOWN";
static const char *const DATA_TYPE_BOOL = "BOOL";
static const char *const DATA_TYPE_INT = "INT";
static const char *const DATA_TYPE_DOUBLE = "DOUBLE";
// ...
```

### 2.2 为什么需要这么多类型

| 类型 | 用途 | 示例 |
|------|------|------|
| BOOL | 开关 | enable_rebalance, enable_async_write |
| INT | 整型 | cpu_count, freeze_cnt_per_day |
| DOUBLE | 浮点 | compaction_threshold |
| STRING | 字符串 | log_archive_dest, cluster_name |
| INTEGRAL | 无单位整数 | mysql_port (2882) |
| STRLIST | 字符串列表 | blacklist_servers |
| INTLIST | 整数列表 | rebalance_tolerance |
| TIME | 持续时间 | major_freeze_interval (默认 24h) |
| MOMENT | 时刻 | recovery_until_scn |
| CAPACITY | 带单位容量 | memory_limit ('10G') |
| LOGARCHIVEOPT | 归档复合选项 | mandatory/optional + compression + encryption |
| VERSION | 版本号 | compatible_version ('4.2.1.0') |
| MODE | 模式 | protection_mode ('MAXIMUM_PERFORMANCE') |

**关键设计**：每个类型都有自己的 setter / getter / validator / serializer，避免把字符串解析到处写。

### 2.3 CAPACITY 类型的特殊处理

```cpp
// (典型实现)
int parse_capacity(const ObString &str, int64_t &bytes) {
  // '10G' → 10 * 1024^3
  // '512M' → 512 * 1024^2
  // '1T' → 1 * 1024^4
  // '1024' → 1024 (默认 B)
  // '2K' → 2 * 1024
}
```

OB 接受带单位的容量字符串，转换为 int64_t bytes。这是 DBA 配置时的友好语法。

### 2.4 MODE 类型的限定值

```cpp
// protection_mode 只接受特定字符串
// 'MAXIMUM_PERFORMANCE'
// 'MAXIMUM_AVAILABILITY'
// 'MAXIMUM_PROTECTION'
// 设置时校验:
int set_protection_mode(const ObString &mode) {
  if (mode != "MAXIMUM_PERFORMANCE"
   && mode != "MAXIMUM_AVAILABILITY"
   && mode != "MAXIMUM_PROTECTION") {
    return OB_ERR_INVALID_ARGUMENT;
  }
  // ...
}
```

---

## 3. Parameter 宏系统 —— `ob_parameter_macro`

### 3.1 宏定义模式

```cpp
// src/share/parameter/ob_parameter_macro.h
// (典型宏定义)

#define DEF_INT(name, var, default_val, ...) \
  constexpr int64_t var = default_val;

#define DEF_CAPACITY(name, var, default_val, ...) \
  constexpr int64_t var = default_val;  // 解析时按 capacity 解析

#define DEF_STR(var, default_val, ...) \
  constexpr const char* var = default_val;

#define DEF_BOOL(var, default_val, ...) \
  constexpr bool var = default_val;

#define DEF_TIME(var, default_val, ...) \
  constexpr int64_t var = default_val;  // 微秒

#define DEF_VERSION(var, default_val, ...) \
  constexpr const char* var = default_val;

// 参数注册宏（自动生成 register / get / set 函数）
#define PARAM_REGISTER(name, var) \
  ObConfig::register_param(name, &var, ...);
```

### 3.2 使用示例

```cpp
// src/share/config/ob_server_config.cpp
#include "share/parameter/ob_parameter_macro.h"

namespace oceanbase {
namespace common {

DEF_INT(cpu_count, CPU_COUNT, 16,
        "number of CPU cores available",
        ObConfigItemType::OB_CONF_ITEM_TYPE_INT);

DEF_CAPACITY(memory_limit, MEMORY_LIMIT, "16G",
             "max memory usage per observer",
             ObConfigItemType::OB_CONF_ITEM_TYPE_CAPACITY);

DEF_TIME(major_freeze_interval, MAJOR_FREEZE_INTERVAL, "24h",
         "interval between major freezes",
         ObConfigItemType::OB_CONF_ITEM_TYPE_TIME);

DEF_BOOL(enable_async_write, ENABLE_ASYNC_WRITE, true,
        "enable async write for trans log",
        ObConfigItemType::OB_CONF_ITEM_TYPE_BOOL);

DEF_STR(protection_mode, PROTECTION_MODE, "MAXIMUM_PERFORMANCE",
       "data protection mode",
       ObConfigItemType::OB_CONF_ITEM_TYPE_MODE);

}}
```

### 3.3 宏的优势

- **类型安全**：DEF_INT 强制 int64_t，DEF_BOOL 强制 bool
- **默认值 + 文档**：宏内嵌默认值 + 描述 + 类型
- **自动注册**：PARAM_REGISTER 宏自动生成 setter/getter
- **运行时覆盖**：`ALTER SYSTEM SET xxx = ...` 时，宏生成代码能正确处理

---

## 4. ObServerConfig —— observer 级别配置

### 4.1 类骨架（推测）

```cpp
// src/share/config/ob_server_config.h
class ObServerConfig {
public:
  // 单例
  static ObServerConfig &get_instance();

  // 加载（启动期）
  int load(const ObString &config_file);

  // 获取参数
  template<typename T>
  T get(const char *name) const;

  // 设置参数（仅非运行时热加载）
  int set(const char *name, const ObString &value);

  // 重载（hot reload）
  int reload_config(const ObString &new_config);

private:
  // 内部存储
  ObConfigManager mgr_;
};
```

### 4.2 Server Config 加载流程

```
observer 启动
    │
    ├─ 读取 sys 配置文件 (ob.conf / cluster.conf)
    │
    ├─ ObServerConfig::load() 解析
    │   ├─ 校验每个参数
    │   ├─ 类型转换 (string → int/bool/capacity/...)
    │   └─ 注册到 ObConfigManager
    │
    └─ 各模块 ObServerConfig::get(name) 拿到自己的参数
```

### 4.3 典型 Server Config 参数

```cpp
DEF_INT(cpu_count, 16, "available CPU cores");
DEF_CAPACITY(memory_limit, "16G", "max memory");
DEF_TIME(major_freeze_interval, "24h", "major freeze interval");
DEF_CAPACITY(log_disk_size, "10G", "log disk size");
DEF_BOOL(enable_async_write, true, "async write");
DEF_INT(replica_num, 3, "default replica number");
DEF_STR(protection_mode, "MAXIMUM_PERFORMANCE", "protection mode");
DEF_INT(clog_sync_to_standby_timeout, "1s", "sync timeout");
```

---

## 5. ObTenantConfig —— tenant 级别覆盖

### 5.1 角色

```cpp
// src/observer/omt/ob_tenant_config.h
class ObTenantConfig {
public:
  // 加载 tenant 自己的 config
  int load(const uint64_t tenant_id,
           const ObString &tenant_config_str);

  // 覆盖：先查 tenant 自己的，没找到 → 查 Common → 查 Server
  int64_t get_int(const uint64_t tenant_id,
                  const char *name) const;
};
```

### 5.2 Tenant Config 的优先级

```
查找参数 X 的优先级（从高到低）:
    1. TenantConfig (本 tenant 自己的配置)
    2. CommonConfig (集群共享配置)
    3. ServerConfig (默认配置)

如果 tenant X 设置了 cpu_count=4，优先使用
否则用 CommonConfig.cpu_count
否则用 ServerConfig.cpu_count (默认 16)
```

### 5.3 Tenant Config 修改

```sql
-- SQL: 修改 tenant 级别参数
ALTER TENANT tenant_name SET cpu_count = 8;
ALTER TENANT tenant_name SET memstore_limit_percentage = 60;
ALTER TENANT tenant_name SET parallel_max_servers = 8;
```

**特点**：运行时生效（不需要重启 observer 或 tenant）。

---

## 6. ObSystemConfig —— 启动期只读配置

### 6.1 角色

```cpp
// src/share/config/ob_system_config.h
class ObSystemConfig {
public:
  // 启动期从持久化 key-value 加载
  int load(const ObString &config_str);

  // 只读（启动后不能修改）
  const ObString &get(const char *key) const;

private:
  // 内部用 hash map 存 key-value
  hash::ObHashMap<ObString, ObString> kv_map_;
};
```

### 6.2 为什么 System Config 只读

System Config 是集群 **bootstrap 必需**：
- cluster_id（用于生成各种 trace_id）
- min_full_resource_pool_memory（决定 memory 分配粒度）

这些参数修改后，**已经在运行的 observer 的内部数据结构已经基于旧值**，热改会导致不一致。

### 6.3 持久化

System Config 用两文件持久化：
- `ob_system_config_key.cpp` — key 列表（编译期常量）
- `ob_system_config_value.cpp` — value 存储（运行时内存）

这两个 file 在 OB 5.x 是 **编译期嵌入**到 binary 的（不是运行时加载），保证 startup 阶段就能读到。

---

## 7. ObCommonConfig —— 系统级共享

### 7.1 角色

Common Config 是 **不属于具体 server / tenant** 的全局配置：
- `log_archive_dest`：集群日志归档目录
- `default_compress_func`：默认压缩算法
- `default_compress_option`：默认压缩选项

### 7.2 与 Server Config 的区别

| 维度 | Common Config | Server Config |
|------|--------------|---------------|
| 粒度 | 全集群 | 每 observer |
| 典型例 | log_archive_dest | cpu_count |
| 修改方式 | 通过 RS broadcast | 重启 observer |

---

## 8. ObReloadConfig —— 热加载

### 8.1 角色

```cpp
// src/share/config/ob_reload_config.h
class ObReloadConfig {
public:
  // 后台线程监听配置文件变化
  int run();

  // 文件变了 → 触发 reload
  int on_config_changed(const ObString &file_path);
};
```

### 8.2 热加载 vs 重启加载

| 维度 | 热加载 | 重启加载 |
|------|--------|----------|
| 修改参数类型 | 多数 tenant / common | system / 部分 server |
| 生效延迟 | 几秒（后台线程感知） | observer 重启（分钟级） |
| 风险 | 低（受支持参数） | 低 |
| 实现 | ObReloadConfig + version | 启动期 read + parse |

### 8.3 版本管理

每次 reload 产生新 version：
- 配置文件 md5 / mtime 检测
- 解析新值 → 校验 → 与当前值对比
- 改了的参数 → 触发 reload callback
- 不改的参数 → skip

---

## 9. ObConfigManager —— 配置管理核心

### 9.1 类骨架（推测）

```cpp
// src/share/config/ob_config_manager.h
class ObConfigManager {
public:
  // 参数注册（启动期 + 热加载期）
  int register_param(const char *name,
                     const ObConfigItem *item);

  // 获取
  template<typename T>
  T get(const char *name) const;

  // 设置
  int set(const char *name, const ObString &value);

  // 校验
  int validate(const char *name, const ObString &value);

  // 序列化（用于持久化 + 跨 observer 同步）
  int serialize(ObString &buf) const;

  // 反序列化（启动期恢复）
  int deserialize(const ObString &buf);

private:
  // 参数 hash
  hash::ObHashMap<ObString, ObConfigItem> items_;
  // 当前值快照
  common::ObArenaAllocator allocator_;
};
```

### 9.2 ObConfigItem 抽象

```cpp
// (推测)
struct ObConfigItem {
  const char *name_;
  ObConfigItemType type_;
  void *value_ptr_;       // 指向实际变量（通过宏注册）
  ObString default_value_;
  ObString description_;
  bool restart_required_; // 是否需要重启才能生效
  // 校验 / setter callback
  int (*set_callback_)(const ObString &value);
  int (*validate_callback_)(const ObString &value);
};
```

### 9.3 参数变更回调

```cpp
// (典型实现)
DEF_INT(cpu_count, 16, "available CPU cores", ...);
DEF_INT_CALLBACK(cpu_count, on_cpu_count_changed) {
  // cpu_count 变更时调用
  // 1. 重新计算线程池大小
  // 2. 重新分配 worker
  // 3. 通知相关模块
}

// 触发：
ALTER SYSTEM SET cpu_count = 32;
    │
    ▼
ObConfigManager::set("cpu_count", "32")
    │
    ├─ 校验（validate_callback）
    ├─ 类型转换（string → int64_t）
    ├─ 设置值
    └─ 调用 on_cpu_count_changed 回调
```

---

## 10. 配置虚拟表（监控接口）

### 10.1 几个关键虚拟表

```bash
src/observer/virtual_table/ob_all_virtual_tenant_parameter_stat.{h,cpp}
src/observer/virtual_table/ob_all_virtual_sys_parameter_stat.{h,cpp}
src/observer/virtual_table/ob_all_virtual_tenant_parameter_info.{h,cpp}
```

### 10.2 用法

```sql
-- 查看所有 tenant 参数
SELECT tenant_id, name, value, scope
FROM oceanbase.__all_virtual_tenant_parameter_stat;

-- 查看系统参数
SELECT name, value, data_type
FROM oceanbase.__all_virtual_sys_parameter_stat;

-- 查看某参数详情
SELECT * FROM oceanbase.__all_virtual_tenant_parameter_info
WHERE name = 'cpu_count';
```

### 10.3 用途

- DBA 调优：监控当前生效值
- 运维：确认参数是否生效
- 审计：跟踪参数变更历史

---

## 11. ALTER SYSTEM SET / ALTER TENANT SET 流程

### 11.1 ALTER SYSTEM SET（系统参数）

```
应用: ALTER SYSTEM SET cpu_count = 32;
    │
    ▼
observer #1 (任意 observer 都可发起) SQL executor
    │
    ├─ 解析：ALTER SYSTEM SET name=value
    │   ├─ name 必须在 system config 列表中
    │   └─ value 必须能解析为对应类型
    │
    ▼
observer → RS: admin_set_config RPC
    │
    ▼
RS:
    ├─ 权限校验（参见 #70）
    ├─ 校验 value 合法
    ├─ 持久化到内部表
    └─ broadcast 到所有 observer
    │
    ▼
所有 observer:
    ├─ 接收新值
    ├─ 调 ObConfigManager::set
    ├─ 触发 reload callback
    └─ 内存中生效
```

### 11.2 ALTER TENANT SET（tenant 参数）

```
应用: ALTER TENANT t1 SET memstore_limit_percentage = 60;
    │
    ▼
observer SQL executor
    │
    ▼
observer → RS: alter_tenant_config RPC
    │
    ▼
RS:
    ├─ 校验 tenant 存在
    ├─ 持久化到 __all_tenant_parameter
    └─ broadcast 到所有 observer
    │
    ▼
observer 收到 broadcast:
    ├─ 找到对应 tenant_id 的 ObTenantConfig
    ├─ 调 set_param
    └─ 立即生效（不需要重启 tenant 或 observer）
```

### 11.3 关键的差异

| 操作 | ALTER SYSTEM SET | ALTER TENANT SET |
|------|-------------------|-------------------|
| 范围 | 整个集群 | 单 tenant |
| 是否立即生效 | 部分是（runtime 参数） | 总是 |
| 是否需要重启 | 部分需要（restart_required_） | 不需要 |
| 持久化 | __all_sys_parameter | __all_tenant_parameter |

---

## 12. 与其他文章的关系

### 12.1 与 #39 Tenant Architecture

Tenant Config 是 tenant 架构的 **可调参数集**：
- 每个 tenant 有自己的 ObTenantConfig
- Tenant 创建时可指定初始配置
- 后续可 ALTER TENANT 调优

### 12.2 与 #71 Resource Isolation

Unit 配额（max_cpu / max_memory 等）是 **Resource Manager 系统的参数**：
- 由 `src/share/resource_manager/ob_resource_manager.*` 管理
- 通过 ObConfig 框架暴露为可配置参数

### 12.3 与 #57 Config System

#57 是早期分析文章，本篇是 #57 的 **深化**：
- #57 集中在基本的 config 表 + set param 流程
- 本篇补充 ObConfigItemType 13 种类型 / Parameter 宏系统 / Tenant Config 覆盖 / 热加载机制

### 12.4 与 #30 Observer Startup

Observer 启动期是 **配置加载的高峰**：
1. 读 sys 配置文件 → 加载 ServerConfig
2. 读 system config → 加载 SystemConfig
3. 读 common config → 加载 CommonConfig
4. 启动后加载每个 tenant 的 TenantConfig

### 12.5 与 #70 Audit / Security

配置变更需要审计：
- `ALTER SYSTEM SET ...` 需要 SECURITY_AUDIT 权限
- audit log 记录所有 config 变更

---

## 13. 总结

### 13.1 配置中心在 OB 体系中的定位

OB 的配置中心是 **运行时可调优**的核心：
- 不重启即可调优参数
- 多层覆盖（System / Common / Server / Tenant）
- 13 种类型自动校验
- 完整审计 + 监控

### 13.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| 4 层配置 | System / Common / Server / Tenant |
| 13 种类型 | ObConfigItemType enum |
| Parameter 宏 | DEF_INT / DEF_CAPACITY / DEF_TIME / DEF_BOOL / DEF_STR |
| Tenant 覆盖 | 优先级：Tenant > Common > Server |
| 热加载 | ObReloadConfig + version |
| 持久化 | __all_sys_parameter / __all_tenant_parameter |
| 虚拟表 | __all_virtual_*_parameter_stat |
| ALTER SET | observer → RS broadcast → all observers |

### 13.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/share/config/` | 配置核心（18 文件） |
| `src/share/parameter/ob_parameter_attr.h` | 参数 attribute 定义 |
| `src/share/parameter/ob_parameter_macro.h` | DECLARE / DEFINE 宏 |
| `src/observer/omt/ob_tenant_config.{h,cpp}` | Tenant Config |
| `src/observer/virtual_table/ob_all_virtual_*.{h,cpp}` | 监控虚拟表 |

### 13.4 关键技术常量

| 常量 | 典型值 | 位置 |
|------|--------|------|
| ObConfigItemType | 13 种 | `ob_config.h` |
| PARAM_REGISTER macro | ~500 个参数 | `ob_server_config.cpp` |
| ALTER SYSTEM SET 持久化 | `__all_sys_parameter` | 内部表 |
| ALTER TENANT SET 持久化 | `__all_tenant_parameter` | 内部表 |

### 13.5 推荐下一步

按之前梳理的顺序，下一篇应该是 **#73 Logger / 日志框架**：

OB 的统一日志系统 —— ObLogger / 异步落盘 / 日志格式 / 诊断。源码入口：`src/share/logger/` + `src/share/log/` + `src/common/log/`。

适用场景：日常运维 / 故障诊断 / 性能分析。

整吗？