# Aura — 扁平 AST 索引方案（综合设计）

**版本**：v0.2（迭代中）
**涉及**：内存池 / 序列化 / 反射 / AI 变异

---

## 0. 当前方案的问题

Phase 1 的 `std::vector<ASTNode>` 索引方案有四个硬伤：

| 问题 | 影响 |
|------|------|
| `std::vector` 不走 arena | 每次 push_back 走堆分配，arena 白做了 |
| `ASTNode` 内含 `std::string` / `std::vector` | 嵌套分配，碎片化，内存池浪费 |
| 未考虑序列化格式 | 后续 ABF 序列化需要再做索引转换 |
| 未考虑反射迭代 | `std::variant` 的 `std::visit` 在索引版本中不存在了 |

---

## 1. 四维设计约束

```
         ┌──────────┐
         │   Arena   │ ← pmr bump allocator，零碎片
         └────┬─────┘
              │
    ┌─────────┼─────────┐
    │         │         │
    ▼         ▼         ▼
┌──────┐ ┌────────┐ ┌────────┐
│ ABF  │ │ 反射   │ │ AI     │
│序列化 │ │ (M4)   │ │ 变异   │
└──────┘ └────────┘ └────────┘
```

### 1.1 Arena 约束

```
- 所有 AST 节点内存来自 pmr monotonic_buffer_resource
- reset() → 整块回收，O(1)，无逐节点析构
- AST 存活周期 =  arena 两次 reset() 之间
- 跨 reset 存活的数据必须走独立分配（如符号表）
```

→ **结论**：`AST` 容器必须用 `pmr::vector` + arena allocator，不可用 `std::vector`。

### 1.2 ABF 序列化约束

```
当前 ABF v2 格式（aura_serialization.md §4）：
  varint node_tag | varint extension_id | length | payload

每节点格式：
  [tag][field_count][field...][child_count][child_id...]

序列化路径：
  flat AST → iter nodes → write each node + children as delta-encoded IDs

设计目标：
  反序列化可以不重建索引（mmap + 指针修整即可）
```

→ **结论**：`NodeId` 必须是**连续的**（nodes 的 index = ID），序列化时按 `nodes` 顺序写，反序列化时顺序读。子节点用 delta encoding（`child - parent`）进一步压缩。

### 1.3 反射约束（M4）

```
static reflection (C++26 P2996) 需要：
  - 编译期已知节点类型枚举
  - 编译期已知字段布局
  - 运行时可迭代所有节点

constexpr AST 遍历：
  for (const auto& node : ast) {
    if constexpr (reflect(node.tag)) { ... }
  }
```

→ **结论**：节点必须是普通可复制的值类型（trivially copyable），`std::string` / `std::vector` 不可用。必须用 SoA 或固定大小 + 外部字符串池。

### 1.4 AI 变异约束

```
AI Agent 操作模式：
  1. 编译一期 AST → 得到 NodeId 集合
  2. 提交 patch: "把 node[42] 的 child0 指向 node[7]"
  3. 增量编译：只变 delta，不重建全树

需要：
  - NodeId 稳定（reset 后失效，但同一期编译内不变）
  - patch = {node_id, field_offset, new_value}
  - 子树替换 = 改一个 child_id，arena 无需全量回收
```

→ **结论**：索引方案天然支持增量 patch。AI 只用 ID 描述变更。

---

## 2. 综合设计

### 2.1 节点存储：SoA + 固定大小

放弃 `ASTNode` 大统一结构。改用 **struct-of-arrays**（SoA），每个字段一个 `pmr::vector`：

```cpp
class FlatAST {
    // SoA 存储 —— 所有 vector 使用 arena allocator
    pmr::vector<NodeTag>   tag_;         // 1B/节点
    pmr::vector<int64_t>   int_val_;     // 8B/节点（仅 LiteralInt 有效）
    pmr::vector<SymId>     sym_id_;      // 4B/节点（Variable/Let/Define 名）
    pmr::vector<NodeId>    child0_;      // 4B/节点（单子节点）
    pmr::vector<NodeId>    child1_;      // 4B/节点
    pmr::vector<NodeId>    child2_;      // 4B/节点（if 需要三个）
    
    // 多子节点（Call args）：子节点索引范围
    pmr::vector<uint32_t>  children_begin_;  // 4B/节点
    pmr::vector<uint32_t>  children_end_;    // 4B/节点
    pmr::vector<NodeId>    children_data_;   // 扁平子节点数组
    
    // Lambda 参数：字符串 ID 范围
    pmr::vector<uint32_t>  params_begin_;
    pmr::vector<uint32_t>  params_end_;
    pmr::vector<SymId>     params_data_;
    
    NodeId root_ = NULL_NODE;
};
```

**每节点固定 29 字节**（tag + 3×child + begin/end 对），远小于 `ASTNode` 的 `std::string`+`std::vector` 开销。

### 2.2 字符串驻留

```cpp
class StringPool {
    pmr::vector<char> buf_;              // 连续字符串数据
    pmr::unordered_map<string_view, SymId> map_;
public:
    SymId intern(string_view s);
    string_view resolve(SymId id) const;
};
```

- `SymId` 是 `uint32_t`，指向 `buf_` 中的偏移
- 字符串数据连续存储，零碎片
- `AST` 中用 `SymId` 代替 `std::string`，反射友好

### 2.3 与 Arena 集成

```cpp
class ASTArena {
    pmr::monotonic_buffer_resource resource_;
    std::pmr::pool_resource fallback_;  // 溢出fallback
    StringPool pool_;
    // ...
    
    FlatAST create_ast() {
        return FlatAST{allocator()};
    }
};
```

- `FlatAST` 所有 `pmr::vector` 都走 arena allocator
- `reset()` 时全部释放
- `StringPool` 的 buffer 也走 arena（reset 即失）

### 2.4 序列化映射

```
FlatAST SoA layout              ABF binary format
──────────────────────────────────────────────────
tag_[i]           →  varint(node_tag)
int_val_[i]       →  varint(int_value)      (if LiteralInt)
sym_id_[i]        →  varint(sym_id)         (if needs name)
child0_[i]        →  varint(delta(child0))  (parent-relative)
child1_[i]        →  varint(delta(child1))
children_data_    →  [varint(count), varint(delta(c0)), ...]

反序列化：
  从二进制顺序读节点 → 直接追加到 tag_ / child0_ / ... 末尾
  delta → 绝对 ID 修复在读取后进行
```

### 2.5 与 Expr 桥接

Phase 1 的 `flatten_expr()` 保留并适配到 `FlatAST`：

```cpp
NodeId flatten_expr(const Expr* expr, FlatAST& ast, StringPool& pool);
```

---

## 3. 迁移路线图

```
Phase 1 (当前)  →  AST 索引类型定义 + flatten_expr
Phase 2         →  SoA 实现 + arena 集成
Phase 3         →  序列化/反序列化对接
Phase 4         →  parser 直接产 FlatAST（跳过 Expr）
Phase 5         →  删除旧 Expr 树类型
```

### 当前 Phase 1 的问题

Phase 1 的 `std::vector<ASTNode>` + `std::string` 不能落地到 arena，也不能四维统一。**建议 Phase 1 作为原型验证保留，Phase 2 直接上 SoA + arena 集成。**

---

## 4. 与现有设计文档的关系

| 文档 | 关系 |
|------|------|
| `aura_memory_pool.md` | FlatAST 的 `pmr::vector` 走 arena allocator |
| `aura_serialization.md` | ABF v2 格式直接映射 FlatAST 的 SoA layout |
| `aura_architecture.md §3.3` | Trees that Grow 的 Phase 扩展可以保留为 FlatAST 的扩展字段 |
| `aura_caas.md` | CompilerService 返回 `FlatAST&`（而非 `Expr*`）给 AI Agent |

---

## 5. 开放问题

1. **pmr::vector 扩容**: `monotonic_buffer_resource` + `null_memory_resource` 上游会在扩容时 crash。需要允许 fallback 到堆，或初始 buffer 足够大（32MB+）。
2. **SoA vs AoS 性能**: SoA 在遍历（反射、序列化）时缓存更好，但增删单节点时要同步所有 `pmr::vector`。对于 AST 的"一次构建、批量消费"模式，SoA 优势明显。
3. **Lambda 参数**: `params_data_` 用 `SymId` 数组当前设计是 `pmr::vector`。如果大部分 lambda 参数 ≤3 个，可内联到节点固定字段。

---

> 本文档是 `aura_ast_dod.md`，与 `aura_memory_pool.md`、`aura_serialization.md`、`aura_architecture.md` 并列。Phase 2 实现前建议各相关方 review。
