# 107-nio-libeasy-reactor — OceanBase NIO (1/2): libeasy 整体架构与 Reactor 线程模型

> 基于 OceanBase 主线源码 (commit `f2e437ea62` 之后)
> 源码锚点: `deps/easy/src/io/easy_io.h` + `deps/easy/src/io/easy_io_struct.h` + `deps/easy/src/io/easy_connection.{h,c}` + `deps/easy/src/io/easy_baseth_pool.{h,c}` + `deps/easy/src/io/ev.{h,c}` + `deps/easy/src/io/easy_request.h` + `deps/easy/src/io/easy_message.h`
> 使用 doom-lsp (clangd LSP) 做符号解析与数据流追踪
> 接续 #103-#106 atomic 系列 — 本系列 2 篇拆 OB NIO, 再接 #109-#110 Worker 系列

---

## 0. 全文导读

OB 网络栈自下而上分为 5 层: kernel → ev → libeasy → obrpc → server。libeasy 是 OB 自研的 Reactor 网络库,提供:

- 跨平台 IO 多路复用 (epoll / kqueue / io_uring via `ev.h`)
- 多 IO 线程池 (`easy_io_thread_t`,默认数量 = `min(NCPU, 8)`)
- 连接管理 (`easy_connection_t`) + 请求管理 (`easy_request_t`) + 消息管理 (`easy_message_t`)
- 协议无关的 handler dispatch (应用层注册 `easy_io_handler_pt`)
- 用户态线程支持 (`easy_uthread`,后续部分路径切到 C++20 coroutine)
- 跨 region 限流 (`easy_region_ratelimitor_t`)

| 主题 | 本篇 | 后续 |
|------|------|------|
| **libeasy Reactor + 线程模型** | ✅ #107 (本篇) | |
| easy_io 连接生命周期 + obrpc 协议栈 | | #108 |

### libeasy 在 OB 栈中的位置

| 层 | 模块 | 职责 |
|----|------|------|
| 应用层 | observer / sql / rootserver | 业务处理 |
| RPC 层 | obrpc / `ob_net_*` | 序列化 + 路由 + 重试 |
| IO 抽象 | `easy_io_t` | Reactor 主结构,跨平台封装 |
| 网络框架 | libeasy | Reactor + IO 线程 + 连接池 |
| 系统调用 | ev (libev 改造) | epoll / kqueue / io_uring |
| 内核 | kernel | TCP/IP 协议栈 |

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| #103 atomic | `easy_atomic_t` 是 libeasy 内部统计用的原子类型;`easy_thread_pool_t::produce_seq/consume_seq` 是 counter 模式 |
| #104 atomic Flag | `easy_connection_t::status` 是 atomic Flag 模式 |
| #25 内存管理 | libeasy 用 `easy_pool_t` 做内存池,跟随 connection / request 释放 |
| #27 RPC/obrpc | obrpc 是 libeasy 的上层封装 (见 #108) |

---

## 1. 背景 / 概念

### 1.1 Reactor vs Proactor 模式

| 维度 | Reactor | Proactor |
|------|---------|----------|
| 谁通知 ready | IO 线程 epoll_wait | 内核完成 IO 后通知 |
| read/write | 应用线程 | 内核 (aio_* / io_uring) |
| 跨平台 | epoll / kqueue / iocp | iocp / io_uring |
| 复杂度 | 低 | 中 |
| 性能 | 优 (Linux) | 优 (Windows iocp / Linux io_uring) |

OB 用 Reactor,因为:

1. Linux epoll 性能已经够好 (90% 场景下与 io_uring 持平)
2. 与 libev 复用,代码简单 (无 callback hell)
3. io_uring 在 OB 主流版本 (3.x / 4.x) 还**未**大规模启用 (有实验性 patch 在 `deps/easy/src/io/easy_io.c` 后台分支)
4. OB 的 RPC 协议栈在同步模型上做了大量优化,Reactor 更适配

### 1.2 为什么 OB 自研 libeasy (不用 muduo / asio)

| 选项 | 评估 |
|------|------|
| muduo | 缺少 io_uring 支持,RPC 路由需要自己扩展 |
| asio | 跨平台但 C++ 模板代码膨胀,OB 编译慢 (asio 头文件 2000+ 行) |
| libevent | IO 线程模型固定,不易扩展 SO_REUSEPORT 多队列 |
| **libeasy** | ✅ 自研,跟 OB RPC 协议栈紧耦合,支持 SO_REUSEPORT 多队列 + 跨 region 限流 |

**libeasy 历史**: 2010 年由 OB 早期架构师封宇 / 席海锋 等人设计,沿用至今已 15+ 年。核心思想是把 "IO 线程 + 用户态线程池 + 协议栈" 三层分清楚,每一层可独立调优。

### 1.3 libeasy 线程模型

```
                 easy_io_t (main config)
                       │
        ┌──────────────┼──────────────┐
        │              │              │
   io_thread[0]   io_thread[1]   io_thread[N-1]    (默认 N = min(NCPU, 8))
        │              │              │
   ev_loop(epoll) ev_loop(epoll) ev_loop(epoll)
        │              │              │
   listen(SO_REUSEPORT)              ← kernel 做负载均衡
        │              │              │
   conns[]       conns[]       conns[]             (每线程独立 hash)
        │              │              │
   handler()     handler()     handler()           (跨线程分发, 用 easy_thread_pool_t)
        │              │              │
   user_thread_pool (optional)                     (handler 可 dispatch 到工作线程)
```

**关键设计**:

- 每个 `io_thread` 有独立的 listen socket (SO_REUSEPORT 让 kernel 做负载均衡)
- `io_thread` 内部 epoll 串行处理 (单线程,无锁)
- handler 可以跨线程 dispatch (通过 `easy_thread_pool_t`)
- 用户态线程 (uthread) 在 `io_thread` 上调度 (协程)

### 1.4 libeasy 配置项

| 配置 | 默认 | 说明 |
|------|------|------|
| `io_thread_count` | `min(NCPU, 8)` | IO 线程数 |
| `listen_count` | 1024 | listen backlog |
| `use_so_reuseport` | 1 | SO_REUSEPORT 多队列 (强烈建议开启) |
| `no_delay` | 0 | TCP_NODELAY |
| `keepalive_enabled` | 0 | TCP keepalive (建议开启) |
| `ratelimit_enabled` | 0 | 跨 region 限流 |
| `ssl_enabled` | 0 | SSL 加密 |
| `no_thread` | 0 | 单线程模式 (测试用) |
| `graceful_shutdown_timeout` | 30s | 优雅退出超时 |

---

## 2. 实现细节

### 2.1 `easy_io_t` 主结构

[`deps/easy/src/io/easy_io_struct.h:90-180`](deps/easy/src/io/easy_io_struct.h):

```cpp
struct easy_io_t {
  easy_list_t           eio_list_node;          // 全局 easy_io 列表
  ev_loop              *loop;                   // 主 loop (用于 accept thread / stat watcher)
  easy_atomic_t         shutdown;               // 关闭标志 (atomic) — 跟 #104 Flag 连接
  pthread_t             tid;                    // 主线程 tid
  int                   io_thread_count;        // IO 线程数
  easy_io_thread_t    **io_threads;             // IO 线程数组
  easy_thread_pool_t   *user_thread_pool;       // 用户态线程池 (handler dispatch)
  easy_list_t           conn_list;              // 全局连接列表 (用于 graceful shutdown)
  easy_list_t           server_list;            // 全局 server (listen) 列表
  easy_hash_t          *cconn_list;             // client 连接 hash (addr → conn)
  easy_list_t           client_list;            // 客户端列表
  easy_baseth_t         connect_thread;         // 客户端连接线程
  int                   eventfd;                // eventfd 用于跨线程唤醒
  ev_io                 eventfd_watcher;        // libev watcher
  int                   signalfd;               // signalfd 用于信号处理
  ev_io                 signalfd_watcher;
  int                   timerfd;                // timerfd 用于定时器
  ev_io                 timerfd_watcher;
  // ...
  void                 *user_data;
};
```

**关键设计**:

- `shutdown` 用 `easy_atomic_t`,关闭时设为 1 — 跟 #104 Flag 模式连接
- `io_threads[]` 是 IO 线程数组,启动后不可变 (避免 rehash)
- `user_thread_pool` 是可选的 worker pool (用于把 IO 事件 dispatch 到工作线程)
- `eventfd` / `signalfd` / `timerfd` 把传统阻塞 IO 改成 event-driven

### 2.2 `easy_io_thread_t` 结构

[`deps/easy/src/io/easy_io_struct.h:200-280`](deps/easy/src/io/easy_io_struct.h):

```cpp
struct easy_io_thread_t {
  ev_loop              *loop;                   // libev loop (epoll wrapper)
  easy_atomic_t         quit;                   // 退出标志 (atomic)
  pthread_t             tid;                    // 线程 tid
  int                   idx;                    // 线程索引 (用于 hash 到 connection)
  easy_list_t           conn_list;              // 本线程连接列表
  easy_hash_t          *conn_array;             // 本线程连接 hash (fd → conn)
  easy_list_t           message_list;           // 待处理消息列表 (handler 排队)
  easy_list_t           user_message_list;      // 用户态线程消息
  easy_thread_pool_t   *user_thread_pool;       // 用户态线程池 (per-thread)
  // 统计字段 (跟 #103 Counter 连接)
  int64_t               done_count;             // 处理完成计数 (atomic)
  int64_t               doing_count;            // 处理中计数 (atomic)
  int64_t               conn_new_count;         // 新建连接计数
  int64_t               conn_close_count;       // 关闭连接计数
  int64_t               packet_done_count;      // 处理 packet 计数
  // ...
};
```

**关键字段**:

- `loop`: libev 的 event loop 封装 (epoll wrapper)
- `conn_array`: 本线程 fd → conn 的 hash 表 (无锁,因为单线程访问)
- `done_count` / `doing_count`: 统计字段 (跟 #103 Counter 模式连接)
- `doing_count > 0` 持续很长时间 → IO 线程卡死 (用于 watchdog 监控)

### 2.3 ev 抽象层

[`deps/easy/src/io/ev.h`](deps/easy/src/io/ev.h):

```cpp
// libev 改造版,简化 API (只保留 OB 用的部分)
typedef struct ev_io {
  int                   fd;        // 文件描述符
  int                   events;    // EV_READ / EV_WRITE
  void                (*cb)(struct ev_loop *, struct ev_io *, int);
  void                 *data;
} ev_io;

struct ev_loop *ev_loop_new(unsigned int flags);
void ev_io_init(ev_io *w, void (*cb)(struct ev_loop *, ev_io *, int),
                int fd, int events);
void ev_io_start(struct ev_loop *loop, ev_io *w);
void ev_io_stop(struct ev_loop *loop, ev_io *w);
int  ev_run(struct ev_loop *loop, int flags);
void ev_loop_destroy(struct ev_loop *loop);

// 定时器
typedef struct ev_timer {
  double                at;        // 触发时间 (秒)
  double                repeat;    // 重复周期
  void                (*cb)(struct ev_loop *, struct ev_timer *, int);
  void                 *data;
} ev_timer;
void ev_timer_init(ev_timer *w, void (*cb)(...), double repeat, double after);
void ev_timer_start(struct ev_loop *loop, ev_timer *w);
```

**后端选择** (编译时确定):

- Linux: epoll (`ev_epoll.c`,主路径)
- macOS / BSD: kqueue (`ev_kqueue.c`)
- (实验性) io_uring (在 `easy_io.c` 的 `#ifdef HAVE_IO_URING` 分支,默认关闭)

OB 主流版本用 epoll 后端 (Linux only,因为 macOS / Windows 不在生产路径)。

### 2.4 eventfd / signalfd / timerfd 集成

[`deps/easy/src/io/easy_io.c:300-420`](deps/easy/src/io/easy_io.c):

```cpp
int easy_eio_start(easy_io_t *eio) {
  // 1. 创建 eventfd (用于跨线程唤醒)
  eio->eventfd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  ev_io_init(&eio->eventfd_watcher, easy_io_eventfd_cb, eio->eventfd, EV_READ);
  ev_io_start(loop, &eio->eventfd_watcher);

  // 2. signalfd (signal handling in main thread)
  sigset_t mask;
  sigfillset(&mask);
  sigdelset(&mask, SIGKILL);
  sigdelset(&mask, SIGSTOP);
  eio->signalfd = signalfd(-1, &mask, SFD_NONBLOCK | SFD_CLOEXEC);
  ev_io_init(&eio->signalfd_watcher, easy_io_signalfd_cb,
             eio->signalfd, EV_READ);
  ev_io_start(loop, &eio->signalfd_watcher);

  // 3. timerfd (定时任务,如 stat watcher)
  eio->timerfd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
  ev_io_init(&eio->timerfd_watcher, easy_io_timerfd_cb,
             eio->timerfd, EV_READ);
  ev_io_start(loop, &eio->timerfd_watcher);

  // 4. 启动 IO 线程
  for (int i = 0; i < eio->io_thread_count; i++) {
    easy_io_thread_t *ioth = eio->io_threads[i];
    easy_baseth_init(&ioth->thread, easy_io_thread_main, ioth);
    pthread_create(&ioth->thread.tid, NULL,
                   easy_baseth_start_routine, &ioth->thread);
  }
  return EASY_OK;
}
```

**关键设计**:

- `eventfd` 用于 IO 线程间通信 (一个线程写 8 字节,另一个线程 epoll_wait 唤醒)
- `signalfd` 把信号处理移到 main thread (避免多线程信号 race,POSIX 信号在多线程下语义模糊)
- `timerfd` 跟 `ev_timer` 配合,实现高精度定时器 (vs 旧的 `alarm()` / `setitimer()`)
- 三个 fd 都设 `EFD_NONBLOCK | EFD_CLOEXEC` (非阻塞 + exec 时关闭)

### 2.5 `easy_baseth_pool` 基础线程池

[`deps/easy/src/io/easy_baseth_pool.h`](deps/easy/src/io/easy_baseth_pool.h):

```cpp
struct easy_baseth_t {
  easy_atomic_t         stop;                  // 停止标志
  pthread_t             tid;                   // 线程 tid
  int                   idx;                   // 线程索引
  easy_thread_pool_t   *tp;                    // 所属 pool
  void                (*on_start)(struct easy_baseth_t *);
  void                (*on_close)(struct easy_baseth_t *);
  void                 *user_data;
};

struct easy_thread_pool_t {
  easy_baseth_t       **threads;               // 线程数组
  int                   thread_count;          // 线程数
  int                   queue_size;            // 任务队列大小 (must be power of 2)
  easy_atomic_t         produce_seq;           // 生产序号 — 跟 #103 Counter 连接
  easy_atomic_t         consume_seq;           // 消费序号
  void                 *task_queue;            // 环形队列 (per-thread 一个)
  // callback
  int                 (*cb)(easy_request_t *); // 任务处理回调
  void                (*on_start)(struct easy_baseth_t *);
  void                (*on_close)(struct easy_baseth_t *);
  // 统计
  int64_t               task_done_count;       // 完成计数 (atomic)
  int64_t               task_push_count;       // 入队计数 (atomic)
};
```

**关键设计**:

- `produce_seq` / `consume_seq` 组成 MPSC 环形队列 — 跟 #103 `map_queue::produce_seq_/consume_seq_` 同模式 (但这里是 per-thread,不是全局)
- 任务队列大小必须是 2 的幂 (用 mask 替代 mod)
- 多线程生产 (任意 IO 线程),单线程消费 (每个 baseth 独立消费自己的队列)
- 跟 #105 Refcount 模式也有连接 — `baseth` 引用计数 (用于 graceful shutdown)

### 2.6 启动流程

```cpp
// deps/easy/src/io/easy_io.c: easy_eio_start()
int easy_eio_start(easy_io_t *eio) {
  int ret = EASY_OK;

  // 1. 初始化 main loop (用于 stat watcher + 主线程 accept)
  eio->loop = ev_loop_new(EVFLAG_AUTO);

  // 2. 初始化 eventfd / signalfd / timerfd (见 2.4)
  if ((ret = easy_eio_init_eventfd(eio)) != EASY_OK) goto error;
  if ((ret = easy_eio_init_signalfd(eio)) != EASY_OK) goto error;
  if ((ret = easy_eio_init_timerfd(eio)) != EASY_OK) goto error;

  // 3. 启动 IO 线程 (pthread_create)
  for (int i = 0; i < eio->io_thread_count; i++) {
    easy_io_thread_t *ioth = eio->io_threads[i];
    easy_baseth_init(&ioth->thread, easy_io_thread_main, ioth);
    if (pthread_create(&ioth->thread.tid, NULL,
                       easy_baseth_start_routine,
                       &ioth->thread) != 0) {
      ret = EASY_ERROR;
      goto error;
    }
  }

  // 4. 主线程进入 accept / wait
  if (eio->no_thread) {
    // 单线程模式: 主线程直接 epoll
    easy_io_thread_main(eio->io_threads[0]);
  } else {
    // 多线程模式: 主线程 wait,让 IO 线程各自 listen
    easy_eio_wait(eio);
  }

  return EASY_OK;
error:
  easy_eio_shutdown(eio);
  return ret;
}
```

### 2.7 IO 线程主循环 (`easy_io_thread_main`)

```cpp
// deps/easy/src/io/easy_io.c
static void *easy_io_thread_main(void *arg) {
  easy_io_thread_t *ioth = (easy_io_thread_t *) arg;

  // 1. 初始化 per-thread loop
  ioth->loop = ev_loop_new(EVFLAG_AUTO);

  // 2. 启动 listen (SO_REUSEPORT 共享同一端口)
  easy_list_for_each(s, &ioth->eio->server_list) {
    easy_listen_t *listen = easy_list_entry(s, easy_listen_t, list_node);
    if (listen->fd < 0) {
      listen->fd = easy_socket_listen(listen->addr, listen->backlog, ...);
      ev_io_init(&listen->watcher, easy_io_accept_cb,
                 listen->fd, EV_READ);
      ev_io_start(ioth->loop, &listen->watcher);
    }
  }

  // 3. 主循环 (epoll_wait)
  while (!easy_atomic_get(&ioth->quit)) {
    ev_run(ioth->loop, EVRUN_ONCE);

    // 4. 处理 message_list (handler 排队到这里)
    easy_connection_t *c;
    easy_list_for_each_entry(c, &ioth->message_list, message_list_node) {
      // 调 handler 处理 packet
      easy_io_process_message(c);
    }
  }

  // 5. 退出清理
  ev_loop_destroy(ioth->loop);
  return NULL;
}
```

**关键点**:

- `ev_run(EVRUN_ONCE)` — 一次 epoll_wait 后立即返回 (避免长时间阻塞)
- `message_list` 是 handler 队列 — 避免在 epoll 回调中执行长逻辑 (会阻塞其他 connection)
- `quit` 是 atomic — shutdown 时从其他线程 set,IO 线程检测后退出

### 2.8 优雅退出

```cpp
int easy_eio_shutdown(easy_io_t *eio) {
  // 1. 设 shutdown 标志
  easy_atomic_set(&eio->shutdown, 1);

  // 2. 关闭所有 listen socket (停止接受新连接)
  easy_list_for_each(s, &eio->server_list) {
    easy_listen_t *listen = easy_list_entry(s, easy_listen_t, list_node);
    close(listen->fd);
  }

  // 3. 通知每个 IO 线程退出 (写 eventfd)
  for (int i = 0; i < eio->io_thread_count; i++) {
    easy_io_thread_t *ioth = eio->io_threads[i];
    easy_atomic_set(&ioth->quit, 1);
    uint64_t u = 1;
    write(eio->eventfd, &u, sizeof(u));   // 唤醒 IO 线程
  }

  // 4. 关闭所有 client connection (发 FIN)
  // (等待 graceful_shutdown_timeout)

  // 5. 等待 IO 线程退出 (pthread_join)
  for (int i = 0; i < eio->io_thread_count; i++) {
    pthread_join(eio->io_threads[i]->thread.tid, NULL);
  }

  // 6. 清理 eventfd / signalfd / timerfd
  close(eio->eventfd);
  close(eio->signalfd);
  close(eio->timerfd);

  return EASY_OK;
}
```

**关键设计**:

- 先停 listen (不再接受新连接)
- 再清理已有 connection (发 FIN,等对方关闭或超时)
- 最后 join IO 线程 (确保资源释放)
- 整个流程是**同步**的,容易出错 (slow connection 阻塞 shutdown — 见 #108 改进方案)

### 2.9 协程支持 (`easy_uthread`)

[`deps/easy/src/thread/easy_uthread.h`](deps/easy/src/thread/easy_uthread.h):

```cpp
typedef struct easy_uthread_t {
  easy_list_t           node;
  void                 *stack;                 // 协程栈
  int                   stack_size;
  int                   status;                // EASY_UTHREAD_INIT/RUNNING/SUSPENDED
  ucontext_t            ctx;                   // ucontext (Linux)
  void                (*entry)(void *);
  void                 *args;
  void                 *ret;
} easy_uthread_t;

extern int  easy_uthread_init(easy_uthread_t *uth, int stack_size);
extern int  easy_uthread_create(easy_uthread_t *uth,
                                 void (*entry)(void *), void *args);
extern void easy_uthread_yield();
extern void easy_uthread_resume(easy_uthread_t *uth);
extern void easy_uthread_destroy(easy_uthread_t *uth);
```

**使用模式** (obrpc 调用方):

```cpp
void obrpc_invoke_async(...) {
  easy_session_t *s = easy_session_create(sizeof(...));
  easy_uthread_t *uth = ...;
  easy_session_set_uthread(s, uth);
  easy_connection_send_session(c, s);
  easy_uthread_yield();   // 当前协程挂起,等 RPC 返回后 resume
  // 醒来时,ret 已被填好
  ...
}
```

**OB 5.x 演进**: 部分路径从 `easy_uthread` 切到 **C++20 coroutine** (`ob_occam_*`),但 `easy_uthread` 仍是大多数 RPC client 的实现。

---

## 3. 性能

### 3.1 单 IO 线程性能 (echo benchmark)

| 指标 | 值 |
|------|-----|
| 每秒新建连接 (短连接) | ~10 万 |
| 每秒处理请求 (echo, 64 B) | ~50 万 |
| 长连接 (1 万) CPU 占用 | ~10% (单核) |
| 长连接 (10 万) 内存 | ~50 MB (per-conn ~500 B) |
| 平均延迟 | < 100 μs |

### 3.2 多 IO 线程扩展性

| io_thread_count | QPS (echo) | CPU 占用 |
|-----------------|------------|----------|
| 1 | 50 万 | 单核跑满 |
| 4 | 180 万 | 4 核 |
| 8 | 320 万 | 8 核 |
| 16 | 480 万 | 16 核 (扩展性 ~0.75) |

**瓶颈**:

- shared cache line (统计字段 doing_count / done_count)
- lock contention in `user_thread_pool` (跨线程 dispatch)
- memory bandwidth (memcpy for packet)

### 3.3 SO_REUSEPORT vs 单 listen

| 方案 | 100K conn QPS |
|------|---------------|
| 单 listen + accept mutex | ~30 万 |
| SO_REUSEPORT 多队列 | ~80 万 |

SO_REUSEPORT 让 kernel 自动负载均衡 (基于五元组 hash),避免 accept 锁争用。**OB 默认开启**。

### 3.4 memory footprint

| 结构 | 大小 |
|------|------|
| `easy_connection_t` | ~600 B |
| `easy_request_t` | ~150 B |
| `easy_message_t` | ~200 B |
| `easy_buf_t` | ~50 B |
| per-conn 总开销 | ~1 KB (含 `easy_pool_t`) |

10 万长连接 → ~100 MB 内存 (用于 connection 状态机),加 packet buffer 总计 ~200 MB。

---

## 4. v2 连接

| 文章 | 关联点 |
|------|--------|
| #25 内存管理 | libeasy 用 `easy_pool_t` 内存池,跟 OB 内存模型集成 |
| #27 RPC/obrpc | obrpc 在 easy_io 之上,用 `easy_request_t` 做 RPC packet (见 #108) |
| #103 atomic | `easy_atomic_t` / `produce_seq` / `consume_seq` 是 counter 模式 |
| #104 atomic Flag | `easy_connection_t::status` 是 Flag 模式 (见 #104 BCAS) |
| #108 (本系列下篇) | easy_io 连接生命周期 + obrpc 序列化 |

---

## 5. 调优 Checklist

### 5.1 IO 线程数

```bash
# 默认值
io_thread_count = min(NCPU, 8)

# 调优建议
- 高并发小包 (RPC): io_thread_count = NCPU (跟核数对齐)
- 大包 IO 密集 (备份): io_thread_count = NCPU / 2 (避免 IO 等待阻塞)
- 混合负载: io_thread_count = min(NCPU, 8) (默认,经过生产验证)
- 不建议超过 16 (扩展性下降到 0.75 以下)
```

### 5.2 SO_REUSEPORT

```bash
# 必须开启 (默认开启)
use_so_reuseport = 1

# 检查是否生效
ss -tnlp 'sport = :<port>'
# 看到多个进程 listen 同一端口 = 生效
# (实际上是一个进程多个 thread, ss 看不出来,但 ss -tnlp 的 Inode 会不同)
```

### 5.3 eventfd / signalfd / timerfd

```bash
# 检查文件描述符 (确认都创建)
ls -la /proc/<pid>/fd/ | grep -E "(eventfd|signalfd|timerfd)"

# 数量应该是:每个 io_thread 1 个 eventfd + 1 个 signalfd + 1 个 timerfd
# 加上 main loop 的 3 个 → 总共 = 3 * (io_thread_count + 1)
```

### 5.4 keepalive

```bash
# 启用 TCP keepalive (避免长连接死链)
keepalive_enabled = 1
keepalive_idle = 60     # 60s 后开始探测
keepalive_intvl = 10    # 探测间隔 10s
keepalive_probes = 3    # 探测 3 次失败就断开

# (kernel 也有 net.ipv4.tcp_keepalive_* 参数,需要同步设置)
```

### 5.5 graceful shutdown 超时

```bash
# 优雅退出最长等待时间
graceful_shutdown_timeout = 30   # 30s 超时 (默认)

# 超时后强制关闭 (建议开启)
shutdown_force = 1
# 超时后会 close 所有连接,不等待 graceful FIN
```

### 5.6 listen backlog

```bash
# listen backlog
listen_count = 1024

# 检查 kernel 参数
sysctl net.core.somaxconn
# 应该 >= listen_count

# 检查当前 backlog 占用
ss -lnt 'sport = :<port>'
# Recv-Q 接近 Send-Q → backlog 满,需要调大
```

### 5.7 buffer size

```bash
# socket send / recv buffer
# OB 通常不主动调, 用 kernel 默认 (TCP 自动调优)
# 特殊场景 (大包 RPC): 可调 SO_SNDBUF / SO_RCVBUF 到 1 MB
```

---

## 6. 故障 case

### 6.1 IO 线程死循环 / hang

**症状**: 整个进程不响应请求,但 RSS / CPU 正常

**原因**:

- IO 线程陷入 handler (handler 死循环 / 长事务 / 等锁)
- epoll_wait 返回后,某个 connection 进入死循环
- 信号处理没有走 signalfd (在 handler 里被阻塞)

**排查**:

```bash
# 1. 看每个线程在做什么
gdb -p <pid> -ex "thread apply all bt" -batch

# 2. 检查 libeasy 的 doing_count
# (从 /proc/<pid>/stat 或者 vtable 拿)
# 如果某个 io_thread.doing_count 长期不归 0 → 死循环
cat /proc/<pid>/io | grep -E "doing_count|done_count"
```

**解决**:

- handler 不能长事务 (超过 100ms 要 dispatch 到 `user_thread_pool`)
- 启用 watchdog 监控 `io_thread::doing_count` (超时报警)
- handler 中避免用 `pthread_mutex_lock` (可能等锁)

### 6.2 listen backlog 满 → 新连接被 RST

**症状**: 部分 client 连不上 server,但旧连接正常

**原因**:

- accept() 调用太慢 (handler 卡住)
- listen backlog 设置太小
- kernel accept queue 满 (`net.core.somaxconn`)

**排查**:

```bash
# 看 listen backlog
ss -lnt 'sport = :<port>'
# Recv-Q 接近 Send-Q → backlog 满

# 看 kernel drops
netstat -s | grep -i listen
# "ListenOverflows" / "ListenDrops" 计数 → kernel accept queue 满
```

**解决**:

- 增大 listen backlog: `listen_count = 1024`
- 调大 kernel 参数: `sysctl net.core.somaxconn = 4096`
- 启用 SO_REUSEPORT (分散 accept 压力)
- 排查 handler 是否卡住 (见 6.1)

### 6.3 shutdown hang

**症状**: `kill -TERM` 后进程不退出,等几分钟才退出

**原因**:

- slow connection (客户端不响应 FIN)
- handler 卡住,没退出
- 关闭流程是同步的,一个 io_thread 卡住全卡住

**排查**:

```bash
# 看 IO 线程 stack
gdb -p <pid> -ex "thread N" -ex "bt" -batch
# 看每个 io_thread 在做什么
```

**解决**:

- 启用 `graceful_shutdown_timeout` (默认 30s)
- 超时后强制 shutdown (`shutdown_force = 1`,close all connections)
- 客户端 keepalive 检测死链
- libeasy 4.x 改进: 异步 shutdown (见 follow-up #3)

### 6.4 eventfd / signalfd 漏关闭

**症状**: 进程重启后 `lsof` 看到旧的 fd 没释放 (但进程已退出,实际无影响)

**原因**:

- `easy_eio_destroy` 漏调用
- crash 时没走正常关闭流程 (SIGSEGV / SIGKILL)
- signal handler 中断了关闭流程

**解决**:

- 退出前必须 `easy_eio_destroy`
- crash handler 注册 cleanup (用 `atexit` 或 signal handler)
- systemd / docker 用 `TimeoutStopSec` 强杀

### 6.5 信号在 IO 线程上触发 (race)

**症状**: 偶发死锁 / 数据竞争

**原因**:

- signal handler 跑在任意线程,不是 main thread
- POSIX 信号在多线程下语义模糊 (signal mask 来自哪个线程?)

**排查**:

```bash
# 看是否有自定义 signal handler
grep -rn "signal(" src/ | head
# 如果有,且没走 signalfd → 问题
```

**解决**:

- 用 `signalfd` (libeasy 已默认开启)
- 把 `sigaction` 注册到 main thread,IO 线程 block 信号
- 自定义 signal handler 必须是 async-signal-safe (只用 atomic / write)

---

## 7. 源码锚点 (grep)

```bash
# 找到 libeasy 的关键定义
grep -n "easy_io_t\|easy_io_thread_t\|easy_connection_t\|easy_request_t" \
  deps/easy/src/io/*.h

# Reactor 模式入口
grep -n "easy_eio_start\|easy_eio_stop\|easy_eio_shutdown" \
  deps/easy/src/io/easy_io.c

# ev 抽象层
grep -n "ev_loop_new\|ev_io_init\|ev_run" \
  deps/easy/src/io/ev.h

# 多线程池
grep -n "easy_baseth_init\|easy_thread_pool_t\|produce_seq\|consume_seq" \
  deps/easy/src/io/easy_baseth_pool.{h,c}

# eventfd / signalfd / timerfd
grep -n "eventfd\|signalfd\|timerfd" \
  deps/easy/src/io/easy_io.c

# 启动流程
grep -n "easy_eio_start\b\|easy_io_thread_main\b" \
  deps/easy/src/io/easy_io.c

# 协程支持
grep -n "easy_uthread_init\|easy_uthread_yield\|easy_uthread_resume" \
  deps/easy/src/thread/easy_uthread.{h,c}
```

---

## 8. Cross-cutting

| 主题 | 关联点 |
|------|--------|
| atomic | `easy_atomic_t` 是 #103 Counter 模式;`produce_seq` / `consume_seq` 也是 Counter 模式 |
| Flag | `easy_connection_t::status` 是 #104 Flag 模式 (BCAS 状态机) |
| 内存 | `easy_pool_t` 是 #25 内存管理的简化版 (per-connection pool) |
| 线程 | IO 线程是 #109 Worker 体系的一部分 (`easy_io_thread` 是 worker 的一种) |
| RPC | obrpc 在 libeasy 之上 (见 #108) |
| 信号 | signalfd 把信号处理移到 main thread,避免 race |
| SSL | `easy_ssl_*` 在 libeasy 之上,提供加密通道 |
| 限流 | `easy_region_ratelimitor_t` 跨 region 限流 (跟 #28 资源管理相关) |

---

## 9. 总结

libeasy 是 OB 网络栈的核心,提供:

- Reactor 模式 + 多 IO 线程 (默认 `min(NCPU, 8)`)
- 跨平台 IO 多路复用 (epoll / kqueue / io_uring 实验性)
- 协程支持 (`easy_uthread`)
- 协议无关的 handler dispatch
- 多级消息处理 (`easy_message_t`)
- 跨 region 限流

OB 用 libeasy (而非 muduo / asio) 是因为:

1. 跟 OB RPC 协议栈紧耦合 (obrpc / NetClient / NetServer)
2. SO_REUSEPORT 多队列优化
3. 跟 OB 内存模型集成 (`easy_pool_t`)

**libeasy 在 OB 5.x 的演进**:

- 加入 io_uring 后端 (实验性,在后台分支)
- 协程 (`libeasy uthread` → C++20 coroutine 部分路径)
- 零拷贝 (sendfile / splice 备份)
- 异步 graceful shutdown (解决 6.3 的痛点)

---

## 10. 后续可扩展方向

1. **libeasy uthread vs C++20 coroutine 对比** — OB 5.x 在部分路径已切到 C++20 coroutine (`ob_occam_*`),但 libeasy uthread 仍是大头。两者 yield / resume 语义差异、性能对比、内存占用
2. **SO_REUSEPORT + io_uring 端到端 benchmark** — 现有 benchmark 多是 echo,没有真实 OB RPC 流量。io_uring 真实收益 (vs epoll) 需在 OB 协议栈下验证
3. **easy_io graceful shutdown 异步化** — 当前同步流程是痛点 (slow connection 卡 shutdown)。改为:close listen → 等所有 connection 关闭 (异步,带超时) → join thread
4. **eventfd vs io_uring event 唤醒对比** — eventfd 是为了跨线程通信,io_uring 有原生 event 机制 (CQE),可以省掉 eventfd 这一层
5. **libeasy 跟 kernel TCP 层深度优化** — `TCP_DEFER_ACCEPT` (减少空 accept) / `TCP_FASTOPEN` (加速新连接) / `SO_ATTACH_REUSEPORT_CBPF` (自定义 SO_REUSEPORT 路由)
6. **跨 region 限流 (`easy_region_ratelimitor_t`) 详细剖析** — OB 多 region 部署时,跨 region RPC 限流策略 (per-region 令牌桶 + 滑动窗口)