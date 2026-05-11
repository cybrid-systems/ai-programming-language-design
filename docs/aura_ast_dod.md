# Aura — 扁平 AST 索引方案（综合设计）

**版本**：v0.3
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

### 2.1 节点元数据：constexpr 表

每个 `NodeTag` 的元数据在编译期已知，用于反射、序列化、验证：

```cpp
export struct NodeMeta {
    NodeTag tag;
    std::string_view name;
    uint8_t fixed_children;    // child0/1/2 中哪些有效
    bool has_var_children;     // 是否有变长子节点（Call args）
    bool has_string;           // 是否有字符串名（Variable/Let/Define）
    bool has_int;              // 是否有整数值（LiteralInt）
    bool has_params;           // 是否有参数列表（Lambda）
};

export constexpr std::array<NodeMeta, 8> kNodeMeta = {{
    {NodeTag::LiteralInt, "LiteralInt", 0, false, false, true,  false},
    {NodeTag::Variable,   "Variable",   0, false, true,  false, false},
    {NodeTag::Call,       "Call",       1, true,  false, false, false},
    {NodeTag::IfExpr,     "IfExpr",     3, false, false, false, false},
    {NodeTag::Lambda,     "Lambda",     1, false, false, false, true},
    {NodeTag::Let,        "Let",        2, false, true,  false, false},
    {NodeTag::LetRec,     "LetRec",     2, false, true,  false, false},
    {NodeTag::Define,     "Define",     1, false, true,  false, false},
}};
```

用在 contracts 中：
```cpp
NodeId add_node(NodeTag tag)
    [[pre: static_cast<uint8_t>(tag) < kNodeMeta.size()]];
```

---

### 2.2 节点存储：SoA + 统一 child 方案

放弃 child0/1/2 + children_begin/end 的冗余设计。每个节点用统一的 **child_begin + child_count** 指向扁平 `child_data_`：

```
child_begin_[i]     →  child_data_ 中的起始位置
child_count_[i]     →  子节点数量
                     →  固定子节点（如 if 的 3 个）和变长子节点（call args）
                        统一存储，降低复杂度
```

```cpp
class FlatAST {
    // SoA 存储 —— 所有 vector 使用 arena allocator
    pmr::vector<NodeTag>   tag_;            // 1B/节点
    pmr::vector<int64_t>   int_val_;        // 8B/节点（LiteralInt）
    pmr::vector<SymId>     sym_id_;         // 4B/节点（Variable/Let/Define）
    pmr::vector<uint32_t>  child_begin_;    // 4B/节点
    pmr::vector<uint32_t>  child_count_;    // 4B/节点
    pmr::vector<NodeId>    child_data_;     // 扁平子节点数组
    
    // Lambda 参数
    pmr::vector<uint32_t>  param_begin_;
    pmr::vector<uint32_t>  param_count_;
    pmr::vector<SymId>     param_data_;
    
    NodeId root_ = NULL_NODE;
};
```

**每节点 21 字节**（tag + int_val/sym_id union + child_begin + child_count），
加上平摊的 child_/param_data 开销，典型节点 ~25-30 字节。

#### NodeView — 轻量只读视图

```cpp
export struct NodeView {
    NodeTag tag;
    std::int64_t int_value;          // 仅 LiteralInt 有效
    SymId sym_id;                    // 仅命名字段有效
    std::span<const NodeId> children;
    std::span<const SymId> params;   // 仅 Lambda 有效

    // 便捷方法
    bool has_int() const { return tag == NodeTag::LiteralInt; }
    bool has_name() const { return sym_id != INVALID_SYM; }
    NodeId child(uint32_t i) const { return children[i]; }
};

NodeView FlatAST::get(NodeId id) const {
    return NodeView{
        .tag      = tag_[id],
        .int_value = int_val_[id],
        .sym_id   = sym_id_[id],
        .children = std::span(child_data_.data() + child_begin_[id],
                              child_count_[id]),
        .params   = std::span(param_data_.data() + param_begin_[id],
                              param_count_[id]),
    };
}
```

ranges 遍历：
```cpp
for (auto v : ast | std::views::transform(&FlatAST::get)) {
    if (v.tag == NodeTag::Call) {
        for (auto c : v.children) { ... }
    }
}
```

---

### 2.3 字符串驻留

```cpp
class StringPool {
    pmr::vector<char> buf_;
    // 开放寻址哈希表（替代 std::pmr::unordered_map，避免指针 chasing）
    pmr::vector<uint32_t> hash_tbl_;
    pmr::vector<SymId>    hash_keys_;
public:
    SymId intern(std::string_view s);
    std::string_view resolve(SymId id) const;
};
```

- `SymId` 是 `uint32_t`，指向 `buf_` 中的偏移
- 字符串数据连续存储，零碎片
- 开放寻址哈希表，全 arena 分配，无额外指针间接

---

### 2.4 与 Arena 集成

```cpp
class ASTArena {
    pmr::monotonic_buffer_resource resource_;
    pmr::unsynchronized_pool_resource fallback_;  // 扩容 fallback
    StringPool pool_;

    FlatAST create_ast() {
        return FlatAST{allocator()};
    }
};
```

- `FlatAST` 所有 `pmr::vector` 走 arena allocator
- `reset()` 时全部释放
- `fallback_` 防止扩容时 crash（`monotonic` 溢出后走 pool）
- `StringPool` 的 buffer 也走 arena（reset 即失）

---

### 2.5 AI Patch 接口

```cpp
export struct Patch {
    NodeId node;             // 目标节点
    uint32_t field_offset;   // 字段偏移（枚举或字节偏移）
    uint64_t new_value;      // 新值（SymId / NodeId / int64）
};

export bool apply_patch(FlatAST& ast, std::span<const Patch> patches)
    [[post: patches_applied == patches.size()]];
```

变异示例：
```cpp
// AI 把 (+ x 1) → (string-append x "1")
Patch patches[] = {
    {add_node, /*tag_field*/0, uint64_t(NodeTag::Call)},
    {add_node, /*func_field*/..., string_pool.intern("string-append")},
    {plus_literal, /*value_field*/..., string_pool.intern("1")},
};
apply_patch(ast, patches);
```

---

### 2.6 序列化映射

```
FlatAST SoA layout              ABF binary format
───────────────────────────────────────────────────
tag_[i]                    →  varint(tag)
int_val_[i] / sym_id_[i]   →  varint(value/id)     (按 tag 决定)
child_[i] (delta encoded)  →  [varint(count), varint(delta(c0)), ...]
param_[i] (delta encoded)  →  [varint(count), varint(param_id0), ...]

反序列化：
  顺序读 → 追加到 tag_ / int_val_ / ... 末尾
  delta → 绝对 NodeId 修复：delta + node_id
```

fixup 函数：
```cpp
void fixup_deltas(FlatAST& ast) {
    for (auto id : std::views::iota(0u, ast.size())) {
        auto begin = ast.child_begin_[id];
        auto count = ast.child_count_[id];
        for (auto& cid : std::span(ast.child_data_.begin() + begin, count))
            cid += id;  // delta → absolute
    }
}
```

---

### 2.7 与 Expr 桥接

```cpp
NodeId flatten_expr(const Expr* expr, FlatAST& ast, StringPool& pool);
```

Phase 4 后此函数废弃（parser 直接产 FlatAST）。

---

## 3. 迁移路线图

```
Phase 1 (已提交)  →  AST 索引原型 + flatten_expr（std::vector<ASTNode>）
Phase 2 (当前)    →  SoA + arena + StringPool + NodeView
Phase 3           →  序列化/反序列化对接
Phase 4           →  parser 直接产 FlatAST（跳过 Expr）
Phase 5           →  删除旧 Expr 树类型
```

### Phase 2 文件清单

```
NEW:  src/core/ast_flat.ixx       — FlatAST, NodeView, NodeMeta, Patch
NEW:  src/core/ast_pool.ixx       — StringPool (开放寻址)
MOD:  src/core/arena.ixx          — 集成 StringPool
MOD:  src/core/ast_impl.cpp       — flatten_expr 适配 FlatAST (SoA)
```

---

## 4. 与现有设计文档的关系

| 文档 | 关系 |
|------|------|
| `aura_memory_pool.md` | FlatAST 的 `pmr::vector` 走 arena allocator |
| `aura_serialization.md` | ABF v2 格式直接映射 FlatAST 的 SoA layout |
| `aura_architecture.md §3.3` | Trees that Grow 的 Phase 扩展可保留为 FlatAST 扩展字段 |
| `aura_caas.md` | CompilerService 返回 `FlatAST&`（而非 `Expr*`）给 AI Agent |

---

## 5. 开放问题

1. **pmr::vector 扩容**：`monotonic_buffer_resource` 初始 buffer 建议 8-16MB，加上 `unsynchronized_pool_resource` 作为 fallback 防止溢出 crash。
2. **SoA 同步开销**：增删节点需要同步所有 `pmr::vector`。对于 AST 的"一次构建、批量消费"模式，非问题。
3. **Lambda 参数内联**：`param_count_` > 3 才走 `param_data_`，≤3 可内联到固定字段（可选优化）。

---

> 本文档是 `aura_ast_dod.md` v0.3，与 `aura_memory_pool.md`、`aura_serialization.md`、`aura_architecture.md` 并列。
