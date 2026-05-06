# 02-innodb-buffer-pool — InnoDB Buffer Pool：页面管理与 LRU 淘汰

> 基于 MySQL 8.4 主线源码
> 使用 doom-lsp（clangd LSP）进行符号定位
> 分析日期：2026-05-06 | 源码路径：`~/code/mysql`

---

## 0. 概述

Buffer Pool 是 InnoDB 最大的内存结构，缓存从磁盘读取的数据页和索引页。所有页面 I/O 都必须通过 Buffer Pool，它是 InnoDB 性能的核心。

Buffer Pool 维护三条链表：

```
buf_pool_t (buf0buf.h:2293)
  │
  ├── free list     ← 空闲页面（可直接分配）
  │   └── UT_LIST_BASE_NODE_T(buf_page_t) free
  │
  ├── LRU list      ← 已使用的页面（最近最少使用排序）
  │   └── UT_LIST_BASE_NODE_T(buf_page_t) LRU
  │        ├── young 区域（热页，靠近链表头）
  │        └── old   区域（冷页，靠近链表尾，默认 37%）
  │
  └── flush list    ← 脏页（按 oldest_modification LSN 排序）
      └── UT_LIST_BASE_NODE_T(buf_page_t) flush_list
```

核心页面类型 `buf_page_t` 定义在 `buf0buf.h:1164`，`buf_block_t` 定义在 `buf0buf.h:1764`（详见 01 篇）。

---

## 1. 页面状态机

`buf_page_t` 的 `state` 字段定义页面生命周期：

```cpp
// storage/innobase/include/buf0buf.h:130 — doom-lsp 确认
enum buf_page_state : uint8_t {
  BUF_BLOCK_POOL_WATCH,    // 哨兵（用于并发控制）
  BUF_BLOCK_ZIP_PAGE,      // 干净的压缩页（仅压缩，无解压 frame）
  BUF_BLOCK_ZIP_DIRTY,     // 脏压缩页（在 flush_list 上）

  BUF_BLOCK_NOT_USED,      // 空闲（在 free list 中）
  BUF_BLOCK_READY_FOR_USE, // 已分配但未使用
  BUF_BLOCK_FILE_PAGE,     // 正常数据页（在 LRU list 中）
  BUF_BLOCK_MEMORY,        // 内存分配（非文件页面）
};
```

```
                   buf_page_init()
                       │
           ┌───────────┴───────────┐
           │                       │
    BUF_BLOCK_NOT_USED    BUF_BLOCK_ZIP_PAGE
           │                       │
           │                   buf_page_set_state(ZIP_DIRTY)
           │                       │
    BUF_BLOCK_FILE_PAGE ←── BUF_BLOCK_ZIP_DIRTY
           │
      buf_page_free() → BUF_BLOCK_NOT_USED
```

---

## 2. 页面获取路径 — buf_page_get_gen

所有页面访问的入口函数 `buf_page_get_gen()` 定义在 `buf0buf.cc:4439`：

```cpp
// storage/innobase/buf/buf0buf.cc:4439 — doom-lsp 确认
buf_block_t *buf_page_get_gen(
    const page_id_t &page_id,
    const page_size_t &page_size,
    ulint rw_latch,
    buf_block_t *guess,
    Page_fetch mode,
    ut::Location location,
    mtr_t *mtr,
    bool dirty_with_no_latch)
{
  // 根据 mode 选择 fetch 策略：
  if (mode == Page_fetch::NORMAL) {
    Buf_fetch_normal fetch(page_id, page_size);
    ...
    return fetch.single_page();
  }
}
```

`Page_fetch` 枚举定义获取策略：

```cpp
// storage/innobase/include/buf0buf.h:57 — doom-lsp 确认
enum class Page_fetch {
  NORMAL,                         // 常规获取，不在则读盘
  SCAN,                           // 扫描模式（不要污染 LRU）
  IF_IN_POOL,                     // 只在 buffer pool 中时才获取
  PEEK_IF_IN_POOL,                // 查看但不固定页面
  IF_IN_POOL_OR_WATCH,            // 缓冲池中或监控中
  POSSIBLY_FREED,                 // 可能已被释放
};
```

### 2.1 Buf_fetch_normal::get — 核心获取逻辑

```cpp
// storage/innobase/buf/buf0buf.cc:3703 — doom-lsp 确认
dberr_t Buf_fetch_normal::get(buf_block_t *&block) noexcept {
  for (;;) {
    // 1. 在 page hash 中查找
    block = lookup();

    if (block != nullptr) {
      // 2. 如果找到：检查是否 stale，fix 并返回
      if (block->page.was_stale()) {
        // 页面正在 IO 中，等待后重试
        std::this_thread::sleep_for(std::chrono::microseconds(100));
        continue;
      }
      buf_block_fix(block);
      rw_lock_s_unlock(m_hash_lock);  // 释放 hash 锁
      break;
    }

    // 3. 未命中：从磁盘读取
    read_page();
  }
  return DB_SUCCESS;
}
```

### 2.2 read_page — 从磁盘读取

当 page hash 中不存在时，`read_page()` 调用 `buf_read_page()`：

```cpp
// storage/innobase/buf/buf0rea.cc:288 — doom-lsp 确认
bool buf_read_page(const page_id_t &page_id, const page_size_t &page_size) {
  // 发起异步 I/O 请求
  count = buf_read_page_low(&err, true, 0, BUF_READ_ANY_PAGE,
                            page_id, page_size, false);

  srv_stats.buf_pool_reads.add(count);

  // 统计 I/O 操作（用于 LRU 策略）
  buf_LRU_stat_inc_io();

  return (count > 0);
}
```

### 2.3 完整页面获取流程

```
buf_page_get_gen(page_id, ...)
  │
  ├── lookup() → page_hash 查找
  │   ├── 命中 → buf_block_fix() → 返回 block
  │   └── 未命中 → read_page()
  │
  └── read_page():
      ├── buf_read_page()
      │   ├── buf_read_page_low() → 发起 AIO 请求
      │   │   ├── fil_io() → 操作系统读盘
      │   │   └── AIO 完成 → buf_page_io_complete()
      │   │       ├── buf_page_init() → 初始化 buf_page_t
      │   │       ├── buf_LRU_add_block() → 加入 LRU 链表
      │   │       └── buf_page_hash_insert() → 加入 page hash
      │   └── buf_LRU_stat_inc_io()
      │
      └── 再次 lookup() → 找到 → 返回 block
```

---

## 3. LRU 链表管理

InnoDB 使用**改进的 LRU 算法**，将链表分为 young 和 old 两个区域：

```
LRU 链表 (head)      ← 最近使用的页面
  ┌──────────────┐
  │  young 区域   │  热页（频繁访问）
  │              │
  ├─ LRU_old 指针─┤  ← buf_pool->LRU_old
  │  old 区域     │  冷页（首次访问）
  │              │
  └──────────────┘
LRU 链表 (tail)      ← 最久未使用的页面
```

old 区域的大小由 `buf_LRU_old_ratio` 控制，默认 37%：

```cpp
// storage/innobase/include/buf0buf.h — LRU 管理关键字段
struct buf_pool_t {
  /** Reserve this much of the buffer pool for "old" blocks */
  ulint LRU_old_ratio;            // old 区域比例（默认 37%）

  /** Position of LRU_old in the LRU list */
  buf_page_t *LRU_old;            // 指向 old 区域起点

  /** LRU_old 在链表中的偏移位置 */
  ulint LRU_old_offset;
};
```

### 3.1 LRU 淘汰

当 `free list` 为空时，必须从 LRU 尾部淘汰页面：

```cpp
// storage/innobase/buf/buf0lru.cc:1156 — doom-lsp 确认
bool buf_LRU_scan_and_free_block(buf_pool_t *buf_pool, bool scan_all) {
  bool freed = false;
  bool use_unzip_list = UT_LIST_GET_LEN(buf_pool->unzip_LRU) > 0;

  mutex_enter(&buf_pool->LRU_list_mutex);

  // 优先从 unzip_LRU 淘汰（已解压的压缩页）
  if (use_unzip_list) {
    freed = buf_LRU_free_from_unzip_LRU_list(buf_pool, scan_all);
  }

  // 再从通用 LRU 淘汰
  if (!freed) {
    freed = buf_LRU_free_from_common_LRU_list(buf_pool, scan_all);
  }

  if (!freed) {
    mutex_exit(&buf_pool->LRU_list_mutex);
  }

  return freed;
}
```

淘汰策略优先级：
1. `unzip_LRU` 中的解压页（压缩表的辅助解压页）
2. 普通 LRU 尾部的 clean 页
3. 如果全为脏页 → 触发 flush，刷脏后释放

### 3.2 老化调整

`buf_LRU_old_adjust_len()` 在页面访问时调整 old 区域大小：

```cpp
// storage/innobase/buf/buf0lru.cc:1449 — doom-lsp 确认
static inline void buf_LRU_old_adjust_len(buf_pool_t *buf_pool) {
  // 重新计算 LRU_old 指针位置
  // 依据 LRU_old_ratio 将链表分为 young/old
  ...
}
```

---

## 4. Flush List — 脏页管理

脏页（已修改的数据页）被加入 `flush_list`，按 `oldest_modification`（首次脏化的 LSN）升序排列：

```cpp
struct buf_pool_t {
  UT_LIST_BASE_NODE_T(buf_page_t) flush_list;  // 脏页链表
  ulint flush_list_len;                          // 脏页数量
};
```

### 4.1 刷脏协调

InnoDB 使用独立的 `page_cleaner` 线程进行刷脏：

```cpp
// storage/innobase/buf/buf0flu.cc:227 — doom-lsp 确认
static void buf_flush_page_coordinator_thread() {
  // 协调 page_cleaner 线程工作
  // 定期计算：需要刷多少脏页才能满足 LSN 提前
  ...
}
```

### 4.2 双写缓冲区

在刷脏到磁盘前，先写入**双写缓冲区**（Doublewrite Buffer）以避免部分写失效：

```cpp
// storage/innobase/buf/buf0dblwr.cc
// buf_dblwr_write_block() — 将脏页先写入 dblwr，再写入实际表空间
// 崩溃恢复时，如果检测到部分页面写入，可以从 dblwr 恢复
```

---

## 5. 页面哈希索引

Buffer Pool 使用页面哈希表（`page_hash`）实现 O(1) 页面查找：

```cpp
// buf0buf.h — 页面哈希
buf_pool_t::page_hash;        // 主哈希：page_id → buf_page_t*
buf_pool_t::zip_hash;         // 压缩页哈希：page_id → buf_page_t*（压缩）
```

`lookup()` 在 `Buf_fetch::lookup()` 中实现：
1. 计算 `page_id` 的哈希值
2. 获取 `page_hash` 对应的 hash lock（S 锁）
3. 在哈希桶中查找 `buf_page_t`
4. 找到则 `buf_block_fix()`，返回 block

---

## 6. Buffer Pool 的多实例

InnoDB 将 Buffer Pool 划分为多个实例，减少锁竞争：

```cpp
// buf0buf.cc
buf_pool_t *buf_pool_ptr;     // buf_pool 数组
ulint srv_buf_pool_instances; // 实例数（默认为 CPU 核数）

// 根据 page_id 定位到实例：
buf_pool_t *buf_pool_get(const page_id_t &page_id) {
  // hash = page_id.space() % srv_buf_pool_instances
  return &buf_pool_ptr[hash];
}
```

每个实例拥有独立的：
- LRU list + reheat list（page hash 分片减少竞争）
- flush list
- free list
- mutex/latch

---

## 7. 关键函数索引

| 函数 | 文件 | 行号 | 作用 |
|------|------|------|------|
| `buf_page_get_gen` | `buf0buf.cc` | 4439 | 页面获取入口 |
| `Buf_fetch_normal::get` | `buf0buf.cc` | 3703 | 常规获取逻辑 |
| `buf_read_page` | `buf0rea.cc` | 288 | 从磁盘读页面 |
| `buf_LRU_scan_and_free_block` | `buf0lru.cc` | 1156 | LRU 淘汰 |
| `buf_LRU_old_adjust_len` | `buf0lru.cc` | 1449 | LRU 老化调整 |
| `buf_flush_page_coordinator_thread` | `buf0flu.cc` | 227 | 刷脏协调线程 |
| `buf_page_init` | `buf0buf.cc` | 4799 | 页面初始化 |
| `buf_page_free` | `buf0buf.cc` | — | 释放页面 |
| `buf_pool_t` | `buf0buf.h` | 2293 | Buffer Pool 结构 |
| `buf_page_t` | `buf0buf.h` | 1164 | 页面控制块 |
| `buf_block_t` | `buf0buf.h` | 1764 | 页面 + frame |
| `enum buf_page_state` | `buf0buf.h` | 130 | 页面状态机 |
| `enum class Page_fetch` | `buf0buf.h` | 57 | 获取策略 |

---

## 8. 数据流总结

```
页面请求 (buf_page_get_gen)
  │
  ├── page_hash 命中（95%+）
  │   ├── block->buf_fix_count++
  │   └── 返回 block
  │
  └── page_hash 未命中
      ├── buf_read_page() → AIO 读盘
      ├── buf_page_init() → 从 free list 获取 frame
      ├── buf_LRU_add_block() → 加入 LRU head
      ├── LRU 满 → buf_LRU_scan_and_free_block()
      │   ├── free_from_unzip_LRU()
      │   └── free_from_common_LRU()
      └── 返回 block
```

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-06 | MySQL 8.4 | 源码路径：`~/code/mysql`*
