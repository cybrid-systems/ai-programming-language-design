# 17. InnoDB 自适应哈希索引（Adaptive Hash Index, AHI）— 源码深度分析

> 本文基于 MySQL 8.0/9.0 源码，深入分析 InnoDB Adaptive Hash Index（AHI）的架构设计、数据结构、构建/查找/删除路径、并发控制与性能调优。核心源文件：`btr0sea.cc`、`btr0sea.h`、`buf0buf.h`、`hash0hash.h`、`ha0ha.h`。

---

## 0. 概述

AHI（Adaptive Hash Index）是 InnoDB 在 B+Tree 索引页之上构建的一层**轻量级内存哈希缓存**。它不是传统意义上的独立索引结构——不持久化、不占用磁盘空间，而是在 Buffer Pool 中运行时根据访问模式**自适应**构建和销毁。

### AHI 解决的问题

InnoDB 的 B+Tree 查询时间复杂度为 O(log n)，对于热数据（频繁等值查询的 key），每次搜索都走完整树遍历是不必要的。AHI 将热 key 映射到 `rec_t*`（物理记录指针），将查找复杂度降为 **O(1)**。

```
B+Tree 查找（无 AHI）:
  root → non-leaf → non-leaf → ... → leaf → rec_t*
  O(log n) 次页面读写

AHI 查找（命中时）:
  dtuple → hash → rec_t*
  O(1) 次内存访问
```

### 何时该启用 AHI？

AHI 在以下场景收益显著：

- **等值查询密集**（`WHERE pk = ?` 或 `WHERE sec_key = ?`）：hash 查找直接命中
- **热 key 集中**：少数 key 占大部分访问，AHI 只缓存这些热 key
- **主键自增 + 随机二级索引查询**：二级索引通过主键回表频繁查聚簇索引

在以下场景考虑禁用（`innodb_adaptive_hash_index = OFF`）：

- **大量范围查询**（`BETWEEN`, `>`）：AHI 对范围查询几乎无收益
- **高并发写入频繁 DDL**：AHI 维护开销大，构建/删除频繁
- **AHI 分区争用严重**：`SHOW ENGINE INNODB STATUS` 中 `RW-latch` 的 `btr_search_latch` 等待很高

### AHI 的主要参与方

| 组件 | 文件 | 职责 |
|------|------|------|
| `btr_search_sys_t` | `btr0sea.h:93` | 全局 AHI 系统，含分区和哈希表 |
| `btr_search_t` | `btr0sea.h:46` | 每个索引的搜索统计信息 |
| `buf_block_t::ahi_t` | `buf0buf.h:1802` | 每个缓冲页记录 AHI 前缀参数和索引归属 |
| `btr_search_prefix_info_t` | `buf0buf.h:1739` | 前缀参数（字段数、字节数、方向） |
| `ha_node_t` | `ha0ha.h:164` | 哈希表链节点 |
| `hash_table_t` | `hash0hash.h` | 通用哈希表实现（InnoDB 几乎所有 hash 都基于此） |

---

## 1. 核心数据结构详解

### 1.1 全局 AHI 系统 — btr_search_sys_t

```cpp
// btr0sea.h:93
class btr_search_sys_t {
 public:
  btr_search_sys_t(size_t hash_size);

  /* ── 每个 AHI 分区 ── */
  class search_part_t {
   public:
    void initialize(size_t hash_size);

    /* 保护该分区的读写锁 */
    /* S 锁：多个查找线程可同时读；X 锁：只有一个写线程（构建/删除） */
    alignas(ut::INNODB_CACHE_LINE_SIZE)
        rw_lock_t latch;

    /* 哈希表：dtuple_hash_value → rec_t* */
    /* 每个表项是一个 ha_node_t 链表 */
    alignas(ut::INNODB_CACHE_LINE_SIZE)
        hash_table_t *hash_table;

    /* 预分配的空闲缓冲块，用于 hash_table 的内存堆扩展 */
    /* 这是为了避免在持有 AHI 锁时分配内存（malloc 可能阻塞） */
    std::atomic<buf_block_t *> free_block_for_heap;
  };

  /* 分区数组 */
  ut::unique_ptr_aligned<search_part_t[]> parts;
};

/* 全局单例 */
extern btr_search_sys_t *btr_search_sys;
```

**分区（partitioning）设计**：

```
btr_search_sys
  ├── parts[0] → latch + hash_table + free_block
  ├── parts[1] → latch + hash_table + free_block
  ├── parts[2] ...
  └── parts[n-1] ...

索引通过 index_id 取模路由到分区:
  partition = index_id % btr_ahi_parts
```

`btr_ahi_parts` 默认值是 `btr_ahi_parts_default = 8`，可通过 `innodb_adaptive_hash_index_parts` 配置（1-512）。分区数的影响：

| 分区数 | 优点 | 缺点 |
|--------|------|------|
| 1 | 实现简单 | 高并发 S 锁争用严重 |
| 8（默认） | 8 路并行读，8 路并行写 | 低索引负载时缓存碎片化 |
| 64+ | 极致并行 | 小表 hash 条目分散，cache miss 增加 |

`free_block_for_heap` 是一个精妙的**预分配机制**：

当构建 AHI 时需要向 hash_table 的堆分配 `ha_node_t` 节点。但 **malloc 可能触发页面错误或锁竞争**。因此 AHI 在启动时预分配一个空闲块：

```
AHI 构建时:
  1. 尝试从 free_block_for_heap 获取预分配空间
  2. 不够时，在线程释放 AHI X 锁后，再申请新空间
  3. 下次构建时先检查 free_block_for_heap 是否够用
```

这样持有 X 锁的关键路径不会遇到阻塞式内存分配。

### 1.2 索引级搜索信息 — btr_search_t

每个 `dict_index_t` 关联一个 `btr_search_t`，跟踪该索引的 AHI 使用情况：

```cpp
// btr0sea.h:46
struct btr_search_t {
  /* 引用计数：有多少缓冲块为此索引构建了 AHI 条目 */
  std::atomic<size_t> ref_count;

  /* 根页面帧缓存（上次读取的根页地址的猜测） */
  buf_block_t *root_guess;

  /* 超过此阈值后才启动 hash 分析 */
  /* BTR_SEARCH_HASH_ANALYSIS = 17 */
  std::atomic<uint64_t> hash_analysis;

  /* 上一次的 AHI hash 搜索是否成功 */
  bool last_hash_succ;

  /* 连续 hash 搜索成功/有潜力成功的计数 */
  /* 范围: 0 ~ BTR_SEARCH_BUILD_LIMIT + 5 */
  std::atomic<uint64_t> n_hash_potential;

  /* 推荐的 hash 前缀参数（通过访问模式学习得到） */
  std::atomic<btr_search_prefix_info_t> prefix_info;
};
```

**各字段的生命周期**：

```
索引创建时:
  btr_search_t = {ref_count=0, root_guess=null, hash_analysis=0,
                  last_hash_succ=false, n_hash_potential=0,
                  prefix_info={n_fields=0, n_bytes=0, left_side=true}}

每次 B+Tree 搜索后 → btr_search_info_update()
  hash_analysis++  → 累计到 17 触发 btr_search_info_update_slow()
  n_hash_potential 根据 up_match/low_match 调整
  prefix_info 由分析结果更新

n_hash_potential >= 100 且页面级统计达标 → 构建 AHI
```

### 1.3 前缀参数 — btr_search_prefix_info_t

```cpp
// buf0buf.h:1739
struct alignas(alignof(uint64_t)) btr_search_prefix_info_t {
  uint32_t n_bytes;    /* 不完整字段的字节数（如 VARCHAR 部分前缀） */
  uint16_t n_fields;   /* 完整字段数 */
  bool left_side;      /* true=缓存每组最左记录，false=缓存最右记录 */
};
```

**`left_side` 的详细解释**：

当 AHI 为页面上的一组记录构建 hash 时，它只缓存该组的边界记录。考虑一个非唯一二级索引 `KEY(name)`，页面中的记录：

```
记录: [Alice, 1], [Alice, 2], [Alice, 3], [Bob, 5], [Carol, 7]
前缀: "Alice" → 3 条记录共享同一前缀
```

如果 `n_fields=1`（只取 `name` 列），AHI 不会缓存 3 条，而是：

```
left_side=true:  缓存每组最左记录
  hash("Alice") → [Alice, 1]    ← 等值/大于查询从此开始
  hash("Bob")   → [Bob, 5]
  hash("Carol") → [Carol, 7]

left_side=false: 缓存每组最右记录
  hash("Alice") → [Alice, 3]    ← 小于查询从此开始
  hash("Bob")   → [Bob, 5]
  hash("Carol") → [Carol, 7]
```

**为什么需要 `left_side` 而不是直接缓存所有记录？**

1. **内存节省**：`n_fields` 通常等于索引列数。非唯一索引可能有很多重复值，缓存全部记录会占用大量 AHI 内存
2. **B+Tree 定位特性**：B+Tree 的叶子节点记录是有序排列的。定位到组边界后，线性扫描相邻记录的开销极低（cache line 预取友好）
3. **范围查询支持**：`left_side=true` 的边界记录可以作为范围查询的起点

`n_bytes` 处理部分前缀场景：

```cpp
// 假设 KEY(name(10)) — 10 字节前缀索引
// 如果 n_fields=1，n_bytes=10
// AHI 只取 name 的前 10 字节做 hash
// 两条 name="abcdefghijklmn" 和 "abcdefghijxyz" 前缀相同 → hash 相同
```

### 1.4 缓冲页 AHI 控制块 — buf_block_t::ahi_t

每个 Buffer Pool block 上的 AHI 信息：

```cpp
// buf0buf.h:1802
struct ahi_t {
  /* 推荐的（来自索引的）前缀参数 */
  std::atomic<btr_search_prefix_info_t> recommended_prefix_info;

  /* 实际已经用于构建 hash 的前缀参数 */
  std::atomic<btr_search_prefix_info_t> prefix_info;

  /* 指向该页所属的索引对象 */
  /* nullptr = 未缓存到 AHI */
  std::atomic<dict_index_t *> index;
};
```

为什么需要 `recommended_prefix_info` 和 `prefix_info` 两个字段？

```
1. 索引级 btr_search_t 定期分析访问模式 → 更新 recommended_prefix_info
2. AHI 构建时读取 recommended_prefix_info → 构建 hash → 写入 prefix_info
3. 如果 recommended_prefix_info ≠ prefix_info → 说明前缀参数变了
   → 触发现有 AHI 条目删除 + 用新参数重新构建
```

这是一种**乐观的两阶段更新**：索引级分析持续更新推荐参数，实际构建时做最终判断。

### 1.5 哈希表节点 — ha_node_t

```cpp
// ha0ha.h:164
struct ha_node_t {
  uint64_t hash_value;   /* 存储的完整 hash 值（用于冲突检测） */
  ha_node_t *next;       /* 链式下一节点（桶内链表） */
  const rec_t *data;     /* 指向 InnoDB 物理记录 */
};
```

**data 指针的特殊性**：

`rec_t*` 指向的是 Buffer Pool 中页帧上的物理记录偏移。由于 InnoDB 使用固定大小的页面（默认 16KB），可以通过记录指针反查出所属的 `buf_block_t`：

```c
// buf0buf.h:880 — buf_block_from_ahi()
static inline buf_block_t *buf_block_from_ahi(const byte *ptr) {
  /* ptr 属于某页帧，利用对齐和页面大小反查 */
  ulint offset = ut_align_offset(ptr, UNIV_PAGE_SIZE);
  byte *page = const_cast<byte *>(ut_align_down(ptr, UNIV_PAGE_SIZE));
  return static_cast<buf_block_t *>(buf_pool_from_page(page));
}
```

这意味着**页帧必须始终固定在 Buffer Pool 中**——一旦被驱逐，指向它的 `ha_node_t::data` 就变成野指针。AHI 通过以下机制保证：

- 页面被驱逐前，先调用 `btr_search_drop_page_hash_index()` 删除该页上所有 AHI 条目
- AHI 条目的删除和页面驱逐在同一互斥锁保护下完成
- 因此 AHI 只存在于不可驱逐或固定页面上

---

## 2. 查找路径

### 2.1 B+Tree 搜索入口 — btr_cur_search_to_nth_level()

```cpp
// btr0btr.cc — 简化结构
dberr_t btr_cur_search_to_nth_level(
    dict_index_t *index, ulint level,
    const dtuple_t *tuple, ulint mode,
    ulint latch_mode, btr_cur_t *cursor,
    ulint has_search_latch, mtr_t *mtr) {

  /* ── 步骤 1：尝试 AHI 快速查找 ── */
  if (latch_mode <= BTR_MODIFY_PREV &&
      srv_adaptive_hash_index) {

    if (btr_search_guess_on_hash(
            tuple, mode, latch_mode,
            cursor, has_search_latch, mtr)) {
      /* AHI 命中 → 直接返回，cursor 已定位到记录 */
      return DB_SUCCESS;
    }
  }

  /* ── 步骤 2：AHI 未命中 → 完整 B+Tree 遍历 ── */
  /* 从根节点逐级向下，锁定中间节点和叶子节点 */
  ...

  /* ── 步骤 3：遍历结束后，更新 AHI 统计信息 ── */
  /* 为下一次查找积累 AHI 构建决策所需的数据 */
  btr_search_info_update(cursor);
}
```

调用的前提条件 `latch_mode <= BTR_MODIFY_PREV` 意味着只有**读操作**和**乐观修改操作**才走 AHI 路径。悲观修改（需要分裂/合并的修改）不尝试 AHI，因为这类操作大概率已持有较高等级的 latch，避免死锁。

### 2.2 AHI 快速查找 — btr_search_guess_on_hash()

这是 AHI 最关键的函数，定义在 `btr0sea.cc:804`：

```cpp
bool btr_search_guess_on_hash(
    const dtuple_t *tuple, ulint mode,
    ulint latch_mode, btr_cur_t *cursor,
    ulint has_search_latch, mtr_t *mtr) {

  /* ── 步骤 1：快速否决 ── */

  /* 全局禁用 */
  if (!btr_search_enabled) return false;                       // 809

  btr_search_t *info = index->search_info;
  /* 该索引无 AHI 潜力 */
  if (info->n_hash_potential == 0) return false;              // 823

  /* ── 步骤 2：计算 hash 值 ── */
  const auto prefix_info = info->prefix_info.load();          // 825

  /* 判断是否能使用 AHI 前缀（检查元组字段数是否足够） */
  if (dtuple_get_n_fields(tuple) < prefix_info.n_fields ||
      (prefix_info.n_bytes > 0 &&
       dtuple_get_n_fields(tuple) == prefix_info.n_fields)) {
    /* 字段数不够 → 不能使用 AHI */
    return false;
  }

  /* 用 dtuple_hash() 计算 hash 值 */
  /* 内置 hash 种子，防止恶意构造的 key 导致 hash 冲突攻击 */
  const auto hash_value =
      dtuple_hash(tuple, prefix_info.n_fields, prefix_info.n_bytes,
                  btr_hash_seed_for_record(index));             // 849

  /* ── 步骤 3：尝试获取 AHI 分区 S 锁（不等待！）─────── */
  /* 这是关键：不等待意味着 AHI 永远不会成为阻塞点 */
  if (!btr_search_s_lock_nowait(index, UT_LOCATION_HERE)) {   // 853
    /* AHI 锁忙 → 跳过 AHI，走 B+Tree */
    return false;
  }

  /* ── 步骤 4：在 hash 表中查找 ── */
  rec = (rec_t *)ha_search_and_get_data(
      btr_get_search_table(index), hash_value);                // 870

  if (rec == nullptr) {
    /* hash miss → 释放锁，走 B+Tree */
    btr_search_s_unlock(index);
    return false;                                              // 878
  }

  /* ── 步骤 5：从 rec 指针反查缓冲块 ── */
  buf_block_t *block = buf_block_from_ahi(rec);               // 880

  /* ── 步骤 6：获取页面的 latch（同样不等待）─────── */
  /* AHI 条目的 rec_t* 可能已被 BUF_FREE 的信号标记为无效 */
  if (!buf_page_get_known_nowait(
          latch_mode, block, cache_only,
          dict_index_is_clust_rec(rec), UT_LOCATION_HERE, mtr)) { // 883
    /* 页面不可用 → 释放 AHI 锁，走 B+Tree */
    btr_search_s_unlock(index);
    return false;
  }

  /* ⚠️ 此时已持有页面 latch，但尚未释放 AHI 锁 */
  /* 这形成了一个 S-latch → S-latch 的持有顺序：AHI < page */
  /* 这是严格防止的：不能 AHI → page 持有顺序反过来 */

  /* ── 步骤 7：验证 hash 猜测是否正确 ── */
  if (!btr_search_check_guess(cursor, has_search_latch,
                              tuple, mode, mtr)) {            // 919
    /* 猜测错误（hash 冲突或前缀不精确）→ 释放所有锁，走 B+Tree */
    return false;
  }

  /* ── 步骤 8：成功！ ── */
  info->last_hash_succ = true;
  cursor->flag = BTR_CUR_HASH;
  btr_search_s_unlock(index);

  /* 更新性能统计 */
  MONITOR_INC(MONITOR_ADAPTIVE_HASH_SEARCH);

  return true;                                                 // 983
}
```

**为什么使用 `_nowait` 锁？**

AHI 是一个"有更好，没有也行的优化"。如果 AHI 锁上有等待，说明**当前 AHI 分区正在被修改（构建/删除）**——这通常持续极短时间。此时等待不如直接走 B+Tree 遍历：

```
time
├── 线程 A: 查找 → 尝试 AHI 锁 → 锁忙 → 走 B+Tree (1~3μs 额外)
└── 线程 B: 构建 AHI → 持有 X 锁 (10~100μs)
   └── 如果线程 A 等待 → 被阻塞 10~100μs → 更差！
```

```
场景          | AHI 命中 | AHI 不命中（走 B+Tree）
──────────────|──────────|───────────────────────
等值查询（热） | ~0.3μs  | ~10μs （3 层 B+Tree）
范围查询（冷） | 不命中   | ~50μs
```

**验证步骤 `btr_search_check_guess` 的精确性**：

```c
// btr0sea.cc:706
static bool btr_search_check_guess(
    btr_cur_t *cursor, ulint has_search_latch,
    const dtuple_t *tuple, ulint mode, mtr_t *mtr) {

  rec_t *rec = btr_cur_get_rec(cursor);

  /* 检查 hash 定位到的记录与目标元组的匹配程度 */
  /* 使用 cmp_dtuple_rec_with_match_low() 逐字段比较 */
  ulint matched_fields;
  ulint matched_bytes;
  int cmp = cmp_dtuple_rec_with_match_low(
      tuple, rec, &matched_fields, &matched_bytes);

  /* 根据 mode（PAGE_CUR_LE, PAGE_CUR_GE 等）判断比较结果是否匹配 */
  /* mode = PAGE_CUR_GE → rec >= tuple 算匹配 */
  /* mode = PAGE_CUR_LE → rec <= tuple 算匹配 */

  if (mode == PAGE_CUR_GE) {
    return cmp >= 0;
  } else if (mode == PAGE_CUR_L) {
    return cmp < 0;
  } else if (mode == PAGE_CUR_LE) {
    return cmp <= 0;
  } else if (mode == PAGE_CUR_G) {
    return cmp > 0;
  }
  return false;
}
```

这里实际上**没有做精确的 hash 值匹配**——只比较了记录和元组。如果 hash 冲突导致错误的记录，`cmp_dtuple_rec_with_match_low` 会返回错误的方向，从而触发 B+Tree 回退。这就是为什么 hash 表中存储了完整的 `hash_value`（`ha_node_t::hash_value`）用于冲突检测。

### 2.3 调用链总结

```
SQL: SELECT * FROM t WHERE pk = 42
  └─ row_search_mvcc()
      └─ btr_pcur_open_with_no_init()
          └─ btr_cur_search_to_nth_level(index, tuple, ...)
              ├─ [AHI 尝试] btr_search_guess_on_hash()
              │   ├─ n_hash_potential == 0? → 跳过
              │   ├─ dtuple_hash() → hash_value
              │   ├─ btr_search_s_lock_nowait() → 失败? → 跳过
              │   ├─ ha_search_and_get_data() → rec_t*
              │   ├─ buf_block_from_ahi() → buf_block_t*
              │   ├─ buf_page_get_known_nowait() → latch page
              │   └─ btr_search_check_guess() → 正确?
              │       └─ 正确! → cursor 就位，返回
              │       └─ 错误! → fall through
              └─ [B+Tree 遍历] 完整树搜索
                  └─ btr_search_info_update()
                      └─ btr_search_info_update_slow()
                          └─ [可能触发] btr_search_build_page_hash_index()
```

---

## 3. 构建路径

### 3.1 构建触发条件 — 两阶段决策

AHI 不是一次构建完成的，而是通过两阶段条件判断：

**阶段 1：索引级统计（btr_search_info_update → btr_search_info_update_slow）**

```cpp
// btr0sea.cc:649
static void btr_search_info_update_slow(btr_cur_t *cursor) {
  btr_search_t *info = index->search_info;

  /* 每 17 次调用才进入这个慢路径 */
  /* info->hash_analysis 每次调用递增 */
  if (info->hash_analysis < BTR_SEARCH_HASH_ANALYSIS) {
    info->hash_analysis++;
    return;
  }
  info->hash_analysis = 0;

  /* 更新前缀选择信息 */
  btr_search_info_update_hash(cursor);

  /* 判断是否需要构建 AHI */
  if (info->n_hash_potential < BTR_SEARCH_BUILD_LIMIT) {
    /* 潜力不足 → 不构建 */
    info->last_hash_succ = false;
    return;
  }

  /* 为索引的每个有"帮助"数据的缓冲页触发构建 */
  ...
}
```

`BTR_SEARCH_HASH_ANALYSIS = 17` 和 `BTR_SEARCH_BUILD_LIMIT = 100` 的定义：

```cpp
// btr0sea.cc:94
constexpr uint64_t BTR_SEARCH_BUILD_LIMIT = 100;
// btr0sea.cc:91
constexpr uint64_t BTR_SEARCH_HASH_ANALYSIS = 17;
```

**阶段 1.5：前缀选择算法（btr_search_info_update_hash）**

```cpp
// btr0sea.cc:406
static void btr_search_info_update_hash(btr_cur_t *cursor) {
  btr_search_t *info = index->search_info;

  /* 获取上次 B+Tree 搜索中的匹配信息 */
  /* up_match: 从最左字段算起，完全匹配的字段数（向上方向） */
  /* low_match: 从最左字段算起，完全匹配的字段数（向下方向） */
  ulint up_match = cursor->up_match;
  ulint up_bytes = cursor->up_bytes;
  ulint low_match = cursor->low_match;
  ulint low_bytes = cursor->low_bytes;

  /* ── 核心决策：选择最优的 prefix_info ── */
  /* 基于 B+Tree 搜索中实际使用的匹配信息 */

  /* 当前推荐的前缀参数 */
  auto prefix_info = info->prefix_info.load();
  uint16_t cur_n_fields = prefix_info.n_fields;
  uint32_t cur_n_bytes = prefix_info.n_bytes;
  bool cur_left_side = prefix_info.left_side;

  /* 如果 up_match 或 low_match 与当前前缀匹配 */
  bool low_matches_prefix = (low_match == cur_n_fields &&
                             low_bytes >= cur_n_bytes);
  bool up_matches_prefix = (up_match == cur_n_fields &&
                            up_bytes >= cur_n_bytes);

  /* 增量更新 n_hash_potential */
  if (prefix_info.left_side) {
    /* left_side: 需要 low 方向匹配且 up 方向不匹配 → 说明这是一个"从左边"的访问 */
    if (!low_matches_prefix && up_matches_prefix) {
      info->n_hash_potential++;
      return;
    }
  } else {
    /* right_side: 需要 up 方向匹配且 low 方向不匹配 */
    if (low_matches_prefix && !up_matches_prefix) {
      info->n_hash_potential++;
      return;
    }
  }

  /* ── 不匹配 → 尝试调整前缀 ── */
  /* 选择 up_match 和 low_match 中较大的作为新前缀 */
  if (up_match >= low_match) {
    new_n_fields = up_match;
    new_n_bytes = up_bytes;
    new_left_side = true;
  } else {
    new_n_fields = low_match;
    new_n_bytes = low_bytes;
    new_left_side = false;
  }

  ...
  /* 如果前缀参数变了 → 重置 n_hash_potential = 0 */
  /* 因为用新前缀需要重新积累统计 */
  info->n_hash_potential.store(0);
  info->prefix_info.store({new_n_fields, new_n_bytes, new_left_side});
}
```

**前缀选择的启发式算法**：

```
B+Tree 搜索后，cursor 记录了两个方向的匹配程度:
  up_match:  从最左列开始，上和上一条记录匹配了几个字段
  low_match: 从最左列开始，下和下一条记录匹配了几个字段

例: KEY(a, b)
搜索: WHERE a = 1 AND b = 50

假设叶子页中有记录:
  (1, 48) ← 上一条
  (1, 50) ← 命中记录
  (1, 55) ← 下一条

up_match = 2 (a=1, b=50 和 a=1, b=48 都匹配 a, 但 b 不匹配上下游)
low_match = 2 (a=1, b=50 和 a=1, b=55 同理)

实际计算：因为 a 列完全匹配（上/下），b 列部分匹配但方向不同
→ 选择 larger of up_match/low_match 作为 n_fields
→ 如果 up_match >= low_match → left_side = true
→ n_fields = 1 (只有 a 列完全匹配，b 列只有一个方向匹配)
```

**阶段 2：页面级统计（btr_search_update_block_hash_info）**

即使索引级统计显示 `n_hash_potential >= 100`，每个缓冲页还需要满足页面级条件：

```cpp
// btr0sea.cc:554
static bool btr_search_update_block_hash_info(
    btr_cur_t *cursor, buf_block_t *block, dict_index_t *index) {

  /* n_hash_helps: 该页被分析的次数 */
  /* n_recs: 该页的记录数 */
  /* 条件: n_hash_helps * BTR_SEARCH_PAGE_BUILD_LIMIT > n_recs */
  if (block->n_hash_helps > n_recs / BTR_SEARCH_PAGE_BUILD_LIMIT) {

    /* 更新推荐前缀 */
    block->ahi.recommended_prefix_info.store(
        index->search_info->prefix_info.load());

    /* 检查是否需要重新构建 */
    auto prefix_info = block->ahi.prefix_info.load();
    auto recommended = block->ahi.recommended_prefix_info.load();
    if (recommended != prefix_info) {
      /* 前缀变了 → 需要重新构建 */
      return true;
    }
  }

  return false;
}
```

`BTR_SEARCH_PAGE_BUILD_LIMIT` 也是 100。因此每页需要至少被帮助 `n_recs / 100` 次才触发构建。对于有 455 条记录的页，需要至少 `455 / 100 = 5` 次帮助才有资格。

### 3.2 实际构建 — btr_search_build_page_hash_index()

```cpp
// btr0sea.cc:1404
static void btr_search_build_page_hash_index(
    dict_index_t *index, buf_block_t *block, bool update) {

  const auto prefix_info = block->ahi.recommended_prefix_info.load();

  /* ── 步骤 1：检查是否需要删除旧的 AHI ── */
  if (block->ahi.index && block->ahi.prefix_info.load() != prefix_info) {
    /* 前缀参数变了 → 先清空该页已有的 AHI 条目 */
    btr_search_drop_page_hash_index(block);
    /* 此时 block->ahi.index = nullptr */
  }

  /* ── 步骤 2：扫描页面记录，计算每个 group 的 hash 值 ── */

  /* 预分配最大可能数量的数组 */
  /* n_cached = 该页记录的候选条数 */
  ulint n_cached = 0;
  hash_value_t hashes[PAGE_MAX_RECS + 1];
  const rec_t *recs[PAGE_MAX_RECS + 1];

  /* 从 infimum 下一条开始扫描 */
  rec_t *rec = page_rec_get_next(page_get_infimum_rec(page));

  while (true) {
    rec_t *next_rec = page_rec_get_next(rec);

    if (page_rec_is_supremum(next_rec)) {
      /* 最后一条记录的处理 */
      if (!prefix_info.left_side) {
        /* right_side: 缓存每个 group 的最后一个记录 */
        hashes[n_cached] = hash_value;
        recs[n_cached] = rec;
        n_cached++;
      }
      break;
    }

    /* 计算下一条记录的 hash */
    hash_value_t next_hash_value = rec_hash(next_rec, prefix_info);

    /* 判断是否处于 group 边界 */
    /* 如果本记录和下一页记录的 hash 不同 → group boundary */
    if (hash_value != next_hash_value) {
      if (prefix_info.left_side) {
        /* 缓存本 group 的第一条记录 */
        hashes[n_cached] = hash_value;
        recs[n_cached] = rec;
        n_cached++;
      }
      /* right_side: 不缓存当前 — 缓存会在遍历到 group 结束时触发 */
      else if (prefix_info.left_side_was_set) {
        /* right_side: 缓存上个 group 的最后一条记录 */
        hashes[n_cached] = prev_hash_value;
        recs[n_cached] = prev_rec;
        n_cached++;
      }
    }

    rec = next_rec;
    hash_value = next_hash_value;
  }

  /* ── 步骤 3：获取 AHI X 锁（不等待）───── */
  /* X 锁意味着其他线程不能读该分区的 hash 表 */
  if (!btr_search_x_lock_nowait(index, UT_LOCATION_HERE)) {
    /* 失败 → 跳过构建，下次再试 */
    return;
  }

  /* ── 步骤 4：插入 hash 表 ── */
  for (size_t i = 0; i < n_cached; i++) {
    ha_insert_for_granularity(table, hash_table,
                               hashes[i], block, recs[i]);
    /* ha_insert_for_granularity 内部:
     *   1. 计算桶位置: bucket = hashes[i] % table->n_cells
     *   2. 创建 ha_node_t 节点
     *   3. 插入链表头部
     */
  }

  /* ── 步骤 5：更新 block 状态 ── */
  block->ahi.index = index;            /* 标记该页已缓存 */
  block->ahi.prefix_info = prefix_info; /* 记录实际使用的前缀 */
  index->search_info->ref_count++;     /* 增加索引引用计数 */

  btr_search_x_unlock(index);
}
```

**关键设计：为什么不缓存所有记录？**

对于非唯一索引，可能有数百条记录共享相同的前缀（如 `KEY(status)` 的 status 只有少数几种值）。如果缓存所有记录，hash 表会膨胀到产生大量冲突。相反，只缓存 group 边界记录：

```
页面记录: [A][A][A][A][B][B][C][D][D][D][D][D]
                    ↑        ↑  ↑        ↑
left_side=true:     A        B  C        D
left_side=false:        A     B  C           D
```

查找流程：
1. hash("A") → 返回 [A] 第一条记录
2. 比较实际元组 → 如果不等于 [A] 且 > [A]，在 B+Tree 页内向后扫描
3. 由于页面已在 BP 中（步骤 6 已 latch），向后扫描是 O(n) 但 n 通常很小（一条 cache line 64 字节可容纳多个相邻记录）

---

## 4. 删除路径

当 AHI 条目不再有效时，必须彻底清除以避免野指针。

### 4.1 页面驱逐时的清理 — btr_search_drop_page_hash_index()

这是最常用的删除路径。Buffer Pool 在驱逐页面（`buf_LRU_free_page`）前必须删除该页上的 AHI 条目：

```cpp
// btr0sea.cc:1005
void btr_search_drop_page_hash_index(buf_block_t *block, bool force) {

  /* ── 步骤 1：快速检查该页是否有 AHI 条目 ── */
  const auto index = block->ahi.index.load();
  if (index == nullptr) return;  /* 没有缓存 → 直接返回 */

  /* ── 步骤 2：扫描页面，收集所有 hash 值 ── */
  /* 需要和构建完全相同的 hash 算法 */
  mtr_t mtr;
  mtr_start(&mtr);

  hash_value_t hashes[PAGE_MAX_RECS + 1];
  ulint n_cached = 0;

  rec_t *rec = page_rec_get_next(page_get_infimum_rec(page));
  while (!page_rec_is_supremum(rec)) {
    hash_value_t hash_value = rec_hash(rec, block->ahi.prefix_info);

    /* 去重：只有 group 边界才需要删除 */
    rec_t *next_rec = page_rec_get_next(rec);
    if (page_rec_is_supremum(next_rec) ||
        rec_hash(next_rec, block->ahi.prefix_info) != hash_value) {

      hashes[n_cached] = hash_value;
      recs[n_cached] = rec; /* 用于验证删除正确性 */
      n_cached++;
    }

    rec = next_rec;
  }

  mtr_commit(&mtr);

  /* ── 步骤 3：获取分区 X 锁 ── */
  btr_search_x_lock(index, UT_LOCATION_HERE);

  /* ── 步骤 4：批量删除 hash 条目 ── */
  auto hash_table = btr_get_search_table(index);
  for (ulint i = 0; i < n_cached; i++) {
    /* ha_remove_a_node_to_page: 删除 hash 表中指向指定页面的所有节点 */
    ha_remove_a_node_to_page(hash_table, hashes[i],
                             block->frame);  /* 传页面帧地址，匹配所有属于该页的节点 */
  }

  /* ── 步骤 5：更新状态 ── */
  btr_search_set_block_not_cached(block);
  /* 这会将:
   *   block->ahi.index = nullptr
   *   block->ahi.prefix_info = 0
   *   并递减 index->search_info->ref_count
   */

  btr_search_x_unlock(index);
}
```

**清除链是怎样的？**

`ha_remove_a_node_to_page()` 遍历 hash 桶的链表，删除所有 `node->data` 属于该页帧的节点：

```c
// ha0ha.cc — 简化
void ha_remove_a_node_to_page(hash_table_t *table, hash_value_t hash,
                              const byte *page) {
  ha_node_t **prev = ha_chain_get_nth_addr(table, hash, bucket_no);
  ha_node_t *node = *prev;

  while (node) {
    if (ut_align_down(node->data, UNIV_PAGE_SIZE) == page) {
      /* 找到指向该页的节点 → 删除 */
      *prev = node->next;     /* 链表摘除 */
      mem_heap_free(table->heap, node);  /* 归还到堆 */
      break;                   /* 每个 hash 值只缓存了一个节点 */
    }
    prev = &node->next;
    node = node->next;
  }
}
```

### 4.2 Record 移动时的更新 — btr_search_update_hash_on_move()

B+Tree 在节点分裂或合并时，记录会从一个页移动到另一个页。此时 AHI 条目需要从旧页迁移到新页：

```cpp
// btr0sea.cc:1580
void btr_search_update_hash_on_move(
    buf_block_t *new_block, buf_block_t *block,
    dict_index_t *index) {

  /* ── 步骤 1：从旧页删除所有 AHI 条目 ── */
  btr_search_drop_page_hash_index(block);

  /* ── 步骤 2：在新页上重新构建 ── */
  btr_search_build_page_hash_index(index, new_block, true);
}
```

为什么不用"更新指针"而是"全删重建"？

因为记录在页内的偏移变了（新页面可能用不同的 slot 数组），`ha_node_t::data` 指向的是旧页帧上的偏移，无法廉价地映射为新的偏移。而且 B+Tree 分裂/合并通常是低频操作，全删重建的开销微不足道。

### 4.3 全局禁用 — btr_search_disable()

当 `innodb_adaptive_hash_index` 被设置为 OFF，或需要清理整个 AHI 时：

```cpp
// btr0sea.cc:314
bool btr_search_disable() {

  /* 步骤 1：X-latch 所有 AHI 分区（全局不可用） */
  btr_search_x_lock_all(UT_LOCATION_HERE);

  /* 步骤 2：清空所有分区 hash 表的堆 */
  for (size_t i = 0; i < btr_ahi_parts; i++) {
    auto part = btr_search_sys->parts[i];
    mem_heap_empty(part.hash_table->heap);
    memset(part.hash_table->cells, 0,
           part.hash_table->n_cells * sizeof(void *));
  }

  /* 步骤 3：遍历所有缓冲块，清除 block->ahi.index */
  /* 这是最昂贵的步骤：需要扫描 BP 中的每个页面 */
  buf_pool_clear_hash_index();  // buf0buf.cc

  /* 步骤 4：全局禁用标记 */
  btr_search_enabled = false;

  btr_search_x_unlock_all();
}

// buf0buf.cc — buf_pool_clear_hash_index()
void buf_pool_clear_hash_index() {
  for (auto chunk : buf_pool->chunks) {
    for (auto block = chunk->blocks;
         block < chunk->blocks + chunk->size;
         block++) {
      btr_search_set_block_not_cached(block);
    }
  }
}
```

**全局禁用为什么昂贵？**

Buffer Pool 可能有几十万个页面。`buf_pool_clear_hash_index()` 遍历所有块、检查并清除 ahi 状态，在几百 GB BP 的系统上可能耗时几十毫秒。但通常禁用 AHI 只发生一次（启动配置或 DBA 手动操作），所以这个开销可接受。

---

## 5. 并发控制与死锁预防

### 5.1 锁模型

```
AHI 分区: parts[i]
  └── latch (rw_lock_t)
      ├── S-lock: 多个查找线程可同时读（btr_search_guess_on_hash）
      └── X-lock: 单个线程构建/删除（btr_search_build / drop）
```

**查找路径的锁顺序**（`btr0sea.cc:853-990`）：

```
1. btr_search_s_lock_nowait(part)     ← AHI 分区 S 锁
2. ha_search_and_get_data()           ← 读 hash 表（无锁，依赖 AHI X 锁排除写者）
3. buf_page_get_known_nowait()        ← 页面块 S/X 锁（对数据页）
4. btr_search_check_guess()           ← 读记录（页面 S/X 锁已持有）
5. btr_search_s_unlock(part)          ← 释放 AHI S 锁
```

**构建路径的锁顺序**（`btr0sea.cc:1529-1575`）：

```
1. btr_search_x_lock(part)            ← AHI 分区 X 锁
2. ha_insert_for_granularity()        ← 写 hash 表
3. btr_search_x_unlock(part)          ← 释放 AHI X 锁
```

### 5.2 为什么 AHI 不会死锁？

因为 AHI 的锁获取模式是**无等待（nowait）和固定顺序**：

- **查找路径**使用 `_nowait`：即使 AHI 锁被持有，也不会阻塞，直接走 B+Tree，不会 AHI 等 page → page 等 AHI 的闭环
- **构建路径**持有 AHI X 锁时不获取其他锁：构建过程只是扫描已经固定在 BP 中的页帧，计算 hash 并插入 hash 表，不涉及新的页面 latch 获取
- **删除路径**在页面驱逐前执行：删除时获取 X 锁，但此时页面已经标记为"可驱逐"，不会有其他线程同时在操作该页面

### 5.3 伪删除问题

由于 AHI 使用 `_nowait`，有一种罕见场景：

```
时刻 1: 线程 A 查找 → AHI S-lock ✓ → 读取 hash → 得到 rec_t*
时刻 2: 线程 B 驱逐页面 → 删除 AHI 条目 → 释放 X-lock
时刻 3: 线程 A 获取页面 latch → 页面已被驱逐！→ buf_page_get_known_nowait 失败
```

通过 `buf_page_get_known_nowait()` 失败来检测：如果页面已被释放，`buf_page_get_known_nowait` 返回 false，AHI 查询回退走 B+Tree。这是一种**乐观的检验**——假设大多数情况下页面仍在 BP 中。

---

## 6. 性能统计与监控

### 6.1 源码级统计

```cpp
// btr0sea.h:76 — 编译时条件统计
#ifdef UNIV_SEARCH_PERF_STAT
  std::atomic<ulint> n_hash_succ;   /* hash 搜索成功次数 */
  std::atomic<ulint> n_hash_fail;   /* hash 搜索失败次数 */
  std::atomic<ulint> n_searches;    /* 总搜索次数 */
#endif

// btr0sea.cc:70-71 — 全局统计（无条件编译）
ulint btr_search_n_succ = 0;
ulint btr_search_n_hash_fail = 0;
```

每次 AHI 查找更新：

```cpp
// btr_search_guess_on_hash 中 — btr0sea.cc:890
// 失败时预设:
info->n_hash_fail++;

// 成功时修正 (btr0sea.cc:981-985):
info->n_hash_fail--;
info->n_hash_succ++;
info->last_hash_succ = true;
```

### 6.2 SHOW ENGINE INNODB STATUS 输出

```
-------------------------------------
INSERT BUFFER AND ADAPTIVE HASH INDEX
-------------------------------------
Ibuf: size 1, free list len 0, seg size 2,
0 merges
merged operations:
 insert 0, delete mark 0, delete 0
discarded operations:
 insert 0, delete mark 0, delete 0
Hash table size 34679, node heap has 1 buffer(s)
Hash table size 34679, node heap has 0 buffer(s)
Hash table size 34679, node heap has 0 buffer(s)
...
0.00 hash searches/s, 0.00 non-hash searches/s
```

**关键解读**：

- `Hash table size 34679`：每个分区的 hash 表容量（2 的幂次，由 `btr_search_sys_create()` 中 `innodb_adaptive_hash_index_parts` 决定）
- `node heap has N buffer(s)`：每个分区已分配的堆 buffer 数量（越多说明 AHI 条目越多）
- `hash searches/s`：当前 AHI 命中率。如果远低于 `non-hash searches/s`，AHI 可能没有发挥应有的作用
- 每个分区一行——如果有 8 个分区，则有 8 行 `Hash table size ...`

### 6.3 Performance Schema 监控

```sql
-- AHI 相关的 wait event
SELECT * FROM performance_schema.wait_events_by_instance
WHERE event_name LIKE '%btr_search%';

-- AHI 分区 latch 等待统计
SELECT * FROM performance_schema.rwlock_instances
WHERE name LIKE '%btr_search%';
```

如果 `btr_search_latch` 的等待时间显著，说明 AHI 分区争用严重，考虑：
1. 增大 `innodb_adaptive_hash_index_parts`
2. 或禁用 AHI

---

## 7. 内存占用估算

AHI 的内存消耗可以粗略估算：

```
一个 AHI 条目 (ha_node_t) = 8 (hash_value) + 8 (next) + 8 (data) = 24 字节
+ hash 表本身的上限: n_cells × 8 字节 = hash_size × 8
+ heap 管理的 buffer 块开销

假设使用默认参数:
- innodb_adaptive_hash_index_parts = 8
- 每个分区 hash_size = buf_pool_get_curr_size() / sizeof(void*) / btr_ahi_parts

对于 64GB Buffer Pool:
- hash_size ≈ 64GB / 8 / 8 ≈ 1GB 每分区 → 总内存 ≈ 8GB
- 实际条目: 取决于热页数量，通常远少于 hash_size

对于 8GB Buffer Pool:
- hash_size ≈ 8GB / 8 / 8 ≈ 128MB 每分区 → 总内存 ≈ 1GB
```

因此 AHI 可能消耗 Buffer Pool 的 1%-3% 用于自身。如果 BP 本身紧张（small buffer pool with large working set），AHI 的内存开销可能会加剧 page 竞争。

---

## 8. 调优与限制

### 8.1 关键参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `innodb_adaptive_hash_index` | ON | 全局 AHI 启用/禁用 |
| `innodb_adaptive_hash_index_parts` | 8 | AHI 分区数（1-512） |

### 8.2 何时该禁用 AHI

```sql
SET GLOBAL innodb_adaptive_hash_index = OFF;
```

适合禁用的场景：

1. **高并发写入**：`btr_search_drop_page_hash_index` 在每次页面驱逐/分裂时调用，如果写入量巨大，AHI 维护（构建+删除）本身会成为 CPU 热点
2. **范围查询为主**：`WHERE id BETWEEN 1 AND 10000` 这种查询不经过 AHI，但 AHI 仍然在为其他查询消耗内存
3. **BP 压力大**：AHI 占用 BP 宝贵的内存资源
4. **云 RDS 实例**：云上实例的 bp 通常按成本配置，AHI 的额外内存开销可能不值得

### 8.3 常见问题诊断

**AHI 命中率低**：

```
SELECT (SUM(hash_searches) - SUM(non_hash_searches)) / SUM(hash_searches) AS hit_ratio
FROM information_schema.INNODB_METRICS
WHERE name LIKE 'adaptive_hash_%';
```

如果命中率 < 50% 且 AHI 维护开销高，考虑禁用。

**AHI latch 争用**：

```
SHOW ENGINE INNODB MUTEX;
```

如果看到 `btr_search_latch` 的 `spin_waits` 很高，尝试增加分区数或禁用 AHI。

---

## 9. 源码索引

| 函数/结构 | 文件 | 行号 | 关键作用 |
|-----------|------|------|---------|
| `btr_search_t` struct | `btr0sea.h` | 46 | 索引级 AHI 统计信息 |
| `btr_search_sys_t` class | `btr0sea.h` | 93 | 全局 AHI 系统（含分区） |
| `btr_search_sys_t::search_part_t` | `btr0sea.h` | 93 | 单个 AHI 分区 |
| `BTR_SEARCH_HASH_ANALYSIS` | `btr0sea.cc` | 91 | 17 — 分析触发频率 |
| `BTR_SEARCH_BUILD_LIMIT` | `btr0sea.cc` | 94 | 100 — 构建触发阈值 |
| `btr_search_guess_on_hash()` | `btr0sea.cc` | 804 | AHI 快速查找主路径 |
| `btr_search_check_guess()` | `btr0sea.cc` | 706 | 验证 hash 猜测 |
| `btr_search_info_update_slow()` | `btr0sea.cc` | 649 | 索引级 AHI 统计更新 |
| `btr_search_info_update_hash()` | `btr0sea.cc` | 406 | 前缀选择算法 |
| `btr_search_update_block_hash_info()` | `btr0sea.cc` | 554 | 页面级构建判断 |
| `btr_search_build_page_hash_index()` | `btr0sea.cc` | 1404 | 实际构建 AHI 条目 |
| `btr_search_drop_page_hash_index()` | `btr0sea.cc` | 1005 | 页面驱逐时删除 AHI |
| `btr_search_update_hash_on_move()` | `btr0sea.cc` | 1580 | 记录移动时更新 AHI |
| `btr_search_disable()` | `btr0sea.cc` | 314 | 全局禁用 AHI |
| `buf_block_from_ahi()` | `buf0buf.h` | 880 | rec_t* 反查 buf_block_t* |
| `btr_search_prefix_info_t` | `buf0buf.h` | 1739 | 前缀参数结构体 |
| `buf_block_t::ahi_t` | `buf0buf.h` | 1802 | 缓冲页 AHI 控制块 |
| `ha_node_t` | `ha0ha.h` | 164 | hash 表链节点 |
| `ha_search_and_get_data()` | `ha0ha.h` | 49 | hash 表查找 |
| `ha_insert_for_granularity()` | `ha0ha.h` | 95 | hash 表插入 |
| `ha_remove_a_node_to_page()` | `ha0ha.cc` | 152 | 按页帧删除 hash 条目 |
