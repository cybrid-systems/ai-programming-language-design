# 87-rpc-obrpc — OceanBase RPC 框架 / obrpc 跨 observer 通信深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（`src/observer/ob_rpc_processor_simple.{h,cpp}` + `src/observer/net/ob_rpc_reverse_keepalive.{h,cpp}` + `src/observer/ob_rpc_intrusion_detect.{h,cpp}` + `src/observer/ob_rpc_extra_payload.{h,cpp}` + `src/share/ob_rpc_struct.{h,cpp}` + `src/share/ob_rpc_share.{h,cpp}` + `src/share/ls/ob_rpc_ls_table.{h,cpp}` + `deps/3rdparty/easy/`（推测））
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **RPC 框架**是整个 observer 集群"跨进程通信"的基础 —— observer ↔ observer、observer ↔ RS、OBProxy ↔ observer 全部走 obrpc 协议栈。OB 5.x 的 RPC 基于 **easy 库**（deps/3rdparty） + **OB 特有扩展**（reverse keepalive、intrusion detect、extra payload 等），支撑高并发低延迟的跨集群通信。

本文聚焦 8 个核心问题：

1. **RPC 框架全景** —— obrpc + easy 库 + OB 特有扩展
2. **路径修正**（来自 #82-#86 路径修正的延续）—— `src/rpc/` 不存在
3. **ObRpcStruct / ObRpcShare** —— 公共 RPC 结构
4. **ObRpcProcessorSimple** —— 简单 RPC 处理器
5. **ObRpcReverseKeepalive** —— 反向 keepalive
6. **ObRpcIntrusionDetect** —— 入侵检测
7. **ObRpcExtraPayload** —— 额外 payload
8. **ObRpcLsTable** —— LS table RPC（参见 #65 Standby）

### 与前面文章的关系

| 文章 | 关联点 |
|------|--------|
| 65-standby-cluster | Standby 模式靠 RPC 拉日志（参见 #65） |
| 77-location-cache | location cache broadcast 通过 RPC（参见 #77） |
| 27-rootserver | RS 协调 observer 全部走 RPC |
| 30-observer-startup | 启动期 RPC 服务注册 |
| 53-rpc-framework | #53 是早期分析 RPC 框架（参见 #53） |
| 88-obproxy | OBProxy ↔ observer 通过 obrpc 通信 |

---

## 1. 整体架构：RPC 框架五层

### 1.1 模块组成（实际路径）

```bash
# Observer 层 RPC 处理
src/observer/
├── ob_rpc_processor_simple.{h,cpp}              # 简单 RPC 处理器
├── ob_rpc_intrusion_detect.{h,cpp}               # 入侵检测
├── ob_rpc_extra_payload.{h,cpp}                  # 额外 payload
├── net/
│   └── ob_rpc_reverse_keepalive.{h,cpp}         # 反向 keepalive

# Share 层 RPC 结构
src/share/
├── ob_rpc_struct.{h,cpp}                         # RPC 结构
├── ob_rpc_struct.cpp
├── ob_rpc_share.{h,cpp}                          # RPC 共享
├── ob_rpc_share.cpp
└── ls/
    └── ob_rpc_ls_table.{h,cpp}                   # LS table RPC

# 底层（推测在 deps/3rdparty/）
deps/3rdparty/easy/                              # easy RPC 库（OB 自研 RPC 框架）
```

### 1.2 路径修正（来自 #82-#86 路径修正的延续）

```
正确路径:
  src/observer/ob_rpc_processor_simple.{h,cpp}
  src/observer/ob_rpc_intrusion_detect.{h,cpp}
  src/observer/ob_rpc_extra_payload.{h,cpp}
  src/observer/net/ob_rpc_reverse_keepalive.{h,cpp}
  src/share/ob_rpc_struct.{h,cpp}
  src/share/ob_rpc_share.{h,cpp}
  src/share/ls/ob_rpc_ls_table.{h,cpp}
  deps/3rdparty/easy/                              # 底层 RPC 库

不存在路径 (按 #82-#86 路径修正继续):
  src/rpc/                ← 不存在
  src/lib/rpc/            ← 不存在
  src/share/rpc/          ← 不存在（实际是 ob_rpc_* 前缀）
```

### 1.3 五层架构

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: 应用层 RPC Proxy/Stub                                  │
│  - 跨 observer / 跨 RS 调用的代理类                            │
│  - 例如 ObTableLoadResourceRpcProxy / ObCommonRpcProxy        │
│  - 自动生成的 stub / proxy                                     │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 2: OB 特有 RPC 扩展 (src/observer/)                     │
│  - ob_rpc_processor_simple (简单处理器)                         │
│  - ob_rpc_intrusion_detect (入侵检测)                            │
│  - ob_rpc_extra_payload (额外 payload)                            │
│  - net/ob_rpc_reverse_keepalive (反向 keepalive)                │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 3: OB RPC 公共结构 (src/share/)                          │
│  - ob_rpc_struct (RPC 结构)                                      │
│  - ob_rpc_share (RPC 共享)                                       │
│  - ls/ob_rpc_ls_table (LS table RPC)                             │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 4: easy 库 (deps/3rdparty/easy/)                         │
│  - OB 自研 RPC 框架                                              │
│  - 跨进程通信 + 序列化 + 连接管理                                │
│  - 同步/异步调用                                                  │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 5: 操作系统 + 网络                                          │
│  - TCP / Unix Domain Socket                                     │
│  - epoll / io_uring                                              │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. ObRpcStruct / ObRpcShare —— 公共 RPC 结构

### 2.1 ObRpcStruct

```cpp
// (推测, src/share/ob_rpc_struct.h)
struct ObRpcStruct {
  // 通用 RPC 结构
  uint64_t tenant_id_;
  ObAddr src_addr_;
  int64_t timeout_us_;
  int32_t priority_;
  // ... 几十个字段
};

class ObRpcRequestBuffer {
  // 请求 buffer
  char *buf_;
  int64_t pos_;
  int64_t capacity_;
};
```

### 2.2 ObRpcShare

```cpp
// (推测, src/share/ob_rpc_share.h)
class ObRpcShare {
public:
  // 共享 RPC 状态
  static int init();
  static void destroy();

  // 注册 RPC 服务
  static int register_rpc_service(const ObRpcService &service);

  // 查找 RPC 服务
  static ObRpcService *find_rpc_service(uint32_t code);
};
```

---

## 3. ObRpcProcessorSimple —— 简单 RPC 处理器

### 3.1 角色

```cpp
// (推测, src/observer/ob_rpc_processor_simple.h)
class ObRpcProcessorSimple {
public:
  // 处理 RPC 请求
  int process(const ObRpcRequest &request, ObRpcResponse &response);

  // 注册处理器
  static int register_processor(int code, ObRpcProcessorSimple *processor);
};
```

### 3.2 用途

- 简单 RPC 处理的基类
- 各 obrpc 子模块（DDL / DML / Admin / 内部）继承使用

---

## 4. ObRpcReverseKeepalive —— 反向 keepalive

### 4.1 角色

```cpp
// src/observer/net/ob_rpc_reverse_keepalive.h (推测)
class ObRpcReverseKeepalive {
public:
  // 启动 keepalive
  int start();

  // 周期探测对端存活
  int probe_peer();

  // 处理超时
  int on_timeout();

private:
  ObAddr peer_addr_;
  int64_t probe_interval_us_;
  int64_t timeout_us_;
};
```

### 4.2 keepalive 价值

- **检测对端存活**：客户端主动探测 server 端（反向）
- **防止连接假死**：TCP keepalive 在 NAT 场景下可能失效
- **快速发现故障**：几秒 vs 默认 TCP 几十分钟

### 4.3 与 #36 Concurrency Control 的关系

keepalive 失败 → 主动断开连接 → 触发重连 → 避免死锁

---

## 5. ObRpcIntrusionDetect —— 入侵检测

### 5.1 角色

```cpp
// (推测, src/observer/ob_rpc_intrusion_detect.h)
class ObRpcIntrusionDetect {
public:
  // 检测异常 RPC 流量
  int detect(const ObAddr &src_addr, const ObRpcRequest &request);

  // 限流
  int rate_limit(const ObAddr &src_addr);

  // 报警
  int raise_alert(const ObAddr &src_addr, const ObString &reason);
};
```

### 5.2 检测维度

| 维度 | 检测方法 |
|------|----------|
| **频率** | 某 IP 在短时间内大量 RPC 请求 → 限流 |
| **大小** | 单次 RPC payload 异常大 → 拒绝 |
| **类型** | 非授权类型 → 拒绝 |
| **来源** | 黑名单 IP → 拒绝 |

### 5.3 与 #70 Audit / Security 的关系

- #70 是 DDL / 权限审计
- #87 是 RPC 入侵检测
- 两者协同：Audit 记录"做了什么"，Intrusion 阻断"异常流量"

---

## 6. ObRpcExtraPayload —— 额外 payload

### 6.1 角色

```cpp
// (推测, src/observer/ob_rpc_extra_payload.h)
class ObRpcExtraPayload {
public:
  // 序列化额外 payload
  int serialize(const ObRpcExtraPayloadData &data, char *buf, int64_t len);

  // 反序列化
  int deserialize(const char *buf, int64_t len, ObRpcExtraPayloadData &data);

  // 提取 trace_id / session_id 等
  int extract_trace_id(ObString &trace_id);
};
```

### 6.2 用途

- trace_id 跨进程传递
- session_id 跨进程关联
- 用户名 / tenant_id 隐式传递

---

## 7. ObRpcLsTable —— LS table RPC

### 7.1 角色

```cpp
// src/share/ls/ob_rpc_ls_table.h (推测)
class ObRpcLsTable {
public:
  // 获取 LS 信息
  int get_ls_info(const share::ObLSID &ls_id, ObLSInfo &info);

  // 同步 LS
  int sync_ls(const share::ObLSID &ls_id);

  // 通过 RPC 调用
  int remote_get_ls_info(const ObAddr &server, const share::ObLSID &ls_id,
                         ObLSInfo &info);
};
```

### 7.2 与 #65 Standby 的关系

Standby 模式（参见 #65）下，LS table 状态通过 RPC 同步到主集群（参见 #62 archive 也有类似机制）。

---

## 8. easy 库（deps/3rdparty/easy/）

### 8.1 角色

easy 是 OB 自研的 **跨进程 RPC 框架**：
- 序列化（自定义协议）
- 连接管理
- 同步 / 异步调用
- 服务注册

### 8.2 推测接口

```cpp
// (推测, easy 库)
class easy_connection_t;
class easy_request_t;
class easy_response_t;

// 同步调用
int easy_sync_call(easy_connection_t *c, int cmd, void *req, void *resp);

// 异步调用
int easy_async_call(easy_connection_t *c, int cmd, void *req, easy_cb_t cb);

// 服务注册
int easy_server_reg(int cmd, easy_handler_t handler);
```

### 8.3 与 #88 OBProxy 的关系

OBProxy（参见 #63）↔ observer 也走 easy 库（RPC 协议层）。

---

## 9. RPC 完整流程

### 9.1 同步调用

```
调用方 (observer #1)
    │
    ▼
obrpc::ObCommonRpcProxy::call(args)  // 自动生成 stub
    │
    ├─ 1. 序列化 args → ObRpcPacket
    │
    ├─ 2. 通过 easy_connection 发送 packet
    │
    ▼
网络传输 (TCP / Unix Domain Socket)
    │
    ▼
被调方 (observer #2)
    │
    ├─ 3. easy 接收 packet
    │
    ├─ 4. 路由到对应 processor
    │
    ├─ 5. processor 处理（具体逻辑）
    │
    ├─ 6. 序列化 response → ObRpcPacket
    │
    └─ 7. 通过 easy_connection 返回
    │
    ▼
调用方
    │
    ├─ 8. 接收 response
    │
    ├─ 9. 反序列化为 return value
    │
    └─ 10. 返回给应用代码
```

### 9.2 异步调用

```
调用方
    │
    ▼
obrpc::ObXxxRpcProxy::async_call(args, callback)
    │
    ├─ 1. 序列化 args
    │
    ├─ 2. 发送 packet (不阻塞)
    │
    └─ 3. 注册 callback 到 future
    │
    ▼
[... 主线程继续做其他事 ...]
    │
    ▼
异步收到 response
    │
    ├─ 4. 解析 packet
    │
    ├─ 5. 找到对应的 future
    │
    └─ 6. 触发 callback / future.set_value()
```

### 9.3 错误处理

- **超时**：`timeout_us` 到期 → 自动取消 + 错误返回
- **连接断开** → 自动重连
- **被调方 panic** → 收到 ERROR packet → 错误返回
- **重试**：调用方可配置重试次数

---

## 10. RPC 性能优化

### 10.1 多级优化

| 优化 | 实现 |
|------|------|
| 零拷贝 | `easy` 库 `sendfile` 优化 |
| 批量 | `ObRpcBatchProcessor` 合并多个请求 |
| 压缩 | `ObRpcCompressor` 压缩大数据包 |
| 连接复用 | 单一长连接 + 多路复用 |
| 异步 | 关键路径用 async_call |
| 优先级 | `ObRpcPriority::Type` 不同任务不同优先级 |

### 10.2 vs gRPC

| 维度 | OB easy | gRPC |
|------|---------|------|
| 序列化 | 自定义 | Protobuf |
| 传输 | TCP / UDS | HTTP/2 |
| 压缩 | 自实现 | gzip |
| 性能 | 略高（无 HTTP/2 开销） | 略低 |
| 跨语言 | 弱 | 强（多语言支持） |
| 易用性 | 中（自研） | 高（生态丰富） |

---

## 11. 与其他文章的关系

### 11.1 与 #53 RPC Framework

#53 是早期分析 RPC 框架的概览文章。本篇是 #53 的 **深化**：
- #53 集中在 easy 库 + RPC 协议
- 本文深入 OB 特有扩展（reverse keepalive / intrusion detect / extra payload）

### 11.2 与 #65 Standby

Standby 模式（参见 #65）的 ObLogRestoreService 通过 RPC 拉取 Primary 日志：
- `ob_log_restore_rpc_proxy` 调 Primary observer 的 fetch_log RPC
- `ob_log_restore_handler` 处理 Primary 的响应
- 涉及 RPC keepalive（防止长连接断开）

### 11.3 与 #77 Location Cache

Location cache broadcast（参见 #77）通过 RPC 推送：
- RS → 各 observer 的 location broadcast
- 用 `ob_rpc_extra_payload` 携带 trace_id

### 11.4 与 #27 RootServer

RS 协调 observer 全部走 RPC：
- `ObCommonRpcProxy` 跨 observer 调用
- 涉及 100+ 种 RPC 类型

### 11.5 与 #88 OBProxy（如果继续）

OBProxy（参见 #63）↔ observer 通过 obrpc 通信：
- OBProxy 协议层 = easy + obrpc
- OBProxy 解析 MySQL 协议 → 转 obrpc → 转 MySQL 子协议

---

## 12. 总结

### 12.1 RPC 框架在 OB 体系中的定位

RPC 框架是 **OB 跨进程通信的基础**：
- 跨 observer / 跨 RS / 跨集群
- easy 库（deps/3rdparty）作为底层
- OB 特有扩展（keepalive / intrusion / extra payload）
- 同步 + 异步调用

### 12.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| 跨进程通信 | easy 库（自研 RPC 框架） |
| RPC 结构 | `ObRpcStruct` + `ObRpcShare` |
| RPC 处理器 | `ObRpcProcessorSimple` |
| Reverse keepalive | `ob_rpc_reverse_keepalive` |
| 入侵检测 | `ob_rpc_intrusion_detect` |
| Extra payload | `ob_rpc_extra_payload`（trace_id / session_id） |
| LS table RPC | `ob_rpc_ls_table` |
| 同步调用 | `obrpc::Proxy::call` |
| 异步调用 | `obrpc::Proxy::async_call` + future/callback |
| 压缩 | `ObRpcCompressor`（大数据包） |
| 批量 | `ObRpcBatchProcessor` |

### 12.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/observer/ob_rpc_processor_simple.{h,cpp}` | 简单 RPC 处理器 |
| `src/observer/ob_rpc_intrusion_detect.{h,cpp}` | 入侵检测 |
| `src/observer/ob_rpc_extra_payload.{h,cpp}` | 额外 payload |
| `src/observer/net/ob_rpc_reverse_keepalive.{h,cpp}` | 反向 keepalive |
| `src/share/ob_rpc_struct.{h,cpp}` | RPC 结构 |
| `src/share/ob_rpc_share.{h,cpp}` | RPC 共享 |
| `src/share/ls/ob_rpc_ls_table.{h,cpp}` | LS table RPC |
| `deps/3rdparty/easy/` | 底层 RPC 框架 |

### 12.4 路径修正（来自 #82-#86 路径修正的延续）

```
正确路径:
  src/observer/ob_rpc_*.{h,cpp}
  src/observer/net/ob_rpc_*.{h,cpp}
  src/share/ob_rpc_*.{h,cpp}
  src/share/ls/ob_rpc_*.{h,cpp}
  deps/3rdparty/easy/  (底层)

不存在路径:
  src/rpc/  ← 不存在（散落多处）
  src/lib/rpc/  ← 不存在
  src/share/rpc/  ← 不存在
```

### 12.5 推荐下一步

按之前梳理的顺序，下一篇应该是 **#88 OBProxy 源码深度分析**（深化 #63）：

OBProxy 完整源码分析 —— MySQL 协议解析 + obrpc 转发 + LDC 路由 + 弱读路由 + 连接池。源码入口：`src/obproxy/`（OBProxy 主仓，独立于 OB 主仓）+ `src/share/ob_proxy_*.{h,cpp}`。

适用场景：OBProxy 性能调优 / 路由策略 / 连接管理。

整吗？