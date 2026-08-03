# #6 v2 — Aura Fiber System (concurrency + GC hooks + mutation safety)

> 接续 #1 v2 Agent Orchestration + #4 v2 Runtime + #5 v2 Compiler：前面讲了
> aura 的运行时抽象、Runtime、Compiler。本文聚焦 **Fiber System** ——stackful
> fiber + M:N scheduler + MultiFiberMailbox + parallel_orch + MutationBoundary
> + GC hooks。这是 aura 并发 / 异步 / mutation-safety 的底座。

---

## 0. 全文导读

Aura Fiber 五层:

```
Thread (pthread)
  ↓ 1:N
Worker (M:N)
  ↓ 1:N
Fiber (stackful coroutine, ~8KB stack)
  ↓
Fiber::yield / Fiber::resume (cooperative scheduling)
  ↓
MultiFiberMailbox (BP gate / decay / priority)
  ↓
parallel_orch (parallel_intend / parallel_run / FailurePolicy)
  ↓
MutationBoundaryGuard + GC hooks (mutation safety)
```

本文按"架构 → Fiber → Scheduler → Mailbox → parallel_orch → Mutation Safety
→ GC hooks → 调优"展开。

---

## 1. Fiber System 整体架构

### 1.1 三层并行模型

```
Thread (OS) ─ 1 : N ─→ Worker (POSIX thread)
Worker ─ 1 : N ─→ Fiber (cooperative coroutine, stackful)
Fiber ─ communicate via ─→ MultiFiberMailbox
```

**关键 insight**: aura 用 **M:N 调度**（M fibers on N threads）。类似 Go runtime
的 goroutine 模型，但底层是 **stackful coroutine**（ucontext 实现）而不是
goroutine 的 split-stack。

### 1.2 文件结构

```
src/serve/
├── fiber.h / fiber.cpp           # Fiber 类
├── scheduler.h / scheduler.cpp   # M:N Scheduler
├── worker.h / worker.cpp         # Worker (pthread + 多个 fiber)
├── thread_pool.h / thread_pool.cpp
├── mailbox.h                      # 单 fiber mailbox
├── multi_fiber_mailbox.h / .ixx   # 多 fiber mailbox (Issue #1585/#1211)
├── parallel_orch.h / .ixx         # 并行任务编排 (Issue #1586/#1202)
├── gc_coordinator.h / .cpp         # GC 协调
├── serve_async.h / .cpp           # async serve 集成
├── http_health.h / .cpp           # HTTP health endpoint
└── aura_platform.h                # 平台抽象

src/core/
├── gc_hooks.h                     # GC 回调
├── mutation.ixx                   # MutationBoundary
└── resource_quota.hh              # 资源配额
```

### 1.3 关键依赖

```cpp
// src/serve/multi_fiber_mailbox.h 头 30 行(关键 Issue 列表)
//
// multi_fiber_mailbox.h — Issue #1585 / #1211 / #1595 / #2312 / #2316:
// MultiFiberMailbox with
// multi-attach, broadcast, blocking recv, priority, and backpressure.
// #1595: linear-claim payload prefix filter (linear-viol:) + process counters.
// #1881: fanout linear_checks + local push stats.
// #2010: shared linear filter on all entry points; fanout backpressure
//        observability (+ orch hook for dashboards).
// #2188: forbid blocking recv / Fiber::yield while MutationBoundary is live
//        (depth>0 or held) — Policy A: non-blocking empty + metric, no park.
// #2347: Guard-live blocking recv → hard audit under Strict/production.
//        Agent contract: **Guard 内禁止 blocking recv**; use try_recv /
//        recv(wait=false) or exit MutationBoundary first. Policy A stays
//        non-blocking; Strict bumps hard counter and may force-rollback
//        after N rejects in one outermost Guard window.
// #2312: push/fanout defer (Backpressure) when target holds MutationBoundary.
// #2378: defer drain SLA — deferred_depth / HWM, flush latency after
//        outermost Guard exit, starvation signal if depth stays open.
//        Zero cost when deferred_depth==0 (single relaxed load on Ok path).
// #2511: outermost Guard exit forces deferred drain under budget
//        (AURA_MAILBOX_HOLD_DRAIN_BUDGET_US, default 1000 µs). Soft: retain
//        + starvation. Strict: force-resolve remaining depth + audit.
//        AC5: depth==0 → single relaxed load.
// #2316: wire mu_ acquire to lock_order::on_acquire(Level::Mailbox) for
//        rank-table audit + AURA_LOCK_ORDER_CANARY inversion detection.
```

每行 = 一个 Issue + 一段设计决策。这是 aura 的 "code as documentation"
风格。

### 1.4 近期 fiber 相关 commit（20+ 条）

```
80c388d1 ci(chaos): promote multi-fiber hard-fail counters into ./build.py gate (#2554)
e0f024a5 feat(typecheck/fiber): steal/densify joint OccurrenceGoal + type_dep freshness (#2552)
32ed8fc4 feat(fiber): demote is_stealable to candidate; snapshot is sole steal gate (#2549)
178652b5 feat(fiber/steal): hard-AND residual GcDeferReason == 0 on steal-complete (#2546)
d6e05138 feat(security): Restricted hard-fiber optional policy contract (#2536)
a67e4ed7 feat(security/fiber): mandate TenantScope at fiber spawn/resume entry (#2491)
c3659599 feat(fiber): Soft orch-agent boundary 提升为轻量 Guard 子集，统一 depth/held 语义 (#2515)
87cabdcf feat(fiber): reclaim non-yielding body without permanent ownership leak (#2498)
351c9eee feat(fiber): MutationSafetySnapshot sequence ticket for sample→resume (#2518)
0060c829 feat(obs): live max outermost MutationBoundary hold probe (#2517)
17268636 fix(ubsan): capture Fiber* once in MutationBoundaryGuard mirrors
3df7e3cb feat(pcv): production default-on TLS freelist for exclusive short-lived allocs (#2521)
```

fiber + mutation safety 是 **aura 最高频迭代区域**（每个 PR 都涉及）。

---

## 2. Fiber (stackful coroutine)

### 2.1 Fiber 类

```cpp
// src/serve/fiber.h
#include <ucontext.h>  // glibc makecontext/swapcontext

class Fiber {
public:
    using Fn = std::function<void()>;

    Fiber(Fn fn, size_t stack_size = 8 * 1024);
    ~Fiber();

    // 协作式让出
    static void yield();

    // 调度器从 yield 点恢复
    void resume();

    // 标识
    std::uint64_t id() const { return id_; }

    // 当前 fiber (TLS)
    static Fiber* current();

private:
    ucontext_t ctx_;          // ucontext 上下文
    char* stack_;             // 8 KB stack
    size_t stack_size_;
    Fn fn_;
    std::uint64_t id_;
};
```

### 2.2 ucontext 实现

```cpp
// fiber.cpp
Fiber::Fiber(Fn fn, size_t stack_size)
    : fn_(std::move(fn)), stack_size_(stack_size) {
    stack_ = new char[stack_size];
    getcontext(&ctx_);
    ctx_.uc_stack.ss_sp = stack_;
    ctx_.uc_stack.ss_size = stack_size;
    ctx_.uc_link = &parent_ctx_;  // fiber 退出后回到 parent
    makecontext(&ctx_, fiber_trampoline, 0);
}

void Fiber::resume() {
    Fiber* prev = current_fiber;
    current_fiber = this;
    swapcontext(&prev->ctx_, &ctx_);
}

void Fiber::yield() {
    swapcontext(&current_fiber->ctx_, &scheduler_ctx_);
}
```

**关键 insight**: `ucontext_t` 是 POSIX 的协作式 coroutine 原语。比线程
快（~1μs vs ~10μs），但同一时刻一个 fiber 占用一个 worker（协作式调度）。

### 2.3 TLS (Thread-Local Storage)

```cpp
// fiber.h 头
extern "C" std::uint64_t aura_fiber_current_id();

// Implementation: thread-local Fiber* current_fiber;
thread_local Fiber* current_fiber = nullptr;

std::uint64_t Fiber::id() const { return id_; }
std::uint64_t aura_fiber_current_id() {
    return current_fiber ? current_fiber->id_ : 0;
}
```

**关键 insight**: `current_fiber` 是 **per-thread**（不是 per-fiber）。同一
worker 上的所有 fiber 共享一个 thread → 共享 TLS。这是 "Fiber 不是 OS 线
程" 的标志。

### 2.4 TenantScope Hooks (#2491)

```cpp
// fiber.h 头
// Issue #2491: TenantScope install / release hooks at fiber resume /
// yield boundary. Strong definitions live in evaluator_fiber_mutation.cpp;
// weak no-op stubs in fiber_bridge.cpp keep non-evaluator link units
// (test_concurrent / test_issue_*) resolving without dragging the full
// module into their link unit.

extern "C" void aura_fiber_resume_hook(Fiber* f);
extern "C" void aura_fiber_yield_hook(Fiber* f);

// Hook fired on every resume/yield
// Strong impl: install/release TenantScope for current fiber
// Weak stub: no-op (for non-evaluator link units)
```

**关键 insight**: `TenantScope` 是 **multitenancy 隔离边界**。每个 fiber
resume 时装上 scope，yield 时卸下。这是 "fiber = tenant actor" 的实现。

---

## 3. Scheduler (M:N)

### 3.1 Scheduler 架构

```cpp
// src/serve/scheduler.h
namespace aura::serve {

class Scheduler {
public:
    // 启动 N 个 Worker + 1 个 IO 线程
    void start(size_t num_workers);
    // 停止
    void shutdown();

    // 调度 fiber (run-to-completion + work-stealing)
    void spawn(Fiber::Fn fn);

private:
    std::vector<std::unique_ptr<Worker>> workers_;
    std::unique_ptr<IOThread> io_thread_;
    // 全局 run queue (待 steal)
    std::deque<Fiber*> global_queue_;
    // Fiber ID → fiber (用于 join)
    std::unordered_map<uint64_t, Fiber*> fiber_map_;
};

}  // namespace aura::serve
```

### 3.2 Worker

```cpp
// worker.cpp
class Worker {
public:
    void run() {
        while (running_) {
            // 1. 从 local queue 取 fiber
            Fiber* f = local_queue_.pop();
            if (!f) {
                // 2. work-steal: 从其他 worker 偷
                f = steal_from_other_worker();
            }
            if (!f) {
                // 3. 全局 queue
                f = scheduler_->global_queue_.pop();
            }
            if (!f) {
                // 4. idle → sleep until eventfd signaled
                idle_wait();
                continue;
            }
            // 5. 跑 fiber (until yield / completion)
            f->resume();
            // 6. fiber done?
            if (f->is_done()) {
                scheduler_->on_fiber_done(f);
            }
        }
    }
};
```

### 3.3 IO Thread

```cpp
// IOThread
class IOThread {
public:
    void run() {
        // 主线程专用:处理 epoll/stdin/timer
        while (running_) {
            // epoll_wait on eventfd (跨线程通知)
            int n = epoll_wait(epfd_, events_, max_events_, timeout_ms_);
            for (int i = 0; i < n; ++i) {
                // 处理事件:kick fiber to wake up
                kick_fiber(events_[i].data.fiber);
            }
        }
    }
};
```

### 3.4 Steal/Densify（近期高频改进）

```
Issue #2549: demote is_stealable to candidate; snapshot is sole steal gate
Issue #2546: hard-AND residual GcDeferReason == 0 on steal-complete
Issue #2552: steal/densify joint OccurrenceGoal + type_dep freshness

新设计:
  - "可 steal" 从 boolean (is_stealable) 改为 candidate score
  - snapshot 是唯一 steal gate (snapshot 决定 fiber 当前状态)
  - steal-complete 需要 residual GcDeferReason == 0 (GC 不 defer)
  - steal + densify 联合 OccurrenceGoal + type_dep freshness

aura 的 fiber steal 不是简单的 work-stealing (像 Go runtime),
而是 **type-dep-aware** + **gc-aware** 的复杂决策。
```

---

## 4. MultiFiberMailbox

### 4.1 整体设计

```cpp
// src/serve/multi_fiber_mailbox.h
class MultiFiberMailbox {
public:
    // 推入 payload (BP gate: high_water + linear filter)
    void push(int64_t payload);
    // 非阻塞取
    std::optional<int64_t> try_recv();
    // 阻塞取
    int64_t recv(std::chrono::milliseconds timeout);
    // 广播
    void broadcast_fanout(int64_t payload);
    // 多 attach
    void attach(std::uint64_t fiber_id);
    void detach(std::uint64_t fiber_id);

private:
    std::deque<int64_t> queue_;
    std::uint64_t high_water_;      // BP threshold
    std::uint64_t mailbox_bp_recent_total_;  // BP 计数
    std::chrono::seconds decay_window_;     // 衰减窗口
    std::mutex mu_;                 // lock_order Level::Mailbox
};
```

### 4.2 Backpressure Gate

```cpp
// Issue #2228: backpressure admission gate
void MultiFiberMailbox::push(int64_t payload) {
    // 1. linear-violation 过滤
    if (linear_check_violates(payload)) {
        // 1.1 记录 metric,drop
        g_orch_module_stats.linear_violation_total.fetch_add(1);
        return;
    }
    // 2. 高水位检查
    std::lock_guard<std::mutex> lock(mu_);  // lock_order audit
    if (queue_.size() >= high_water_) {
        mailbox_bp_recent_total_.fetch_add(1);  // BP 计数
        // 2.1 MutationBoundary 持有?defer (Issue #2312)
        if (aura_evaluator_mutation_boundary_held()) {
            // 2.1.1 进入 defer queue (Issue #2378)
            defer_queue_.push(payload);
            return;
        }
        // 2.2 否则:阻塞发送方 (issue #2511)
        throw MailboxBackpressure{};
    }
    queue_.push(payload);
}
```

### 4.3 Decay Window（#2465）

```cpp
// 周期衰减 mailbox_bp_recent_total_,避免历史累积导致永久拒绝
class BPDecayTimer {
public:
    void tick() {
        auto now = now_us();
        if (now - last_tick_ >= decay_window_) {
            // 衰减到 decay_factor * 当前
            uint64_t cur = bpr_total_.load();
            uint64_t decayed = cur * decay_factor_;  // e.g. 0.5
            bpr_total_.store(decayed);
            last_tick_ = now;
        }
    }
};
```

### 4.4 强反压 + 软反压（#2511）

```
AURA_MAILBOX_HOLD_DRAIN_BUDGET_US = 1000 µs (默认)

当 Mailbox 持有期间 (receiver 在 recv()) + push 触发 BP:
  - Soft policy:  defer (进 defer queue, 不阻塞 sender)
  - Strict policy: 立即 reject (audit, 可能 force-rollback)

receiver 退出 recv() 时:
  - 优先 drain defer queue (在 1000 µs budget 内)
  - 超 budget: starvation signal
```

### 4.5 Linear Filter (#1595, #2010)

```cpp
// payload prefix 包含 linear violation tag
struct LinearFilter {
    // push / fanout 都过 linear check
    bool check(int64_t payload) {
        // 提取 payload 前缀的 linear info
        auto info = decode_linear_info(payload);
        // 检查 linear 合约
        if (info.has_violation) {
            linear_violation_total_.fetch_add(1);
            return false;  // reject
        }
        return true;
    }
};
```

**关键 insight**: Linear 类型系统需要 **runtime check**。Mailbox 是 linear
值传递的关键路径 → linear check 在 push/fanout 处。

---

## 5. parallel_orch (parallel_intend / parallel_run)

### 5.1 parallel_intend (Issue #1586/#1202)

```cpp
// src/serve/parallel_orch.h
class ParallelOrch {
public:
    // Issue #1587: composable FailurePolicy
    enum FailurePolicy {
        FAIL_FAST,           // 任何失败立即 abort
        COLLECT_ALL,         // 收集所有结果(忽略失败)
        RETRY_N,             // 重试 N 次
        CIRCUIT_BREAKER,     // 故障率阈值后熔断
    };

    // Issue #1584: Fiber::join
    // Issue #1595: linear enforcement
    // Issue #2007: composable policy
    template <typename Fn>
    ParallelResult parallel_intend(
        std::span<Fn> tasks,
        FailurePolicy policy,
        std::optional<int> max_concurrency = std::nullopt,
        std::optional<std::chrono::ms> timeout = std::nullopt);
};
```

### 5.2 流程

```
1. tasks[] 拆分到 N 个 worker (max_concurrency)
2. 每个 task 用 Fiber 包装
3. 每个 fiber push 到 worker 的 local queue
4. worker 并发跑
5. FailurePolicy 控制失败处理
6. join 所有 fiber (Issue #1584 Fiber::join)
7. 聚合结果返回

join Ok 后:
  - bump linear enforcement counters (#1595)
  - 触发 host refresh via complete_post_join_linear_enforcement
```

### 5.3 FailurePolicy 组合

```cpp
// RetryN(FailFast(CircuitBreaker(tasks)))
//  → 内层先试 CircuitBreaker
//  → 重试 N 次 CircuitBreaker
//  → 任意一次失败立即 FailFast
```

**关键 insight**: composable FailurePolicy 让 caller 灵活组合错误处理策略
——和 Haskell 的 ExceptT monad transformer 类似。

### 5.4 性能

```
parallel_intend 100 个 task (max_concurrency=8):
  - 默认 sequential (~100x task latency)
  - :pure #f + eval_mu 串行 (~100x task latency + eval_mu overhead)
  - :pure #t + unlocked (~12.5x speedup,8x 并发)

Memory: ~8 KB/fiber × N fibers
```

---

## 6. Mutation Safety

### 6.1 MutationBoundary 概念

```cpp
// src/core/mutation.ixx
class MutationBoundaryGuard {
public:
    MutationBoundaryGuard();   // 进入边界:depth++
    ~MutationBoundaryGuard();  // 离开边界:depth--, audit linear types

    static std::size_t depth();        // 当前 depth
    static bool held();                // 是否持有
};
```

### 6.2 Guard 内禁止的事

```
Issue #2188: forbid blocking recv / Fiber::yield while MutationBoundary is live
  - recv() in Guard → 强制 try_recv() (non-blocking)
  - yield() in Guard → 立即 panic / strict audit
  - Policy A: non-blocking empty + metric, no park
  - Strict: hard audit, force-rollback after N rejects

Issue #2347: Agent contract — Guard 内禁止 blocking recv
```

**关键 insight**: Guard 内禁止 park/yield/recv,避免 linear type 状态在
"持有但不活动"时泄漏。如果 fiber 在 Guard 内 park,Guard 不释放,其他
fiber 无法进入 → 死锁。

### 6.3 TLS null-check (#51a7035f)

```cpp
// Issue #51a7035f: co-locate TLS null-check for mutation-safety publish
// 之前: TLS check 在多处重复, 可能 null-deref
// 现在: 集中到一个 helper

extern "C" std::size_t aura_evaluator_mutation_boundary_depth() {
    // 强定义 in evaluator_fiber_mutation.cpp
    // 弱 stub: return 0
}
```

### 6.4 MutationSafetySnapshot (#2518)

```cpp
// Issue #2518: MutationSafetySnapshot sequence ticket for sample→resume
class MutationSafetySnapshot {
public:
    // 在 Guard 内"采样" (capture current fiber state)
    static Snapshot sample();
    // resume 时 check snapshot 是否仍然有效
    static bool is_valid(Snapshot s);
};
```

### 6.5 Soft / Hard policy (#2515, #2536)

```
Soft policy:
  - Guard 内 park/yield: 警告 + metric
  - 适合开发 / 测试
  - 不强制

Hard policy (Strict):
  - Guard 内 park/yield: panic / force-rollback
  - 适合 production
  - 强制 (Issue #2347)
```

### 6.6 实时 Hold Probe (#2517)

```cpp
// Issue #0060c829: live max outermost MutationBoundary hold probe
// Metrics:
extern "C" std::size_t aura_max_outermost_hold_us();
```

监控 "Guard 持有最长多久" —— 用于 production SLA 监控。

---

## 7. GC Integration (fiber-aware)

### 7.1 GC Hooks

```cpp
// src/core/gc_hooks.h
class GcHooks {
public:
    // fiber 创建时
    static void on_fiber_created(Fiber* f);
    // fiber yield 时 (可能 GC)
    static void on_fiber_yield(Fiber* f);
    // fiber resume 时 (GC complete?)
    static void on_fiber_resume(Fiber* f);
    // fiber 完成时
    static void on_fiber_done(Fiber* f);
};
```

### 7.2 GC Coordinator

```cpp
// src/serve/gc_coordinator.h
class GCCoordinator {
public:
    // 调度 GC
    void schedule_gc();
    // 阻塞直到所有 fiber 在 safe point
    void wait_for_safe_points();
    // GC pass
    void gc_pass();
};
```

### 7.3 TL Arena (#1359 fix)

```cpp
// src/compiler/runtime_shared.h
struct TLarena {
    uint8_t* base = nullptr;
    size_t offset = 0;
    size_t capacity = 0;  // 0 = resolve to kDefaultCapacity on first init/alloc
};

// Issue #1359: 之前 64MB eager malloc per thread → 100 fibers = 6.4GB!
// 现在: initial 1MB (or AURA_TL_ARENA_INITIAL_MB), growth doubles
```

**关键 insight**: Fiber 多 → thread 多 → per-thread arena 多 → 内存爆炸。
**初始 1MB + 动态增长** 解决。

### 7.4 TLS freelist (#2521)

```cpp
// Issue #3df7e3cb: production default-on TLS freelist for exclusive short-lived allocs
// 单 fiber 频繁 alloc/free 小对象 → 走 freelist (避免每次 malloc)
thread_local std::vector<void*> tls_freelist_;
```

---

## 8. Agent ↔ Fiber Integration (接 #1)

### 8.1 spawn_agent_with_mailbox 用 Fiber

```
spawn_agent_with_mailbox(spec):
  1. ResourceQuota preflight (#1880)
  2. 创建 mailbox (MultiFiberMailbox)
  3. scheduler.spawn(fiber_lambda(spec.thunk, mailbox))
  4. 注册 name table
  5. 返回 AgentHandle (move-only RAII)
```

### 6.2 Agent poll → Fiber yield

```cpp
// orch:agent-poll (Issue #2540 coop yield edge)
// 强制 Fiber::yield when max_no_yield_ms elapsed
void coop_yield() {
    auto last = fiber_last_yield_us();
    if (now_us() - last > max_no_yield_ms_) {
        Fiber::yield();  // 让其他 fiber 跑
    }
}
```

### 8.3 mailbox_backpressure_recent_total

```cpp
// 接 #1 v2 Agent Orchestration
// orch spawn 用 mailbox_bp_recent_total 做 admission gate
g_orch_module_stats.mailbox_bp_recent_total.fetch_add(1, std::memory_order_relaxed);
// 在 push / broadcast_fanout BP 路径 bump
```

---

## 9. 调优 Checklist

```
□ Fiber 数?
  - 默认 max_concurrency = N worker × 4
  - 监控 fiber 创建/销毁率
  - 单 worker > 10K fiber → scheduler 抖动

□ Mailbox BP?
  - high_water 调优 (默认 64)
  - decay_window 调优 (默认 60s)
  - 监控 defer_depth + starvation_signal

□ MutationBoundary?
  - 避免长事务 (Guard 持有 > 1s 是危险信号)
  - 监控 max_outermost_hold_us
  - Soft vs Hard policy 选择

□ Work-Steal 负载?
  - 监控每个 worker 的 local_queue size
  - steal 频繁 = 负载不均 (考虑 task 划分)

□ GC 内存?
  - TLarena 初始大小
  - 监控 fiber 创建/销毁 + arena 重置频率

□ Mutation Safety?
  - guard 内禁止 park/yield (linter check)
  - linear violation metric 持续 > 0 → 调代码

□ Performance?
  - fiber 创建/上下文切换 < 1µs
  - mailbox push 阻塞 < 5µs
  - parallel_intend vs sequential speedup
```

---

## 10. v2 subseries 收官回顾（aura v2 #6）

接续 #1-5 v2,本文聚焦 Fiber System。

```
aura v2 deep-dive 系列 (本篇为 #6):

#1 v2  Agent Orchestration (orch.ixx + agent_spawn.h + AgentScope) ✅
#2 v2  Build System (build.py + 9 gates + CMake + Sanitizer + PGO)  ✅
#3 v2  Parser (S-expression + Racket 兼容 + ABF)  ✅
#4 v2  Runtime (runtime.c + Pointer Tagging + AOT/JIT bridge + ABI)  ✅
#5 v2  Compiler (C++26 modules + AOT/JIT + Evaluator 8-TU P0 split)  ✅
#6 v2  Fiber System (concurrency + GC hooks + mutation safety)  ← 本文
#7 v2  Type System (type_dep freshness + denseness + linear types)
#8 v2  Module System (multi-define + require + free-vars)
#9 v2  JIT / AOT (aura_jit + hot-update + aot_mangle)
#10 v2 Self-Modification (代码自己进化的核心机制)
```

---

## 11. 下一篇预告

按 aura 主题自然顺序:

- **#7 v2 Type System** — type_dep freshness + denseness + linear types(接 #5 Compiler + #6 Fiber)
- **#8 v2 Module System** — multi-define + require + free-vars(接 #3 Parser + #5 Compiler)
- **#9 v2 JIT / AOT** — aura_jit + hot-update + aot_mangle(接 #4 Runtime + #5 Compiler)

下一篇选哪个?

---

## 12. 参考(可执行的源码锚点)

- `~/code/aura/src/serve/fiber.h` — Fiber 类(ucontext + TLS + TenantScope hooks)
- `~/code/aura/src/serve/fiber.cpp` — Fiber 实现
- `~/code/aura/src/serve/scheduler.h` — M:N Scheduler
- `~/code/aura/src/serve/scheduler.cpp`
- `~/code/aura/src/serve/worker.h` — Worker(pthread + fiber queue)
- `~/code/aura/src/serve/worker.cpp`
- `~/code/aura/src/serve/thread_pool.h`
- `~/code/aura/src/serve/multi_fiber_mailbox.h` — 多 fiber mailbox(Issue #2188/#2312/#2511)
- `~/code/aura/src/serve/multi_fiber_mailbox.ixx`
- `~/code/aura/src/serve/parallel_orch.h` — parallel_intend(Issue #1586/#1202)
- `~/code/aura/src/serve/parallel_orch.ixx`
- `~/code/aura/src/serve/gc_coordinator.h` — GC 协调
- `~/code/aura/src/serve/gc_coordinator.cpp`
- `~/code/aura/src/serve/serve_async.h` — async serve 集成
- `~/code/aura/src/serve/serve_async.cpp`
- `~/code/aura/src/serve/http_health.h` — HTTP health endpoint
- `~/code/aura/src/serve/aura_platform.h` — 平台抽象
- `~/code/aura/src/core/gc_hooks.h` — GC 回调
- `~/code/aura/src/core/mutation.ixx` — MutationBoundary
- `~/code/aura/src/core/mutators.ixx` — mutation primitives
- `~/code/aura/src/core/resource_quota.hh` — 资源配额
- `~/code/aura/src/core/envframe_lifetime.ixx` — env frame 生命周期
- `~/code/aura/src/core/lifetime_pin.ixx` — lifetime pinning
- `~/code/aura/src/core/panic_checkpoint_raii.ixx` — panic-safe RAII
- `~/code/aura/src/compiler/runtime_shared.h` — TL Arena + PairSlot
- `~/code/aura/scripts/check_fiber_mutate_safety.py` — fiber mutation safety linter
- `~/code/aura/.githooks/pre-commit` — commit 时跑 lint
- `~/code/aura/.githooks/pre-push` — push 时跑 gate

---

#6 v2 (aura) 完。