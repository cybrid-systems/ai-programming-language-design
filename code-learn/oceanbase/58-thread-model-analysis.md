# 线程模型与线程池 — ThreadPool、工作队列、线程管理

## 目录

1. [概述](#1-概述)
2. [核心类关系图](#2-核心类关系图)
3. [`Thread` — 内核线程的轻量封装](#3-thread--内核线程的轻量封装)
4. [`Threads` — 线程池基类](#4-threads--线程池基类)
5. [`ObDynamicThreadPool` — 动态任务线程池](#5-obdynamicthreadpool--动态任务线程池)
6. [`ObSimpleDynamicThreadPool` — 自适应收缩线程池](#6-obsimpledynamicthreadpool--自适应收缩线程池)
7. [`ObSimpleThreadPool` — 带队列的简单线程池](#7-obsimplethreadpool--带队列的简单线程池)
8. [`ObMapQueueThreadPool` — 基于哈希的 MapQueue 线程池](#8-obmapqueuethreadpool--基于哈希的-mapqueue-线程池)
9. [`ObReentrantThread` — 可重入线程](#9-obreentrantthread--可重入线程)
10. [`ObAsyncTaskQueue` — 异步任务队列](#10-obasynctaskqueue--异步任务队列)
11. [`ObWorkQueue` — Timer + 任务队列](#11-obworkqueue--timer--任务队列)
12. [`TGMgr` — 线程组管理器](#12-tgmgr--线程组管理器)
13. [总结](#13-总结)

---

## 1. 概述

OceanBase 的线程模型采用**分层设计**，从底层 pthread 封装到高层线程组管理器，构建了一套完整的线程体系。所有核心代码集中在 `deps/oblib/src/lib/thread/` 目录下。

```
ls deps/oblib/src/lib/thread/
```

输出中的关键文件：

- **thread.h / threads.h** — 底层 pthread 封装和线程池基类
- **thread_pool.h** — `ThreadPool` 类型别名（即 `Threads`）
- **ob_dynamic_thread_pool.h/cpp** — 动态线程池（自动管理线程生命周期）
- **ob_simple_thread_pool.h/ipp** — 带队列的简单线程池
- **ob_map_queue_thread_pool.h/cpp** — 基于 hash 分配的 MapQueue 线程池
- **ob_reentrant_thread.h/cpp** — 可重入线程模式
- **ob_async_task_queue.h** — 异步任务队列
- **ob_work_queue.h/cpp** — Timer 和任务队列的结合
- **thread_mgr.h** — 线程组管理器 TGMgr（全局调度中枢）

---

## 2. 核心类关系图

```
┌──────────────────────────────┐
│          Thread              │  (thread.h) 底层 pthread 封装
│   - pth_ (pthread_t)         │
│   - start/stop/wait/destroy  │
└──────────┬───────────────────┘
           │ 聚合管理
           ▼
┌──────────────────────────────┐
│         Threads              │  (threads.h) 线程池基类
│   - threads_[] (Thread*)     │  ThreadPool = Threads
│   - start/stop/wait/run      │
│   - set_thread_count()       │
│   - virtual run1()           │
└──────┬──────────┬────────────┘
       │          │
       ▼          ▼
┌──────────────────────┐  ┌──────────────────────┐
│  ObDynamicThreadPool │  │  ObReentrantThread   │
│  (线程池+任务队列)    │  │  (可重入线程)         │
└──────────┬───────────┘  └──────────────────────┘
           │
           ▼
┌──────────────────────┐
│  ObSimpleDynamicPool │  (自适应收缩)
│  + ObSimpleThreadPool│  (带队列)
│  + ObMapQueueThread  │  (hash分配)
└──────────────────────┘
           │
           ▼
┌──────────────────────────────┐
│  TGMgr (thread_mgr.h)       │  全局线程组管理器
│  - tgs_[] 全局 ITG 数组     │
│  - create_tg/destroy_tg     │
│  - TG_CREATE/TG_START 宏    │
└──────────────────────────────┘
```

---

## 3. `Thread` — 内核线程的轻量封装

`thread.h` 定义了 `Thread` 类，是对 Linux pthread 的轻量封装。

### 关键成员 (thread.h)

```cpp
class Thread {
  // ...
private:
  pthread_t pth_;          // pthread 句柄
  Threads *threads_;       // 所属的线程池
  int64_t idx_;            // 在线程池中的索引
  int64_t stack_size_;     // 栈大小
  bool stop_;              // 停止标记
  int64_t tid_;            // 线程 TID
  static thread_local Thread* current_thread_;  // 线程本地当前线程
};
```

### 核心生命周期

- **start()** — 通过 `pthread_create` 创建内核线程，入口为静态函数 `__th_start`
- **stop()** — 设置 `stop_ = true`，通知线程退出
- **wait()** — `pthread_join` 等待线程结束
- **destroy()** — 释放栈资源

### 静态工具方法 (thread.h)

```cpp
static Thread &current();                   // 获取当前 Thread 对象
static int64_t update_loop_ts();            // 更新循环时间戳，用于诊断
```

### 等待诊断支持 (thread.h)

`Thread` 提供了丰富的线程等待标记，用于诊断和分析：

```cpp
static constexpr uint8_t WAIT                 = (1 << 0);
static constexpr uint8_t WAIT_IN_TENANT_QUEUE = (1 << 1);
static constexpr uint8_t WAIT_FOR_IO_EVENT    = (1 << 2);
// ...

static thread_local uint8_t wait_event_;
static thread_local int64_t event_no_;
```

配合 `WaitGuard`、`RpcGuard`、`JoinGuard` 等 RAII 守卫类，可精确追踪线程阻塞原因。

---

## 4. `Threads` — 线程池基类

`threads.h` 定义了 `Threads` 类（即 `ThreadPool`），这是所有线程池的基类。

`thread_pool.h` 仅做别名：

```cpp
using ThreadPool = Threads;
```

### 核心数据结构 (threads.h)

```cpp
class Threads {
  int64_t n_threads_;       // 当前线程数
  int64_t init_threads_;    // 初始化线程数
  Thread **threads_;        // Thread 指针数组
  int64_t stack_size_;      // 栈大小
  bool stop_;               // 停止标记
  SpinRWLock lock_;         // 保护线程数变更
  IRunWrapper *run_wrapper_;// 租户上下文
};
```

### 生命周期方法 (threads.h)

| 方法 | 功能 |
|------|------|
| `start()` | 创建所有线程并启动 |
| `stop()` | 设置 `stop_=true`，停止所有线程 |
| `wait()` | 等待所有线程结束 |
| `destroy()` | 释放所有线程资源 |
| `run(int64_t idx)` | 每个线程的入口，设置 Worker 后调用 `run1()` |

### 动态调整线程数 (threads.cpp)

`set_thread_count()` 允许在运行时动态调整线程数：

```cpp
// threads.cpp
int Threads::set_thread_count(int64_t n_threads)
{
  SpinWLockGuard g(lock_);
  return do_set_thread_count(n_threads, false);
}
```

`do_set_thread_count()` 的实现逻辑（threads.cpp）：

- **减少线程**：停止并销毁多余的线程
- **增加线程**：分配新的 `Thread` 数组，创建新线程
- **启动前设置**：如果线程池尚未启动，只更新 `init_threads_`

### 线程回收机制 (threads.cpp)

`thread_recycle()` 和 `try_thread_recycle()` 用于销毁已停止的空闲线程：

```cpp
int Threads::do_thread_recycle(bool try_mode)
{
  // 遍历所有线程，对 has_set_stop() 的线程执行
  // destroy + 内存释放操作
  // 并压缩 threads_ 数组
}
```

### NUMA 感知 (threads.cpp)

`set_numa_info()` 允许设置 NUMA 节点亲和性：

```cpp
void Threads::set_numa_info(uint64_t tenant_id, bool enable_numa_aware, int32_t group_index)
{
  if (num_nodes > 0) {
    if (group_index != -1) {
      numa_info_.numa_node_ = group_index % num_nodes;
      numa_info_.interleave_ = false;
    }
  }
}
```

### 租户上下文 (threads.h)

```cpp
void set_run_wrapper(IRunWrapper *run_wrapper);  // 设置租户上下文
IRunWrapper *get_run_wrapper();                   // 获取租户上下文
```

`IRunWrapper` 接口提供了 `pre_run()`、`end_run()`、`id()` 方法，用于在多租户场景下隔离不同租户的执行上下文。

---

## 5. `ObDynamicThreadPool` — 动态任务线程池

`ob_dynamic_thread_pool.h` 定义了 `ObDynamicThreadPool`，它继承自 `lib::ThreadPool`（即 `Threads`）。

### 设计思路

一个监控线程（`run1()` 中的管理线程）动态管理多个工作线程，工作线程从一个共享的 `ObFixedQueue` 中消费任务。

### 核心数据结构 (ob_dynamic_thread_pool.h)

```cpp
class ObDynamicThreadPool: public lib::ThreadPool {
  static const int64_t MAX_THREAD_NUM = 512;
  static const int64_t MAX_TASK_NUM = 1024 * 1024;

  ObFixedQueue<ObDynamicThreadTask> task_queue_; // 共享任务队列
  ObDynamicThreadInfo thread_infos_[MAX_THREAD_NUM]; // 线程信息数组
  ObThreadCond task_thread_cond_;  // 工作线程等待条件
  ObThreadCond cond_;             // 管理线程等待条件
  volatile bool is_stop_;
  int64_t thread_num_;            // 期望的工作线程数
  int64_t start_thread_num_;      // 已启动数
  int64_t stop_thread_num_;       // 已停止数
  bool need_idle_;
};
```

### 工作流程

1. **管理线程**（`run1()`）循环执行：
   - 调用 `check_thread_status()` 检查当前线程数与期望值是否匹配
   - 不足则启动新线程，超出则停止多余线程
   - 空闲时在 `cond_` 上等待

2. **工作线程**（`task_thread_func()`）循环执行：
   - 从 `task_queue_` pop 任务
   - 如果队列空，在 `task_thread_cond_` 上等待
   - 如果收到停止信号（`is_stop_`），退出循环

3. **任务提交**（`add_task()`）：
   - 入队后 signal 工作线程条件变量，唤醒一个等待的工作线程

### 关键实现细节 (ob_dynamic_thread_pool.cpp)

```cpp
void *ObDynamicThreadPool::task_thread_func(void *data)
{
  ObDynamicThreadInfo *thread_info = reinterpret_cast<ObDynamicThreadInfo *>(data);
  ObDynamicThreadTask *task = NULL;

  while (!thread_info->is_stop_) {
    task = NULL;
    if (OB_SUCCESS != (tmp_ret = thread_info->pool_->pop_task(task))) {
      if (OB_ENTRY_NOT_EXIST == tmp_ret) {
        thread_info->pool_->task_thread_idle();  // 队列空，等待
      } else if (OB_IN_STOP_STATE == tmp_ret) {
        break;
      }
    } else {
      task->process(thread_info->is_stop_);  // 处理任务
    }
  }
}
```

`ObDynamicThreadPool` 的 `stop_all_threads()` 方法在停止时广播条件变量，唤醒所有工作线程使其退出。

---

## 6. `ObSimpleDynamicThreadPool` — 自适应收缩线程池

`ObSimpleDynamicThreadPool` 定义在 `ob_dynamic_thread_pool.h` 中，是支持自适应线程数调整的基类。

### 自适应线程 (ob_dynamic_thread_pool.h)

```cpp
class ObSimpleDynamicThreadPool : public lib::ThreadPool {
  int64_t min_thread_cnt_;    // 最小线程数
  int64_t max_thread_cnt_;    // 最大线程数
  int64_t running_thread_cnt_; // 正在执行任务的工作线程数
  int64_t threads_idle_time_;  // 线程空闲时间累加
  ObMutex update_threads_lock_; // 保护线程数变更
};
```

### `ObSimpleThreadPoolDynamicMgr` (ob_dynamic_thread_pool.cpp)

全局单例管理器，定期检查所有注册的 `ObSimpleDynamicThreadPool`，根据负载决策扩容/缩容：

```cpp
void ObSimpleThreadPoolDynamicMgr::run1()
{
  while (!has_set_stop()) {
    // 遍历所有注册的线程池
    for (int i = 0; i < simple_thread_pool_list_.count(); i++) {
      ObSimpleThreadPoolStat &pool_stat = simple_thread_pool_list_.at(i);
      ObSimpleDynamicThreadPool *pool = pool_stat.pool_;

      // 如果线程空闲时间 > 检查间隔 且 线程数 > 最小线程数 → 缩容
      if (idle > interval && ...) {
        pool->try_inc_thread_count(-1);
      }

      // 检查队列积压 → 扩容
      pool->try_expand_thread_count();
    }
    ob_usleep(CHECK_INTERVAL_US, true);  // 每 200ms 检查一次
  }
}
```

缩容间隔为 `SHRINK_INTERVAL_US = 3s`，检查间隔为 `CHECK_INTERVAL_US = 200ms`（ob_dynamic_thread_pool.h）。

### 扩容策略 (ob_dynamic_thread_pool.cpp)

```cpp
void ObSimpleDynamicThreadPool::try_expand_thread_count()
{
  int64_t queue_size = get_queue_num();
  if (queue_size <= 0) return;

  int inc_cnt = min(queue_size, max_thread_cnt_ - cur_thread_count);
  if (inc_cnt > 0) {
    for (int i = 1; i <= inc_cnt; ++i) {
      ret = set_thread_count_and_try_recycle(cur_thread_count + 1);
    }
  }
}
```

---

## 7. `ObSimpleThreadPool` — 带队列的简单线程池

`ob_simple_thread_pool.h` 定义 `ObSimpleThreadPoolBase<T>`，它继承自 `ObSimpleDynamicThreadPool`，添加了任务队列。

```cpp
// ob_simple_thread_pool.h
using ObSimpleThreadPool = ObSimpleThreadPoolBase<ObLightyQueue>;
```

### 核心数据结构

```cpp
template <class T = ObLightyQueue>
class ObSimpleThreadPoolBase : public ObSimpleDynamicThreadPool {
  T queue_;              // 任务队列（默认 ObLightyQueue）
  int64_t total_thread_num_;   // 总配置线程数
  int64_t active_thread_num_;  // 当前激活线程数
  ObAdaptiveStrategy adaptive_strategy_;  // 自适应策略
  int64_t last_adjust_ts_;
};
```

### 自适应策略 (ob_simple_thread_pool.h)

`ObAdaptiveStrategy` 控制基于运行时间统计的线程数调整：

```cpp
class ObAdaptiveStrategy {
  int64_t least_thread_num_;  // 最少线程数
  int64_t estimate_ts_;       // 评估周期（微秒）
  int64_t expand_rate_;       // 扩容阈值（占比的百分比）
  int64_t shrink_rate_;       // 缩容阈值
};
```

### 自适应调度 (ob_simple_thread_pool.ipp)

`run1()` 中每个线程的工作循环（当 `adaptive_strategy_` 有效时）：

```cpp
// 统计工作 vs 空闲时间比
idle_ts += (wakeup_ts - start_ts);   // 空闲时间
run_ts  += (handle_ts - wakeup_ts);  // 工作时间

if (idle_ts + run_ts > estimate_ts) {
  if (run_ts > expand_ts) {
    // 工作时间占比过高 → 扩容
    new_thread_num = old_thread_num + 2;
  } else if (run_ts < shrink_ts) {
    // 工作时间占比过低 → 缩容
    if (old_thread_num > least_thread_num) {
      new_thread_num = old_thread_num - 1;
    }
  }
}
```

### 任务提交 (ob_simple_thread_pool.ipp)

```cpp
int push(void *task) {
  ret = queue_.push(task);
  try_expand_thread_count();  // 提交时快速检查是否需要扩容
}
```

停止时的清理逻辑：

```cpp
if (has_set_stop()) {
  void *task = NULL;
  while (OB_SUCC(queue_.pop(task))) {
    handle_drop(task);  // 处理遗留任务
  }
}
```

---

## 8. `ObMapQueueThreadPool` — 基于哈希的 MapQueue 线程池

`ob_map_queue_thread_pool.h` 定义了 `ObMapQueueThreadPool`，它为每个线程分配独立的队列，通过哈希将任务分配到指定线程。

### 设计目标

避免多线程竞争同一个共享队列，通过 hash 将任务固定到某个线程，提高缓存友好性和效率。

### 核心数据结构 (ob_map_queue_thread_pool.h)

```cpp
struct ThreadConf {
  HostType *host_;
  int64_t thread_index_;
  QueueType queue_;     // 每个线程独立的 ObMapQueue
  ObCond cond_;         // 条件变量，用于等待/通知
};

class ObMapQueueThreadPool : public lib::ThreadPool {
  static const int64_t MAX_THREAD_NUM = 64;
  ThreadConf tc_[MAX_THREAD_NUM];  // 每个线程拥有独立的配置
  const char *name_;
};
```

### Task 分发 (ob_map_queue_thread_pool.cpp)

```cpp
int ObMapQueueThreadPool::push(void *data, const uint64_t hash_val)
{
  const int64_t target_index = static_cast<int64_t>(hash_val % get_thread_count());
  ThreadConf &tc = tc_[target_index];

  tc.queue_.push(data);  // 非阻塞 push
  tc.cond_.signal();     // 通知目标线程
}
```

### `ObMapQueue` — 无锁队列 (ob_map_queue.h)

`ObMapQueue<T>` 使用 `ObLinearHashMap` 实现了一个无锁队列，通过原子 CAS 操作实现非阻塞的 push/pop：

```cpp
template <typename T>
class ObMapQueue {
  int push(const T &val) {
    int64_t sn = ATOMIC_AFADD(&dummy_tail_, 1);  // 原子获取序列号
    map_.insert(key, val);                         // 写入 hash map
    while (!ATOMIC_BCAS(&tail_, sn, sn + 1)) {}  // 等待，直到 tail 追上
  }

  int pop(T &val) {
    while (head < tail) {
      if (ATOMIC_BCAS(&head_, sn, sn + 1)) {  // CAS 竞争 pop
        map_.erase_if(key, cond);               // 从 hash map 移除
      }
    }
  }
};
```

### 线程工作循环 (ob_map_queue_thread_pool.cpp)

```cpp
void ObMapQueueThreadPool::run1()
{
  while (!has_set_stop()) {
    void *task = NULL;
    if (OB_FAIL(next_task_(thread_index, task))) {
      break;
    }
    handle(task, has_set_stop());
  }
}

int next_task_(int64_t index, void *&task) {
  while (!has_set_stop()) {
    if (OB_FAIL(tc.queue_.pop(task))) {
      if (OB_EAGAIN == ret) {
        tc.cond_.timedwait(DATA_OP_TIMEOUT);  // 超时 1s
        continue;
      }
    } else {
      break;
    }
  }
}
```

---

## 9. `ObReentrantThread` — 可重入线程

`ob_reentrant_thread.h` 定义了 `ObReentrantThread`，它提供了一种特殊的线程执行模式：线程创建后不会立刻执行任务，而是等待显式的 `logical_start()` 信号。

### 设计思路

适用于需要精细控制线程执行时机的场景，如异步任务队列。线程在 `stop_` 为 true 时在条件变量上等待，收到信号后执行 `run2()`，执行完再回去等待。

### 核心接口 (ob_reentrant_thread.h)

```cpp
class ObReentrantThread : public lib::ThreadPool {
  int create(int64_t thread_cnt, const char* thread_name = nullptr);
  int start() override;          // 首次启动线程
  void stop() override;          // 停止线程

  int logical_start();           // 发送执行信号，唤醒线程执行 run2()
  void logical_stop();           // 停止执行
  void logical_wait();           // 等待正在执行的任务完成

  virtual int blocking_run() = 0; // 子类需实现阻塞循环

protected:
  volatile bool stop_;           // 控制逻辑运行状态
  int64_t running_cnt_;          // 正在执行的任务数
  ObThreadCond cond_;            // 条件变量
};
```

### 核心实现 (ob_reentrant_thread.cpp)

```cpp
int ObReentrantThread::blocking_run()
{
  while (OB_SUCC(ret)) {
    bool need_run = false;
    {
      ObThreadCondGuard guard(cond_);
      if (stop_) {
        if (ThreadPool::has_set_stop()) break;  // 永久退出
        cond_.wait(3000);  // 等待 logical_start() 信号
      } else {
        need_run = true;
        running_cnt_++;  // 任务计数
      }
    }
    if (need_run) {
      run2();               // 执行用户逻辑
      running_cnt_--;
      cond_.broadcast();    // 通知 logical_wait()
    }
  }
}
```

`logical_start()` 和 `logical_stop()` 通过修改 `stop_` 和 broadcast 来控制线程的运行状态，使线程可以重复启停。

### BLOCKING_RUN_IMPLEMENT 宏 (ob_reentrant_thread.h)

```cpp
#define BLOCKING_RUN_IMPLEMENT() \
  nothing(); return ObReentrantThread::blocking_run();
```

子类只需调用此宏即可实现 `blocking_run()`。

---

## 10. `ObAsyncTaskQueue` — 异步任务队列

`ob_async_task_queue.h` 定义了 `ObAsyncTaskQueue`，它继承自 `ObReentrantThread`，将异步任务管理接入可重入线程框架。

### 核心数据结构 (ob_async_task_queue.h)

```cpp
class ObAsyncTaskQueue : public ObReentrantThread {
  ObLightyQueue queue_;                    // 任务队列
  ObConcurrentFIFOAllocator allocator_;    // 任务内存分配器
};
```

### 任务接口

```cpp
class ObAsyncTask {
  virtual int process() = 0;            // 处理任务
  virtual int64_t get_deep_copy_size() const = 0;  // 深拷贝大小
  virtual ObAsyncTask *deep_copy(char *buf, int64_t buf_size) const = 0;

  // 重试机制
  int64_t retry_interval_;  // 重试间隔（默认 1s）
  int64_t retry_times_;     // 重试次数（默认无限）
};
```

### 工作流程 (ob_async_task_queue.h)

- `push()` 将任务深拷贝后入队
- `run2()` 周期性 pop 任务并调用 `process()`
- 任务失败后根据 `retry_times_` 和 `retry_interval_` 决定是否重试

---

## 11. `ObWorkQueue` — Timer + 任务队列

`ob_work_queue.h` 定义了 `ObWorkQueue`，它组合了 `ObTimer` 和 `ObAsyncTaskQueue`，提供定时 + 异步任务的能力。

### 核心设计 (ob_work_queue.h)

```cpp
class ObWorkQueue {
  ObTimer timer_;                    // 定时器
  ObAsyncTaskQueue task_queue_;      // 异步任务队列
};
```

### `ObAsyncTimerTask` (ob_work_queue.h)

结合了 `ObTimerTask` 和 `ObAsyncTask`：

```cpp
class ObAsyncTimerTask : public ObAsyncTask, public ObTimerTask {
  virtual void runTimerTask() override {
    work_queue_.add_async_task(*this);  // 定时器触发后，将任务提交到异步队列
  }
  virtual int process() = 0;  // 异步执行的真正逻辑
};
```

### 生命周期管理 (ob_work_queue.cpp)

```cpp
int ObWorkQueue::start() {
  task_queue_.start();   // 先启动任务队列
  timer_.start();        // 再启动定时器
}

int ObWorkQueue::stop() {
  timer_.cancel_all();   // 先取消所有定时器
  timer_.stop();
  task_queue_.stop();
}
```

---

## 12. `TGMgr` — 线程组管理器

`thread_mgr.h` 定义了完整的线程组管理系统，这是 OceanBase 线程架构的顶层调度中枢。

### `ITG` — 线程组接口 (thread_mgr.h)

```cpp
class ITG {
  virtual int thread_cnt() = 0;
  virtual int set_thread_cnt(int64_t) = 0;
  virtual int start() = 0;
  virtual void stop() = 0;
  virtual void wait() = 0;

  virtual int set_runnable(TGRunnable &runnable);
  virtual int set_handler(TGTaskHandler &handler);
  virtual int push_task(void *task);
  virtual int push_task(void *task, const uint64_t hash_val);
};
```

### 线程组类型枚举 (thread_mgr.h)

```cpp
enum class TGType {
  INVALID,
  REENTRANT_THREAD_POOL,
  THREAD_POOL,
  TIMER,
  QUEUE_THREAD,
  DEDUP_QUEUE,
  ASYNC_TASK_QUEUE,
  MAP_QUEUE_THREAD
};
```

### `TGMgr` — 全局管理器 (thread_mgr.h)

```cpp
class TGMgr {
  static constexpr int MAX_ID = 122880;  // 最大 TG ID
  ITG *tgs_[MAX_ID];                     // 所有线程组

  int create_tg(int tg_def_id, int &tg_id);
  int create_tg_tenant(int tg_def_id, int &tg_id, int64_t qsize = 0);
  void destroy_tg(int tg_id, bool is_exist = false);
};
```

### 线程定义表 — thread_define.h

```cpp
TG_DEF(MEMORY_DUMP, memDump, THREAD_POOL, 1)
TG_DEF(SchemaRefTask, SchemaRefTask, DEDUP_QUEUE, 1, 1024, 1024, ...)
TG_DEF(SYSLOG_COMPRESS, SyslogCompress, THREAD_POOL, 1)
```

### TG 宏 (thread_mgr.h)

使用宏来简化线程组操作：

```cpp
#define TG_CREATE(tg_def_id, tg_id) TG_MGR.create_tg(tg_def_id, tg_id)
#define TG_START(tg_id)             TG_INVOKE(tg_id, start)
#define TG_SET_RUNNABLE_AND_START(tg_id, args...)  // 设置 + 启动
#define TG_SET_HANDLER_AND_START(tg_id, args...)   // 设置处理函数 + 启动
#define TG_PUSH_TASK(tg_id, args...) TG_INVOKE(tg_id, push_task, args)
```

### 具体 TG 实现

每种 TGType 对应一个 ITG 子类：

| 类 | 用途 | 封装的方式 |
|----|------|-----------|
| `TG_REENTRANT_THREAD_POOL` | 可重入线程池 | `MyReentrantThread` |
| `TG_THREAD_POOL` | 普通线程池 | `MyThreadPool` |
| `TG_QUEUE_THREAD` | 队列线程 | `MySimpleThreadPool` + `run1()` / `handle()` |
| `TG_MAP_QUEUE_THREAD` | MapQueue 线程 | `MyMapQueueThreadPool` + `handle()` |
| `TG_DEDUP_QUEUE` | 去重队列 | `ObDedupQueue` |
| `TG_TIMER` | 定时器 | `ObTimer` |
| `TG_ASYNC_TASK_QUEUE` | 异步任务队列 | `ObAsyncTaskQueue` |

### `TGRunnable` 和 `TGTaskHandler` (thread_mgr_interface.h)

```cpp
class TGRunnable {
  virtual void run1() = 0;
  bool has_set_stop() const;
  void set_stop(bool stop);
  uint64_t get_thread_idx() const;
};

class TGTaskHandler {
  virtual void handle(void *task) = 0;
  virtual void handle(void *task, volatile bool &is_stoped);
  virtual void handle_drop(void *task);
  uint64_t get_thread_idx() const;
};
```

---

## 13. 总结

OceanBase 的线程模型呈现**分层、可组合**的特点：

1. **底层**：`Thread` 封装 pthread，提供诊断、等待追踪等机制
2. **线程池基类**：`Threads` 管理线程数组，支持动态扩缩容、NUMA 感知、租户隔离
3. **高级线程池**：多种变体满足不同需求——动态线程池管理工作者线程、MapQueue 实现无锁分区队列、SimpleThreadPool 结合队列和自适应调度
4. **可重入线程**：`ObReentrantThread` 提供逻辑启停能力，线程可重复运行
5. **异步任务系统**：`ObAsyncTaskQueue` + `ObWorkQueue` 提供 Timer 和异步任务集成
6. **全局管理**：`TGMgr` 统一管理所有线程组的生命周期，定义表 + 宏的 DSL 风格简化了使用

这种设计在性能、灵活性和隔离性之间取得了平衡，既支持高吞吐的并行任务处理，又提供了精细的租户隔离和资源控制能力。
