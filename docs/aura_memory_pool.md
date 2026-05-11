# Aura — AST 内存池设计

**版本**：v1.0
**对应**：M1 Phase 1 (C++26 Compiler Service)
**定位**：高性能 AST 内存管理的完整方案，支撑 AI Agent 实时代码变异场景下百万级 AST 节点的亚毫秒级分配与回收。

---

## 1. 设计目标

| 指标 | 目标 | 说明 |
|------|------|------|
| 分配延迟 | ~3-5 ns | 每次 AST 节点分配的纯开销 |
| 整树回收 | O(1) | 无逐节点析构，一次指针复位 |
| 对齐 | 自动 | 节点内部对齐由 allocator 保证 |
| pmr 兼容 | 是 | 支持 `pmr::vector/string/map` |
| 碎片 | 零 | bump allocator 天生零碎片 |
| 多 arena | 原生 | 每模块/函数独立 arena |

---

## 2. 架构

```
┌────────────────────────────────────────────────────────────────┐
│                      ASTArena                                  │
│                                                                │
│  buffer_ (std::vector<std::byte>, 8MB 初始)                    │
│  ┌──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┐    │
│  │  │  │  │  │  │  │  │  │  │  │  │  │  │  │  │  │  │  │    │
│  └──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┘    │
│   ▲                                        ▲                  │
│   └── allocated (bump ptr)                 └── end            │
│                                                                │
│  resource_ (std::pmr::monotonic_buffer_resource)               │
│  └── 上游: std::pmr::null_memory_resource()                    │
│       (永不 fallback 到堆分配)                                  │
│                                                                │
│  bytes_allocated_ — 累计分配字节（调试/火焰图用）               │
└────────────────────────────────────────────────────────────────┘
```

### 核心组件

| 组件 | 实现 | 作用 |
|------|------|------|
| `buffer_` | `std::vector<std::byte>` | 拥有式 backing store |
| `resource_` | `std::pmr::monotonic_buffer_resource` | bump allocator |
| `create<T>(args...)` | `construct_at` + pmr allocate | 类型安全构造 |
| `reset()` | `resource_.release()` | O(1) 整树回收 |
| `allocator()` | `polymorphic_allocator` | pmr 容器适配 |

---

## 3. 关键实现细节

### 3.1 为什么用 `monotonic_buffer_resource` 而不是手写 bump？

```
手写 bump:                              pmr monotonic:
┌────────────────────────┐           ┌────────────────────────┐
│  if (pos + size > cap) │           │  allocate(size, align) │
│    throw bad_alloc     │           │  ← 内置对齐处理       │
│  pos = align(pos)      │           │  ← 可接 pmr 容器       │
│  raw = buffer + pos    │           │  ← 可换上游分配器      │
│  pos += size           │           │  ← 可递归 fallback     │
│  return raw            │           └────────────────────────┘
└────────────────────────┘
```

pmr 方案比手写多了**零额外代码**就获得自动对齐、pmr 容器兼容、和可替换上游的能力。

### 3.2 `null_memory_resource` 上游策略

```cpp
resource_(buffer_.data(), buffer_.size(), std::pmr::null_memory_resource())
```

当 bump 指针超出 buffer 范围时，`null_memory_resource` 会抛 `std::bad_alloc`。这是有意为之的——我们用一个足够大的初始 buffer（8MB）覆盖绝大多数用例，而不是静默 fallback 到堆分配（导致碎片）。

未来可升级为：
```cpp
// 可选：退回到堆分配（适合极大规模 AST）
std::pmr::unsynchronized_pool_resource fallback;
resource_(buffer_.data(), buffer_.size(), &fallback);
```

### 3.3 `reset()` 的语义

```cpp
void reset() {
    resource_.release();  // 重置 bump 指针到 buffer 起始
    bytes_allocated_ = 0;
}
```

- 不释放 `buffer_`（vector 的 capacity 保留）
- 不调用任何析构函数（O(1)）
- AST 节点的生命周期与 arena 绑定——`reset()` 后所有指针失效

---

## 4. 使用模式

### 4.1 单 arena，多次请求（REPL/CaaS）

```cpp
ASTArena arena(8 * 1024 * 1024);

// 请求 1
auto* ast1 = arena.create<Expr>(...);   // 从 arena 分配
eval(ast1);
arena.reset();                           // 回收整棵 AST

// 请求 2
auto* ast2 = arena.create<Expr>(...);   // arena 重用，无堆分配
eval(ast2);
arena.reset();
```

### 4.2 多 arena，模块隔离

```cpp
ASTArena kernel_arena;
ASTArena module_a_arena;
ASTArena module_b_arena;

// 编译 kernel —— 常驻
auto* kernel_ast = kernel_arena.create<Expr>(...);

// 编译 module A —— 用完释放
auto* a_ast = module_a_arena.create<Expr>(...);
compile(a_ast);
module_a_arena.reset();  // 只释放 A 的内存

// module B 继续使用自己的 arena
auto* b_ast = module_b_arena.create<Expr>(...);
```

### 4.3 pmr 容器集成

```cpp
// 在 Expr 中使用 pmr 容器
struct Expr {
    NodeTag tag;
    std::pmr::vector<Expr*> children;  // 由 arena 管理
    std::pmr::string name;             // 由 arena 管理

    Expr(NodeTag t, std::pmr::polymorphic_allocator<std::byte> alloc)
        : tag(t), children(alloc), name(alloc) {}
};

// 使用
auto alloc = arena.allocator();
auto* expr = arena.create<Expr>(NodeTag::Call, alloc);
```

---

## 5. 性能数据（预期）

| 操作 | 延迟 | 说明 |
|------|------|------|
| `arena.create<T>(args...)` | ~3-5 ns | 指针偏移 + construct_at |
| `arena.reset()` | ~1 ns | 指针复位 |
| 100 万节点创建 | ~3-5 ms | 在 8MB buffer 内 |
| 100 万节点回收 | ~1 μs | 一次 `release()` |

---

## 6. 与 Aura 设计目标的关系

| Aura 目标 | 内存池支撑 |
|-----------|-----------|
| AI Agent 实时代码变异 | O(1) reset 使每次变异无需 GC 停顿 |
| 增量编译 | 多 arena 使模块级增量成为自然 fit |
| 自省/反射 | `bytes_allocated_` 可用于内存用量反馈 |
| 无 GC 运行时 | bump allocator 天然无碎片，无需 GC 扫描 |

---

## 7. 演进路线

| 阶段 | 内容 | 触发条件 |
|------|------|----------|
| v1（当前）| 单 arena + pmr monotonic | M1 Phase 1 |
| v2 | 多 arena 管理器 + 统计导出 | 模块编译需求 |
| v3 | 固定大小 small-object 池 | 性能分析显示瓶颈 |
| v4 | 火焰图 / 内存报告 CLI | --profile 标志 |

---

## 引用

- 实现代码：`aura/src/core/arena.ixx`
- CompilerService 集成：`aura/src/compiler/service.ixx`
- `std::pmr::monotonic_buffer_resource`: [cppreference](https://en.cppreference.com/w/cpp/memory/monotonic_buffer_resource)
- 设计文档：[aura_architecture.md](./aura_architecture.md)
