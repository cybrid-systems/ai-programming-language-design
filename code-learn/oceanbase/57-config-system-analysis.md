# §57 配置管理 ObConfig — 配置中心、动态变更、热加载

> 分析日期：2026-05-03  
> 源码路径：`src/share/config/`（18 个文件）  
> 核心文件：`ob_config.h`、`ob_config_manager.h`、`ob_reload_config.h`、`ob_server_config.h`、`ob_common_config.h`、`ob_system_config.h`

---

## 一、概述

OceanBase 的配置管理子系统（ObConfig）是一个支持 **动态热加载**、**多级分层**、**可持久化** 的配置中心。它从 SeasLog/Redis 等项目的配置管理中汲取经验，但在分布式数据库场景下做了大量扩展。

整个配置子系统位于 `src/share/config/`，配合 `src/share/parameter/` 下的宏定义和元数据基础设施，共同构成了一个完整的配置生命周期管理体系。

本文围绕以下核心问题展开：

1. 配置项如何定义和组织？
2. 配置的层级结构是什么？
3. 动态变更（ALTER SYSTEM SET）如何实现？
4. 配置的持久化和版本管理如何工作？
5. 设计者的关键权衡和决策是什么？

---

## 二、文件清单与职责划分

```
src/share/config/
├── ob_config.h / .cpp          # 配置基类 (ObConfigItem) 及所有类型子类
├── ob_config_helper.h / .cpp   # 校验器 (Checker)、解析器 (Parser)、容器
├── ob_config_manager.h / .cpp  # 配置管理器：加载、同步、持久化
├── ob_reload_config.h / .cpp   # 配置热加载函数对象
├── ob_server_config.h / .cpp   # 服务器级配置（最上层）
├── ob_common_config.h / .cpp   # 通用配置基类（中间层）
├── ob_system_config.h / .cpp   # 系统配置（底层存储，从内表读取）
├── ob_system_config_key.h      # 系统配置键 (通过 zone/svr_type/IP 多级匹配)
├── ob_system_config_value.h    # 系统配置值 (包括 value/info/section/scope 等)
└── ob_config_mode_name_def.h   # 配置模式名称定义
```

```
src/share/parameter/
├── ob_parameter_attr.h / .cpp  # ObParameterAttr — 配置项元数据 (Section/Scope/EditLevel)
├── ob_parameter_macro.h        # 配置项定义宏体系
├── ob_parameter_seed.ipp       # 所有配置项的种子定义 (~3441 行)
└── default_parameter.json      # 默认参数 JSON
```

---

## 三、配置项的类层次体系

### 3.1 类型体系总图

ObConfig 采用了经典的类型化配置设计。所有配置项统一继承自 `ObConfigItem`，针对不同数据类型派生出具体子类：

```
ObConfigItem (基类)
├── ObConfigBoolItem          — 布尔值 (True/False)
├── ObConfigIntItem           — 整数 (int64_t)
├── ObConfigDoubleItem        — 浮点数 (double)
├── ObConfigStringItem        — 字符串 (最长 65536 字节)
├── ObConfigIntegralItem      — 整型基类 (带 min/max 范围校验)
│   ├── ObConfigIntItem       — 整数
│   ├── ObConfigTimeItem      — 时间 (如 30s, 1000us)
│   ├── ObConfigCapacityItem  — 容量 (如 10G, 500M)
│   └── ObConfigVersionItem   — 版本号 (如 4.2.0.0)
├── ObConfigMomentItem        — 时刻 (disable/hour/minute)
├── ObConfigStrListItem       — 字符串列表
├── ObConfigIntListItem       — 整数列表
├── ObConfigModeItem          — 模式位图 (配合 ObConfigParser)
└── ObConfigLogArchiveOptionsItem — 归档选项 (MANDATORY/COMPRESSION/ENCRYPTION)
```

### 3.2 ObConfigItem 基类 (`ob_config.h:75-147`)

基类定义了配置项的**通用生命周期**和**线程安全访问**：

```cpp
// ob_config.h:83-90
void init(Scope::ScopeInfo scope_info,
          const char *name,
          const char *def,
          const char *info,
          const ObParameterAttr attr = ObParameterAttr());
void add_checker(const ObConfigChecker *new_ck)
{
  ck_ = OB_NEW(ObConfigConsChecker, g_config_mem_attr, ck_, new_ck);
}
```

关键设计决策：

1. **锁机制**（`ob_config.h:139`）：每个配置项拥有独立的 `ObLatch` 读写锁（`ObLatchIds::CONFIG_LOCK`），支持并发读。宏 `CONFIG_LOCK_EXEMPTION` 控制是否在特定路径下跳过加锁。

2. **值的双缓冲**（`ob_config.cpp:123-156`）：每个配置项维护 `value_str_`（当前值）和 `value_reboot_str_`（重启值），通过 `set_value()` 和 `set_reboot_value()` 分别写入。

3. **版本追踪**：每个配置项维护两个版本号：
   - `version_`（`ob_config.h:120`）：当前有效版本的版本号
   - `dumped_version_`（`ob_config.h:121`）：已持久化到文件的版本号

4. **校验器链**（`ob_config.h:85-89`）：通过 `ObConfigConsChecker` 将多个校验器串成链表，每次 `set_value()` 后调用 `check()` 验证合法性。

### 3.3 配置项类型枚举 (`ob_config.h:49-66`)

```cpp
enum ObConfigItemType{
  OB_CONF_ITEM_TYPE_UNKNOWN = -1,
  OB_CONF_ITEM_TYPE_BOOL = 0,         // 布尔型
  OB_CONF_ITEM_TYPE_INT = 1,          // 整数型
  OB_CONF_ITEM_TYPE_DOUBLE = 2,       // 浮点型
  OB_CONF_ITEM_TYPE_STRING = 3,       // 字符串型
  OB_CONF_ITEM_TYPE_INTEGRAL = 4,     // 整型基类
  OB_CONF_ITEM_TYPE_STRLIST = 5,      // 字符串列表
  OB_CONF_ITEM_TYPE_INTLIST = 6,      // 整型列表
  OB_CONF_ITEM_TYPE_TIME = 7,         // 时间值
  OB_CONF_ITEM_TYPE_MOMENT = 8,       // 时刻值
  OB_CONF_ITEM_TYPE_CAPACITY = 9,     // 容量值
  OB_CONF_ITEM_TYPE_LOGARCHIVEOPT = 10, // 归档选项
  OB_CONF_ITEM_TYPE_VERSION = 11,      // 版本号
  OB_CONF_ITEM_TYPE_MODE = 12,         // 模式位图
};
```

### 3.4 值的写入路径 (`ob_config.cpp:114-156`)

```cpp
// ob_config.cpp:114-120
bool ObConfigItem::set_value_with_lock(const common::ObString &string)
{
  DRWLock::WRLockGuard guard(OTC_MGR.rwlock_);
  return set_value_unsafe(string);
}

// ob_config.cpp:137-156
bool ObConfigItem::set_value_unsafe(const common::ObString &string)
{
  int64_t pos = 0;
  int ret = OB_SUCCESS;
  ObLatchWGuard wr_guard(lock_, ObLatchIds::CONFIG_LOCK);
  const char *ptr = value_ptr();
  if (nullptr == ptr) {
    value_valid_ = false;
  } else if (OB_FAIL(databuff_printf(const_cast<char *>(ptr), value_len(), pos,
                                      "%.*s", string.length(), string.ptr()))) {
    value_valid_ = false;
  } else {
    value_valid_ = set(ptr);
    if (inited_ && value_valid_) {
      value_updated_ = true;
    }
  }
  return value_valid_;
}
```

写入策略采用**双重加锁**：
1. 外层：全局 `OTC_MGR.rwlock_` — 保护配置管理器的整体状态（`ob_config.cpp:115`）
2. 内层：单个配置项的 `ObLatch` — 保护值的读写一致性（`ob_config.cpp:140`）

---

## 四、宏体系与配置项定义（ob_parameter_macro.h）

### 4.1 宏体系设计

OceanBase 使用了一个高度风格化的宏体系来定义配置项。所有配置定义位于 `ob_parameter_seed.ipp`（3441 行）。

核心宏定义在 `ob_parameter_macro.h`：

```cpp
// ob_parameter_macro.h:72-105
#define DEF_INT(args...)       _DEF_PARAMETER_SCOPE_RANGE_EASY(public, Int, args)
#define DEF_DBL(args...)       _DEF_PARAMETER_SCOPE_RANGE_EASY(public, Double, args)
#define DEF_CAP(args...)       _DEF_PARAMETER_SCOPE_RANGE_EASY(public, Capacity, args)
#define DEF_TIME(args...)      _DEF_PARAMETER_SCOPE_RANGE_EASY(public, Time, args)
#define DEF_BOOL(args...)      _DEF_PARAMETER_SCOPE_EASY(public, Bool, args)
#define DEF_STR(args...)       _DEF_PARAMETER_SCOPE_EASY(public, String, args)
#define DEF_VERSION(args...)   _DEF_PARAMETER_SCOPE_EASY(public, Version, args)
#define DEF_IP(args...)        _DEF_PARAMETER_SCOPE_IP_EASY(public, String, args)
#define DEF_MOMENT(args...)    _DEF_PARAMETER_SCOPE_EASY(public, Moment, args)
#define DEF_INT_LIST(args...)  _DEF_PARAMETER_SCOPE_EASY(public, IntList, args)
#define DEF_STR_LIST(args...)  _DEF_PARAMETER_SCOPE_EASY(public, StrList, args)
```

每个宏展开后生成：
1. 一个类声明（继承自对应的 `ObConfigXxxItem`）
2. 构造函数初始化（注册到全局 `ObConfigContainer`）
3. 重写的 `value_default_ptr()` — 返回编译期常量默认值

### 4.2 典型配置定义示例 (`ob_parameter_seed.ipp`)

```cpp
// 集群级、自带范围校验的整型配置（DYNAMIC_EFFECTIVE）
DEF_INT(rpc_port, OB_CLUSTER_PARAMETER, "2882", "(1024,65536)",
        "the port number for RPC protocol. Range: (1024, 65536) in integer",
        ObParameterAttr(Section::OBSERVER, Source::DEFAULT, EditLevel::DYNAMIC_EFFECTIVE));

// 集群级、只读的字符串配置（READONLY）
DEF_STR(data_dir, OB_CLUSTER_PARAMETER, "store", "the directory for the data file",
        ObParameterAttr(Section::SSTABLE, Source::DEFAULT, EditLevel::READONLY));

// 租户级、需重启生效的容量配置（STATIC_EFFECTIVE）
DEF_CAP(sql_work_area, OB_TENANT_PARAMETER, "1G", "[10M,)",
        "Work area memory limitation for tenant",
        ObParameterAttr(Section::OBSERVER, Source::DEFAULT, EditLevel::STATIC_EFFECTIVE));

// 带可选值的字符串配置（自动校验合法值）
DEF_STR(redundancy_level, OB_CLUSTER_PARAMETER, "NORMAL",
        "EXTERNAL: use external redundancy; NORMAL: tolerate one disk failure; "
        "HIGH: tolerate two disk failure if disk count is enough",
        ObParameterAttr(Section::SSTABLE, Source::DEFAULT, EditLevel::DYNAMIC_EFFECTIVE),
        "EXTERNAL, NORMAL, HIGH");

// 带自定义校验器的整数配置
_DEF_PARAMETER_SCOPE_CHECKER_EASY(private, Capacity, memory_limit, OB_CLUSTER_PARAMETER,
        "0M", common::ObConfigMemoryLimitChecker, "[0M,)",
        "...", ObParameterAttr(...));
```

### 4.3 配置参数的元数据 (ObParameterAttr)

每个配置项关联一个 `ObParameterAttr`，包含以下维度（`ob_parameter_attr.h:32-42`）：

| 维度 | 可选值 | 含义 |
|------|--------|------|
| **Section** | ROOT_SERVICE, LOAD_BALANCE, SSTABLE, LOGSERVICE, CACHE, TRANS, RPC, OBSERVER, RESOURCE_LIMIT ... | 配置项所属功能域 |
| **Scope** | CLUSTER / TENANT | 配置的范围：集群级或租户级 |
| **Source** | DEFAULT / FILE / OBADMIN / CMDLINE / CLUSTER / TENANT | 配置来源 |
| **EditLevel** | READONLY / STATIC_EFFECTIVE / DYNAMIC_EFFECTIVE | **生效级别**：只读 / 需重启 / 立即生效 |
| **VisibleLevel** | SYS / COMMON / INVISIBLE | 可见性层级 |
| **CompatMode** | MYSQL / ORACLE / COMMON | 兼容模式 |

三种编辑级别 (`ob_parameter_attr.cpp:37-43`)：

```cpp
bool ObParameterAttr::is_static() const
{
  return edit_level_ == EditLevel::STATIC_EFFECTIVE;  // 需重启
}

bool ObParameterAttr::is_readonly() const
{
  return edit_level_ == EditLevel::READONLY;           // 只读
}
```

在 `ob_parameter_seed.ipp` 中：
- **DYNAMIC_EFFECTIVE**: 806 个配置项
- **STATIC_EFFECTIVE**: 15 个配置项
- **READONLY**: 10 个配置项

这个比例（~96% 动态）说明 OceanBase **极力追求无需重启的配置变更体验**。

---

## 五、配置的层级结构

ObConfig 采用三层配置继承体系：

```
ObInitConfigContainer (配置容器初始化)
        ↓
  ObBaseConfig (加载/转储基础功能)
        ↓
  ObCommonConfig (通用配置，check_all/print/to_json_array 等)
        ↓
  ObServerConfig (服务器配置，含所有参数定义 ← 最关键的上层)
```

### 5.1 ObInitConfigContainer (`ob_common_config.h:19-31`)

负责初始化全局的 `ObConfigContainer`（一个以 `ObConfigStringKey` 为键的 `ObHashMap`），确保在**静态初始化**阶段所有配置项正确注册。

```cpp
// ob_common_config.h:22-24
const ObConfigContainer &get_container();
static ObConfigContainer *&local_container();
```

### 5.2 ObBaseConfig (`ob_common_config.h:34-76`)

提供配置的 I/O 基础能力：

```cpp
// ob_common_config.h:60-64
int load_from_buffer(const char *config_str, const int64_t config_str_len,
  const int64_t version = 0, const bool check_name = false);
int load_from_file(const char *config_file, const int64_t version = 0, const bool check_name = false);
int dump2file(const char *config_file) const;
```

### 5.3 ObServerConfig (`ob_server_config.h:93-153`)

最核心的上层配置类，通过宏展开自动生成所有具体的配置项成员：

```cpp
// ob_server_config.h:120-122
#undef OB_CLUSTER_PARAMETER
#define OB_CLUSTER_PARAMETER(args...) args
#include "share/parameter/ob_parameter_seed.ipp"
#undef OB_CLUSTER_PARAMETER
```

这个技巧极为巧妙：`ob_parameter_seed.ipp` 中的每一行配置定义通过宏展开都会为 `ObServerConfig` 生成一个对应的成员变量。当 `OB_CLUSTER_PARAMETER` 展开为空时，同一文件被用于 rootserver 中的校验器。

```cpp
// ob_server_config.h:143-144
#define GCONF (::oceanbase::common::ObServerConfig::get_instance())
#define GMEMCONF (::oceanbase::common::ObServerMemoryConfig::get_instance())
```

`GCONF` 宏是整个 OceanBase 代码中最常用的全局配置访问入口。

### 5.4 ObConfigContainer (`ob_config_helper.h:321-332`)

配置项存储容器，基于 `ObHashMap`：

```cpp
// ob_config_helper.h:321-332
template <class Key, class Value, int num>
class __ObConfigContainer
  : public hash::ObHashMap<Key, Value *, hash::NoPthreadDefendMode>
{
public:
  __ObConfigContainer()
  {
    this->create(num, OB_HASH_BUCKET_CONF_CONTAINER, OB_HASH_NODE_CONF_CONTAINER);
  }
};

typedef __ObConfigContainer<ObConfigStringKey,
                            ObConfigItem, OB_MAX_CONFIG_NUMBER> ObConfigContainer;
```

---

## 六、配置管理器：ObConfigManager (`ob_config_manager.h`)

`ObConfigManager` 是整个配置子系统的中枢，负责配置的**加载、同步、持久化和热加载**。

### 6.1 生命周期 (`ob_config_manager.h:39-50`, `ob_config_manager.cpp:38-50`)

```cpp
// ob_config_manager.h:43-50
int base_init();         // 初始阶段：system_config_.init() + server_config_.init()
int init(const ObAddr &server);  // 启动阶段：初始化定时器线程
void destroy();          // 销毁

// ob_config_manager.cpp:38-50
int ObConfigManager::base_init()
{
  int ret = OB_SUCCESS;
  if (OB_FAIL(system_config_.init())) {
    LOG_ERROR("init system config failed", K(ret));
  } else if (OB_FAIL(server_config_.init(system_config_))) {
    LOG_ERROR("init server config failed", K(ret));
  }
  update_task_.config_mgr_ = this;
  return ret;
}
```

### 6.2 版本管理 (`ob_config_manager.h:55-59`)

```cpp
inline int64_t ObConfigManager::get_version() const           // 最新收到的版本
  { return update_task_.version_; }
inline int64_t ObConfigManager::get_current_version() const   // 当前正在使用的版本
  { return current_version_; }
inline int64_t ObConfigManager::get_read_version() const      // 可读取的版本
  { return system_config_.get_version(); }
```

三个版本号的设计解决了**分布式环境下的版本推进和回退问题**：

- `get_version()`：rootserver 通知的最新版本号
- `get_current_version()`：本地成功应用的最新版本号
- `get_read_version()`：从 `__all_sys_parameter` 内表读取到的最新版本号

### 6.3 版本变更通知 (`ob_config_manager.cpp:298-353`)

当 rootserver 通知新的配置版本时触发：

```cpp
// ob_config_manager.cpp:298-353
int ObConfigManager::got_version(int64_t version, const bool remove_repeat)
{
  ...
  if (current_version_ == version) {
    // no new version
  } else if (version < current_version_) {
    LOG_WARN("Local config is newer than rs, weird", K_(current_version), K(version));
  } else if (version > current_version_) {
    LOG_INFO("Got new config version", K_(current_version), K(version));
    update_task_.update_local_ = true;
    schedule_task = true;
  }
  if (schedule) {
    TG_CANCEL(lib::TGDefIDs::CONFIG_MGR, update_task_);  // 取消所有等待中的任务
    update_task_.version_ = version;
    update_task_.scheduled_time_ = ObClockGenerator::getClock();
    OB_FAIL(TG_SCHEDULE(lib::TGDefIDs::CONFIG_MGR, update_task_, 0, false));
  }
}
```

### 6.4 本地更新任务 (`ob_config_manager.cpp:356-393`)

`UpdateTask` 是定时的 `ObTimerTask`，实际执行配置变更：

```cpp
// ob_config_manager.cpp:356-393
void ObConfigManager::UpdateTask::runTimerTask()
{
  ...
  if (config_mgr_->current_version_ == version) {
    ret = OB_ALREADY_DONE;
  } else if (config_mgr_->current_version_ > version) {
    ret = OB_CANCELED;
  } else if (update_local_) {
    config_mgr_->current_version_ = version;
    OB_FAIL(config_mgr_->system_config_.clear());  // 清空旧配置
    OB_FAIL(config_mgr_->update_local(version));    // 从内表重新读取
    // 失败则 1 秒后重试
  }
}
```

### 6.5 配置持久化 (`ob_config_manager.cpp:217-293`)

配置以二进制格式持久化到磁盘文件（`observer.conf.bin`），使用**边写边改名**策略保证原子性：

```cpp
// ob_config_manager.cpp:283-290
// 先写入 .tmp 文件 → fsync → rename 为 .bin
// 旧文件备份为 .history
if (0 != ::rename(path, hist_path) && errno != ENOENT) { ... }
if (0 != ::rename(tmp_path, path) && errno != ENOENT) { ... }
```

每次配置更新都会进行 `config_backup()`（`ob_config_manager.cpp:178-202`），将配置拷贝到 `config_additional_dir` 中指定的所有备份目录。

---

## 七、动态配置变更的全路径

### 7.1 ALTER SYSTEM SET 的执行流程

完整的执行路径：

```
用户 SQL: ALTER SYSTEM SET xxx = yyy
    │
    ▼
ob_alter_system_executor.cpp (1738行)
    │ ObAdminSetConfig RPC
    ▼
ob_root_service.cpp:8132 — ObRootService::admin_set_config()
    │
    ▼
ob_system_admin_util.cpp — ObAdminSetConfig::execute()
    │
    ├─ 1. verify_config() — 参数合法性校验
    │     ├─ 配置名是否存在（通过校验器）（1899行）
    │     ├─ 值的类型和范围
    │     └─ 跨参数一致性（如 freeze_trigger 需 > writing_throttling_trigger）
    │
    ├─ 2. update_config() — 写入内表 __all_sys_parameter
    │     ├─ new_version = max(old_version + 1, current_time())
    │     ├─ update_sys_config_() / update_tenant_config_()
    │     └─ 发送 RPC 通知所有 OBServer 新版本号
    │
    └─ 3. set_config_post_hook() — 后置钩子
```

### 7.2 热加载路径

每个 OBServer 收到版本变更通知后的本地更新流程：

```
rootserver RPC: got_version(new_version)
    │
    ▼
ObConfigManager::got_version()
    │ 调度定时任务 UpdateTask
    ▼
UpdateTask::runTimerTask()
    │
    ▼
ObConfigManager::update_local(version)
    │
    ├─ 1. system_config_.clear()           — 清空旧配置哈希表
    │
    ├─ 2. 从 __all_sys_parameter 读取最新配置
    │     └─ SELECT config_version, zone, svr_type, ..., value, info
    │         FROM __all_sys_parameter
    │
    ├─ 3. system_config_.update(result)    — 重建哈希表
    │
    ├─ 4. server_config_.read_config()     — 从 system_config_ 读取到具体配置项
    │
    ├─ 5. reload_config()                  — 触发热加载
    │
    └─ 6. dump2file_unsafe()              — 持久化到磁盘
```

### 7.3 热加载的具体执行 (`ob_config_manager.cpp:154-175`)

```cpp
int ObConfigManager::reload_config()
{
  int ret = OB_SUCCESS;
  if (OB_FAIL(server_config_.check_all())) {
    LOG_WARN("Check configuration failed, can't reload", K(ret));
  } else if (OB_FAIL(reload_config_func_())) {
    LOG_WARN("Reload configuration failed.", K(ret));
  } else if (OB_FAIL(OBSERVER.get_net_frame().reload_ssl_config())) {
    LOG_WARN("reload ssl config for net frame fail", K(ret));
  } else if (OB_FAIL(OBSERVER.get_rl_mgr().reload_config())) {
    LOG_WARN("reload config for ratelimit manager fail", K(ret));
  } else if (OB_FAIL(OBSERVER.get_net_frame().reload_sql_thread_config())) {
    LOG_WARN("reload config for mysql login thread count failed", K(ret));
  } else if (OB_FAIL(ObTdeEncryptEngineLoader::get_instance().reload_config())) {
    LOG_WARN("reload config for tde encrypt engine fail", K(ret));
  } else if (OB_FAIL(GCTX.omt_->update_hidden_sys_tenant())) {
    LOG_WARN("update hidden sys tenant failed", K(ret));
  }
  ...
}
```

热加载依次调用多个子系统自身的 reload 方法，而不是统一遍历配置项。这种 **「订阅者模式」** 的设计允许各子系统仅关注与自己相关的配置项。

### 7.4 ObReloadConfig (`ob_reload_config.h`)

`ObReloadConfig` 是一个简单的函数对象，封装了日志系统配置的即时加载：

```cpp
// ob_reload_config.h:25-35
class ObReloadConfig
{
public:
  explicit ObReloadConfig(ObServerConfig *conf): conf_(conf) {};
  virtual ~ObReloadConfig() {}
  virtual int operator()();

protected:
  ObServerConfig *conf_;

private:
  int reload_ob_logger_set();
};

// ob_reload_config.cpp:17-36
int ObReloadConfig::reload_ob_logger_set()
{
  ...
  // 调用 OB_LOGGER.parse_set(conf_->syslog_level, ...)
  // 调用 ObConfigManager::ob_logger_config_update(*conf_)
  // 调用 ObKVGlobalCache::get_instance().reload_priority()
  ...
}
```

### 7.5 配置的生效方式

根据 `EditLevel` 的不同，配置变更有三种生效方式：

| EditLevel | 宏实现判断 | 行为 | 示例 |
|-----------|-----------|------|------|
| `DYNAMIC_EFFECTIVE` | `!is_static()` | 立即生效，通过 reload_config() 热加载 | `rpc_port`, `zone`, `freeze_trigger_percentage` |
| `STATIC_EFFECTIVE` | `is_static()` | 值写入 `value_reboot_str_`，需要重启 | `high_priority_net_thread_count`, `sql_work_area`, `use_ipv6` |
| `READONLY` | `is_readonly()` | 修改失败，仅在启动时由命令行或配置文件设定 | `data_dir`, `devname`, `ob_startup_mode` |

在 `ObConfigItem` 中，`reboot_effective()` 直接映射到 `attr_.is_static()`（`ob_config.h:130-132`）：

```cpp
bool reboot_effective() const
{
  return attr_.is_static();
}
```

对于需重启的配置项，`spfile_str()` 返回 `value_reboot_ptr()`（`ob_config.h:109-118`）：

```cpp
virtual const char *spfile_str() const
{
  if (reboot_effective() && is_initial_value_set()) {
    ret = value_reboot_ptr();
  } else {
    ret = value_ptr();
  }
  return ret;
}
```

---

## 八、系统配置存储：ObSystemConfig

### 8.1 数据结构 (`ob_system_config.h:27-59`)

```cpp
class ObSystemConfig
{
  typedef hash::ObHashMap<ObSystemConfigKey, ObSystemConfigValue*> hashmap;
  ...
  ObArenaAllocator allocator_;
  hashmap map_;           // 键值哈希表
  int64_t version_;       // 当前版本号
};
```

### 8.2 多层级键匹配 (`ob_system_config_key.h`)

`ObSystemConfigKey` 支持灵活的匹配策略——这是支持**不同粒度配置覆盖**的关键：

```cpp
// ob_system_config_key.h:37-42
bool match(const ObSystemConfigKey &key) const
{
  // 匹配 name + zone（可为空）+ server_type（可为默认值）+ server_ip（可为默认值）+ port（可为0）
  return ...
}
```

配置优先级的匹配规则（`match()` 方法实现，`ob_system_config_key.h:66-76`）：

1. 精确匹配：name + zone + server_type + server_ip + port
2. 默认值通配：name 匹配，但 zone 为空 / server_type 为 "DEFAULT_VALUE" 视为通配
3. 查询时使用 `find_newest()` 找到匹配的最大版本号

---

## 九、校验器体系 (`ob_config_helper.h`)

ObConfig 拥有一个庞大的校验器体系，每个校验器负责特定业务规则。

### 9.1 基础校验器

```cpp
// ob_config_helper.h:27-32
class ObConfigChecker {          // 校验器基类
  virtual bool check(const ObConfigItem &t) const = 0;
};

class ObConfigAlwaysTrue {};     // 总是通过
class ObConfigConsChecker {};    // 校验器链（AND 关系）
class ObConfigIpChecker {};      // IP 地址格式校验
```

### 9.2 业务校验器

文件 `ob_config_helper.h:71-310` 定义了 50+ 个业务校验器：

- **内存相关**：`ObConfigMemoryLimitChecker`, `ObConfigTenantMemoryChecker`, `ObCtxMemoryLimitChecker`
- **触发比例**：`ObConfigFreezeTriggerIntChecker`, `ObConfigWriteThrottleTriggerIntChecker`
- **日志相关**：`ObConfigLogLevelChecker`, `ObConfigMaxSyslogFileCountChecker`, `ObConfigSyslogCompressFuncChecker`
- **存储相关**：`ObConfigTabletSizeChecker`, `ObConfigCompressFuncChecker`
- **安全相关**：`ObConfigSTScredentialChecker`, `ObRpcClientAuthMethodChecker`
- **资源限制**：`ObConfigResourceLimitSpecChecker`, `ObConfigQueryRateLimitChecker`

### 9.3 校验器的组合

`ObConfigConsChecker` 实现了校验器链（`ob_config_helper.h:43-47`）：

```cpp
class ObConfigConsChecker : public ObConfigChecker
{
  ObConfigConsChecker(const ObConfigChecker *left, const ObConfigChecker *right)
    : left_(left), right_(right) {}
  bool check(const ObConfigItem &t) const;
};
```

多个校验器通过 `add_checker()` 串联（`ob_config.h:85-89`）：

```cpp
void add_checker(const ObConfigChecker *new_ck)
{
  ck_ = OB_NEW(ObConfigConsChecker, g_config_mem_attr, ck_, new_ck);
}
```

---

## 十、设计决策与权衡

### 10.1 为什么用宏体系而不是运行时注册？

传统做法是在初始化阶段通过注册函数注册配置项。OceanBase 选择在头文件中通过宏展开生成成员变量，理由是：

1. **编译期确定性**：所有配置项在编译时即可确定，无需运行时动态分配
2. **直接访问性能**：`GCONF.rpc_port` 直接访问成员变量，无哈希查找开销——这在关键路径（如每次 RPC 连接）上极为重要
3. **类型安全**：每个配置项有独立的具体类型而非 `void*`，编译时类型检查
4. **IDE 友好**：头文件中直接可见所有配置项

### 10.2 动态 vs 静态配置的划分标准

从 `ob_parameter_seed.ipp` 的统计数据可以看出：

- **DYNAMIC_EFFECTIVE**（806 项）：运行时安全的参数，如端口、超时、缓存大小、冻结触发比例
- **STATIC_EFFECTIVE**（15 项）：影响数据面初始化的参数，如 `high_priority_net_thread_count`（线程池大小）、`sql_work_area`（内存池划分）、`use_ipv6`（网络栈初始化）
- **READONLY**（10 项）：影响程序初始启动的参数，如 `data_dir`、`devname`、`ob_startup_mode`

划分标准：**「如果更改该配置不需要重建任何核心服务结构，则为动态；否则为静态或只读」**。

### 10.3 配置变更的原子性

- **单机原子性**：`update_local()` 中先 clear 再 rebuild，使用 `DRWLock::WRLockGuard` 保护
- **集群原子性**：rootserver 写入内表生成新版本号，OBServer 异步拉取；版本号严格递增
- **失败回滚**：`UpdateTask::runTimerTask()`（`ob_config_manager.cpp:356-393`）中如果 `update_local()` 失败，恢复 `current_version_` 并在 1 秒后重试

### 10.4 为什么配置支持区分配置层级？

`ObSystemConfigKey` 的 `match()` 方法支持按 zone/server_type/server_ip/port 的多维通配匹配。这种设计来自分布式系统的实际需求：

- 全局默认值 → 所有节点共享
- Zone 级覆盖 → 同一机房/可用区统一配置
- 节点级覆盖 → 特定机器调优
- 查询时返回匹配度最高的配置（`find_newest()` 优先返回高版本）

### 10.5 配置持久化的容错设计

`dump2file()` 采用**「写临时文件 → fsync → rename 替换」**的经典原子写入模式（`ob_config_manager.cpp:217-293`）：

1. 写入 `path.tmp` 文件
2. `fsync()` 确保数据落盘
3. 旧文件重命名为 `path.history`（备份）
4. 临时文件重命名为目标文件

这样即使在写入过程中掉电，最多丢失一次配置变更，而不会破坏已有配置文件的完整性。

---

## 十一、总结

OceanBase 的 ObConfig 配置管理子系统是一个**面向性能、支持运行时动态变更、拥有完备校验体系的配置中心**。

其核心设计亮点：

1. **编译期配置定义**：通过宏体系在头文件中定义所有配置项，编译期生成成员变量，运行时直接访问
2. **三级生效模型**：DYNAMIC_EFFECTIVE（立即生效）— STATIC_EFFECTIVE（重启生效）— READONLY（禁止修改）
3. **版本驱动的变更机制**：rootserver 生成递增版本号，OBServer 异步拉取和热加载
4. **多维配置覆盖**：通过 `ObSystemConfigKey` 的 `match()` 支持全局/Zone/节点三级覆盖
5. **订阅者模式的热加载**：各子系统通过 `reload_config()` 响应配置变更，而非统一遍历
6. **原子性持久化**：边写边改名 + fsync 保证配置文件的完整性

---

## 附录：关键文件行号速查

| 文件 | 关键行号 | 内容 |
|------|---------|------|
| `ob_config.h` | 49-66 | 配置项类型枚举 `ObConfigItemType` |
| `ob_config.h` | 75-147 | `ObConfigItem` 基类定义 |
| `ob_config.h` | 130-132 | `reboot_effective()` 判断是否需重启 |
| `ob_config.cpp` | 114-120 | `set_value_with_lock()` — 带锁的写入路径 |
| `ob_config.cpp` | 137-156 | `set_value_unsafe()` — 值写入核心逻辑 |
| `ob_config_helper.h` | 27-32 | `ObConfigChecker` 校验器基类 |
| `ob_config_helper.h` | 321-332 | `ObConfigContainer` 定义 |
| `ob_config_manager.h` | 34-101 | `ObConfigManager` 类定义 |
| `ob_config_manager.h` | 55-59 | 三个版本号：`get_version/get_current_version/get_read_version` |
| `ob_config_manager.cpp` | 38-50 | `base_init()` 初始化 |
| `ob_config_manager.cpp` | 154-175 | `reload_config()` 热加载 |
| `ob_config_manager.cpp` | 178-202 | `config_backup()` 配置备份 |
| `ob_config_manager.cpp` | 217-293 | `dump2file_unsafe()` 原子持久化 |
| `ob_config_manager.cpp` | 298-353 | `got_version()` 版本通知处理 |
| `ob_config_manager.cpp` | 356-393 | `UpdateTask::runTimerTask()` 本地更新 |
| `ob_config_manager.cpp` | 399-459 | `update_local()` 从内表读取配置 |
| `ob_reload_config.h` | 25-35 | `ObReloadConfig` 函数对象 |
| `ob_reload_config.cpp` | 17-36 | `reload_ob_logger_set()` 日志热加载 |
| `ob_server_config.h` | 93-153 | `ObServerConfig` 类定义 |
| `ob_server_config.h` | 120-122 | 通过宏展开生成配置项成员 |
| `ob_server_config.h` | 143-144 | `GCONF` 和 `GMEMCONF` 宏 |
| `ob_common_config.h` | 19-31 | `ObInitConfigContainer` |
| `ob_common_config.h` | 34-76 | `ObBaseConfig` |
| `ob_system_config.h` | 27-59 | `ObSystemConfig` 类定义 |
| `ob_system_config_key.h` | 42-84 | `ObSystemConfigKey` 多级匹配实现 |
| `ob_parameter_macro.h` | 72-105 | 配置项定义宏体系 |
| `ob_parameter_attr.h` | 32-42 | `ObParameterAttr` 元数据 |
| `ob_parameter_attr.h` | 43-71 | `ObParameterAttr` 类定义 |
| `ob_parameter_attr.cpp` | 37-43 | `is_static()` / `is_readonly()` |
| `ob_parameter_seed.ipp` | 1-50 | 配置项定义示例：DEF_STR/DEF_INT/DEF_CAP |
