# 17. InnoDB 自适应哈希索引 (Adaptive Hash Index, AHI)

> 本文基于 MySQL 8.0/9.0 源码，分析 InnoDB Adaptive Hash Index 的底层实现，包括数据结构、构建触发条件、哈希查找路径与删除机制。核心文件：`btr0sea.cc`、`btr0sea.h`、`buf0buf.h`、`hash0hash.h`、`ha0ha.h`。

---

## 1. 概述

InnoDB 的 AHI 是一个建立在 B+Tree 索引页之上的 **轻量级内存哈希表**，用于加速等值查询。它并不是独立于 B+Tree 的二级索引，而是对 B+Tree 中频繁访问的 key 前缀建立 hash 映射，将 `dtuple -> rec_t*` 的查找从 O(log n) 降为 O(1)。

AHI 由以下几个核心组件构成：

| 组件 | 文件 | 说明 |
|------|------|------|
| `btr_search_sys_t` | `btr0sea.h:93` | 全局 AHI 系统（含分区和哈希表） |
| `btr_search_t` | `btr0sea.h:46` | 每个索引的搜索信息统计 |
| `btr_search_prefix_info_t` | `buf0buf.h:1739` | hash 前缀参数（字段数、字节数、left_side） |
| `buf_block_t::ahi_t` | `buf0buf.h:1802` | 每个缓冲页上的 AHI 控制块 |
| `ha_node_t` | `ha0ha.h:164` | 哈希表链节点 |

---

## 2. 核心数据结构

### 2.1 全局 AHI 系统 `btr_search_sys_t`

```cpp
// btr0sea.h:93
class btr_search_sys_t {
 public:
  btr_search_sys_t(size_t hash_size);

  class search_part_t {
   public:
    void initialize(size_t hash_size);
    // 保护该 hash 分区的读写锁（S 锁用于读，X 锁用于写）
    alignas(ut::INNODB_CACHE_LINE_SIZE) rw_lock_t latch;
    // 自适应哈希表，映射 dtuple_hash -> rec_t*
    alignas(ut::INNODB_CACHE_LINE_SIZE) hash_table_t *hash_table;
    // 预分配的 buffer block，用于哈希表堆扩展
    std::atomic<buf_block_t *> free_block_for_heap;
  };

  // 分区数组：将 AHI 拆分为多个独立分区以减少锁竞争
  ut::unique_ptr_aligned<search_part_t[]> parts;
};

extern btr_search_sys_t *btr_search_sys;  // btr0sea.h:123
```

AHI 通过 **分区 (partitioning)** 设计来缓解锁竞争。每个分区有独立的 `rw_lock_t` 和 `hash_table_t`，索引通过 `index_id % btr_ahi_parts` 定位到对应分区（`btr0sea.h:319`）。

### 2.2 索引级搜索信息 `btr_search_t`

```cpp
// btr0sea.h:46
struct btr_search_t {
  // 引用计数：有多少缓冲块为此索引构建了 AHI
  std::atomic<size_t> ref_count;
  // 根页面帧的缓存猜测（上次读取的根页地址）
  buf_block_t *root_guess;
  // 超过 BTR_SEARCH_HASH_ANALYSIS(17) 时启动 hash 分析
  std::atomic<uint64_t> hash_analysis;
  // 上一次 hash 搜索是否成功
  bool last_hash_succ;
  // 连续成功/可能成功的 hash 搜索计数（0 ~ BTR_SEARCH_BUILD_LIMIT+5）
  std::atomic<uint64_t> n_hash_potential;
  // 推荐的 hash 前缀参数
  std::atomic<btr_search_prefix_info_t> prefix_info;
};
```

### 2.3 Hash 前缀参数 `btr_search_prefix_info_t`

```cpp
// buf0buf.h:1739
struct alignas(alignof(uint64_t)) btr_search_prefix_info_t {
  uint32_t n_bytes;   // 不完整字段的字节数（如 VARCHAR 部分前缀）
  uint16_t n_fields;  // 完整字段数
  bool left_side;     // true=缓存每组最左记录，false=缓存最右记录
};
```

`left_side` 的设计非常精妙：当多个记录拥有相同前缀时，AHI 只缓存该组的边界记录。 `left_side=true` 时缓存**最左**记录（适合 `>=` 查询），`left_side=false` 缓存**最右**记录（适合 `<=` 查询）。

### 2.4 缓冲页 AHI 控制块 `buf_block_t::ahi_t`

```cpp
// buf0buf.h:1802
struct ahi_t {
  // 推荐的（来自索引的）前缀参数
  std::atomic<btr_search_prefix_info_t> recommended_prefix_info;
  // 实际用于构建 hash 的前缀参数
  std::atomic<btr_search_prefix_info_t> prefix_info;
  // 该页对应的索引对象（nullptr 表示未缓存到 AHI）
  std::atomic<dict_index_t *> index;
};
```

### 2.5 哈希表链节点 `ha_node_t`

```cpp
// ha0ha.h:164
struct ha_node_t {
  uint64_t hash_value;    // 数据的 hash 值
  ha_node_t *next;        // 链式下一节点
  const rec_t *data;      // 指向 InnoDB 物理记录
};
```

---

## 3. 调用链：一条完整的 AHI 查找路径

当 `btr_cur_search_to_nth_level()` 在 B+Tree 中定位记录时（`btr0btr.cc:265`），会优先尝试 AHI 快速查找。以下为完整路径：

### 3.1 统一入口：btr_cur_search_to_nth_level

```cpp
// btr0btr.cc（伪代码结构，实际在 btr0sea.h:371 作为内联）
btr_cur_search_to_nth_level(index, ...) {
  // 先尝试 AHI 猜测
  bool ahi_success = btr_search_guess_on_hash(tuple, mode, latch_mode,
                                              cursor, 0, mtr);
  if (ahi_success) {
    // cursor 已定位到记录，直接返回
    return DB_SUCCESS;
  }
  // AHI 失败，走完整 B+Tree 搜索
  // ... B+Tree 逐级向下 ...
  // 搜索结束后，更新 AHI 统计
  btr_search_info_update(cursor);   // btr0sea.h:371
}
```

> `btr_search_info_update` 在 `btr0sea.h:337-371` 定义为 `static inline`，内部调用 `btr_search_info_update_slow`。

### 3.2 AHI 快速查找 `btr_search_guess_on_hash`

```cpp
// btr0sea.cc:804
bool btr_search_guess_on_hash(const dtuple_t *tuple, ulint mode,
                              ulint latch_mode, btr_cur_t *cursor,
                              ulint has_search_latch, mtr_t *mtr) {
  // Step 1: 快速否决条件
  if (!btr_search_enabled) return false;                    // line 809
  if (info->n_hash_potential == 0) return false;            // line 823

  // Step 2: 计算 hash 值
  const auto prefix_info = info->prefix_info.load();        // line 825
  const auto hash_value =
      dtuple_hash(tuple, prefix_info.n_fields, prefix_info.n_bytes,
                  btr_hash_seed_for_record(index));           // line 849

  // Step 3: 获取 AHI S 锁（不等待）
  if (!btr_search_s_lock_nowait(index, UT_LOCATION_HERE)) { // line 853
    return false;
  }

  // Step 4: 从 hash 表查找
  rec = (rec_t *)ha_search_and_get_data(
      btr_get_search_table(index), hash_value);              // line 870

  if (rec == nullptr) return false;                          // line 878

  // Step 5: 定位缓冲块
  buf_block_t *block = buf_block_from_ahi(rec);              // line 880

  // Step 6: 获取页面锁
  if (!buf_page_get_known_nowait(latch_mode, block, ...)) {  // line 883
    return false;
  }

  // Step 7: 验证该 hash 猜测是否正确
  if (!btr_search_check_guess(cursor, has_search_latch,
                              tuple, mode, mtr)) {           // line 919
    return false;
  }

  // Step 8: 成功 — 更新统计
  info->last_hash_succ = true;
  cursor->flag = BTR_CUR_HASH;
  info->n_hash_succ++;                                       // line 983
  return true;
}
```

**关键设计点**：

- 使用 `_nowait` 获取 AHI S 锁（`btr0sea.cc:853`）：失败时不阻塞，直接走 B+Tree 查找，避免 AHI 成为性能瓶颈。
- `ha_search_and_get_data`（`ha0ha.h:49`）直接返回 `ha_node_t::data`，不遍历链表。
- `buf_block_from_ahi`（`buf0buf.h:880`）：通过记录指针反查缓冲块地址，依赖 InnoDB 页面内记录偏移的布局约束。
- `btr_search_check_guess`（`btr0sea.cc:706`）：比较 hash 定位到的记录与目标元组，确保猜测正确。

### 3.3 AHI 构建触发

```
btr_cur_search_to_nth_level()
  └─ btr_search_info_update()              # btr0sea.h:337
       └─ btr_search_info_update_slow()    # btr0sea.cc:649
            ├─ btr_search_info_update_hash()    # btr0sea.cc:406
            │    # 分析 cursor 的 up_match/low_match
            │    # 更新 info->n_hash_potential 和 info->prefix_info
            ├─ btr_search_update_block_hash_info()  # btr0sea.cc:554
            │    # 判断该缓冲块是否需要构建 hash
            └─ btr_search_build_page_hash_index()   # btr0sea.cc:1404
                 # 实际构建 AHI 条目
```

**构建条件**（`btr0sea.cc:406` `btr_search_info_update_hash`）：

```cpp
// 当 cursor->up_match 和 cursor->low_match 的差异表明
// 前缀选择能使哈希生效时，递增 n_hash_potential
if (prefix_info.left_side
        ? (!low_matches_prefix && up_matches_prefix)
        : (low_matches_prefix && !up_matches_prefix)) {
  info->n_hash_potential++;
  return;
}
```

当 `info->n_hash_potential >= BTR_SEARCH_BUILD_LIMIT(=100)`（`btr0sea.cc:94`）且 `block->n_hash_helps > n_recs/BTR_SEARCH_PAGE_BUILD_LIMIT` 时，`btr_search_update_block_hash_info` 返回 true，触发 `btr_search_build_page_hash_index`。

### 3.4 构建过程 `btr_search_build_page_hash_index`

```cpp
// btr0sea.cc:1404
static void btr_search_build_page_hash_index(dict_index_t *index,
                                             buf_block_t *block, bool update) {
  // Step 1: 读取推荐的前缀参数
  const auto prefix_info = block->ahi.recommended_prefix_info.load();  // line 1416

  // Step 2: 处理已有 hash 的页
  if (block->ahi.index && block->ahi.prefix_info.load() != prefix_info) {
    btr_search_drop_page_hash_index(block);    // 先删除旧的
  }

  // Step 3: 扫描页面所有记录，计算 hash 值
  // left_side=true 时缓存每组第一条记录
  // left_side=false 时缓存每组最后一条记录
  for (;;) {
    const auto next_rec = page_rec_get_next(rec);
    if (page_rec_is_supremum(next_rec)) {
      if (!prefix_info.left_side) {
        hashes[n_cached] = hash_value;
        recs[n_cached] = rec;
        n_cached++;
      }
      break;
    }
    // 只在分组边界处插入 hash 条目
    if (hash_value != next_hash_value) {
      // ...
    }
  }

  // Step 4: 获取 AHI X 锁
  if (!btr_search_x_lock_nowait(index, UT_LOCATION_HERE)) {  // line 1529
    return;  // 不等待，下次再试
  }

  // Step 5: 遍历并插入 hash 表
  for (size_t i = 0; i < n_cached; i++) {
    ha_insert_for_hash(table, hashes[i], block, recs[i]);   // line 1575
  }
}
```

核心策略：**不缓存所有记录**，只为每个 equal-prefix-group 缓存一条边界记录。这样既能区分不同 key，又大幅减少内存占用。

---

## 4. AHI 删除路径

### 4.1 页面回收时的清理

```cpp
// btr0sea.cc:1005
void btr_search_drop_page_hash_index(buf_block_t *block, bool force) {
  for (;;) {
    // 检查该页是否有 AHI 条目
    const auto index = block->ahi.index.load();   // line 1007
    if (index == nullptr) return;

    // 遍历页面所有记录，计算 hash 值
    // hashes[n_cached] 存放所有唯一 hash 值
    for (rec = first_rec; !page_rec_is_supremum(rec);
         rec = page_rec_get_next_low(rec, ...)) {
      // ...
      hashes[n_cached] = hash_value;
      n_cached++;
    }

    // 获取 AHI X 锁后批量删除
    btr_search_x_lock(index, UT_LOCATION_HERE);          // line 1139

    // 从 hash 表中删除所有指向该页的条目
    for (size_t i = 0; i < n_cached; i++) {
      ha_remove_a_node_to_page(hash_table, hashes[i], page); // line 1158
    }

    btr_search_set_block_not_cached(block);               // line 1161
    return;
  }
}
```

### 4.2 Record 移动时的更新

```cpp
// btr0sea.cc:1580
void btr_search_update_hash_on_move(buf_block_t *new_block,
                                    buf_block_t *block,
                                    dict_index_t *index) {
  // 1. 从旧页删除所有 AHI 条目
  // 2. 在新页上重新构建
  btr_search_build_page_hash_index(index, new_block, true);
}
```

### 4.3 全局禁用

```cpp
// btr0sea.cc:314
bool btr_search_disable() {
  // 1. X-latch 所有 AHI 分区
  btr_search_x_lock_all(UT_LOCATION_HERE);               // line 316
  // 2. 清空所有 hash 表的堆
  // 3. 遍历所有缓冲块，清除 block->ahi.index
  buf_pool_clear_hash_index();                            // line 338
  // 4. 设置 btr_search_enabled = false
  btr_search_enabled = false;
  btr_search_x_unlock_all();
}
```

---

## 5. 性能统计与监控

```cpp
// btr0sea.h:76
#ifdef UNIV_SEARCH_PERF_STAT
  std::atomic<ulint> n_hash_succ;   // hash 搜索成功次数
  std::atomic<ulint> n_hash_fail;   // hash 搜索失败次数
  std::atomic<ulint> n_searches;    // 总搜索次数
#endif
```

`btr_search_guess_on_hash` 中（`btr0sea.cc:890`），每次失败预设 `info->n_hash_fail++`，成功后回滚并改为 `info->n_hash_succ++`（`btr0sea.cc:981-985`）。

全局统计变量（`btr0sea.cc:70-71`）：

```cpp
ulint btr_search_n_succ = 0;
ulint btr_search_n_hash_fail = 0;
```

---

## 6. 总结

AHI 的实现体现了 InnoDB 在 **自适应优化** 方面的几个关键设计：

1. **惰性与自适应**：构建与否取决于 `n_hash_potential` 和 `n_hash_helps`；不满足条件时不浪费内存。
2. **前缀选择**：通过 `left_side` 字段智能地选择每组的边界记录，在区分度和空间之间取得平衡。
3. **分区 + nowait**：`btr_search_sys_t::search_part_t` 分区设计和 `_nowait` 锁避免 AHI 成为争抢热点。
4. **与 Buffer Pool 的协作**：`buf_block_from_ahi` 利用 InnoDB 物理记录布局反查缓冲块，`buf_page_get_known_nowait` 保证页面状态有效。

### 源码引用汇总

| 文件 | 行号 | 关键内容 |
|------|------|----------|
| `btr0sea.h` | 46 | `struct btr_search_t` 定义 |
| `btr0sea.h` | 93 | `class btr_search_sys_t` 定义 |
| `btr0sea.h` | 338 | `BTR_SEARCH_HASH_ANALYSIS = 17` |
| `btr0sea.cc` | 94 | `BTR_SEARCH_BUILD_LIMIT = 100` |
| `btr0sea.cc` | 186 | `btr_search_sys_create()` |
| `btr0sea.cc` | 406 | `btr_search_info_update_hash()` |
| `btr0sea.cc` | 649 | `btr_search_info_update_slow()` |
| `btr0sea.cc` | 804 | `btr_search_guess_on_hash()` |
| `btr0sea.cc` | 1005 | `btr_search_drop_page_hash_index()` |
| `btr0sea.cc` | 1404 | `btr_search_build_page_hash_index()` |
| `buf0buf.h` | 1739 | `btr_search_prefix_info_t` 定义 |
| `buf0buf.h` | 1764 | `struct buf_block_t` 定义 |
| `buf0buf.h` | 1802 | `struct ahi_t` 定义 |
| `ha0ha.h` | 164 | `struct ha_node_t` 定义 |
| `ha0ha.h` | 49 | `ha_search_and_get_data()` |
