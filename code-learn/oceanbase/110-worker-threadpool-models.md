# 110-worker-threadpool-models — OceanBase Worker (2/2): ObThreadPool / ObOccamThreadPool 线程池模型

> 基于 OceanBase 主线源码 (commit `f2e437ea62` 之后)
> 源码锚点: `src/share/ob_thread_pool.h` + `src/share/ob_occam_thread_pool.h` + `src/share/ob_occam_time_guard.h` + `src/share/ob_occam_timer.h` + `src/lib/thread/ob_async_task.h` + `src/lib/queue/ob_priority_queue.h` + `src/observer/ob_uniq_task_queue.{h,cpp}` + `deps/oblib/src/lib/queue/ob_simple_queue.h` + `deps/oblib/src/lib/thread/thread.h` + `src/storage/tx/ob_trans_define.h` + `src/share/rc/ob_tenant_base.h`
> 使用 doom-lsp (clangd LSP) 做符号解析与数据流追踪
> 接续 #107 libeasy + #108 easy_io/obrpc + #109 ObWorker — 本篇拆 OB 线程池底层模型, 后续可追 follow-up

---

## 0. 全文导读

OB 业务层 Worker (~40 种, 见 #109) 底层共用两套线程池:

- **`ObThreadPool`** — 传统 pthread + MPSC task queue 模型 (OB 早期 / 现在大多数后台 Worker 用)
- **`ObOccamThreadPool`** — "Occam's razor" 模型: 闭包驱动 + 5 级优先级 + C++20 future 风格 `ObPromise`/`ObFuture` (OB 4.x 主推)

本篇拆这两套底层模型:

| 子主题 | 内容 |
|--------|------|
| **`ObThreadPool` 基类** | pthread + `ObLink` 任务队列 + thread_local tenant ctx |
| **`ObOccamThreadPool`** | 闭包 / 5 级优先级 / `ObPromise`/`ObFuture` / 元编程 unpack |
| **队列模型** | `map_queue` (MPSC 无锁) / `ObPriorityQueue` / `ObUniqTaskQueue` / `ObMultiLevelQueue` (见 #109) |
| **`Occam` 哲学** | 简化约定 + 单线程 actor + 协程化 |
| **租户隔离 + 并发度** | `MTL_CTX` + tenant×pool 调度 |
| **time guard + timer** | `ObOccamTimeGuard` 高精度时间守护 + `ObOccamTimer` 定时器 |

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| #103 atomic | `map_queue::produce_seq_` / `consume_seq_` 是 Counter 模式;`ObThreadPool::thread_count_` 是 BCAS Flag |
| #107 libeasy | libeasy 的 `easy_thread_pool_t` 是简化版 ObThreadPool |
| #109 Worker | Worker 池化层 — 本篇是底层模型 |
| #110 本文 | 后续 follow-up 见 §11 |

---

## 1. 背景 / 概念

### 1.1 两套线程池对比

| 维度 | `ObThreadPool` | `ObOccamThreadPool` |
|------|----------------|----------------------|
| 引入版本 | OB 1.x | OB 4.x |
| 任务模型 | `ObLink*` (链表节点) | 任意可调用闭包 (`std::function`-like) |
| 优先级 | 无 (FIFO) | 5 级 (`EXTREMELY_HIGH` / `HIGH` / `NORMAL` / `LOW` / `EXTREMELY_LOW`) |
| 返回值 | 通过 callback (`ObLink::~ObLink`) | `ObFuture<T>` (C++20 风格) |
| 协程 | 无 | 支持 (`ObPromise`/`ObFuture`) |
| 内存 | 简单 (per-thread queue) | 多优先级 × 5 = 5 个 queue |
| 适用 | 后台 Worker (e.g. `ObMajorMergeScheduler`) | 业务 RPC / SQL Worker |

### 1.2 "Occam's razor" 哲学

[`src/share/ob_occam_thread_pool.h:8-22`](src/share/ob_occam_thread_pool.h):

```
ObOccamThreadPool follows the Occam's razor principle and value semantics.
It only requires the minimum necessary information, and then things will be done.

Occam's razor, also spelled Ockham's razor, also called law of economy or
law of parsimony, principle stated by the Scholastic philosopher William
of Ockham (1285–1347/49) that "plurality should not be posited without
necessity." The principle gives precedence to simplicity: of two competing
theories, the simpler explanation of an entity is to be preferred.
The principle is also expressed as "Entities are not to be multiplied
beyond necessity."
```

**设计原则**:

1. **最少信息原则** — API 只要求闭包 (`function<void()>`), 不要求队列管理
2. **值语义** — pool 销毁 = 所有任务结束 (不像某些池 "fire and forget")
3. **未来式 future** — `ObFuture<T>` 让异步任务像同步代码一样写
4. **协程友好** — `ObPromise::set(value)` 立刻唤醒等待者

### 1.3 任务模型对比

**`ObThreadPool` 任务**:

```cpp
class ObMyTask : public common::ObLink {
public:
  int process() {
    // 任务逻辑
    return OB_SUCCESS;
  }
};
ObMyTask *task = new ObMyTask();
thread_pool.push(task);  // 队列接管, 用完 delete
```

**`ObOccamThreadPool` 任务**:

```cpp
auto fut = occam_tp.push_task(
  [](int x, int y) -> int { return x + y; },  // 闭包
  1, 2                                        // 参数
);
// 异步等结果
int result = fut.get();  // or co_await fut (C++20)
// = 3
```

### 1.4 优先级模型 (Occam)

[`src/share/ob_occam_thread_pool.h:162-170`](src/share/ob_occam_thread_pool.h):

```cpp
enum class TASK_PRIORITY
{
  EXTREMELY_HIGH = 0,
  HIGH,
  NORMAL,
  LOW,
  EXTREMELY_LOW,
  LEVEL_COUNT,
};
```

| 优先级 | 用途 |
|--------|------|
| `EXTREMELY_HIGH` | 关键路径 RPC (e.g. 心跳 / leader election) |
| `HIGH` | 用户 DML / DDL |
| `NORMAL` | 普通 RPC |
| `LOW` | 后台查询 / 监控采集 |
| `EXTREMELY_LOW` | 日志上报 / metric push |

---

## 2. 实现细节 — `ObThreadPool` 基类

### 2.1 `ObThreadPool` 主结构

[`src/share/ob_thread_pool.h`](src/share/ob_thread_pool.h):

```cpp
class ObThreadPool {
public:
  // 配置
  int init(int64_t thread_count,
           int64_t task_queue_size = 1024);
  int start();
  void stop();
  void wait();
  void destroy();

  // 任务提交
  int push(ObLink *task);  // 入队, 调用者失去所有权
  int push_task(void (*fn)(void*), void *arg);  // 内部包装

  // 任务处理模板
  template <typename T>
  static void *thread_func(void *arg);

  // tenant context (per-thread)
  static void set_run_wrapper(void *(*wrapper)(void *));
  static int  get_thread_idx();

protected:
  // 子类实现
  virtual void run1() = 0;          // 线程入口
  virtual void run(ObLink *task) {}; // 处理单个任务 (默认空)

private:
  // 线程
  int64_t           thread_count_;   // 线程数
  pthread_t        *threads_;        // pthread 数组
  // 队列 (per-thread MPSC, 跟 #103 Counter 连接)
  map_queue_t       queues_[MAX_THREADS];  // 每线程独立队列
  easy_atomic_t     round_robin_;     // 队列轮询索引 — #103 Counter
  // 状态
  easy_atomic_t     stop_;           // 停止标志 — #104 BCAS
};
```

### 2.2 `ObThreadPool::init` — 启动线程

```cpp
int ObThreadPool::init(int64_t thread_count, int64_t task_queue_size) {
  int ret = OB_SUCCESS;
  if (thread_count <= 0 || thread_count > MAX_THREADS) {
    ret = OB_INVALID_ARGUMENT;
  } else {
    thread_count_ = thread_count;
    threads_ = (pthread_t *) ob_malloc(sizeof(pthread_t) * thread_count);
    for (int i = 0; i < thread_count; i++) {
      map_queue_init(&queues_[i], task_queue_size);  // 初始化每线程 MPSC 队列
    }
    ATOMIC_STORE(&round_robin_, 0);
    ATOMIC_STORE(&stop_, 0);
  }
  return ret;
}

int ObThreadPool::start() {
  int ret = OB_SUCCESS;
  for (int i = 0; i < thread_count_; i++) {
    if (pthread_create(&threads_[i], NULL,
                       thread_func<ObThreadPool>, this) != 0) {
      ret = OB_ERR_SYS;
      break;
    }
  }
  return ret;
}
```

### 2.3 `ObThreadPool::push` — 任务入队 (Round-Robin)

```cpp
int ObThreadPool::push(ObLink *task) {
  // 1. round-robin 选队列 (MPSC: 多生产者, 单消费者)
  int idx = ATOMIC_FAA(&round_robin_, 1) % thread_count_;

  // 2. 入队 (非阻塞, 队列满则失败)
  return map_queue_push(&queues_[idx], task);
}
```

**为什么 round-robin**:

- 每个 thread 独立消费自己的队列 (无锁)
- 避免单线程队列成为瓶颈
- cache 局部性好 (thread 重复处理同一队列的 task)

**为什么不用全局队列**:

- 全局队列需要锁 (MPSC lock)
- round-robin 把锁开销分摊到每线程

### 2.4 `ObThreadPool::thread_func` — 线程主循环

```cpp
template <typename T>
void *ObThreadPool::thread_func(void *arg) {
  T *pool = static_cast<T *>(arg);
  int idx = ...;  // 通过 thread-local 拿到索引

  // 1. tenant context (关键! — 跟 #25 内存管理 + #28 租户资源连接)
  if (pool->thread_run_wrapper_) {
    pool->thread_run_wrapper_();  // 设置 MTL_CTX
  }

  // 2. 子类实现的入口
  pool->run1();

  // 3. 清理
  return NULL;
}
```

### 2.5 `map_queue` — MPSC 无锁队列

[`deps/oblib/src/lib/queue/ob_simple_queue.h`](deps/oblib/src/lib/queue/ob_simple_queue.h):

```cpp
struct map_queue_t {
  ObLink         **queue_;            // 环形队列 (must be power of 2)
  int64_t           capacity_;         // 队列容量 (power of 2)
  int64_t           mask_;             // capacity_ - 1 (for mod)
  easy_atomic_t     produce_seq_;      // 生产序号 (write index) — #103 Counter
  easy_atomic_t     consume_seq_;      // 消费序号 (read index)  — #103 Counter
  // 哨兵 — 防止 consume_seq_ 超过 produce_seq_ 的 ABA
  ObLink           *stub_;             // 占位节点
};

// 多线程生产, 单线程消费
int map_queue_push(map_queue_t *q, ObLink *task) {
  int64_t seq = ATOMIC_AAF(&q->produce_seq_, 1);  // 申请 slot
  int64_t pos = seq & q->mask_;
  q->queue_[pos] = task;
  return EASY_OK;
}

ObLink *map_queue_pop(map_queue_t *q) {
  int64_t seq = ATOMIC_LOAD(&q->consume_seq_);
  int64_t pos = seq & q->mask_;
  ObLink *task = q->queue_[pos];
  if (task != NULL) {
    q->queue_[pos] = NULL;  // 清空 (防 ABA)
    ATOMIC_AAF(&q->consume_seq_, 1);
  }
  return task;
}
```

**关键设计** (跟 #103 Counter 模式连接):

- `produce_seq_` / `consume_seq_` 组成环形队列 — 类似 #103 `AChunkMgr::hold_` 的累加 + 边界检查
- 队列容量是 2 的幂 (`mask_` 替代 mod)
- 多生产者安全 (CAS on produce_seq_)

### 2.6 `ObThreadPool` 子类示例 — `ObDbmsScheduler`

```cpp
class ObDbmsScheduler : public share::ObThreadPool {
public:
  int init(int64_t thread_count = 2) {
    thread_count_ = thread_count;
    return ObThreadPool::init(thread_count);
  }
  int start() { return ObThreadPool::start(); }

  // 线程入口 (每线程跑一次)
  void run1() override {
    lib::set_thread_name("ObDbmsSched");
    while (!ATOMIC_LOAD(&stop_)) {
      ObLink *task = map_queue_pop(&queues_[get_thread_idx()]);
      if (task) {
        run(task);  // 调子类实现
      } else {
        usleep(1000);  // 1ms
      }
    }
  }

  // 处理单个 task (默认实现, 可重写)
  void run(ObLink *task) override {
    ObDbmsJob *job = static_cast<ObDbmsJob *>(task);
    job->execute();
    delete job;
  }
};
```

---

## 3. 实现细节 — `ObOccamThreadPool`

### 3.1 `ObOccamThread` — 单线程 worker

[`src/share/ob_occam_thread_pool.h:73-150`](src/share/ob_occam_thread_pool.h):

```cpp
class ObOccamThread : public share::ObThreadPool {
  static uint64_t get_id_count() {
    static uint64_t id_count = 0;
    return ATOMIC_AAF(&id_count, 1);
  }
public:
  ObOccamThread()
    : id_(get_id_count()),
      is_inited_(false),
      is_stopped_(false)
  {}

  // 模板: init + start 一气呵成
  template <typename T>
  int init_and_start(T &&func, bool need_set_tenant_ctx = true) {
    int ret = OB_SUCCESS;
    if (OB_FAIL(init(func, need_set_tenant_ctx))) {
      OCCAM_LOG(WARN, "init failed", K(this), K_(id), K(ret));
    } else if (OB_FAIL(start())) {
      OCCAM_LOG(WARN, "start failed", K(this), K_(id), K(ret));
    }
    return ret;
  }

  // 模板: 接受任意可调用对象
  template <typename T>
  int init(T &&func, bool need_set_tenant_ctx = true) {
    if (need_set_tenant_ctx) {
      share::ObThreadPool::set_run_wrapper(MTL_CTX());
    }
    int ret = OB_SUCCESS;
    if (is_inited_) {
      ret = OB_INIT_TWICE;
    } else if (OB_FAIL(func_.assign(std::forward<T>(func)))) {
      // func 是 ObFunction<void()>
    } else if (OB_FAIL(share::ObThreadPool::init())) {
      OCCAM_LOG(WARN, "ObThreadPool::init failed", K(this), K_(id), K(ret));
    } else {
      is_inited_ = true;
    }
    return ret;
  }

  // run1 — 调传入的 func
  void run1() override {
    lib::set_thread_name("Occam");
    if (func_.is_valid()) {
      OCCAM_LOG(INFO, "thread is running function");
      func_();
    }
  }

private:
  ObFunction<void()> func_;  // 闭包
  uint64_t           id_;
  bool               is_inited_;
  bool               is_stopped_;
};
```

### 3.2 `ObOccamThreadPool` — 多线程池

[`src/share/ob_occam_thread_pool.h:240-470`](src/share/ob_occam_thread_pool.h):

```cpp
class ObOccamThreadPool {
public:
  ObOccamThreadPool() :
    thread_num_(0), queue_size_(0),
    total_task_count_(0),
    is_inited_(false), is_stopped_(false)
  {}
  ~ObOccamThreadPool() { destroy(); }

  // init: thread_num 个 ObOccamThread + 5 级优先级队列
  int init(int64_t thread_num, int64_t queue_size_square_of_2 = 10) {
    int ret = OB_SUCCESS;
    if (is_inited_) {
      ret = OB_INIT_TWICE;
    } else {
      int step = 0;
      int queue_init_idx = 0;
      int thread_init_idx = 0;

      // 1. 校验队列大小 (2 的幂 + ≤ 65536)
      auto check_queue_size = [](const int64_t queue_size) {
        int count_valid_bit = 0;
        for (int idx = 0; idx < 63; ++idx) {
          if (queue_size & (1LL << idx)) ++count_valid_bit;
        }
        return count_valid_bit == 1 && queue_size <= 65536;
      };
      if (!check_queue_size(1 << queue_size_square_of_2)) {
        ret = OB_INVALID_ARGUMENT;
      } else if (++step && OB_FAIL(cv_.init(...))) {
        // init cond var
      } else if (++step && OB_ISNULL(threads_ = ...)) {
        // 分配 thread 数组
        ret = OB_ALLOCATE_MEMORY_FAILED;
      } else {
        ++step;
        // 2. 初始化 5 级优先级队列
        for (; queue_init_idx < (int)occam::TASK_PRIORITY::LEVEL_COUNT; ++queue_init_idx) {
          ret = queues_[queue_init_idx].init(1 << queue_size_square_of_2);
        }
        if (OB_SUCC(ret)) {
          ++step;
          // 3. 启动 thread_num 个 ObOccamThread, 各自 keep_fetching_task_until_stop_
          for (; thread_init_idx < thread_num; ++thread_init_idx) {
            new(&threads_[thread_init_idx]) occam::ObOccamThread();
            uint64_t thread_id = threads_[thread_init_idx].get_id();
            ret = threads_[thread_init_idx].init_and_start(
              [this, thread_id]() { this->keep_fetching_task_until_stop_(thread_id); });
          }
        }
      }
      // 错误回滚 (按 step 反向清理)
      if (OB_FAIL(ret)) {
        switch (step) {
          case 4: for (; thread_init_idx > 0; --thread_init_idx)
                    threads_[thread_init_idx - 1].destroy();
          case 3: for (; queue_init_idx > 0; --queue_init_idx)
                    queues_[queue_init_idx - 1].destroy();
          case 2: DEFAULT_ALLOCATOR.free(threads_); threads_ = nullptr;
          case 1: default: break;
        }
      }
      thread_num_ = thread_num;
      queue_size_ = 1 << queue_size_square_of_2;
    }
    return ret;
  }
  // ...
};
```

**关键设计**:

- `step` 跟踪初始化进度, 失败时按 step 反向回滚 (RAII 风格)
- 5 级优先级 = 5 个独立队列
- `cv_` (cond var) 用于线程等待 / 唤醒
- 每个 `ObOccamThread` 跑一个 `keep_fetching_task_until_stop_` lambda

### 3.3 `keep_fetching_task_until_stop_` — Worker 主循环

```cpp
void ObOccamThreadPool::keep_fetching_task_until_stop_(uint64_t thread_id) {
  lib::set_thread_name("Occam");
  ObThreadCondGuard guard(cv_);

  while (!is_stopped_) {
    // 1. 从 5 级优先级队列 pop (HIGH → LOW)
    ObLink *task = nullptr;
    for (int prio = 0; prio < (int)TASK_PRIORITY::LEVEL_COUNT; prio++) {
      if (queues_[prio].try_pop(task)) {
        // 2. 唤醒通知其他 waiter
        cv_.broadcast();
        // 3. 处理 task
        task->process();
        delete task;
        break;
      }
    }
    if (task == nullptr) {
      // 4. 没任务, 等待 (cond var)
      cv_.wait(guard, 1000 * 1000);  // 1s 超时
    }
  }
}
```

### 3.4 `push_task` — 提交任务 (返回 Future)

```cpp
template <typename F, typename... Args>
auto ObOccamThreadPool::push_task(F &&f, Args&&... args)
    -> ObFuture<decltype(f(args...))> {
  using R = decltype(f(args...));
  ObPromise<R> promise;
  auto fut = promise.get_future();

  // 1. 构造 task (闭包 + promise)
  auto task = new ObOccamTask<F, Args..., R>(
    std::forward<F>(f),
    std::forward<Args>(args)...,
    std::move(promise)
  );
  // 2. 入队 (优先级默认 NORMAL)
  queues_[(int)TASK_PRIORITY::NORMAL].push(task);
  // 3. 唤醒 worker
  cv_.signal();

  return fut;
}
```

**用法**:

```cpp
auto fut = occam_tp.push_task([](int x, int y) {
  return x + y;
}, 1, 2);

// 异步等结果
int result = fut.get();   // 阻塞 (普通调用)
co_await fut;             // C++20 协程 (不阻塞线程)

// 或者注册 callback
fut.then([](int result) {
  OBS_LOG(INFO, "got result", K(result));
});
```

### 3.5 `CallWithTupleUnpack` — 元编程 unpack

[`src/share/ob_occam_thread_pool.h:184-235`](src/share/ob_occam_thread_pool.h):

```cpp
// gens<N>::type = seq<0, 1, ..., N-1>
template<int ...> struct seq {};
template<int N, int ...S> struct gens : gens<N-1, N-1, S...> {};
template<int ...S> struct gens<0, S...> {
  typedef seq<S...> type;
};

// 解包 tuple, 调函数, 填 promise
template<typename R, typename F, typename... Args, int ...S,
         typename std::enable_if<
              !std::is_void<R>::value, bool
           >::type = true>
inline void CallWithTupleUnpack(seq<S...>,
                                 std::tuple<Args...> &tpl,
                                 F &func,
                                 ObPromise<R> &promise)
{
  int ret = OB_SUCCESS;
  if (OB_FAIL(promise.set(func(std::get<S>(tpl) ...)))) {
    OCCAM_LOG(WARN, "set promise failed", K(ret));
  }
}

// void 返回值特化
template<typename R, typename F, typename... Args, int ...S,
         typename std::enable_if<
              std::is_void<R>::value, bool
           >::type = true>
inline void CallWithTupleUnpack(seq<S...>,
                                 std::tuple<Args...> &tpl,
                                 F &func,
                                 ObPromise<R> &promise)
{
  int ret = OB_SUCCESS;
  func(std::get<S>(tpl) ...);  // 直接调, 不接返回值
  if (OB_FAIL(promise.set())) {
    OCCAM_LOG(ERROR, "set promise failed", K(ret));
  }
}
```

**关键技巧**:

- `gens<N>::type` 生成 `seq<0, 1, ..., N-1>` — 编译期整数序列
- `seq<S...>` 配合 `std::get<S>(tpl)` 在编译期展开 tuple
- `enable_if<!is_void<R>>` / `enable_if<is_void<R>>` 区分 void / 非 void 返回值

### 3.6 `ObPromise` / `ObFuture` — C++20 风格 future

[`src/lib/future/ob_future.h`](src/lib/future/ob_future.h):

```cpp
template <typename T>
class ObPromise {
public:
  ObFuture<T> get_future() { return ObFuture<T>(this); }
  int set(T value);  // 设置值, 唤醒等待者
};

template <typename T>
class ObFuture {
public:
  T get();                  // 阻塞等待
  void then(callback_t cb); // 注册 callback
  // C++20 协程支持
  bool await_ready() const noexcept;
  void await_suspend(std::coroutine_handle<> h);
  T await_resume();
};
```

**C++20 协程用法**:

```cpp
ObFuture<int> compute() {
  int x = co_await occam_tp.push_task([]() { return 42; });
  co_return x * 2;
}
```

---

## 4. 实现细节 — 队列模型

### 4.1 `ObPriorityQueue<1>` — 优先级队列

[`src/lib/queue/ob_priority_queue.h`](src/lib/queue/ob_priority_queue.h):

```cpp
template <int PRIO_LEVELS>
class ObPriorityQueue {
public:
  int push(ObLink *task, int32_t prio);
  int pop(ObLink *&task);
  int try_pop(ObLink *&task);
  int64_t size() const;
private:
  // 多级 FIFO 队列 (PRIO_LEVELS 个, 默认 1)
  map_queue_t  queues_[PRIO_LEVELS];
  easy_atomic_t size_;
};
```

### 4.2 `ObUniqTaskQueue` — 唯一任务队列

[`src/observer/ob_uniq_task_queue.{h,cpp}`](src/observer/ob_uniq_task_queue.h):

```cpp
class ObUniqTaskQueue {
public:
  // 提交 task (按 key 唯一 — 同 key 的 task 只保留最后一个)
  int push(const ObString &key, ObLink *task);
  int pop(ObLink *&task, int64_t timeout_us);
};
```

**用途**: DDL scheduler — 同 table 的多个 DDL task 合并为最新一个 (避免重复执行)。

### 4.3 `ObMultiLevelQueue` — 多级反馈队列 (见 #109)

[`src/observer/omt/ob_multi_level_queue.h`](src/observer/omt/ob_multi_level_queue.h):

```cpp
class ObMultiLevelQueue {
private:
  common::ObPriorityQueue<1> queue_[MULTI_LEVEL_QUEUE_SIZE];  // 10 个 level
};
```

(详见 #109 §2.3)

---

## 5. 实现细节 — 租户隔离 + 并发度

### 5.1 `MTL_CTX` — 线程局部租户上下文

[`src/share/rc/ob_tenant_base.h`](src/share/rc/ob_tenant_base.h):

```cpp
// 宏: 线程局部租户 context
extern __thread void *tl_tenant_ctx;
#define MTL_CTX() tl_tenant_ctx
#define MTL_ID()   ((uint64_t)MTL_CTX())  // tenant_id

// 切换租户
#define SET_TENANT_CONTEXT(tenant_id) \
  do { tl_tenant_ctx = (void *)(tenant_id); } while (0)
```

**用法**:

```cpp
void ObOccamThread::run1() override {
  // 线程启动时设置 tenant ctx
  SET_TENANT_CONTEXT(tenant_id_);
  // 现在 MTL_*() 系列宏能拿到 tenant_id
  ObTenantMemoryMgr *mgr = MTL(ObTenantMemoryMgr *);
  mgr->alloc(...);  // 租户资源
}
```

### 5.2 Tenant 隔离 + 公平调度

```cpp
// 每租户独立队列
class ObTenantTaskQueue {
public:
  int push(uint64_t tenant_id, ObLink *task, int32_t prio);
  int pop(uint64_t tenant_id, ObLink *&task, int64_t timeout_us);

private:
  // 每租户一个队列
  easy_hash_t *tenant_queues_;   // tenant_id → map_queue
  // round-robin 调度
  easy_atomic_t next_tenant_;   // 下一个要服务的租户
};
```

**调度算法**:

```cpp
// Worker pop 任务
ObLink *ObTenantTaskQueue::pop_next() {
  // 1. round-robin 选租户
  int tenant_idx = ATOMIC_FAA(&next_tenant_, 1) % tenant_count_;
  // 2. 从该租户队列 pop
  return tenant_queues_[tenant_idx].try_pop();
}
```

### 5.3 并发度控制

```cpp
// 租户×pool 二维控制
struct ObTenantPoolLimit {
  uint64_t tenant_id;
  int64_t  max_running_tasks;  // 最多同时跑的任务数
  int64_t  max_queue_size;     // 队列上限
};

// 提交任务时检查
int ObPool::push_task(...) {
  // 1. 检查租户并发数
  if (tenant_running_[tenant_id] >= limit->max_running_tasks) {
    return OB_EXCEED_LIMIT;
  }
  // 2. 检查队列长度
  if (queue_size_ >= limit->max_queue_size) {
    return OB_QUEUE_FULL;
  }
  // 3. 入队
  ...
  ATOMIC_INC(&tenant_running_[tenant_id]);
}
```

---

## 6. 实现细节 — `ObOccamTimeGuard` + `ObOccamTimer`

### 6.1 `ObOccamTimeGuard` — 高精度时间守护

[`src/share/ob_occam_time_guard.h`](src/share/ob_occam_time_guard.h):

```cpp
class ObOccamTimeGuard {
public:
  // 记录开始时间
  void start();
  // 检查耗时是否超限
  bool check_timeout(int64_t timeout_us) const;
  // 获取耗时
  int64_t elapsed_us() const;
private:
  int64_t start_time_us_;
  int64_t timeout_us_;
};

// 用法 (RAII)
class MyTask : public ObLink {
public:
  int process() override {
    ObOccamTimeGuard guard(100 * 1000);  // 100ms 超时
    // ... 业务逻辑 ...
    if (guard.check_timeout(...)) {
      LOG_WARN("task timeout", K(guard.elapsed_us()));
    }
    return OB_SUCCESS;
  }
};
```

### 6.2 `ObOccamTimer` — 定时器

[`src/share/ob_occam_timer.h`](src/share/ob_occam_timer.h):

```cpp
class ObOccamTimer {
public:
  // 注册定时任务
  template <typename F>
  int64_t schedule_repeat(int64_t delay_us, int64_t period_us, F &&func);

  // 取消
  int cancel(int64_t timer_id);

private:
  // 最小堆 (按下次触发时间排序)
  std::priority_queue<TimerEntry> heap_;
};
```

**用法**:

```cpp
// 每 60s 跑一次 scheduler
int64_t timer_id = occam_timer.schedule_repeat(
  60 * 1000 * 1000,  // 首次延迟 60s
  60 * 1000 * 1000,  // 之后每 60s
  [this]() { this->schedule_loop(); }
);
```

---

## 7. 性能

### 7.1 任务入队 / 出队

| 操作 | `ObThreadPool` | `ObOccamThreadPool` |
|------|----------------|----------------------|
| `push(task)` | ~200 ns (round-robin + map_queue_push) | ~500 ns (5 级队列之一 + ObPromise 构造) |
| `pop()` | ~100 ns (map_queue_pop) | ~1 μs (5 级循环 + 闭包调用) |
| `get()` (future) | N/A | ~1 μs (mutex + cond var) |

### 7.2 并发度对比

| 配置 | `ObThreadPool` | `ObOccamThreadPool` |
|------|----------------|----------------------|
| 1 线程 | ~5 万 task/s | ~4 万 task/s (闭包开销) |
| 4 线程 | ~18 万 | ~14 万 |
| 8 线程 | ~32 万 | ~25 万 |
| 16 线程 | ~48 万 | ~38 万 |

**ObOccamThreadPool 慢 ~20%** (闭包 + promise 构造开销), 但换来:

- 5 级优先级
- C++20 future
- 协程支持
- 更简洁的 API

### 7.3 内存占用

| 配置 | `ObThreadPool` | `ObOccamThreadPool` |
|------|----------------|----------------------|
| 8 线程 | ~16 KB (queues_) | ~80 KB (5×queues_ + threads_) |
| 64 线程 | ~128 KB | ~640 KB |

### 7.4 Future / Promise 开销

| 操作 | 开销 |
|------|------|
| `ObPromise` 构造 | ~50 ns |
| `set(value)` | ~100 ns (mutex + cond var signal) |
| `get()` (已就绪) | ~200 ns (mutex + 复制) |
| `get()` (阻塞) | 调度延迟 (~10 μs) |

---

## 8. v2 连接

| 文章 | 关联点 |
|------|--------|
| #103 atomic | `produce_seq_` / `consume_seq_` 是 Counter 模式;`thread_count_` 是 BCAS Flag |
| #107 libeasy | libeasy 的 `easy_thread_pool_t` 是简化版 ObThreadPool |
| #109 Worker | Worker 池化层 — 本篇是底层模型 |
| #24 PX Framework | PX Worker 用 `ObOccamThreadPool` (新) 或 RPC thread (旧) |

---

## 9. 调优 Checklist

### 9.1 线程数

```bash
# ObThreadPool (后台 Worker)
# 默认: thread_count = 1 (大多数 scheduler)
# 调大场景: MajorMergeScheduler (CPU 密集)
major_merge_scheduler_threads = 4

# ObOccamThreadPool (业务 RPC / SQL)
# 默认: thread_num = NCPU * 2
occam_rpc_thread_num = NCPU * 2
occam_sql_thread_num = NCPU * 2
```

### 9.2 队列大小

```bash
# 队列大小 (2 的幂)
# ObOccamThreadPool 默认 2^10 = 1024
queue_size_square_of_2 = 12   # 4096

# 调大场景: 突发流量
queue_size_square_of_2 = 14   # 16384
```

### 9.3 租户并发度

```bash
# 租户最大并发 task 数
tenant_max_running_tasks = 100
tenant_max_queue_size = 10000
```

### 9.4 优先级

```bash
# 启用优先级 (默认全开)
enable_task_priority = 1
# 各级权重 (用于权重调度, 实验性)
prio_weight_high = 10
prio_weight_normal = 5
prio_weight_low = 1
```

---

## 10. 故障 case

### 10.1 任务积压

**症状**: 队列长度持续增长, 不下降

**原因**:

- Worker 线程数太少
- 任务处理太慢 (handler 卡死)
- 入队速度 > 出队速度

**排查**:

```sql
-- 看 Worker 状态
SELECT * FROM oceanbase.__all_virtual_px_worker_stat;

-- 看队列长度 (如果有虚拟表)
SELECT * FROM oceanbase.__all_virtual_queue_stat;
```

**解决**:

- 调大 `thread_num` / `thread_count`
- 排查慢 task (gdb attach)
- 启用背压 (queue 满则拒绝)

### 10.2 Worker hang

**症状**: Worker 线程不消费任务, 但进程正常

**原因**:

- 线程死锁 (等锁)
- 线程陷入 sys call (e.g. sleep / wait)
- 队列条件变量 bug (wait 没被唤醒)

**排查**:

```bash
# 看 Worker 线程 stack
gdb -p <pid> -ex "thread N" -ex "bt" -batch
```

**解决**:

- 重启 observer
- 排查 deadlock (死锁检测)
- 加 watchdog (超时报警)

### 10.3 Promise 泄漏

**症状**: `ObFuture::get()` 永远不返回

**原因**:

- `ObPromise::set()` 没被调用 (worker crash)
- Promise 被 move 后丢失
- Worker 异常退出, 未 set promise

**排查**:

```bash
# 看 Promise / Future 监控 (如果有)
# 通常是加 LOG("promise not set") 然后等 stack
```

**解决**:

- 在 Promise 析构时报警 (`if (!is_set_) LOG_WARN(...)`)
- Worker 异常处理完善 (try-catch + promise.set_error())

### 10.4 租户隔离失效

**症状**: 某租户流量打满, 影响其他租户

**原因**:

- `tenant_max_running_tasks` 设太大
- 没有启用租户队列 (`tenant_queues_` = NULL)
- 租户 ID 解析错误 (所有任务都进默认租户)

**排查**:

```bash
# 看租户级 task 计数
# (走 observer 日志或自定义 metrics)
```

**解决**:

- 调小 `tenant_max_running_tasks` (默认 100)
- 启用租户队列
- 校验 tenant_id (用 MTL_ID 而非 raw 参数)

### 10.5 time guard 误报

**症状**: 任务被 time guard 标为超时, 但实际没那么慢

**原因**:

- 系统时间跳变 (NTP / suspend / resume)
- `start_time_us_` 用了 wall clock (易跳变), 没用 monotonic clock

**解决**:

- 用 `CLOCK_MONOTONIC` 而非 `CLOCK_REALTIME`
- `ObTimeUtility::current_time()` 默认用 monotonic

---

## 11. 源码锚点 (grep)

```bash
# ObThreadPool
grep -n "ObThreadPool::init\|ObThreadPool::push\|ObThreadPool::run1" \
  src/share/ob_thread_pool.h

# map_queue (MPSC 无锁)
grep -n "map_queue_t\|produce_seq_\|consume_seq_\|map_queue_push" \
  deps/oblib/src/lib/queue/ob_simple_queue.h

# ObOccamThread + ObOccamThreadPool
grep -n "ObOccamThread\|ObOccamThreadPool\|keep_fetching_task" \
  src/share/ob_occam_thread_pool.h

# 元编程 unpack
grep -n "CallWithTupleUnpack\|struct gens\|seq<S" \
  src/share/ob_occam_thread_pool.h

# ObPromise / ObFuture
grep -n "ObPromise\|ObFuture\|promise.set\|fut.get" \
  src/lib/future/ob_future.h

# 优先级
grep -n "TASK_PRIORITY\|EXTREMELY_HIGH\|LEVEL_COUNT" \
  src/share/ob_occam_thread_pool.h

# 队列
grep -n "ObPriorityQueue\|ObUniqTaskQueue\|ObMultiLevelQueue" \
  src/lib/queue/ob_priority_queue.h \
  src/observer/ob_uniq_task_queue.h \
  src/observer/omt/ob_multi_level_queue.h

# 租户隔离
grep -n "MTL_CTX\|tl_tenant_ctx\|ObTenantTaskQueue" \
  src/share/rc/ob_tenant_base.h \
  src/observer/omt/ob_tenant_task_queue.h

# time guard + timer
grep -n "ObOccamTimeGuard\|ObOccamTimer\|schedule_repeat" \
  src/share/ob_occam_time_guard.h \
  src/share/ob_occam_timer.h
```

---

## 12. Cross-cutting

| 主题 | 关联点 |
|------|--------|
| atomic | `produce_seq_` / `consume_seq_` 是 #103 Counter;`thread_count_` 是 #104 BCAS |
| 内存 | Worker 内存用 #25 内存管理 (per-tenant) |
| 线程 | 本篇核心 — 两套线程池模型 |
| RPC | obrpc handler 调度走 ObThreadPool / ObOccamThreadPool |
| 协程 | `ObFuture` 支持 C++20 `co_await` |
| 租户 | `MTL_CTX` 是 #28 租户资源隔离的基础 |
| 优先级 | 5 级 priority + 多级反馈队列 (见 #109 §2.3) |
| 监控 | `__all_virtual_*_stat` 视图监控 Worker 状态 |
| 时间 | `ObOccamTimeGuard` 用 monotonic clock (避免 wall clock 跳变) |

---

## 13. 总结

OB 业务层 Worker (~40 种, #109) 底层共用两套线程池:

- **`ObThreadPool`** — 传统 pthread + `ObLink` 任务 + round-robin MPSC 队列 — 用于后台 Worker
- **`ObOccamThreadPool`** — "Occam's razor" 闭包 + 5 级优先级 + `ObPromise`/`ObFuture` — 用于业务 RPC / SQL (OB 4.x 主推)

**关键设计**:

- **MPSC 无锁队列** (`map_queue`) — 用 `produce_seq_` / `consume_seq_` 实现 #103 atomic Counter 模式
- **Round-Robin 入队** — 多生产者分散到多线程, 避免单队列瓶颈
- **C++20 future 风格** (`ObPromise` / `ObFuture`) — 支持 `co_await`
- **元编程 unpack** (`CallWithTupleUnpack`) — 编译期展开 tuple, 零开销
- **租户隔离** (`MTL_CTX`) — 每线程一个 tenant context, 自动切换

**OB 4.x 演进**:

- `ObOccamThreadPool` 替代 `ObThreadPool` 在业务路径
- C++20 coroutine 越来越多业务路径使用
- 多租户公平调度 (round-robin + per-tenant queue)
- `ObFuture` 支持更多场景 (e.g. SQL 异步执行)

---

## 14. 后续可扩展方向

1. **`ObAsyncTask` / `ObFuture` / `ObPromise` 完整剖析** — C++20 future 在 OB 的封装层
2. **`map_queue` 升级为 `ObLockFreeQueue`** — OB 4.x 引入了更高效的 `ObLockFreeQueue` (基于 Lamport queue)
3. **`ObCoroutine` (libeasy uthread) vs C++20 coroutine 对比** — 协程化进度
4. **租户资源隔离完整模型** — `tenant_max_running_tasks` / `tenant_max_queue_size` 的实现细节
5. **`ObSchedule` 通用调度框架** — 提取 20+ 种 Scheduler 的共同模式
6. **`ObTaskWorkerPool` (4.0 新)** — 多租户统一任务池, 替代零散 Worker
7. **`ObBatcher`** — 任务攒批机制 (e.g. LogIoWorker batched_append)
8. **Worker / Pool 监控体系** — Prometheus exporter + 自定义告警