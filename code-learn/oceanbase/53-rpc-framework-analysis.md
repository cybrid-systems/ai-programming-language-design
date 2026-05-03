# 53-rpc-framework — OceanBase 节点间 RPC 通信、协议栈与流控

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

OceanBase 是一个分布式数据库，所有分布式操作——PALF 日志复制、事务两阶段提交、分区迁移、GTS 请求、位置查询——都依赖**节点间 RPC 通信**。RPC 框架是 OceanBase 分布式架构的"血管"，承载了所有节点间的控制流和数据流。

### 解决的问题

1. **节点通信**：OBServer 节点之间如何高效、可靠地交换请求和响应
2. **协议分层**：TCP 之上如何定义应用层协议，包括编解码、压缩、校验
3. **流控与保护**：接收方过载时如何反压、请求超时如何管理、内存如何有界

### RPC 框架代码分布

| 路径 | 文件数 | 职责 |
|------|--------|------|
| `deps/oblib/src/rpc/obrpc/` | 57 | OceanBase 的 RPC 语义层：Proxy/Processor/Packet |
| `deps/oblib/src/rpc/frame/` | 20 | 传输层抽象：Transport/Handler/Deliver/Queue |
| `deps/oblib/src/rpc/easy/` | 2 | 对 libeasy 的封装头文件 |
| `deps/oblib/src/rpc/pnio/` | ~55 | 新一代高性能 IO 框架（C 实现） |
| 各模块 `ob_*_proxy.h`、`ob_*_processor.h` | 每个模块约 2~3 | 具体的 RPC 接口定义 |

### 两代 RPC 框架

OceanBase 经历了从 **easy**（基于阿里巴巴的 libeasy 网络库）到 **pnio**（自研高性能 IO 框架）的演进：

| 对比项 | easy（旧） | pnio（新） |
|--------|-----------|-----------|
| 底层库 | libeasy（事件驱动，epoll） | 自研 pnio（epoll + io_uring 就绪） |
| 内存管理 | easy_pool（线性分配） | 自定义 pn_send_alloc / pn_resp_pre_alloc |
| IO 线程模型 | easy 固定 IO 线程 + worker 线程 | pnio IO 线程内直接处理，减少上下文切换 |
| 流控 | easy ratelimit（全局） | pnio 组级别 ratelimit + 写队列 |
| 连接管理 | easy 自动管理 | pnio sock 工厂 + 写队列 |

---

## 1. RPC 请求/响应模式 — Proxy + Processor

OceanBase 所有 RPC 接口遵循统一的模式：

```
客户端：ObXXProxy（继承 ObRpcProxy） → 序列化 → 发送
服务端：ObXXProcessor（继承 ObRpcProcessor） → 反序列化 → 处理
命令码：ObXXPCode（PCODE_DEF 宏注册）
```

### 1.1 RPC 命令码（Packet Code）

所有的 RPC 命令码在一个中央文件中定义：

```cpp
// deps/oblib/src/rpc/obrpc/ob_rpc_packet_list.h — 共 1456 行，定义了 500+ 个 RPC 命令码
#define MAX_PCODE 0xFFFF

// 占位示例
PCODE_DEF(OB_TEST_PCODE, 0x001)
PCODE_DEF(OB_ERROR_PACKET, 0x010)
PCODE_DEF(OB_GET_GTS_REQUEST, 0x421)
PCODE_DEF(OB_PREPARE, 0x601)         // 事务预提交
PCODE_DEF(OB_DO_COMMIT, 0x604)       // 事务提交
PCODE_DEF(OB_LOG_APPEND, 0xA01)      // PALF 日志追加
// ... 500+ 个 PCODE
```

命令码是一个 `uint16_t` 枚举，通过 `PCODE_DEF` 宏展开到 `ObRpcPacketCode`。`ObRpcPacketSet` 提供 `idx_of_pcode` / `name_of_pcode` 的双向映射：

```cpp
// ob_rpc_packet.h:95-125  — doom-lsp 确认
class ObRpcPacketSet
{
  // 从 PCODE_DEF 列表中生成：
  //   names_[]     — "OB_GET_GTS_REQUEST" 等
  //   pcode_[]     — OB_GET_GTS_REQUEST 等
  //   index_[]     — 逆映射，OB_PACKET_NUM 个槽位
  int64_t idx_of_pcode(ObRpcPacketCode code) const;
  const char *name_of_pcode(ObRpcPacketCode code) const;
};
```

### 1.2 RPC 客户端（Proxy）

客户端通过 `ObRpcProxy` 基类发出 RPC 请求：

```cpp
// deps/oblib/src/rpc/obrpc/ob_rpc_proxy.h:50-300  — doom-lsp 确认
class ObRpcProxy
{
public:
  // 同步调用模板
  template <typename Input, typename Out>
  int rpc_call(ObRpcPacketCode pcode,
               const Input &args, Out &result,
               Handle *handle, const ObRpcOpts &opts);

  // 异步调用模板
  template <class pcodeStruct>
  int rpc_post(const typename pcodeStruct::Request &args,
               AsyncCB<pcodeStruct> *cb,
               const ObRpcOpts &opts);

  // 异步回调基类
  template <class pcodeStruct>
  class AsyncCB : public rpc::frame::ObReqTransport::AsyncCB
  {
    Request arg_;
    Response result_;
    ObRpcResultCode rcode_;
  };

protected:
  const rpc::frame::ObReqTransport *transport_;  // 传输层
  common::ObAddr dst_;                           // 目标地址
  int64_t timeout_;                              // 超时（默认 9s）
  uint64_t tenant_id_;
  int32_t group_id_;                              // 负载均衡组
  common::ObCompressorType compressor_type_;      // 压缩类型
  // ...
};
```

具体的 Proxy 通过宏 `RPC_AP` 定义：

```cpp
// src/storage/tx/ob_gts_rpc.h:74-77  — doom-lsp 确认
class ObGtsRpcProxy : public obrpc::ObRpcProxy
{
public:
  RPC_AP(PR1 post, OB_GET_GTS_REQUEST, (transaction::ObGtsRequest), ObGtsRpcResult);
  RPC_AP(PR1 post, OB_GET_GTS_ERR_RESPONSE, (transaction::ObGtsErrResponse), ObGtsRpcResult);
};
```

### 1.3 RPC 服务端（Processor）

服务端通过 `ObRpcProcessor` 模板基类处理请求：

```cpp
// deps/oblib/src/rpc/obrpc/ob_rpc_processor.h:30-65  — doom-lsp 确认
template <class T>
class ObRpcProcessor : public ObRpcProcessorBase
{
public:
  static constexpr ObRpcPacketCode PCODE = T::PCODE;

protected:
  virtual int process() = 0;

  // 反序列化请求
  int decode_base(const char *buf, const int64_t len, int64_t &pos)
  { return common::serialization::decode(buf, len, pos, arg_); }

  // 序列化响应
  int encode_base(char *buf, const int64_t len, int64_t &pos)
  { return common::serialization::encode(buf, len, pos, result_); }

protected:
  typename T::Request arg_;
  typename T::Response result_;
};
```

具体的 Processor：

```cpp
// src/storage/tx/ob_gts_rpc.h:90-98  — doom-lsp 确认
class ObGtsP : public ObRpcProcessor<obrpc::ObGtsRpcProxy::ObRpc<OB_GET_GTS_REQUEST>>
{
protected:
  int process();
  // process() 的实现：
  //   1. 从 arg_ 拿到 ObGtsRequest
  //   2. 调用 ts_mgr_->get_gts()
  //   3. 填充 result_ → ObGtsRpcResult
};
```

### 1.4 RPC 宏展开

`RPC_AP` 宏在 `ob_rpc_proxy_macros.h` 中展开：

```cpp
// ob_rpc_proxy_macros.h:150-180  — doom-lsp 确认
// RPC_AP(PR1 post, OB_GET_GTS_REQUEST, (InputType), OutputType)
// 展开为：
// 1. 定义 ObRpc<OB_GET_GTS_REQUEST> 结构体（含 PCODE、Request、Response）
// 2. 生成 post() / post_() 方法，内部调用 rpc_call() / rpc_post()
// 3. PR1 宏设置优先级为 ORPR1
```

`RPC_S` 宏用于定义同步调用，`RPC_AP` 用于异步调用。

---

## 2. RPC 数据包（Packet）格式

RPC 协议在 TCP 之上定义了自己的应用层报文格式。

### 2.1 报文头

```cpp
// deps/oblib/src/rpc/obrpc/ob_rpc_packet.h:145-200  — doom-lsp 确认
class ObRpcPacketHeader
{
public:
  static const uint8_t  HEADER_SIZE = 136;     // 136 字节头部
  // 标志位
  static const uint16_t RESP_FLAG              = 1 << 15;  // 响应包
  static const uint16_t STREAM_FLAG            = 1 << 14;  // 流式包
  static const uint16_t STREAM_LAST_FLAG       = 1 << 13;  // 流式末尾
  static const uint16_t UNNEED_RESPONSE_FLAG   = 1 << 10;  // 无需响应（fire-and-forget）
  static const uint16_t REQUIRE_REROUTING_FLAG = 1 << 9;   // 需要重路由
  static const uint16_t ENABLE_RATELIMIT_FLAG  = 1 << 8;   // 启用速率限制

  uint64_t checksum_;               // 校验和
  ObRpcPacketCode pcode_;           // 命令码
  uint8_t  hlen_;                   // 头部长度
  uint8_t  priority_;               // 优先级（0-11，ORPR1-ORPR11）
  uint16_t flags_;                  // 标志位
  uint64_t tenant_id_;              // 租户 ID
  uint64_t session_id_;            // 会话 ID
  uint64_t trace_id_[4];            // 256 位 trace ID
  uint64_t timeout_;                // 超时（微秒）
  int64_t  timestamp_;              // 发送时间戳
  ObRpcCostTime cost_time_;         // 耗时统计
  ObCompressorType compressor_type_; // 压缩类型
};
```

**设计要点**：
- 头部 136 字节，包含完整的 trace 和监控信息
- `priority_` 支持 12 级优先级（ORPR1-ORPR11 + DDL）
- 响应包同时复用同一结构，`RESP_FLAG` 标记方向
- trace_id 256 位，支持分布式链路追踪

### 2.2 报文序列化

RPC 报文的序列化分两层：

1. **Header**：固定格式，使用 `ObRpcPacket::encode` / `decode` 方法直接操作字节
2. **Payload**（请求和响应体）：使用 OceanBase 自研的统一序列化框架

```cpp
// deps/oblib/src/rpc/obrpc/ob_rpc_packet.h:200-250  — doom-lsp 确认
class ObRpcPacket : public ObRpcPacketHeader
{
public:
  int encode(char *buf, int64_t len, int64_t &pos) const;
  int decode(const char *buf, int64_t len, int64_t &pos);
  int64_t get_encoded_length() const;
  int set_no_compress();
  int set_compress(const common::ObCompressorType compressor);
};
```

---

## 3. 序列化框架 — OB_UNIS

OceanBase 使用自研的序列化格式，核心在 `ob_unify_serialize.h`。

### 3.1 核心宏

```cpp
// deps/oblib/src/lib/utility/ob_unify_serialize.h:270-370  — doom-lsp 确认
// 声明宏
#define OB_UNIS_VERSION(VER)              // 声明序列化版本
#define OB_SERIALIZE_MEMBER(CLS, ...)     // 自动生成 serialize/deserialize/size
#define OB_DEF_SERIALIZE(CLS)             // 手动定义 serialize 实现
#define OB_DEF_DESERIALIZE(CLS)           // 手动定义 deserialize 实现
```

### 3.2 序列化格式

OB_UNIS 序列化采用 **TLV（Type-Length-Value）风格**，但更紧凑：

```
[version: varint][payload_length: varint][member_1: varint|fixed][member_2: ...]
```

- Version 和 Length 使用 **varint 编码**（变长整型，小值用更少字节）
- 每个成员按声明顺序依次编码
- 支持嵌套结构、数组、指针（通过 `OB_UNIS_ENCODE_ARRAY` 等）
- 向下兼容：新版本添加字段时，旧版本反序列化跳过未知字段

### 3.3 使用示例

```cpp
// src/storage/tx/ob_gts_rpc.h:44-69  — doom-lsp 确认
class ObGtsRpcResult
{
  OB_UNIS_VERSION(1);                    // 声明版本号
public:
  TO_STRING_KV(K_(tenant_id), K_(status), K_(srr), K_(gts_start), K_(gts_end));
private:
  uint64_t tenant_id_;
  int status_;
  transaction::MonotonicTs srr_;
  int64_t gts_start_;
  int64_t gts_end_;
};

// OB_UNIS_VERSION(1) 展开为：
// - 声明 serialize/deserialize/get_serialize_size
// - 自动生成 serialize_/deserialize_/get_serialize_size_ 的成员序列化
```

### 3.4 序列化编码流程

```cpp
// deps/oblib/src/rpc/obrpc/ob_rpc_endec.h:40-100  — doom-lsp 确认
template <typename T>
int rpc_encode_req(ObRpcProxy& proxy, uint64_t gtid, ObRpcPacketCode pcode,
                   const T& args, const ObRpcOpts& opts,
                   char*& req, int64_t& req_sz, ...)
{
  // 1. 计算 payload 大小
  int64_t args_len = common::serialization::encoded_length(args);
  // 2. 从 pnio 分配缓冲区
  char* header_buf = (char*)pn_send_alloc(gtid, header_sz + payload_sz);
  // 3. 编码 header
  init_packet(proxy, pkt, pcode, opts, unneed_resp);
  pkt.encode(header_buf, header_sz + payload_sz, pos);
  // 4. 编码 payload（序列化请求体）
  common::serialization::encode(payload_buf, payload_sz, pos, args);
  // 5. 可选压缩
  if (compressor_type != INVALID_COMPRESSOR) {
    compress_and_encode(...);
  }
}
```

### 3.5 序列化的设计决策

**为什么自研序列化而非 protobuf？**

1. **紧凑性**：protobuf 需要维护 `.proto` 文件 + 代码生成，OB_UNIS 直接在 C++ 头文件中声明，编译期展开
2. **性能**：varint + 定长编码的组合，避免了 protobuf 的反射开销
3. **版本兼容**：每个结构体有一个版本号，`OB_UNIS_VERSION(V)` 编码进报文，服务端校验版本是否匹配
4. **C 兼容**：pnio 层是 C 实现，OB_UNIS 头文件仅使用 C++ 特性，不依赖 RTTI

---

## 4. 传输层框架（Frame）

`rpc/frame/` 目录定义了传输层的抽象接口。

### 4.1 ObReqTransport — 传输接口

```cpp
// deps/oblib/src/rpc/frame/ob_req_transport.h:50-200  — doom-lsp 确认
class ObReqTransport
{
public:
  // 异步回调基类
  class AsyncCB {
    int decode(void *pkt);
    int process();
    virtual AsyncCB *clone(const SPAlloc &alloc) const = 0;
  };

  // 请求结构
  class Request {
    easy_session_t *s_;
    obrpc::ObRpcPacket *pkt_;
    AsyncCB *cb_;
  };

  // 同步发送
  int send(const Request &req, Result &r) const;
  // 异步发送
  int post(const Request &req) const;

private:
  easy_io_t *eio_;
  easy_io_handler_pt *handler_;  // easy 事件处理函数
  int32_t sgid_;                  // 分片组 ID
};
```

### 4.2 ObReqHandler — easy 事件处理

```cpp
// deps/oblib/src/rpc/frame/ob_req_handler.h:40-80  — doom-lsp 确认
class ObReqHandler : public ObIEasyPacketHandler
{
public:
  void *decode(easy_message_t *m);          // 解码
  int encode(easy_request_t *r, void *packet);  // 编码
  int process(easy_request_t *r);           // 处理
  int on_connect(easy_connection_t *c);     // 连接建立
  int on_disconnect(easy_connection_t *c);  // 连接断开
  int on_idle(easy_connection_t *c);        // 空闲检测
  int on_close(easy_connection_t *c);       // 连接关闭

  static const uint8_t MAGIC_HEADER_FLAG[4];         // 魔数头
  static const uint8_t MAGIC_COMPRESS_HEADER_FLAG[4]; // 压缩魔数头
};
```

### 4.3 ObReqDeliver — 请求分发

```cpp
// deps/oblib/src/rpc/frame/ob_req_deliver.h:30-60  — doom-lsp 确认
class ObReqDeliver
{
public:
  virtual int deliver(rpc::ObRequest &req) = 0;  // 将请求分发到队列
  virtual void stop() = 0;
};
```

分发器将解码后的请求路由到对应的队列，实现隔离。

### 4.4 ObReqQueue — 请求队列（Worker 线程入口）

```cpp
// deps/oblib/src/rpc/frame/ob_req_queue_thread.h:30-80  — doom-lsp 确认
class ObReqQueue
{
public:
  bool push(ObRequest *req, int max_queue_len, bool block = true);
  void loop();  // worker 线程主循环

private:
  int process_task(ObLink *task);  // 调用 QHandler → Processor

  common::ObPriorityQueue<1> queue_;  // 优先级队列（单优先级）
  ObiReqQHandler *qhandler_;

  static const int64_t MAX_PACKET_SIZE = 2 * 1024 * 1024L;  // 2MB
};
```

### 4.5 传输层级关系

```
[RPC 语义层]                    ObXXProxy / ObXXProcessor
     ↕ serialize/deserialize
[RPC 报文层]                    ObRpcPacketHeader + OB_UNIS
     ↕ encode/decode
[传输层]                        ObReqTransport / ObReqHandler
     ↕ easy/pnio
[网络层]                        libeasy / pnio
     ↕ TCP
[物理层]                        套接字/网卡
```

---

## 5. 两代 IO 框架：easy vs pnio

### 5.1 easy（旧框架 — libeasy）

easy 是基于阿里巴巴 libeasy 网络库的事件驱动框架：

- 一个 `easy_io_t` 管理所有连接
- 每个 `easy_io_handler_pt` 提供 `decode/encode/process` 回调
- 一个请求进来：`decode` → 反序列化 → 丢入 worker 队列 → worker 处理 → `encode` 响应
- 连接自动管理：`on_connect / on_disconnect` 跟踪连接生命周期

easy 使用 `ObReqTransport` 封装，头文件引用了 `io/easy_io.h`：

```cpp
// ob_req_transport.h:25  — doom-lsp 确认
#include "io/easy_io.h"
```

### 5.2 pnio（新框架 — 自研高性能 IO）

pnio 是 OceanBase 自研的新一代 C 语言 IO 框架，设计目标是更高的性能和更低的延迟。

**核心接口**：

```cpp
// deps/oblib/src/rpc/pnio/interface/group.h:30-100  — doom-lsp 确认
// 启动监听
PN_API int pn_listen(int port, serve_cb_t cb);
// 为监听器分配 IO 线程组
PN_API int pn_provision(int listen_id, int grp, int thread_count);
// 发送请求（客户端）
PN_API int pn_send(uint64_t gtid, struct sockaddr_storage* sock_addr,
                   const pn_pkt_t* pkt, uint32_t* pkt_id_ret);
// 发送响应（服务端）
PN_API int pn_resp(uint64_t req_id, const char* buf, int64_t hdr_sz,
                   int64_t payload_sz, int64_t resp_expired_abs_us);
// 速率限制
PN_API int pn_ratelimit(int grp_id, int64_t value);
```

**pnio 分组模型**：

```
pn_listen(port, serve_cb)          // 主监听线程
    │
    ├── pn_provision(gid=1, thread_count=N)   // 组 1: 普通 RPC
    ├── pn_provision(gid=2, thread_count=N)   // 组 2: 日志复制（高优先级）
    └── pn_provision(gid=3, thread_count=M)   // 组 3: 限流组
```

每个组（Group）有多个 IO 线程（Thread），通过 `gtid = (gid<<32) + tid` 唯一标识：
- 发送端通过 `gtid` 确定发送到哪个 IO 线程
- 接收端通过 `dispatch_accept_fd_to_certain_group()` 将新连接分发到指定组

**pnio 分组含义**：

| 分组 | 用途 | 特点 |
|------|------|------|
| `DEFAULT_PNIO_GROUP` | 普通 RPC | 默认组 |
| `RATELIMIT_PNIO_GROUP` | 限流 RPC | 大请求（日志拉取、CDC）走限流组 |

```cpp
// ob_rpc_proxy.ipp:90-94  — doom-lsp 确认
if (OB_LS_FETCH_LOG2 == pcode_ || OB_CDC_FETCH_RAW_LOG == pcode_) {
  pnio_group_id = ObPocRpcServer::RATELIMIT_PNIO_GROUP;
}
```

**IO 线程模型**：

pnio 的每个 IO 线程运行一个事件循环（`eloop`）：

```c
// deps/oblib/src/rpc/pnio/io/eloop.h:20-35  — doom-lsp 确认
typedef struct eloop_t {
  int fd;                    // eventfd
  dlink_t ready_link;        // 就绪队列
  rl_impl_t rl_impl;         // 速率限制实现
  int8_t thread_usage[12];    // 线程使用统计
} eloop_t;
```

**服务端请求处理**（pkts）：

```c
// deps/oblib/src/rpc/pnio/nio/packet_server.h:30-65  — doom-lsp 确认
typedef struct pkts_t {
  eloop_t* ep;
  listenfd_t listenfd;
  pkts_sf_t sf;              // socket 工厂
  pkts_handle_func_t on_req;  // 请求处理回调
  evfd_t evfd;
  sc_queue_t req_queue;       // 请求队列
  idm_t sk_map;               // socket 映射
  time_wheel_t resp_ctx_hold; // 响应上下文超时管理
} pkts_t;
```

**客户端请求发送**（pktc）：

```c
// deps/oblib/src/rpc/pnio/nio/packet_client.h:30-80  — doom-lsp 确认
typedef struct pktc_t {
  eloop_t* ep;
  pktc_sf_t sf;              // socket 工厂
  evfd_t evfd;
  sc_queue_t req_queue;       // 请求队列
  timerfd_t cb_timerfd;       // 超时定时器
  time_wheel_t cb_tw;         // 时间轮（超时管理）
  hash_t sk_map;              // 目标地址 → socket 哈希
} pktc_t;
```

### 5.3 easy→pnio 的过渡

`ob_rpc_proxy.ipp` 中同时保留了两条路径：

```cpp
// ob_rpc_proxy.ipp:98-134  — doom-lsp 确认
// transport_impl_ == 1 → 使用 pnio（新路径）
if (proxy.transport_impl_ == 1) {
  // pnio 路径
  sockaddr_storage sock_addr;
  uint8_t thread_id = ObPocClientStub::balance_assign_tidx();
  pn_pkt_t pkt = { pnio_req, pnio_req_sz, expire, categ_id, cb, &cb };
  pn_send(gtid, &sock_addr, &pkt, &pkt_id);
} else {
  // easy 路径（旧路径）
  ObReqTransport::Request req;
  transport->create_request(req, dst, payload_sz, timeout, ...);
  transport->send(req, r);
}
```

通过 `ObRpcProxy::transport_impl_` 字段控制使用哪条路径，实现了平滑过渡。

### 5.4 pnio 的架构优势

| 特性 | easy | pnio |
|------|------|------|
| 内存分配 | easy_pool（线性分配，需整体释放） | 按需 `pn_send_alloc` |
| IO 线程内处理 | 必须投递到 worker 线程池 | 支持 IO 线程直接处理（减少上下文切换） |
| Socket 管理 | easy_connection_t | 自研 pktc_sk_t / pkts_sk_t + 写队列 |
| 超时管理 | easy 内置 | 自研时间轮（time_wheel_t） |
| 速率限制 | 全局 | 组级别，每个 socket 独立写队列 |
| 分组隔离 | 无 | 多组隔离（默认组/限流组） |

---

## 6. RPC 客户端与连接管理

### 6.1 ObNetClient — 客户端入口

```cpp
// deps/oblib/src/rpc/obrpc/ob_net_client.h:30-80  — doom-lsp 确认
class ObNetClient
{
public:
  int init(const rpc::frame::ObNetOptions opts);
  int get_proxy(ObRpcProxy &proxy);  // 获取传输层引用
  int load_ssl_config(...);           // SSL 支持

private:
  rpc::frame::ObNetEasy net_;           // easy 网络管理
  ObRpcNetHandler pkt_handler_;         // 包处理
  rpc::frame::ObReqTransport *transport_;
};
```

### 6.2 连接管理

- **连接池**：每个目标地址复用连接，`easy_session_t` 在请求完成后回收到池中
- **连接数**：每个 IO 线程到每个目标维持一条连接 (`OB_RPC_CONNECTION_COUNT_PER_THREAD = 1`)
- **心跳**：`ob_net_keepalive` 定期发送心跳包，检测连接健康状态
- **重连**：`on_disconnect` 事件触发自动重连

### 6.3 ObListener — 服务端多协议监听

```cpp
// deps/oblib/src/rpc/obrpc/ob_listener.h:30-70  — doom-lsp 确认
class ObListener : public lib::Threads
{
public:
  int listen_create(int port);
  int regist(uint64_t magic, int count, int *pipefd_array);

  // 支持 5 种协议
  #define MAX_PROTOCOL_TYPE_SIZE (5)

  // 每个协议类型有独立的 IO 线程管道池
  io_wrpipefd_map_t io_wrpipefd_map_[MAX_PROTOCOL_TYPE_SIZE];
};
```

监听器支持多协议类型：OceanBase RPC、MySQL 协议、复制的日志拉取等。每种协议注册自己的魔术字（magic），监听器通过魔术字识别协议并将连接分发到对应的 IO 线程池。

---

## 7. 流控与反压

### 7.1 组级别速率限制

pnio 支持对每个 IO 组进行速率限制：

```cpp
// deps/oblib/src/rpc/pnio/interface/group.h:85  — doom-lsp 确认
PN_API int pn_ratelimit(int grp_id, int64_t value);
// 设置 group 的带宽限制（字节/秒）
// RATE_UNLIMITED = INT64_MAX 表示不限速
```

### 7.2 写队列（Write Queue）

每个 socket 关联一个写队列：

```c
// deps/oblib/src/rpc/pnio/io/write_queue.h:20-35  — doom-lsp 确认
#define BUCKET_SIZE 1024
typedef struct write_queue_t {
  dqueue_t queue;                  // 队列
  int64_t pos;
  int64_t cnt;                     // 消息计数
  int64_t sz;                      // 总大小
  int16_t categ_count_bucket[BUCKET_SIZE];  // 按类别统计
} write_queue_t;
```

写队列的作用：
1. **缓存**：当发送方快于接收方时，数据缓存在写队列
2. **流控**：当队列积压超过阈值时，发送方被背压
3. **优先级**：高优先级请求优先发送

### 7.3 速率限制实现（rl_impl）

```c
// deps/oblib/src/rpc/pnio/io/rate_limit.h:15-30  — doom-lsp 确认
#define RL_SLEEP_TIME_US 100000  // 最小睡眠时间 100ms

typedef struct rl_impl_t {
  dlink_t ready_link;      // 就绪链表
  int64_t bw;              // 带宽限制（字节/秒）
  rl_timerfd_t rlfd;       // 定时器 fd
} rl_impl_t;

void rl_sock_push(rl_impl_t* rl, sock_t* sk);
```

实现基于**令牌桶**的思路：当 socket 的发送速率超过带宽限制时，把 socket 挂到限速队列，等待定时器触发后再继续发送。

### 7.4 配置阈值

```c
// deps/oblib/src/rpc/pnio/config.h:15-25  — doom-lsp 确认
#define MAX_REQ_QUEUE_COUNT   4096    // 最大请求队列长度
#define MAX_WRITE_QUEUE_COUNT 8192    // 最大写队列长度
#define MAX_CATEG_COUNT 4096          // 最大类别数
```

### 7.5 超时控制

RPC 超时分为两层：

1. **发送超时**：`ObRpcProxy::timeout_` 控制，默认 9s（`MAX_RPC_TIMEOUT = 9000 * 1000`）
2. **IO 超时**：pnio 在 `pktc_cb_t` 中维护 `expire_us`，使用时间轮（`time_wheel_t`）管理超时

```cpp
// deps/oblib/src/rpc/pnio/nio/packet_client.h:55-60  — doom-lsp 确认
struct pktc_cb_t {
  dlink_t timer_dlink;       // 时间轮链表
  int64_t expire_us;         // 超时时间
  // ...
};
```

### 7.6 请求优先级

ObRpcPriority 定义 12 级优先级：

```cpp
// ob_rpc_packet.h:55-65  — doom-lsp 确认
enum ObRpcPriority {
  ORPR_UNDEF = 0,
  ORPR1, ORPR2, ORPR3, ORPR4,
  ORPR5, ORPR6, ORPR7, ORPR8, ORPR9,
  ORPR_DDL = 10,     // DDL 操作最高优先级
  ORPR11 = 11,
};
```

优先级通过 `ObRpcPacketHeader::priority_` 字段在报文中传递，worker 线程使用 `ObPriorityQueue` 优先处理高优先级请求。

---

## 8. 数据包压缩

RPC 支持可选的负载压缩：

```cpp
// deps/oblib/src/rpc/obrpc/ob_rpc_compress_protocol_processor.h:20-50  — doom-lsp 确认
class ObRpcCompressProtocolProcessor
{
public:
  int compress(ObRpcPacket &pkt, char *buf, int64_t len,
               const ObCompressorType compressor);
  int decompress(ObRpcPacket &pkt, char *buf, int64_t len);
};
```

- 压缩类型由 `ObCompressorType` 枚举，支持 lz4、snappy、zlib 等
- 压缩后的报文头部 `MAGIC_COMPRESS_HEADER_FLAG` 标记为已压缩
- `ObRpcPacketHeader::compressor_type_` 字段指示使用的压缩算法
- 仅在 payload 超过阈值时启用压缩

---

## 9. 完整 RPC 调用流程（以 GTS 为例）

### 9.1 客户端调用

```
ObGtsRequestRpc::post()                        // 入口
  → ObGtsRpcProxy::post() (RPC_AP 宏展开)
    → ObRpcProxy::rpc_post()
      → rpc_encode_req()                       // 编码 + 序列化
        → ObRpcPacket::encode()                 // 编码头部
        → serialization::encode()               // 序列化请求体
        → (可选) compress()                     // 压缩
      → (transport_impl_ == 1)
        ? pn_send() [pnio]                     // 发送
        : transport->post() [easy]             // 发送
```

### 9.2 服务端处理

```
pkts_t::on_req() [pnio] / easy 回调          // 收到请求
  → ObReqHandler::decode()                    // 解码
  → ObReqDeliver::deliver()                   // 分发到 worker 队列
  → ObReqQueue::process_task()                // worker 线程处理
    → ObRpcProcessor::process()               // 虚拟分发
      → ObGtsP::process()                     // 实际处理逻辑
        → ts_mgr_->get_gts(args)              // 执行操作
        → encode_base()                       // 编码响应
        → pn_resp() / easy 发送               // 发送响应
```

### 9.3 客户端接收

```
pn_resp_cb / easy 回调                        // 收到响应
  → ObRpcProxy::AsyncCB::decode()             // 解码响应
  → ObGtsRPCCB::process()                     // 处理响应
```

---

## 10. 设计决策分析

### 10.1 为什么从 easy 迁移到 pnio？

1. **性能**：easy 的 libeasy 无法充分利用多核，pnio 的事件循环在每个 IO 线程独立运行，减少了锁竞争
2. **分组隔离**：pnio 支持多个 IO 线程组，可以将不同优先级的流量隔离（日志复制 vs 普通请求）
3. **内存管理**：pnio 的 `pn_send_alloc`/`pn_send_free` 可以按请求分配，避免 easy_pool 的整体释放开销
4. **可控性**：自研框架可以根据 OceanBase 的需求深度定制（如写队列、速率限制、时间轮）

### 10.2 序列化格式选择

- **为什么自研而非 protobuf/thrift**：OceanBase 需要在 C++ 头文件中直接声明序列化，protobuf 需要额外的代码生成步骤；OB_UNIS 的宏展开在编译期完成，零运行时开销
- **为什么用 varint**：减少小整数的编码字节数，磁盘/DAG 控制类消息通常只有几十字节
- **为什么不是 JSON**：JSON 序列化/反序列化开销大，不适合数据库内核的高频通信

### 10.3 异步 RPC 实现模式

OceanBase 的 RPC 实现了**两阶段异步**：
1. **发送异步**：`rpc_post()` 不阻塞，立即返回，通过回调处理响应
2. **处理异步**：服务端 IO 线程不阻塞，将请求投递到 worker 队列，worker 线程处理
3. **回调克隆**：`AsyncCB::clone()` 在异步路径中克隆回调对象，确保线程安全

### 10.4 连接管理策略

- **共享连接**：所有请求共享到同一目标地址的 TCP 连接，减少连接数
- **连接池**：每个 IO 线程维护独立的连接池，避免跨线程竞争
- **SSL 支持**：通过 `ObNetClient::load_ssl_config()` 配置 SSL/TLS，支持本地文件和 BKMI 模式
- **心跳**：`ObNetKeepalive` 定期发送心跳包，30s 超时检测

### 10.5 流控策略

OceanBase 的 RPC 流控采用**多层保护**：

| 层级 | 机制 | 作用 |
|------|------|------|
| IO 线程 | 写队列 + `MAX_WRITE_QUEUE_COUNT` | 限制每个 socket 的积压 |
| 请求队列 | `ObReqQueue::MAX_PACKET_SIZE` | 限制 worker 队列内存 |
| 组限速 | `pn_ratelimit()` 令牌桶 | 控制特定流量组的带宽 |
| 优先级 | `ObPriorityQueue` | 高优先级请求优先处理 |

---

## 11. 源码索引

### 核心 RPC 框架

| 文件 | 行数 | 关键内容 |
|------|------|---------|
| `deps/oblib/src/rpc/obrpc/ob_rpc_packet.h` | ~920 | `ObRpcPacketHeader` 协议头部、`ObRpcPacketSet` PCode 映射 |
| `deps/oblib/src/rpc/obrpc/ob_rpc_packet_list.h` | ~1460 | 全部 500+ RPC 命令码定义 |
| `deps/oblib/src/rpc/obrpc/ob_rpc_proxy.h` | ~430 | `ObRpcProxy` 客户端基类、`AsyncCB` 异步回调 |
| `deps/oblib/src/rpc/obrpc/ob_rpc_proxy.ipp` | ~800 | `rpc_call`、`rpc_post` 实现，含 pnio/easy 双路径 |
| `deps/oblib/src/rpc/obrpc/ob_rpc_processor.h` | ~65 | `ObRpcProcessor` 服务端模板基类 |
| `deps/oblib/src/rpc/obrpc/ob_rpc_processor_base.h` | ~180 | `ObRpcProcessorBase` 基类，包含 `before_process`/`after_process` 生命周期 |
| `deps/oblib/src/rpc/obrpc/ob_rpc_proxy_macros.h` | ~370 | `RPC_AP`、`RPC_S`、`RPC_FUNC_N` 等宏定义 |

### 传输与帧层

| 文件 | 行数 | 关键内容 |
|------|------|---------|
| `deps/oblib/src/rpc/frame/ob_req_transport.h` | 271 | `ObReqTransport` 传输接口（send/post）、`AsyncCB` 接口 |
| `deps/oblib/src/rpc/frame/ob_req_handler.h` | 115 | `ObReqHandler` easy 事件处理（decode/encode/process） |
| `deps/oblib/src/rpc/frame/ob_req_deliver.h` | 67 | `ObReqDeliver` / `ObReqQDeliver` 请求分发 |
| `deps/oblib/src/rpc/frame/ob_req_queue_thread.h` | 111 | `ObReqQueue` 优先级队列实现 |

### pnio 框架

| 文件 | 行数 | 关键内容 |
|------|------|---------|
| `deps/oblib/src/rpc/pnio/interface/group.h` | 143 | pnio 公共 API：`pn_listen`、`pn_provision`、`pn_send`、`pn_resp` |
| `deps/oblib/src/rpc/pnio/nio/packet_server.h` | 78 | `pkts_t` 服务端结构 |
| `deps/oblib/src/rpc/pnio/nio/packet_client.h` | 85 | `pktc_t` 客户端结构 |
| `deps/oblib/src/rpc/pnio/io/eloop.h` | 25 | `eloop_t` 事件循环 |
| `deps/oblib/src/rpc/pnio/io/write_queue.h` | 26 | `write_queue_t` 写队列 |
| `deps/oblib/src/rpc/pnio/io/rate_limit.h` | 23 | `rl_impl_t` 速率限制实现 |
| `deps/oblib/src/rpc/pnio/config.h` | 35 | pnio 配置阈值（队列长度、超时等） |

### 序列化

| 文件 | 行数 | 关键内容 |
|------|------|---------|
| `deps/oblib/src/lib/utility/ob_unify_serialize.h` | 478 | OB_UNIS 序列化框架，`OB_UNIS_VERSION`、`OB_SERIALIZE_MEMBER` 等宏 |
| `deps/oblib/src/lib/utility/serialization.h` | 3000+ | 基础序列化函数（encode/decode/encoded_length for 所有基础类型） |
| `deps/oblib/src/rpc/obrpc/ob_rpc_endec.h` | 201 | `rpc_encode_req` / `rpc_decode_resp` 编码/解码流程 |

### 客户端/服务端管理

| 文件 | 行数 | 关键内容 |
|------|------|---------|
| `deps/oblib/src/rpc/obrpc/ob_net_client.h` | 80 | `ObNetClient` 客户端初始化 |
| `deps/oblib/src/rpc/obrpc/ob_listener.h` | 71 | `ObListener` 多协议监听器 |
| `deps/oblib/src/rpc/obrpc/ob_net_keepalive.h` | ~40 | `ObNetKeepalive` 连接保活 |

### 具体 RPC 示例

| 文件 | 行数 | 关键内容 |
|------|------|---------|
| `src/storage/tx/ob_gts_rpc.h` | 350 | `ObGtsRpcProxy`/`ObGtsP`/`ObGtsRPCCB` — GTS RPC 完整示例 |
| `src/storage/tx/ob_ts_mgr.h` | ~300 | `ObTsMgr` — GTS 全局时间戳管理器 |
| `deps/oblib/src/share/ob_rpc_struct.h` | 数千行 | 各个模块的 RPC 请求/响应结构体定义 |

### 高层调度与分发

| 文件 | 行数 | 关键内容 |
|------|------|---------|
| `src/observer/ob_rpc_intrusion_detection.h` | ~200 | RPC 入侵检测（GC 等保护） |
| `deps/oblib/src/rpc/obrpc/ob_rpc_stat.h` | ~100 | RPC 统计计数 |

---

## 总结

OceanBase 的 RPC 框架是一个**分层设计、双框架并存、深度定制的分布式通信基座**：

1. **Proxy + Processor 模式**提供了清晰的服务化接口，所有模块（事务、日志、存储、位置服务）都遵循同一模式
2. **OB_UNIS 序列化**自研框架在性能和紧凑性上优于通用方案，零反射开销
3. **easy→pnio 过渡**体现了架构演进的务实态度：先用成熟库快速迭代，再自研高性能框架替换
4. **多层流控**（写队列 → 请求队列 → 组限速 → 优先级）保护了系统在高负载下的稳定性
5. **136 字节的报文头**包含了分布式追踪、租户隔离、优先级、压缩等丰富信息，是分布式运维的基础
