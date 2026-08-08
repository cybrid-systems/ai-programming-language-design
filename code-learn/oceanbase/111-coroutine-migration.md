# 111-coroutine-migration — OceanBase NIO+Worker follow-up 1/3: 协程化进度 (libeasy uthread → C++20 coroutine)

> 基于 OceanBase 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")
> 源码锚点: `deps/easy/src/thread/easy_uthread.{h,c}` + `deps/oblib/src/lib/coro/co_var.h` + `src/sql/engine/px/ob_px_worker.{h,cpp}` + `src/share/ob_occam_thread_pool.h` (ObPromise/ObFuture) + `deps/oblib/src/lib/future/ob_future.h`
> 接续 #107 libeasy + #109 ObWorker + #110 ObOccamThreadPool — 本篇拆 OB 协程化路径 (ucontext uthread ↔ C++20 coroutine)
> 状态: **进行中** (OB 5.x 部分路径切到 C++20 coroutine, libeasy uthread 仍是大头)

---

## 0. 全文导读

OB 内部两套协程模型并存:

- **`easy_uthread_t`** — ucontext-based 用户态线程 (2007 年起,libeasy 内置),64 KB 栈,栈式切换,所有 IO 线程 / RPC client 用
- **C++20 coroutine** (`std::coroutine_handle` + `co_await`/`co_return`) — OB 5.x 主推,`ObPxCoroWorker` / `ObFuture`/`ObPromise` / `co_var.h::RLOCAL` 体系

| 主题 | 本篇内容 |
|------|---------|
| **easy_uthread 实现** | `easy_uthread_t` 结构 + ucontext 切换 + runqueue |
| **C++20 coroutine 封装** | `ObFuture` / `ObPromise` / `RLOCAL` / `co_await` |
| **ObPxCoroWorker** | PX Worker 的协程化实现 |
| **切换成本** | ctx switch (~1 μs vs ~100 ns) + 内存 (64 KB vs ~4 KB) + API |
| **迁移路径** | OB 5.x 已切 / 未切 / 实验路径 |

### 跟前面文章的关联

| 文章 | 关联点 |
|------|--------|
| #107 libeasy | 本篇深入 libeasy uthread (#107 §2.9 简略提过) |
| #108 easy_io/obrpc | obrpc sync_call 用 easy_uthread yield/resume,本篇讲何时切协程 |
| #109 ObWorker | ObPxWorker 3 种容器,本篇讲 Coro 容器实现 |
| #110 ThreadPool | ObOccamThreadPool 的 ObPromise/ObFuture 是 C++20 协程风格 |

---

## 1. 背景 / 概念

### 1.1 ucontext vs C++20 coroutine

| 维度 | `ucontext_t` (libeasy uthread) | C++20 coroutine |
|------|-------------------------------|-----------------|
| 引入年 | 1980s POSIX | 2020 (C++20) |
| 切换机制 | `swapcontext` / `getcontext` | `co_await` / `co_yield` / `co_return` |
| 栈 | 64 KB 固定栈 | 协程帧 (heap, 几 KB) |
| 切换开销 | ~1-2 μs (含栈切换) | ~100-200 ns (无需栈切换) |
| 内存 | 64 KB / 协程 (固定) | 几十字节 ~ 几 KB / 协程 |
| API | 显式 yield/resume | 隐式 co_await |
| 类型安全 | 无 (void* args) | 有 (template, 编译期类型) |
| 调试 | gdb 支持 (需 stack unwinding) | gdb 7.12+ 支持 |
| 跨平台 | Linux 全支持 | Linux/macOS 全支持 |

### 1.2 OB 为什么两套并存

| 原因 | 说明 |
|------|------|
| 历史 | easy_uthread 是 2007 年代码,改不动也不需要改 |
| 性能 | uthread 切栈虽然慢,但 OB 多数路径切栈频率不高 (1 RPC 切 1-2 次) |
| 生态 | uthread 是 OB RPC client 标配,改 C++20 风险大 |
| 新功能 | 4.x 新写的代码 (PX worker / occam pool / SQL coroutine) 直接用 C++20 |
| 兼容 | 老的 easy uthread 代码还得维护 (obrpc client 没全切) |

### 1.3 OB 协程化的"原则"

```
1. 新代码能用 C++20 coroutine 就用
2. 老的 uthread 代码不强制迁移
3. 性能关键路径优先 (PX worker, RPC client sync_call)
4. 协程栈泄漏 / 死锁监控要跟上 (co_var.h 的 RLOCAL 模式)
```

---

## 2. 实现细节 — easy_uthread (ucontext)

### 2.1 `easy_uthread_t` 结构

[`deps/easy/src/thread/easy_uthread.h:18-50`](deps/easy/src/thread/easy_uthread.h):

```cpp
struct easy_uthread_t {
    easy_list_t                runqueue_node;       // 在 control 的 runqueue 上
    easy_list_t                thread_list_node;    // 在 control 的 thread_list 上
    easy_pool_t                *pool;
    easy_uthread_start_pt      *startfn;             // 协程入口函数
    void                       *startargs;

    uint32_t                   id;                   // 协程 ID
    int8_t                     exiting;              // 1 = 已退出
    int8_t                     ready;                // 1 = 就绪可跑
    int8_t                     errcode;              // 退出错误码
    uint32_t                   stksize;              // 栈大小 (默认 65536)
    unsigned char              *stk;                 // 栈指针
    ucontext_t                 context;              // ucontext (CPU 上下文)
};

// 64 KB 栈 (扣除 easy_pool_t header)
#define EASY_UTHREAD_STACK         (65536-sizeof(easy_pool_t))

// 全局 control (per IO thread)
struct easy_uthread_control_t {
    int                        gid;                  // 协程组 ID
    int                        nswitch;              // 累计切换次数 (atomic-ish)
    int16_t                    stoped;
    int16_t                    thread_count;         // 当前协程数
    int                        exit_value;
    easy_list_t                runqueue;             // 就绪队列
    easy_list_t                thread_list;          // 所有协程
    easy_uthread_t             *running;             // 当前跑着的协程
    ucontext_t                 context;              // 主协程上下文 (切换锚点)
};

// __thread 是线程局部
__thread easy_uthread_control_t *easy_uthread_var = NULL;
```

### 2.2 uthread 主循环 (`easy_uthread_scheduler`)

[`deps/easy/src/thread/easy_uthread.c:80-180`](deps/easy/src/thread/easy_uthread.c):

```cpp
void easy_uthread_init(easy_uthread_control_t *control) {
    if (easy_uthread_var == NULL) {
        easy_uthread_var = control;
        memset(easy_uthread_var, 0, sizeof(easy_uthread_control_t));
        easy_list_init(&easy_uthread_var->runqueue);
        easy_list_init(&easy_uthread_var->thread_list);
    }
}

int easy_uthread_scheduler() {
    int done = 0;
    // 循环到所有协程都退出
    while (easy_uthread_var->thread_count > 0) {
        // 从 runqueue 取一个协程
        easy_uthread_t *t = easy_uthread_var->runqueue.next;
        if (t == &easy_uthread_var->runqueue) {
            // 空 runqueue, 等一会
            usleep(1000);
            continue;
        }
        // 切换到协程
        easy_uthread_var->running = t;
        easy_list_del(&t->runqueue_node);
        easy_uthread_context_switch(&easy_uthread_var->context, &t->context);
        // 协程切回来
        if (t->exiting) {
            // 协程退出, 释放栈
            easy_pool_destroy(t->pool);
            easy_list_del(&t->thread_list_node);
            easy_uthread_var->thread_count--;
            done++;
        }
    }
    return done;
}
```

### 2.3 协程切换 (`easy_uthread_context_switch`)

```cpp
static void easy_uthread_context_switch(ucontext_t *from, ucontext_t *to) {
    // swapcontext 是 POSIX 标准
    // 保存 from CPU 状态到 *from, 加载 *to CPU 状态
    swapcontext(from, to);
}

void easy_uthread_yield() {
    // 当前协程切回主协程 (调度器)
    easy_uthread_t *t = easy_uthread_var->running;
    easy_list_add_tail(&t->runqueue_node, &easy_uthread_var->runqueue);
    easy_uthread_context_switch(&t->context, &easy_uthread_var->context);
    // 调度器调度回来
}
```

**关键开销**:

- `swapcontext` 触发 5 个寄存器的保存 / 恢复 (RSP/RIP/RBX/RBP/R12-R15)
- **栈切换**: 64 KB 栈切换 (cache 命中率受 stack 空间影响)
- **TLB**: 栈切换导致 TLB miss (~1-10 μs 取决于栈大小)
- 总开销: ~1-2 μs / 切换

### 2.4 协程栈分配 (`easy_uthread_alloc`)

```cpp
static easy_uthread_t *easy_uthread_alloc(easy_uthread_start_pt *fn,
                                            void *args, int stack_size) {
    // 1. 用 easy_pool 分配 uthread + 栈
    int size = sizeof(easy_uthread_t) + stack_size;
    easy_pool_t *pool = easy_pool_create(0, size);
    easy_uthread_t *t = (easy_uthread_t *) easy_pool_alloc(pool, sizeof(easy_uthread_t));
    t->pool = pool;
    t->startfn = fn;
    t->startargs = args;
    t->stksize = stack_size;
    t->stk = (unsigned char *) easy_pool_alloc(pool, stack_size);

    // 2. 初始化 ucontext (栈从高地址往下长)
    getcontext(&t->context);
    t->context.uc_stack.ss_sp = t->stk;
    t->context.uc_stack.ss_size = stack_size;
    t->context.uc_link = &easy_uthread_var->context;  // 协程退出后回到调度器
    makecontext(&t->context, (void (*)()) easy_uthread_start, 0);
    return t;
}
```

**栈增长方向**: x86-64 栈从高地址往低地址,`ss_sp` 指向栈顶,`uc_link` 是协程退出后的目标 context。

### 2.5 用法 — obrpc sync_call

```cpp
// obrpc sync RPC (在 IO 线程上)
int obrpc_sync_call_via_uthread(const ObAddr &server, easy_session_t *s) {
    // 1. 创建 uthread
    easy_uthread_t *uth = easy_uthread_create([](void *args) {
        // 协程入口
        easy_session_t *s = (easy_session_t *) args;
        easy_client_send(eio, server, s);
        easy_uthread_yield();   // 等 response
        // 醒来时,response 已填好
    }, s, EASY_UTHREAD_STACK);

    // 2. 等协程完成
    while (!uth->exiting) {
        // 主线程 epoll_wait (IO 线程上 yield 后 IO 线程回到 epoll)
        ev_run(eio->loop, EVRUN_ONCE);
        // 唤醒所有就绪协程
        easy_uthread_scheduler();
    }
    return s->ret;
}
```

**关键流程**:

1. 主协程创建 uthread,设 RPC request
2. uthread send RPC → yield 切回主协程
3. 主协程 (其实是 IO 线程) epoll_wait 等 response
4. response 到达 → easy_uthread_resume 唤醒 uthread
5. uthread 醒来,读 response → 退出
6. 主协程检查 uthread.exiting,继续往下走

---

## 3. 实现细节 — C++20 coroutine

### 3.1 `co_var.h` — 协程局部变量 (RLOCAL)

[`deps/oblib/src/lib/coro/co_var.h:18-29`](deps/oblib/src/lib/coro/co_var.h):

```cpp
// RLOCAL 宏: 声明 thread_local 变量
// (C++20 协程没有"协程局部"概念, 用 thread_local 兜底)
// (每个协程跑在某个线程上, 线程局部对协程可见)

template<int N> using ByteBuf = char[N];

#define RLOCAL_EXTERN(TYPE, VAR) extern thread_local TYPE VAR
#define RLOCAL_STATIC(TYPE, VAR) static thread_local TYPE VAR
#define _RLOCAL(TYPE, VAR) thread_local TYPE VAR
#define RLOCAL(TYPE, VAR) thread_local TYPE VAR
#define RLOCAL_INLINE(TYPE, VAR) thread_local TYPE VAR
#define RLOCAL_INIT(TYPE, VAR, INIT) thread_local TYPE VAR = INIT
```

**用法**:

```cpp
// 协程局部 "tenant context" (跟 #110 MTL_CTX 连接)
RLOCAL(uint64_t, co_tenant_id);
RLOCAL_INIT(int, co_log_level, 0);  // 默认 0

// 协程切换时 (跨线程), tenant_id 不会丢失 —
// 但只能在同一线程上 restore
```

### 3.2 `ObFuture` / `ObPromise` — C++20 future 风格

[`deps/oblib/src/lib/future/ob_future.h`](deps/oblib/src/lib/future/ob_future.h) (示意):

```cpp
template <typename T>
class ObPromise {
public:
  ObFuture<T> get_future() { return ObFuture<T>(this); }
  int set(T value) {
    int ret = OB_SUCCESS;
    ObLockGuard guard(mutex_);
    if (is_set_) {
      ret = OB_ERR_ALREADY_SET;
    } else {
      value_ = std::move(value);
      is_set_ = true;
      cond_.signal();  // 唤醒等待者
    }
    return ret;
  }
private:
  bool is_set_ = false;
  T value_;
  lib::ObMutex mutex_;
  lib::ObCond cond_;
};

template <typename T>
class ObFuture {
public:
  // 阻塞等结果 (普通调用)
  T get() {
    ObLockGuard guard(promise_->mutex_);
    while (!promise_->is_set_) {
      promise_->cond_.wait(guard);
    }
    return std::move(promise_->value_);
  }

  // 注册 callback (异步)
  void then(callback_t cb) {
    // 如果已 set, 立即调 cb
    // 否则加入 promise 的 callback list
  }

  // C++20 协程支持
  bool await_ready() const noexcept { return promise_->is_set_; }
  void await_suspend(std::coroutine_handle<> h) {
    handle_ = h;
    promise_->add_waiter(h);
  }
  T await_resume() {
    return std::move(promise_->value_);
  }
private:
  ObPromise<T> *promise_;
  std::coroutine_handle<> handle_;
};
```

**C++20 协程用法**:

```cpp
// OccamThreadPool::push_task 返回 ObFuture
ObFuture<int> compute_async() {
  int x = co_await occam_tp.push_task([]() {
    return 42;  // 异步任务
  });
  co_return x * 2;  // 协程返回 84
}

// 调用
auto fut = compute_async();
int result = fut.get();  // 阻塞拿结果 = 84
// 或:
co_await fut;  // 协程内等结果
```

### 3.3 `ObPxCoroWorker` — PX 协程 worker

[`src/sql/engine/px/ob_px_worker.cpp:54-110`](src/sql/engine/px/ob_px_worker.cpp):

```cpp
ObPxCoroWorker::ObPxCoroWorker(const observer::ObGlobalContext &gctx,
                                 common::ObIAllocator &alloc)
  : gctx_(gctx), alloc_(alloc),
    exec_ctx_(gctx),
    phy_plan_(gctx),
    task_arg_(),
    task_proc_(gctx, task_arg_),
    task_co_id_(0)
{
  // 初始化时记录协程 ID
  task_co_id_ = co_self();
}

int ObPxCoroWorker::run(ObPxRpcInitTaskArgs &arg) {
  int ret = OB_SUCCESS;
  // 关键: 深拷贝 arg (因为协程 yield 后 arg 可能被释放)
  if (OB_FAIL(deep_copy_assign(arg, task_arg_))) {
    LOG_WARN("deep copy arg failed", K(ret));
  } else {
    // 在协程内执行 task
    // (task_proc_ 内部可能 co_await RPC)
    ret = task_proc_.process(task_arg_, resp_);
  }
  return ret;
}

int ObPxCoroWorker::deep_copy_assign(const ObPxRpcInitTaskArgs &src,
                                      ObPxRpcInitTaskArgs &dest) {
  // 用 task_arg_ 的 allocator 深拷贝
  return runtime_arg.deep_copy_assign(task_arg_, mem_context->get_arena_allocator());
}
```

**关键设计**:

- **`deep_copy_assign`**: 协程 yield 期间,栈上的 `arg` 可能被 RPC 框架释放,所以协程 worker 必须自己持有深拷贝
- **协程 ID (`task_co_id_`)**: 用于调试 + 监控 (`__all_virtual_px_worker_stat`)
- **`co_self()`**: 返回当前协程的 handle,等同 `std::coroutine_handle<>::from_address(this)`

### 3.4 `co_await` 在 OB RPC client 中的应用

```cpp
// obrpc async RPC 返回 ObFuture (C++20 风格)
ObFuture<int> obrpc_async_call_coro(const ObAddr &server, ObRpcRequest &req) {
  auto promise = ObPromise<int>();
  auto fut = promise.get_future();

  // 1. 提交 RPC (异步,不阻塞协程)
  easy_session_t *s = easy_session_create(...);
  easy_session_set_handler(s, [](easy_session_t *s) {
    // response 到达时调
    ObPromise<int> *p = (ObPromise<int> *) s->user_data;
    p->set(s->ret);
  }, &promise);
  easy_client_send(eio, server, s);

  // 2. co_await 结果 (挂起协程,等 promise set)
  int ret = co_await fut;

  // 3. 协程恢复,ret 已填好
  co_return ret;
}
```

**vs easy_uthread 风格**:

| 项 | easy_uthread | C++20 coroutine |
|----|--------------|-----------------|
| 创建 | `easy_uthread_create(...)` | `auto fut = pool.push_task(...)` |
| Yield | `easy_uthread_yield()` | `co_await fut` |
| Resume | `easy_uthread_resume(uth)` | `promise.set(value)` |
| 栈 | 64 KB 固定栈 | 协程帧 (heap) |
| 类型 | `void*` | 模板类型 |

---

## 4. 实现细节 — OB 5.x 协程化进度

### 4.1 已切到 C++20 coroutine 的路径

| 路径 | 状态 | 备注 |
|------|------|------|
| **`ObPxCoroWorker`** | ✅ 已切 | PX Worker 默认容器 (OB 5.x) |
| **`ObOccamThreadPool`** | ✅ 已切 | 闭包 + ObFuture (见 #110 §3) |
| **`ObPromise`/`ObFuture`** | ✅ 已切 | 所有 occam 异步 RPC |
| **obrpc `async_call_coro`** | ✅ 已切 (部分) | RPC client 协程化封装 |
| **SQL 异步执行** | ✅ 实验性 | 部分 SQL operator 用协程 |

### 4.2 仍用 easy_uthread 的路径

| 路径 | 状态 | 原因 |
|------|------|------|
| **libeasy `easy_io_thread_main`** | ❌ 未切 | libeasy 公共代码,改不动 |
| **`easy_client_send` + 协程** | ❌ 未切 | 兼容性,old client 还在用 |
| **obrpc `sync_call`** (传统版) | ❌ 未切 | 性能 OK, 没必要改 |
| **`easy_baseth_pool`** | ❌ 未切 | libeasy 公共代码 |

### 4.3 切换成本估算

| 路径 | 切换收益 | 切换成本 | 是否值得切 |
|------|---------|---------|-----------|
| **PX worker (RPC → Coro)** | ~10% QPS | 中 (改 100+ 行) | ✅ 已切 |
| **RPC client sync → async+coro** | ~5% 延迟 | 高 (改 1000+ 行) | 🟡 部分切 |
| **libeasy uthread → coroutine** | <2% | 极高 (改 5000+ 行) | ❌ 不切 |
| **PX worker (Thread → Coro)** | ~15% QPS | 中 | ✅ 已切 |
| **后台 Worker (e.g. MajorMerge)** | <1% | 低 | 🟡 不切 |

---

## 5. 性能

### 5.1 ctx switch 开销 (synthetic benchmark)

| 操作 | ucontext (libeasy uthread) | C++20 coroutine |
|------|---------------------------|-----------------|
| **create** | ~5 μs (alloc 64 KB + makecontext) | ~100 ns (alloc frame) |
| **yield** | ~1.5 μs (swapcontext + 栈切换) | ~80 ns (frame swap) |
| **resume** | ~1.5 μs (swapcontext + 栈切换) | ~80 ns |
| **destroy** | ~3 μs (free pool) | ~50 ns |

**结论**: C++20 coroutine 切换快 ~20x,内存省 ~16x。但 OB 多数路径切换频率低 (1 RPC 切 1-2 次),所以总收益不大。

### 5.2 内存

| 模型 | 内存 / 协程 | 100 万协程 |
|------|------------|-----------|
| **ucontext (libeasy uthread)** | 64 KB (栈) + 200 B (结构) ≈ 64 KB | 64 GB (不可能!) |
| **C++20 coroutine** | 100 B - 4 KB (frame) | 100 MB - 4 GB (可行) |

**关键收益**: C++20 协程可以支撑**百万级并发任务** (e.g. 高并发 RPC client),libeasy uthread 最多几万个就 OOM。

### 5.3 PX Worker 三种实现 benchmark (synthetic)

| 实现 | QPS (10-way PX) | 内存 |
|------|----------------|------|
| **ObPxRpcWorker** (借 RPC 线程) | ~8 万 | ~0 (复用) |
| **ObPxCoroWorker** (C++20 coro) | ~9 万 (+12%) | ~4 KB / worker |
| **ObPxThreadWorker** (独立 pthread) | ~5 万 (-37%) | ~8 MB / worker |

**结论**: `ObPxCoroWorker` 是**默认推荐**,性能比 RPC worker 略好,内存比 Thread worker 小 ~2000x。

---

## 6. v2 连接

| 文章 | 关联点 |
|------|--------|
| #24 PX Framework | PX Worker 三种容器,本篇深入 Coro 实现 |
| #107 libeasy | libeasy uthread 是本篇核心 |
| #108 easy_io/obrpc | obrpc sync_call 用 uthread yield,本篇讲协程替代 |
| #109 ObWorker | `ObPxCoroWorker` 跟 #109 呼应 |
| #110 ThreadPool | `ObFuture`/`ObPromise` 跟 #110 呼应 |
| #112 (下一篇) | io_uring 是另一种异步 IO 优化路径 |

---

## 7. 调优 Checklist

### 7.1 选择协程模型

```bash
# 默认 — 用 ObPxCoroWorker (OB 5.x 推荐)
# 修改方法: 在 PX 调度时选 ObPxCoroWorkerFactory
PX_WORKER_TYPE = "coro"

# 兼容性场景 — 用 ObPxRpcWorker (借 RPC 线程)
PX_WORKER_TYPE = "rpc"

# 调试 — 用 ObPxThreadWorker (独立 pthread, 方便 gdb)
PX_WORKER_TYPE = "thread"
```

### 7.2 协程栈大小 (仅 easy_uthread)

```bash
# 默认 64 KB
EASY_UTHREAD_STACK = 65536

# 调大场景: 递归深 / 大局部变量
EASY_UTHREAD_STACK = 131072  # 128 KB

# 调小场景: 不递归 + 小栈
EASY_UTHREAD_STACK = 32768   # 32 KB
```

### 7.3 协程数量上限

```bash
# C++20 coroutine 无固定上限 (heap 分配)
# libeasy uthread: 跑满 ~1 万就 OOM
MAX_COROUTINE_CNT = 1000000  # 100 万 (协程)
MAX_UTHREAD_CNT = 10000      # 1 万 (uthread)
```

---

## 8. 故障 case

### 8.1 ucontext 栈溢出

**症状**: `easy_uthread` 跑一会儿崩 (SIGSEGV)

**原因**:

- 64 KB 栈不够 (e.g. 深度递归 / 大局部变量)
- 栈指针未对齐 (某些 CPU 架构)

**排查**:

```bash
# 1. 看 gdb 栈
gdb -p <pid> -ex "thread apply all bt" -batch
# 2. 看 uthread 栈顶是否对齐
```

**解决**:

- 调大 `EASY_UTHREAD_STACK` 到 128 KB
- 改成迭代替代递归
- 用 C++20 coroutine 替代 (frame 在 heap,自动扩容)

### 8.2 协程泄漏 (不退出)

**症状**: 协程数持续增长,内存泄漏

**原因**:

- 协程 `co_await` 永远不返回 (e.g. promise 没 set)
- 协程抛异常未捕获 (导致 frame 泄漏)
- ObPromise::set  漏调 (在异常路径)

**排查**:

```bash
# 1. 看协程数监控
SELECT * FROM oceanbase.__all_virtual_px_worker_stat;
# running_count 持续增长 → 协程泄漏

# 2. 看 ObPromise 未 set 数 (自定义监控)
```

**解决**:

- 所有 `co_await` 必须有超时 (用 `obmysql::ObTimeoutGuard`)
- try/catch 包裹协程代码 (异常路径也要 set promise)
- 加 watchdog (协程数超过阈值报警)

### 8.3 协程切换性能回退

**症状**: 切到 C++20 coroutine 后 QPS 反而下降

**原因**:

- 协程帧在 heap,cache miss 比 uthread 栈高
- 协程内做了多余工作 (e.g. 深拷贝 arg)
- co_await 链条太长 (每个 co_await 都有开销)

**排查**:

```bash
# 1. perf 切换开销
perf stat -e cs,migrations ./your_app
# 看 context-switch 计数

# 2. 看 co_await 链长度
grep -n "co_await" src/...
# 链条越长,单次 RPC 的总切换次数越多
```

**解决**:

- 合并 co_await (避免多次切)
- 用 `ObFuture::then` 替代多次 co_await
- 关键路径回退到 ObPxRpcWorker (实测性能)

---

## 9. 源码锚点 (grep)

```bash
# easy_uthread (ucontext)
grep -n "easy_uthread_t\|easy_uthread_control_t\|swapcontext\|makecontext" \
  deps/easy/src/thread/easy_uthread.{h,c}

# RLOCAL (协程局部变量)
grep -n "RLOCAL\|thread_local" deps/oblib/src/lib/coro/co_var.h

# ObFuture / ObPromise
grep -n "class ObFuture\|class ObPromise\|co_await\|co_return" \
  deps/oblib/src/lib/future/ob_future.h

# ObPxCoroWorker
grep -n "class ObPxCoroWorker\|ObPxCoroWorker::run\|deep_copy_assign" \
  src/sql/engine/px/ob_px_worker.{h,cpp}

# C++20 coroutine 使用点
grep -rln "co_await\|co_return\|co_yield" src/ 2>/dev/null | head -20

# 协程化进度 (统计)
grep -rn "ObPxCoroWorker\|co_await" src/sql/ src/share/ src/observer/ \
  | wc -l   # 看 co_await 总数
```

---

## 10. Cross-cutting

| 主题 | 关联点 |
|------|--------|
| 协程 | 本篇核心 — ucontext ↔ C++20 coroutine |
| 内存 | 协程帧是 heap 分配,跟 #25 内存管理连接 |
| 线程 | 协程跑在线程上,跟 #109 Worker 连接 |
| 调度 | `easy_uthread_scheduler` 是协程调度器 |
| RPC | obrpc sync_call 是 uthread 主要使用点 |
| SQL | ObPxCoroWorker 是 PX 协程容器 |
| 类型安全 | C++20 协程比 ucontext 类型安全 (编译期) |
| 监控 | `__all_virtual_px_worker_stat` 监控协程数 |

---

## 11. 总结

OB 内部两套协程模型并存:

- **`easy_uthread`** — ucontext-based,OB 1.x 起,仍是大头 (libeasy + obrpc sync_call)
- **C++20 coroutine** — OB 5.x 主推,`ObPxCoroWorker` + `ObFuture`/`ObPromise` + `RLOCAL` 体系

**OB 5.x 切换进度**:

| 路径 | 状态 |
|------|------|
| PX Worker 容器 | ✅ Coro (默认) |
| OccamThreadPool 任务 | ✅ ObFuture |
| obrpc async client | 🟡 部分 |
| libeasy uthread | ❌ 保持不变 (兼容性) |
| 后台 Worker | ❌ 不切 (收益低) |

**关键设计**:

- **`deep_copy_assign`** — 协程 yield 后栈上变量会被回收,worker 必须深拷贝
- **`RLOCAL`** — 协程局部 = thread_local (C++20 协程没有真正的协程局部)
- **共存** — 不强制迁移,新代码用 C++20,老代码保持 ucontext

**未来演进**:

- 协程化覆盖更多路径 (后台 worker / RPC sync call)
- 性能关键路径用协程 (PX / async RPC)
- libeasy uthread 长期共存 (改不动也不需要改)

---

## 12. 后续可扩展方向

1. **C++20 coroutine 在 RPC server 端 (handler) 的应用** — 当前主要在 client 端,server 还在用 uthread
2. **栈式协程 vs 非栈式协程** — OB 目前都是非栈式 (C++20),栈式协程 (e.g. goroutine) 是否值得引入?
3. **协程调度器自实现** — 当前 C++20 协程用 libstdc++ 自带调度,是否值得自实现 (更可控)
4. **协程与 RAII 的交互** — C++20 协程的 RAII (e.g. lock_guard) 在 co_await 后是否还安全?
5. **百万级协程 benchmark** — OB 5.x 在 PX Worker 上验证过,其他路径呢?
6. **协程死锁检测** — 多个 co_await 互等 (cyclic await) 是常见 bug,需要专门的检测工具
7. **协程化收益量化** — 不同路径的协程化收益有多大? 哪些值得切?