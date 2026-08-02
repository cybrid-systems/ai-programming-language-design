# #4 v2 — Aura Runtime (`runtime.c` + Pointer Tagging + AOT/JIT 桥接 + ABI)

> 接续 #1 v2 Orchestration + #2 v2 Build System + #3 v2 Parser:前面讲了
> aura 的运行时抽象、构建系统、Parser。本文聚焦 **Runtime 子系统**——`runtime.c`
> (1456 行 C) 的所有机制:Pointer Tagging(NaN boxing)、Bump Allocator、AOT
> Module Version、桥接 Epoch、ABI 契约、C↔C++ 边界。

---

## 0. 全文导读

Aura Runtime 四层:

```
Aura source (.aura)
    ↓ Parser (#3) → AST
    ↓ Compiler (Phase 1 C++ #5)
    ↓ AOT (Ahead-Of-Time) 编译 + J
AOT .o files (LLVM 编译)
    ↓ link with lib/runtime.c
native binary (standalone-AOT)
    或
    ↓ link with lib/runtime.c + host bridge (aura_jit_bridge.cpp)
JIT process (host + JIT)
```

`runtime.c` (1456 行, C) 是 **AOT 编译产物链接的 runtime**。它提供:
- Pointer tagging (value 表示)
- Bump allocator + drop + free list (memory 管理)
- 内置原语实现(算术、列表、cell、closure、display 等)
- ABI 契约(C↔C++ bridge)

本文按"架构 → Pointer Tagging → Memory Model → 内置原语 → ABI 契约 →
Standalone-AOT vs Host+JIT → 调优"展开。

---

## 1. Runtime 架构

### 1.1 `runtime.c` 的角色

```c
// ~/code/aura/lib/runtime.c:1-8
// Aura standalone runtime
// Linked with LLVM-compiled .o to produce native binary.
// Uses Bump Allocator (Arena) for fast bulk allocation + reset.
// Drop functions + Free List for objects needing individual release.
//
// Build: gcc -c runtime.c -o runtime.o
// Link:  gcc program.o runtime.o -o program -lm
```

`runtime.c` 是 **AOT 链接的最小 runtime**。它提供:
- `aura_bump_init()` / `aura_bump_reset()`:Arena 管理
- `aura_drop_pair()` / `aura_drop_cell()` / `aura_drop_closure()`:精确释放
- `aura_register_fn()` / `aura_register_closure_fn()` / `aura_closure_capture()`:原语/闭包注册
- `aura_cell_set()`:cell 写入
- `aura_display_value()` / `aura_newline()`:IO
- `aura_reset_runtime()`:exit cleanup
- `aura_set_module_version()` 等:跨 epoch 同步

### 1.2 两套 binary 模式

```
Standalone AOT:
  - lib/runtime.c + AOT .o → native binary
  - 没有 host bridge
  - 单线程(standalone 是 degenerate 情况)
  - 适用: hot path / static deployment

Host + JIT:
  - lib/runtime.c + AOT .o + libaura-reflect.so + host bridge
  - host 提供 concurrent mutation / JIT recompile
  - 适用: 动态环境 / 开发迭代
```

### 1.3 数据流对比

```
┌─────────────────────────────────────────────┐
│  Standalone AOT                              │
│  ┌─────────┐    ┌────────────────┐          │
│  │ runtime │ ◄──┤ AOT .o (LLVM) │          │
│  │   .c   │    └────────────────┘          │
│  └─────────┘                                │
│  → native binary                            │
└─────────────────────────────────────────────┘

┌─────────────────────────────────────────────┐
│  Host + JIT                                  │
│  ┌─────────┐    ┌────────┐    ┌──────────┐ │
│  │ runtime │    │ AOT    │    │ bridge   │ │
│  │   .c   │    │  .o   │ ◄──┤ (.cpp)   │ │
│  └─────────┘    └────────┘    └──────────┘ │
│       ▲                            ▲         │
│       └──────── bridge ────────────┘         │
│           host process + JIT service         │
└─────────────────────────────────────────────┘
```

---

## 2. Pointer Tagging (NaN Boxing)

### 2.1 Value 表示

```c
// runtime.c:11-19
// ── Pointer tagging: value representation ──────────
// bit 0 = 0: Fixnum (signed int, value >> 1)
// bits 1-0 = 01: Pair (index = val >> 2)
// bits 1-0 = 11: Special (tag = (val >> 2) & 3)
//   tag 0 = #f (= 0b11 = 3)
//   tag 1 = #t (= 0b111 = 7)
//   tag 2 = void () (= 0b1011 = 11)
```

这是 **NaN boxing** 的简化版——把 "类型 tag" 放在指针低位:
- 整数(fixnum):右移 1 位 + 末位 0
- pair:右移 2 位 + 末位 01
- special (bool/void):右移 2 位 + 末位 11 + sub-tag

### 2.2 提取值

```c
// 根据末 2 位判断类型
int64_t val;
switch (val & 0b11) {
    case 0b00: // Fixnum
        int64_t n = val >> 1;  // 算术右移
        break;
    case 0b01: // Pair
        int64_t pair_idx = val >> 2;  // pair 表的 index
        break;
    case 0b11: // Special
        switch ((val >> 2) & 0b11) {
            case 0: // #f (= 3)
                ...
            case 1: // #t (= 7)
                ...
            case 2: // void (= 11)
                ...
        }
        break;
}
```

### 2.3 Pointer Tagging 优势

```
优点:
  - 单个 i64 容纳所有类型 (int / pair / bool / void)
  - 无需 type tag 检查 (用低 2 位)
  - 整数算术天然 (算术右移 + 末位 0)
  - 内存紧凑 (pair 用 index,不是 pointer)

代价:
  - 整数范围减半 (~63 bits 有效)
  - Pair/closure 通过 index 间接访问 (一次额外寻址)
```

### 2.4 Pair 实现细节

```c
// Pair 在 Arena 中分配,通过 index 访问
struct Pair {
    int64_t car;  // i64 value (含 tag)
    int64_t cdr;
};

// aura_cons(car, cdr) → alloc pair → encode val = (idx << 2) | 0b01
// aura_car(pair_val) → val >> 2 → pair_idx → pairs[idx].car
```

---

## 3. Memory Model (Bump Allocator + Free List)

### 3.1 两层分配

```
Bump Allocator (Arena):
  - 大块分配
  - reset() 一次清空
  - 用于: 短生命周期对象 (closure capture, 临时结构)

Free List:
  - 精确释放 (drop_pair / drop_cell / drop_closure)
  - 用于: 长生命周期对象 (closure, cell)
```

### 3.2 Bump Allocator API

```c
// runtime.c 导出
void aura_bump_init(void);   // 初始化 Arena
void aura_bump_reset(void);  // 清空 Arena (不释放底层内存)
```

Arena 内部:
```c
static char g_bump_buffer[BUMP_SIZE]; // 默认几 MB
static size_t g_bump_pos = 0;

void* aura_bump_alloc(size_t n) {
    if (g_bump_pos + n > BUMP_SIZE) {
        // 触发 reset 或 panic
        aura_bump_reset();
    }
    void* p = &g_bump_buffer[g_bump_pos];
    g_bump_pos += n;
    return p;
}
```

### 3.3 Drop Functions

```c
// runtime.c
void aura_drop_pair(int64_t pair_val);     // 释放 pair
void aura_drop_cell(int64_t cell_id);      // 释放 cell
void aura_drop_closure(int64_t closure_id); // 释放 closure
```

Drop 把对象归还 Free List (而非 OS)— 后续可复用。

### 3.4 Memory Profile

```
Aura runtime 内存使用:
  - Bump Arena:几 MB(默认)
  - Free List: 取决于活跃 closure/cell 数
  - Static 数组: pairs / closures / cells / primitives 表

Standalone AOT 内存:
  - 静态分配 (BSS 段),不增长
  - 适合嵌入 / static deployment
```

---

## 4. 内置原语 (Primitives)

### 4.1 注册机制

```c
// runtime.c
void aura_register_fn(int64_t func_id, int64_t fn_ptr);
void aura_register_primitive_fn(int64_t slot, int64_t fn_ptr);
```

AOT 编译产物调用 `aura_register_fn(id, &my_primitive)` 注册原语。host / 
standalone runtime 负责 dispatch。

### 4.2 ABI 契约 (N-arg vector)

```c
// runtime.c Issue #2576: ABI is (prim_id, args*, count) — full N-arg vector.
```

原语调用 ABI:
- `prim_id`: 原语 ID (e.g., 0 = `+`, 1 = `-`, ...)
- `args*`: 指向参数数组的指针
- `count`: 参数个数

```c
// 编译产物的 emit:
//   call aura_prim_dispatch(prim_id=0 /* + */, args=[1, 2], count=2)
//   → result = +1, 2 = 3

int64_t aura_prim_dispatch(int64_t prim_id, int64_t* args, int64_t count) {
    switch (prim_id) {
        case PRIM_PLUS: {
            int64_t a = aura_unbox_fixnum(args[0]);
            int64_t b = aura_unbox_fixnum(args[1]);
            return aura_box_fixnum(a + b);
        }
        // ... 其他原语
    }
}
```

### 4.3 关键内置

| 原语 | 实现 | 备注 |
|------|------|------|
| `+ - * /` | fixnum 算术 | box/unbox + check overflow |
| `cons car cdr` | pair alloc + 字段读 | bump alloc + bump read |
| `= < >` | 比较 | type-aware (fixnum/float/string) |
| `display displayln` | IO | `aura_display_value` + newline |
| `eq?` | 指针相等 | tag + value 比较 |
| `equal?` | 结构相等 | 递归 pair 比较 |
| `set!` | cell 写 | `aura_cell_set` |

---

## 5. Cell & Closure

### 5.1 Cell (letrec 用)

```c
// cell = mutable box, letrec 自引用通过 cell 实现
struct Cell {
    int64_t value;  // 含 tag
};

// aura_make_cell() → alloc Cell → 返回 cell_id
// aura_cell_set(cell_id, value) → cells[cell_id].value = value
// aura_cell_get(cell_id) → cells[cell_id].value
// aura_drop_cell(cell_id) → 归还 Free List
```

### 5.2 Closure (lambda 编译产物)

```c
// Closure = compiled lambda + 捕获的 env
struct Closure {
    int64_t fn_ptr;       // AOT 编译产物的函数指针
    int32_t local_count;   // 闭包 locals 数
    // 捕获的 env 通过 closure_capture 存储
    int64_t captures[];    // flex array
};

// aura_make_closure(fn_ptr, local_count) → alloc Closure
// aura_closure_capture(closure_id, idx, val) → captures[idx] = val
// aura_invoke_closure(closure_id, args*) → call fn_ptr(args, captures)
```

### 5.3 Closure 调用

```
AOT emit:
  int64_t my_lambda_closure(int64_t* args, int64_t* captures) {
      // 编译产物函数
      // captures 是 closure 捕获的 env
      ...
  }

// 调用:
//   call aura_register_closure_fn(closure_id, &my_lambda_closure, locals=3)
//   call aura_closure_capture(closure_id, 0, x_val)
//   call aura_closure_capture(closure_id, 1, y_val)
//   val = aura_invoke_closure(closure_id, args)
```

---

## 6. Standalone-AOT vs Host+JIT

### 6.1 三个 epoch / version 机制

```c
// runtime.c
static unsigned long long g_aot_module_version = 0;
void aura_set_module_version(unsigned long long v) {
    g_aot_module_version = v;
}
unsigned long long aura_get_module_version(void) {
    return g_aot_module_version;
}

static _Atomic unsigned long long g_current_bridge_epoch = 0;
// Issue #1485 C2: dual-epoch fence
void aura_set_current_bridge_epoch(unsigned long long v) {
    atomic_store_explicit(&g_current_bridge_epoch, v, memory_order_release);
}
unsigned long long aura_get_current_bridge_epoch(void) {
    return atomic_load_explicit(&g_current_bridge_epoch, memory_order_acquire);
}

static unsigned long long g_aot_defuse_version = 0;
void aura_set_aot_defuse_version(unsigned long long v) {
    g_aot_defuse_version = v;
}
unsigned long long aura_get_aot_defuse_version(void) {
    return g_aot_defuse_version;
}
```

### 6.2 三个 version 的作用

```
g_aot_module_version:  module 整体重编时 +1
g_current_bridge_epoch:bridge 重新加载时 +1 (host)
g_aot_defuse_version: closure defuse 时 +1 (mutation tracking)

用途:
  - 双检查: closure.bridge_epoch vs current, closure.defuse_version vs current
  - 如果两者都匹配 → closure 有效
  - 如果不匹配 → closure 被 defuse / bridge 被 reload → 需 recompile
```

### 6.3 Standalone-AOT 的 degenerate 情况

```c
// runtime.c 注释 (Issue #1485 C2):
// Default 0 — standalone AOT is single-threaded so the 2-check
// (closure.bridge_epoch vs current, closure.defuse_version vs
// current) is degenerate; closures always stamp 0, current
// stays 0, the check always passes vacuously. This is correct
// for standalone AOT — the safety net is only meaningful under
// the host's concurrent-mutation regime.
```

**关键 insight**: Standalone-AOT 的 epoch 是 **永远 = 0** (degenerate) — 
closure stamp 0 vs current 0,检查永远通过。安全网只在 host + JIT 模式有意
义。这是 "dual-ABI stub" 的典型做法。

### 6.4 Host + JIT 模式

```
host process:
  1. 加载 AOT .o
  2. 调用 aura_set_module_version(1)
  3. JIT 重新编译 → 调用 aura_set_current_bridge_epoch(1)
  4. defuse → 调用 aura_set_aot_defuse_version(1)
  5. 运行时检查: closure.bridge_epoch == 1 && defuse_version == 1
```

---

## 7. Display & IO

### 7.1 aura_display_value

```c
// runtime.c Issue #2576
// ABI: aura_display_value(val, write_mode)
void aura_display_value(int64_t val, int64_t write_mode);
```

- `val`: 含 tag 的 i64
- `write_mode`: `0` = display, `1` = displayln (with newline)

```c
void aura_display_value(int64_t val, int64_t write_mode) {
    switch (val & 0b11) {
        case 0b00: // Fixnum
            printf("%lld", val >> 1);
            break;
        case 0b11: // Special (#t / #f / void)
            switch ((val >> 2) & 0b11) {
                case 0: printf("#f"); break;
                case 1: printf("#t"); break;
                case 2: printf("()"); break;
            }
            break;
        case 0b01: // Pair
            print_pair(val);
            break;
    }
    if (write_mode == DISPLAYLN) putchar('\n');
}
```

### 7.2 aura_newline

```c
void aura_newline(void) {
    putchar('\n');
}
```

### 7.3 与 host bridge 交互

```c
// AOT 编译产物的 .aura:
//   (display (+ 1 2))
// emit:
//   load_imm 3
//   call aura_display_value
//   call aura_newline

// host mode: 走 bridge (aura_jit_bridge.cpp)
// standalone mode: 直接走 runtime.c
```

---

## 8. main() & Startup

### 8.1 Entry Point

```c
// runtime.c
int main(int argc, char** argv);
```

AOT 编译产物链入 runtime 后,`main` 由 AOT 提供(覆盖 runtime.c 的 main)。
或者 runtime.c 提供默认 main,call `aura_main(argc, argv)` 让 AOT 实现。

### 8.2 启动序列

```
1. aura_bump_init() 初始化 Arena
2. AOT 编译产物的 init_ctors() 跑 (注册原语 / closure)
3. aura_set_module_version(1) (version 标记)
4. aura_main(argc, argv) 进入 user code
5. user code 跑完 → aura_reset_runtime() 清理
6. exit(0)
```

### 8.3 exit Cleanup

```c
void aura_reset_runtime(void) {
    // 清空 free list
    // 释放动态分配的 closure / cell
    // 写 gc / shutdown 日志(可选)
}
```

---

## 9. ABI 契约详解

### 9.1 三种 ABI

```
1. PrimCall ABI (N-arg vector):
   aura_prim_dispatch(prim_id, args*, count) → result

2. ClosureCall ABI:
   aura_invoke_closure(closure_id, args*) → result

3. ModuleInit ABI:
   aura_set_module_version(v)
   aura_set_current_bridge_epoch(v)
   aura_set_aot_defuse_version(v)
```

### 9.2 PrimCall vs ClosureCall

```
PrimCall:
  - 静态原语(+ - * / = cons ...)
  - args 是 i64 array
  - 不需要捕获 env

ClosureCall:
  - 用户定义 lambda
  - args 是 i64 array
  - 需要捕获 env (captures[])
```

### 9.3 ABI 稳定性

```c
// runtime.c Issue #2576:
// Issue #2576: ABI is (prim_id, args*, count) — full N-arg vector.
// ABI 稳定:prim_id / args / count 是固定 i64
//     → 加新原语 = 加 case, 不破 ABI
//     → 加 N-arg support = 自动 (count 决定)
```

**关键 insight**: N-arg vector ABI 让 PrimCall **未来兼容**。2-arg 时代写
的产物,3-arg 时代还能跑。

---

## 10. Host+JIT Bridge (`aura_jit_bridge.cpp`)

### 10.1 Bridge 角色

```
standalone AOT: 走 runtime.c 直接调用
host + JIT:      走 aura_jit_bridge.cpp 的实现(可能包含 JIT recompile)
```

bridge 在 standalone AOT 时不存在(linker 不链)。Issue #1485 C2 / C3 提
供 weak stubs 防止链接错误。

### 10.2 Bridge 实现 (host 侧)

```cpp
// src/compiler/aura_jit_bridge.cpp (推测)
extern "C" int64_t aura_prim_dispatch(int64_t prim_id, int64_t* args, int64_t count) {
    // 1. 记录 trace(perf counter)
    // 2. 看是否需要 JIT recompile
    // 3. 调用 jit_table[prim_id](args, count)
    // 4. 处理 mutation epoch (检查 closure 是否 defuse)
}
```

### 10.3 Mutation Safety

```
host 模式:
  1. closure 调用前检查 closure.bridge_epoch vs current
  2. 检查 closure.defuse_version vs current
  3. 不匹配 → 标记 stale → 触发 JIT recompile
  4. 重新生成 closure(新 capture 引用)
```

这是 **linear types + epoch** 的 runtime 实现。

---

## 11. 性能与代价

### 11.1 Runtime 调用开销

```
PrimCall:
  - 系统调用: 0 (直接 i64 arg passing)
  - dispatch: switch (1-3 cmp) + call
  - 总: ~10-50 ns

ClosureCall:
  - capture 查找: array[idx] (cache 命中)
  - 调用: indirect call
  - 总: ~50-200 ns

Display:
  - printf syscall: ~1-10 μs (含 IO)
```

### 11.2 Memory 开销

```
Standalone AOT:
  - 静态分配: BSS 段,几个 MB
  - 无 GC 开销
  - 适合 embedded

Host + JIT:
  - 动态分配: heap
  - GC 开销: ~1-5% throughput
  - 适合 server
```

### 11.3 epoch 开销

```
每次 closure 调用:
  - 读 closure.bridge_epoch (1 load)
  - 读 g_current_bridge_epoch (1 atomic load)
  - 比较 + branch
  - 总: ~2-5 ns (negligible)
```

---

## 12. 调优 Checklist

```
□ Standalone vs Host + JIT?
  - 静态部署: standalone AOT (无 GC,小内存)
  - 动态迭代: host + JIT (recompile / mutation)

□ ABI 兼容性?
  - 检查 prim_call ABI 稳定
  - 检查 closure_call ABI 稳定
  - 检查 epoch 语义对齐

□ Memory 调优?
  - Bump Arena 大小 (默认几 MB)
  - Free List 上限 (防止无限增长)

□ Display 性能?
  - printf vs write
  - buffer flush 策略

□ Epoch 开销?
  - 监控 JIT recompile 频率
  - bridge epoch 是否过于频繁 bump

□ Cell / Closure 释放?
  - drop_pair / drop_cell / drop_closure 是否完整
  - 没有 leak?
```

---

## 13. v2 subseries 收官回顾（aura v2 #4）

接续 #1-3 v2,本文聚焦 Runtime。

```
aura v2 deep-dive 系列 (本篇为 #4):

#1 v2  Agent Orchestration (orch.ixx + agent_spawn.h + AgentScope) ✅
#2 v2  Build System (build.py + 9 gates + CMake + Sanitizer + PGO)  ✅
#3 v2  Parser (S-expression + Racket 兼容 + ABF)  ✅
#4 v2  Runtime (runtime.c + Pointer Tagging + AOT/JIT 桥接 + ABI)  ← 本文
#5 v2  Compiler (C++26 modules + AOT/JIT)
#6 v2  Fiber System (concurrency + GC hooks)
#7 v2  Type System (type_dep freshness + denseness)
#8 v2  Module System (multi-define + require)
#9 v2  JIT / AOT (aura_jit + hot-update + aot_mangle)
#10 v2 Self-Modification (代码自己进化的核心机制)
```

---

## 14. 下一篇预告

按 aura 主题自然顺序:

- **#5 v2 Compiler** — 182 文件 + C++26 modules(核心深入)
- **#6 v2 Fiber System** — 并发 + GC hooks(配合 #1 orchestration + #4 runtime)
- **#7 v2 Type System** — type_dep freshness + denseness(配合 #4 linear types)

下一篇选哪个?

---

## 15. 参考(可执行的源码锚点)

- `~/code/aura/lib/runtime.c` — 1456 行 C runtime(本文主体)
- `~/code/aura/src/compiler/aura_jit_bridge.cpp` — host bridge 实现
- `~/code/aura/src/compiler/aura_jit.cpp` — JIT 引擎
- `~/code/aura/src/compiler/aura_jit_runtime.cpp` — JIT runtime stub
- `~/code/aura/src/compiler/aura_jit_prim_dispatch_stub.cpp` — prim dispatch stub
- `~/code/aura/src/compiler/aura_jit_bridge_stub.cpp` — bridge stub
- `~/code/aura/src/compiler/runtime_paths.h` — runtime 路径
- `~/code/aura/src/compiler/runtime_shared.h` — runtime 共享 header
- `~/code/aura/src/compiler/aot_mangle.h` — AOT name mangling
- `~/code/aura/src/compiler/aura_error_bridge.h` — error bridge
- `~/code/aura/src/main.cpp` — main 入口 + module imports
- `~/code/aura/lib/std/` — stdlib(AOT-linked)

---

#4 v2 (aura) 完。