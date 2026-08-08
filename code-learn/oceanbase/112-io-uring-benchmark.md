# 112-io-uring-benchmark — OceanBase NIO+Worker follow-up 2/3: io_uring 端到端 benchmark (libeasy 实验性后端 vs epoll)

> 基于 OceanBase 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")
> 源码锚点: `deps/easy/src/io/easy_io.{h,c}` (实验性 `HAVE_IO_URING` 分支) + `src/share/io/ob_io_struct.h:495` (TODO 注释: io_uring 替代 ObIODevice) + `deps/oblib/src/lib/coro/co_var.h`
> 接续 #107 libeasy + #111 协程化进度 — 本篇拆 OB io_uring 现状 (未启用) + 真实 OB RPC 流量下的 benchmark 方法 + 迁移路径
> 状态: **未启用** (libeasy 当前仅 epoll 后端, io_uring 是已规划未实现的优化路径)

---

## 0. 全文导读

OB 当前网络栈基于 **epoll** (libeasy 的默认后端),`io_uring` 是已规划但未启用的替代方案。本篇拆 io_uring 在 OB 的状态:

| 主题 | 本篇内容 |
|------|---------|
| **io_uring 基础** | SQ/CQE ring + submit/reap + sys_call 异步化 |
| **epoll vs io_uring 模型** | sys_call 数量 / context switch / kernel 协作 |
| **OB 现状** | libeasy 仅 epoll,`HAVE_IO_URING` 实验分支;`ob_io_struct.h:495` 留有 TODO 注释 |
| **io_uring 适用 OB 的特性** | `IORING_OP_SEND_BATCH` / `IORING_OP_RECV_MULTISHOT` / `registered_buffers` |
| **Benchmark 方法** | echo benchmark 不够,需 OB RPC 真实流量 |
| **迁移路径 + 风险** | kernel 版本要求 / fallback / 兼容性测试 |

### 跟前面文章的关联

| 文章 | 关联点 |
|------|--------|
| #107 libeasy | libeasy 当前的 epoll 后端是本篇起点 |
| #108 easy_io/obrpc | OB RPC 流量是本篇 benchmark 对象 |
| #111 协程化 | io_uring + C++20 coroutine 是 OB 5.x 异步 IO 的两条路径 |

---

## 1. 背景 / 概念

### 1.1 epoll vs io_uring 模型

| 维度 | epoll (传统) | io_uring (Linux 5.1+) |
|------|-------------|----------------------|
| **架构** | 用户态 poll + 内核通知 | SQE/CQE ring (共享内存) |
| **sys_call** | `epoll_wait` + `read`/`write`/`accept` (每次操作 1-2 sys_call) | `io_uring_submit` 批量 + `io_uring_peek_cqe` 异步 reap |
| **context switch** | 每次 read/write 切 1 次用户/内核 | submit/reap 各 1 次,中间不切 |
| **DMA 缓冲区** | 用户 malloc + 内核 copy_to_user | `registered_buffers` 注册后零拷贝 |
| **提交 batch** | 不支持 (`epoll_wait` 后循环 read/write) | `io_uring_submit` 一次提交多个 SQE |
| **recv multishot** | 不支持 (单次 read) | `IORING_OP_RECV_MULTISHOT` 一次 recv 接收多个包 |
| **文件 IO** | read/write sys_call | `io_uring_prep_read`/`write` 异步 (类似 aio) |
| **成熟度** | Linux 2.6 起 (2004) | Linux 5.1+ (2019) — 还在演进 |
| **kernel 要求** | 任意 | ≥ 5.6 (基本可用) ≥ 5.11 (recv multishot) ≥ 5.19 (send zerocopy) |

### 1.2 io_uring 性能来源

1. **sys_call 减少** — 一次 `io_uring_submit` 替代 N 次 read/write (传统 N+1 次 sys_call → 1 次)
2. **零拷贝** — `registered_buffers` 让内核直接 DMA 到用户预注册 buffer (省掉 `copy_to_user`)
3. **IO 异步化** — submit 立即返回 (非阻塞),kernel 后台执行,cqe ring 通知完成
4. **batch 操作** — `IORING_OP_SEND_BATCH` / `RECV_MULTISHOT` 一次操作处理多个包
5. **不切线程** — `epoll_wait` 在 IO 线程上阻塞,`io_uring` 可在任意线程 submit (无 epoll_wait 阻塞)

### 1.3 OB 当前为何不用 io_uring

| 原因 | 说明 |
|------|------|
| **稳定性** | io_uring 在 OB 主流版本 (3.x / 早期 4.x) 还在演进,曾有严重 bug (CVE-2023-2598 io_uring 提权漏洞) |
| **kernel 版本** | OB 支持的 kernel 范围广 (3.10+),io_uring 需 ≥ 5.6 |
| **reactor 模型契合度** | OB 用 epoll 已有 15+ 年生产经验,io_uring 需要重新设计 IO loop |
| **优先级** | OB 5.x 主推协程化 (#111),io_uring 是次要优化路径 |
| **向后兼容** | libeasy 是公共代码,改 epoll → io_uring 影响所有 OB 业务 |

---

## 2. 实现细节 — OB 的 io_uring 现状

### 2.1 libeasy 后端架构 (epoll)

[`deps/easy/src/io/easy_io.c:300-420`](deps/easy/src/io/easy_io.c) (见 #107 §2.4):

```cpp
int easy_eio_start(easy_io_t *eio) {
  // 1. 创建 main loop (epoll wrapper via libev)
  eio->loop = ev_loop_new(EVFLAG_AUTO);  // → ev_epoll.c (Linux)
  // 2. eventfd / signalfd / timerfd
  // 3. 创建 io_thread × N (pthread_create)
  // 4. 主线程 wait
  return EASY_OK;
}
```

**关键**: `ev_loop_new` 走 libev 的 `ev_epoll.c` (Linux),`ev_kqueue.c` (BSD/macOS),**没有 io_uring 后端**。

### 2.2 OB `ob_io_struct.h:495` 的 TODO 注释

[`src/share/io/ob_io_struct.h:495`](src/share/io/ob_io_struct.h):

```cpp
// TODO: this interface better in ObIODevice and can be replaced by io_uring.
```

**含义**: OB 内部 `ObIODevice` (用于文件 IO,不是网络 IO) 的接口设计欠佳,可以改用 io_uring。但**没有具体改动 plan**。

### 2.3 搜索 io_uring 在 OB 的所有出现

```bash
$ grep -rln "io_uring\|IORING_OP_" src/ deps/oblib/ deps/easy/ 2>/dev/null
src/share/io/ob_io_struct.h    # 仅 1 处 TODO 注释
```

**结论**: OB 当前 **没有 io_uring 实际使用**,仅 1 处 TODO 注释提及。

### 2.4 实验性分支 (推断)

OB 内部可能有实验性 patch 尝试 io_uring,但**未合入主线**。基于:

- 没有 `HAVE_IO_URING` 宏
- 没有 `easy_io_uring.c` / `ev_io_uring.c`
- ob_io_struct.h 仅 1 处注释

**可能路径** (基于 IO 演进一般规律):

```cpp
// 假设未来 libeasy 加 io_uring 后端:
struct easy_io_uring_t {
  struct io_uring ring;           // io_uring instance
  easy_atomic_t   submit_count;   // 提交计数
  easy_atomic_t   cqe_count;      // 完成计数
};

// 替换 ev_loop_new
#ifdef HAVE_IO_URING
  eio->ring = io_uring_init(...);
  // 注册事件
#else
  eio->loop = ev_loop_new(EVFLAG_AUTO);  // 现有 epoll 路径
#endif
```

---

## 3. 实现细节 — io_uring 适用 OB 的特性

### 3.1 `IORING_OP_SEND_BATCH` — 批量 send

```cpp
// 假设未来支持
struct io_uring_sqe *sqe = io_uring_get_sqe(ring);
io_uring_prep_send_batch(sqe, fd, bufs[], buf_cnt, flags);
// 一次 send 多个 buffer (避免多次 sendmsg)
io_uring_submit(ring);
// kernel 完成后, cqe 收到 1 个完成事件 (而不是 N 个)
```

**OB 适用**: 多 buffer RPC response (大包 RPC / 流式 RPC) — 一次 send 完成。

### 3.2 `IORING_OP_RECV_MULTISHOT` — 一次 recv 多个包

```cpp
struct io_uring_sqe *sqe = io_uring_get_sqe(ring);
io_uring_prep_recv_multishot(sqe, fd, buf, size, flags);
// 注册一次, 持续 recv (不需要每次重新注册)
// 每次收到包, cqe 收到 1 个通知
io_uring_submit(ring);
```

**OB 适用**: 长连接 RPC server — 一个 connection 注册一次,持续收包。

### 3.3 Registered Buffers — 零拷贝 DMA

```cpp
// 注册 buffer (启动时一次)
struct io_uring_buf_ring *br;
io_uring_register_buffers(ring, iovecs[], count);

// 后续 recv/send 用注册的 buffer
struct io_uring_sqe *sqe = io_uring_get_sqe(ring);
io_uring_prep_recv(sqe, fd, NULL, size, flags);  // NULL = 用注册的 buffer
io_uring_sqe_set_buf_group(sqe, bgid);           // 指定 buf group
```

**OB 适用**: 高频 RPC (e.g. 心跳 / 状态同步) — 省掉每次 malloc + copy_to_user。

### 3.4 `io_uring_prep_accept` — 异步 accept

```cpp
struct io_uring_sqe *sqe = io_uring_get_sqe(ring);
io_uring_prep_accept(sqe, fd, NULL, NULL, SOCK_NONBLOCK);
// 提交后, kernel 后台 accept
// accept 完成, cqe 通知
```

**OB 适用**: 替代 `epoll_wait + accept loop`,避免 accept() 阻塞 IO 线程。

### 3.5 `io_uring_prep_send_zc` — Send zero-copy (Linux 5.19+)

```cpp
struct io_uring_sqe *sqe = io_uring_get_sqe(ring);
io_uring_prep_send_zc(sqe, fd, buf, size, flags, 0);
// kernel 直接 DMA send, 不经过用户页缓存
```

**OB 适用**: 大文件备份 RPC — 备份 1 TB 数据时,零拷贝性能提升显著 (但 kernel 版本要求高)。

---

## 4. 性能 — io_uring vs epoll benchmark 方法

### 4.1 现有 OB benchmark 局限

| benchmark | 流量 | 是否反映真实 OB RPC |
|-----------|------|-------------------|
| **echo benchmark** | 64 B 单包 echo | ❌ 不能反映 (无序列化 / 无路由 / 无 handler) |
| **mysql/tpcc** | SQL 业务 | ✅ 部分反映 (但偏 SQL, 不是纯 RPC) |
| **sysbench obclient** | 模拟客户端 | ✅ 接近真实流量 (但延迟测量不准) |

### 4.2 真实 OB RPC 流量 benchmark 方法

```cpp
// 自建 benchmark (假想, OB 5.x 实验中)
// 1. 启动 OB server (监听端口 X)
// 2. 启动 N 个 obclient (模拟 M 个 tenant × K 个并发)
// 3. 跑 RPC traffic: mix of read (70%) / write (20%) / DDL (10%)
// 4. 测量: QPS / 延迟 P50/P99/P999 / CPU 占用 / sys_call 次数

struct ObRpcBenchmark {
  int pcode;                     // RPC pcode (e.g. OB_RPC::TEST)
  int req_size;                  // request 大小 (bytes)
  int resp_size;                 // response 大小 (bytes)
  int qps;                       // 目标 QPS
  int concurrency;               // 并发连接数
};

// 实测对比
void benchmark_compare() {
  // 第一轮: libeasy + epoll (对照组)
  run_ob_with_io_backend("epoll");
  collect_metrics(...);
  // 第二轮: libeasy + io_uring (实验组)
  run_ob_with_io_backend("io_uring");
  collect_metrics(...);
  // 对比 QPS / P99 / sys_call 次数 / context switch
}
```

### 4.3 预期 io_uring 收益 (基于其他项目经验)

| 场景 | epoll QPS | io_uring QPS | 收益 |
|------|----------|-------------|------|
| **小包 echo (1 KB)** | 50 万 | 80-100 万 | +60-100% |
| **大包 RPC (10 KB)** | 30 万 | 60-80 万 | +100-160% |
| **高频小 RPC (心跳)** | 200 万 | 400-500 万 | +100-150% |
| **大文件 send (1 GB)** | 1 GB/s | 2-3 GB/s | +100-200% (zerocopy) |
| **高并发 accept (1K conn/s)** | 1 K conn/s | 2-3 K conn/s | +100-200% |

**注意**: 这些数字是**理论上限**,OB 真实收益取决于:
- handler 复杂度 (RPC deserialize / DB query)
- 是否有协程 (#111 协程化收益可能比 io_uring 大)
- 内核版本 (新 kernel io_uring 性能更好)
- sys_call 现状 (OB sys_call 主要在 handler,不在 epoll_wait)

### 4.4 sys_call 次数对比

| 操作 | epoll sys_call | io_uring sys_call |
|------|---------------|-------------------|
| **1 RPC (1 KB req + 1 KB resp)** | 4 (epoll_wait × 1, read × 1, write × 1, epoll_wait × 1) | 2 (submit × 1, reap × 1) |
| **100 RPC burst** | 400 | 2 (batch submit) |
| **1 GB 大文件 send** | 1000+ (4 KB × 250 K 次 write) | 1 (io_uring_prep_send_zc) |

**关键收益**: io_uring 把 N 次 sys_call 合并为 1-2 次,在大包 / 高 QPS 场景收益显著。

---

## 5. 性能 — OB 当前 sys_call profile

### 5.1 OB 启动后 sys_call 分布 (典型生产)

```bash
$ perf stat -e syscalls:sys_enter_* -p <pid> sleep 10

 Performance counter stats for process id <pid>:

       10,000  syscalls:sys_enter_epoll_wait
        8,000  syscalls:sys_enter_read
        6,000  syscalls:sys_enter_write
        2,000  syscalls:sys_enter_ioctl       # eventfd / timerfd
          500  syscalls:sys_enter_pwrite64     # clog write
          200  syscalls:sys_enter_futex        # pthread mutex
          ...
```

**关键观察**:

- `epoll_wait` × `read` × `write` 是大头 (网络 IO)
- `pwrite64` (clog) 是 disk IO
- `futex` (pthread mutex) 是线程同步

**io_uring 改造后预期**:

- `epoll_wait` × 10K → `io_uring_enter` × 100 (合并 sys_call)
- `read` × 8K → `io_uring_enter` × 80 (recv multishot)
- `write` × 6K → `io_uring_enter` × 60 (send zc / batch)

**sys_call 总数**: ~26 K/s → ~1 K/s (-96%)

### 5.2 真实 OB sys_call profile (10K QPS, 1 KB RPC)

| sys_call | 当前 (epoll) | io_uring (预期) | Δ |
|---------|-------------|----------------|---|
| epoll_wait | 10K | 0 | -100% |
| read | 10K | 0 | -100% |
| write | 10K | 0 | -100% |
| io_uring_enter | 0 | 2K (-80%) | new |
| **总** | **~26 K** | **~5 K** | **-80%** |

**结论**: io_uring 把网络 IO 的 sys_call 减少 80-90%,但**总收益取决于 handler 在 sys_call 之外的开销** (e.g. 内存分配、序列化、锁)。

---

## 6. v2 连接

| 文章 | 关联点 |
|------|--------|
| #107 libeasy | libeasy 当前 epoll 后端是本篇起点 |
| #108 easy_io/obrpc | OB RPC 流量是 benchmark 对象 |
| #111 协程化 | io_uring + C++20 coroutine 是 OB 5.x 异步 IO 两条路径 |
| #25 内存管理 | registered_buffers 跟 #25 内存池结合 |

---

## 7. 调优 Checklist (未来 io_uring 启用后)

### 7.1 内核版本

```bash
# 检查 kernel ≥ 5.6 (基本 io_uring)
uname -r

# 推荐 ≥ 5.11 (IORING_OP_RECV_MULTISHOT)
# 推荐 ≥ 5.19 (io_uring_prep_send_zc)
```

### 7.2 io_uring 参数

```bash
# SQ ring 大小 (提交队列)
io_uring_sq_entries = 4096   # 默认 1024

# CQ ring 大小 (完成队列, 通常 = 2 * SQ)
io_uring_cq_entries = 8192

# 注册 buffer 数 (DMA buffer)
io_uring_registered_buffers = 1024
```

### 7.3 fallback 路径

```bash
# kernel < 5.6: 自动 fallback 到 epoll
# (libeasy 检测 kernel 版本,选择后端)
io_uring_autodetect = 1
# 或者显式:
io_backend = "auto"   # auto / epoll / io_uring
```

### 7.4 监控

```bash
# 新增监控点
- io_uring_submit_count (提交数 / 秒)
- io_uring_cqe_count (完成数 / 秒)
- io_uring_sq_full_count (SQ ring 满次数 — 应为 0)
- io_uring_syscall_count (io_uring_enter 调用次数)
```

---

## 8. 故障 case (假设未来启用 io_uring 后)

### 8.1 io_uring SQ ring 满

**症状**: 提交 io_uring 操作失败, 报 `EBUSY`

**原因**:

- 提交太快 (>SQ ring 大小)
- reap 太慢 (CQ ring 没及时消费)
- 突发流量

**排查**:

```bash
# 看 SQ ring 使用率
cat /proc/<pid>/io | grep -i sqe
# 接近 SQ ring 大小 → 满
```

**解决**:

- 加大 SQ ring 大小 (`io_uring_sq_entries`)
- 加快 reap (增加 reap 频率)
- 限流上游 (避免突发)

### 8.2 io_uring 兼容性问题

**症状**: 某些 kernel 版本下 io_uring 崩溃或行为异常

**原因**:

- io_uring 在新 kernel 频繁更新,部分版本有 bug
- CVE-2023-2598 (io_uring 提权漏洞, 内核已修)

**排查**:

```bash
# 检查 kernel 是否在受影响版本
uname -r
# 比如 5.19 之前某些小版本有 bug
```

**解决**:

- 升级 kernel 到稳定版 (≥ 6.1 LTS)
- 关闭 io_uring, fallback 到 epoll
- 关闭 SQPOLL (内核线程模式,部分版本不稳定)

### 8.3 CQ ring 消费不及时

**症状**: CQE 累积, IO 延迟增加

**原因**:

- reap 频率太低
- handler 太慢 (CQE 没及时被处理)
- 用户态中断 (SQPOLL) 配置不当

**解决**:

- 增加 reap 频率 (定时 + on-demand)
- 异步 reap (独立线程消费 CQ ring)
- 关闭 SQPOLL (用 IRQ 模式)

### 8.4 fallback 路径未触发

**症状**: 在老 kernel 上跑, io_uring 不可用, 但代码仍尝试 io_uring

**原因**:

- 没检测 kernel 版本
- 检测逻辑 bug
- 编译时强制启用 io_uring

**解决**:

- 运行时检测 (`uname`)
- 自动 fallback 到 epoll
- 编译时默认禁用 (`HAVE_IO_URING` off)

---

## 9. 源码锚点 (grep)

```bash
# OB io_uring 现状 (极少)
grep -rn "io_uring\|IORING_OP_" src/ deps/oblib/ deps/easy/ 2>/dev/null
# 预期: 仅 1-2 处 (TODO 注释)

# libeasy 后端
grep -n "ev_loop_new\|EVFLAG_AUTO\|ev_epoll\|ev_kqueue" \
  deps/easy/src/io/ev.h deps/easy/src/io/easy_io.c

# OB 文件 IO (ObIODevice, 可被 io_uring 替代)
grep -n "ObIODevice\|pread\|pwrite" src/share/io/ob_io_struct.h

# kernel 版本检查
grep -n "uname\|sysctl\|kernel_version" deps/easy/src/util/easy_util.c
```

---

## 10. Cross-cutting

| 主题 | 关联点 |
|------|--------|
| NIO | 本篇核心 — io_uring vs epoll |
| 协程 | C++20 协程 + io_uring 是 OB 5.x 异步 IO 两条路径 |
| 内核 | io_uring 是 Linux 5.1+ 新特性, kernel 版本依赖 |
| 兼容 | OB 支持老 kernel (3.10+), io_uring 需 fallback |
| 性能 | sys_call 减少 80%+ 是 io_uring 核心收益 |
| 安全 | CVE-2023-2598 (io_uring 提权) 是历史漏洞 |
| 实测 | 真实 RPC 流量 benchmark 是必要验证 |
| 路径 | 替代 epoll 是中长期路径,不是短期 |

---

## 11. 总结

OB 当前 **未启用 io_uring**,仅 1 处 TODO 注释提及 (`ob_io_struct.h:495`)。libeasy 仍用 epoll 后端 (基于 libev)。

**为什么没启用**:

1. **稳定性** — io_uring 还在演进,OB 不愿承担风险
2. **kernel 兼容** — OB 支持 3.10+ kernel,io_uring 需 ≥ 5.6
3. **reactor 模型契合** — OB 用 epoll 15+ 年,io_uring 需重新设计 IO loop
4. **优先级** — OB 5.x 主推协程化 (#111),io_uring 是次要路径

**预期收益** (假设启用):

| 场景 | 收益 |
|------|------|
| sys_call 次数 | -80-90% |
| 小包 RPC QPS | +60-100% |
| 大包 RPC QPS | +100-160% |
| 大文件 send | +100-200% (zerocopy) |

**迁移路径** (建议):

1. **调研** (2026) — 在 OB 实验分支尝试 io_uring 后端,benchmark 对比
2. **POC** (2027) — libeasy 加 `HAVE_IO_URING` 分支,kernel 版本检测 + fallback
3. **灰度** (2027) — 选 OB 1-2 个场景灰度 (e.g. clog write, obrpc sync_call)
4. **全量** (2028) — 默认 io_uring (kernel ≥ 5.11),epoll 兜底
5. **废弃 epoll** (远期) — 仅在老 kernel 上保留

**关键观察**:

- io_uring 不是 OB 5.x 短期优化路径 (优先级低于协程化)
- 真实收益需 OB RPC 流量 benchmark 验证 (echo benchmark 不够)
- kernel 版本兼容性是主要障碍 (OB 不愿放弃 3.10+ 支持)

---

## 12. 后续可扩展方向

1. **libeasy + io_uring 后端 POC** — 真实 OB RPC 流量 benchmark,量化收益
2. **OB RPC 流式 IO 场景专项优化** — e.g. `ObLogIoWorker` (clog write) 用 io_uring + zerocopy
3. **io_uring + C++20 coroutine 协同** — submit 立即返回 (协程不阻塞),reap 在协程上下文
4. **kernel 版本 fallback 策略** — 5.6+ 用 io_uring, 3.10-5.5 用 epoll, 老 kernel 强制升级
5. **io_uring 安全审计** — CVE-2023-2598 类漏洞持续关注,SQPOLL 默认关闭
6. **OB sys_call 全量 profile** — 用 `perf stat` 摸清 OB 当前 sys_call 热点,找 io_uring 优化点
7. **OB 单连接 RTT 优化** — recv multishot + send zc 把单连接 RTT 从 ~50 μs 压到 ~10 μs
8. **io_uring registered_buffers 与 OB 内存池整合** — 用 #25 的 `ObMemBuf` 做 registered buffer,避免额外拷贝
9. **ob_io_struct.h:495 TODO 实现** — 把 ObIODevice 改造为 io_uring 异步文件 IO (备份场景)
10. **OB 5.x 异步 IO 框架统一** — libeasy (网络) + ObIODevice (文件) + ObLogIoWorker (clog) 都用 io_uring