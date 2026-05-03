# 14-memtable-internals — OceanBase Memtable 内部结构：Hash 表、Key 编码与行存格式

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

前几篇文章从 MVCC 行（01）、Iterator（02）、Compact（05）到 Freezer（06）覆盖了 Memtable 的外围机制——事务版本管理、扫描迭代、行压缩和冻结持久化。但 Memtable **内部**的数据结构一直没有深入展开。

本文聚焦于 Memtable 的核心内脏：

- **Hash 索引** (`ObMtHash`)——Memtable 如何通过 Hash 表实现 O(1) 行级查找
- **Key 编码** (`ObMemtableKey`)——行键如何序列化、比较和哈希
- **行存格式** (`ObMemtableData`)——写入行数据在内存中的编码方式
- **Iterator 体系**——多层级扫描迭代器如何串联起来
- **内存分配**——内存池 (`ObMemtableCtxObjPool`) 的设计

**doom-lsp 确认**：核心文件分布在以下路径：

| 文件 | 行数 | 职责 |
|------|------|------|
| `storage/memtable/ob_mt_hash.h` | ~733 | `ObMtHash` 无锁 Hash 表实现 |
| `storage/memtable/ob_memtable_key.h` | ~342 | `ObMemtableKey` 行键编码与哈希 |
| `storage/memtable/ob_memtable_data.h` | ~107 | `ObMemtableData` 行数据格式 |
| `storage/memtable/ob_memtable_iterator.h` | ~326 | 五类 Iterator 声明 |
| `storage/memtable/ob_memtable.h` | ~605 | `ObMemtable` 顶级类 |
| `storage/memtable/ob_memtable_ctx_obj_pool.h` | ~163 | 对象池缓存 |

---

## 1. ObMemtable 类结构

### 1.1 继承体系

`ObMemtable` 继承自 `ObITabletMemtable`（`storage/ob_i_tablet_memtable.h`），后者又继承 `ObFreezeCheckpoint`。所以每个 `ObMemtable` 实例天然是一个 Checkpoint 单元（06-Freezer 文章有详细描述）。

```cpp
// ob_memtable.h:184-610 - doom-lsp 确认
class ObMemtable
{
  // ─── 公共接口 ───
  int init(...);
  int set(...);                                    // 单行写入（insert/update/delete）
  int multi_set(...);                              // 批量写入
  int get(...);                                    // 单行读取
  int scan(...);                                   // 范围扫描
  int multi_get(...);                              // 批量读取
  int multi_scan(...);                             // 多范围扫描
  int lock(...);                                   // 行锁
  int replay_row(...);                             // 日志回放
  int row_compact(...);                            // 行内版本压缩

  // ─── 私有方法 ───
  int mvcc_write_(...);                            // @L477 — MVCC 写入核心
  int batch_mvcc_write_(...);                      // @L483 — 批量写入
  int mvcc_replay_(...);                           // @L491 — 日志回放写入
  int build_row_data_(...);                        // @L550 — 行数据编码

private:
  // ─── 核心成员 ───
  bool use_hash_index_;                            // @L582 — 可选 BTree（仅历史用途）
  ObLSHandle ls_handle_;                           // @L584 — 所属 Logstream
  common::ObIAllocator &local_allocator_;          // @L585 — 本地分配器
  ObMTKVBuilder kv_builder_;                       // @L586 — KV 构建器
  ObMvccEngine mvcc_engine_;                       // @L589 — MVCC 引擎
  // ... 状态标志、统计信息等
};
```

### 1.2 关键设计

1. **双索引可选**：`use_hash_index_` 字段（@L582）控制使用 Hash (`ObMtHash`) 还是 BTree (`ObKeyBtree`) 做 Memtable 行索引。默认走 Hash 索引。BTree 索引在早期版本或特殊场景下使用。
2. **原子状态机**：`state_`（@L597）管理 Memtable 的生命周期（ACTIVE → FREEZING → READY_FOR_FLUSH → FLUSHED）。
3. **本地分配器**：`local_allocator_`（@L585）负责 Memtable 内部所有内存分配，包括 Hash 表的布桶和节点。

---

## 2. 核心索引：ObMtHash

`ObMtHash`（`ob_mt_hash.h:307-733`）是 OceanBase Memtable 的默认索引结构。与传统 Hash 表不同，它是一个**惰性扩容的无锁可扩展 Hash 索引**，使用二分链接的布桶策略。

### 2.1 结点层次

```
ObHashNode                 ← 基础链表结点（next_, hash_）
  ├── ObMtHashNode         ← 存储 Key + ObMvccRow* 的真实数据结点
  ├── bucket_node          ← 布桶结点（hash_ 最低位 = 0）
  └── zero_node_           ← 0 号布桶（常驻，始终 filled）
```

```cpp
// ob_mt_hash.h:58-113 - doom-lsp 确认
struct ObHashNode {
  ObHashNode *next_;                              // @L60 — 链表后继
  uint64_t hash_;                                 // @L61 — 哈希值（含标志位）
};

struct ObMtHashNode : public ObHashNode {
  Key key_;                                       // @L98 — ObStoreRowkeyWrapper（不是指针，是嵌入）
  ObMvccRow *value_;                              // @L99 — MVCC 行指针
};
```

**设计要点**：`ObMtHashNode` 直接嵌入 `Key` 对象而非指针——这意味着每个结点完整持有 Key 的副本，避免了额外的间接引用。行键比较时只需一次指针跳转就能定位到 Key 数据。

### 2.2 布桶惰性填充（Lazy Bucket Filling）

Hash 表的布桶（bucket node）不是创建时就全部分配的，而是**在第一次访问某个子范围时才分配**。这是 `ObMtHash` 最巧妙的设计之一。

```cpp
// ob_mt_hash.h:344-356 - doom-lsp 确认
ObMtHash(common::ObIAllocator &allocator)
  : allocator_(allocator), arr_(allocator), arr_size_(INIT_HASH_SIZE)
{
  tail_node_.hash_ = 0xFFFFFFFFFFFFFFFF;          // 哨兵：恒大于任何结点
  tail_node_.next_ = NULL;
  zero_node_.set_bucket_filled(0);                // 0 号布桶始终 filled
  zero_node_.next_ = &tail_node_;
}
```

初始时只有 128 个布槽（`INIT_HASH_SIZE = 128`, @L727），但实际布桶空间通过 `ObMtArray` 按需分配。每个 `get`/`insert` 操作会：

1. 从 `arr_size_` 对应的桶数量开始，计算 `hash % bucket_count`
2. 如果对应位置的布桶未填充（`is_bucket_filled() == false`），**递归向上**找已填充的父布桶
3. 记录沿途所有未填充布桶到 `Genealogy` 链中
4. 在父布桶的链表中找到合适位置后，**串行填充**所有未填充布桶（`fill_bucket`）

```cpp
// ob_mt_hash.h:439-482 - doom-lsp 确认
int get_bucket_node(const int64_t arr_size,
                    const uint64_t query_key_so_hash,
                    ObHashNode *&bucket_node,
                    Genealogy &genealogy)
{
  int64_t bucket_count = common::next_pow2(arr_size);
  int64_t arr_idx = bucket_count;

  while (OB_SUCC(ret) && arr_idx > 0) {
    arr_idx = get_arr_idx(query_key_so_hash, bucket_count);
    if (OB_UNLIKELY(0 == arr_idx)) {
      bucket_node = &zero_node_;      // 0 号桶始终 filled
    } else if (arr_idx == last_arr_idx || arr_idx >= arr_size) {
      bucket_count >>= 1;             // 递归减半
    } else {
      ret = arr_.at(arr_idx, bucket_node);
      if (!bucket_node->is_bucket_filled()) {
        bucket_count >>= 1;
        genealogy.append_parent(bucket_node, arr_idx);
      } else {
        break;                        // 找到已填充的父布桶
      }
    }
  }
  return ret;
}
```

**填充过程通过 CAS 保证线程安全**（`ob_mt_hash.h:541-584`——`fill_pair`）：

```
Thread A fills parent → splits child into parent's list
Thread B sees child → spins until child is_filled
```

### 2.3 Hash 编码与比特反转

`ObMtHash` 使用一种特殊的 Hash 编码策略：

```
rowkey → murmurhash → mark_hash(置低2位为1) → bitrev(比特反转)
```

```cpp
// ob_mt_hash.h:46-52 - doom-lsp 确认
OB_INLINE static uint64_t mark_hash(const uint64_t key_hash) {
  return (key_hash | 3ULL);          // 最低 2 位置 1：标记为数据结点
}

OB_INLINE int64_t back2idx(const int64_t bucket_hash) {
  return bitrev(bucket_hash & (~0x3)); // 清除低 2 位后反转恢复
}
```

**哈希值的比特布局**：

```
┌──────────────┬──┬──┐
│  bitrev(hash)  │B1│B0│
│  62-0 位       │  │  │
└──────────────┴──┴──┘
                  │  └── 最低位：0 = bucket node, 1 = mt_node (data node)
                  └───── 次低位：0 = invisible, 1 = visible (filled)
```

这个设计的精妙之处在于：

- **bitrev 后单调性反转**：bitrev 后的哈希值越高 → 原始哈希值越低，使链表遍历可以从高位向低位进行
- **比较函数可通过 hash_ 值快速判定**：`compare_node`（@L117-143）先比较 hash_ 数值，仅当 hash_ 相等时才深入比较 Key 内容，极大减少 Key 比较的开销

### 2.4 存储阵列：ObMtArray

`ObMtArray`（@L258-305）是 Hash 表底层存储，采用**二级分治**架构：

```
ObMtArray
  ├── ObMtArrayBase<MY_NORMAL_BLOCK_SIZE>  small_arr_  (≈ 52 万槽位)
  └── ObMtArrayBase<MY_BIG_BLOCK_SIZE>    large_arr_  (≈ 343 亿槽位)

每个 ObMtArrayBase 内部：
  dir_  → 指针数组（DIR_SIZE 项，指向 SEG_SIZE 大小的段）
  seg   → 实际布桶结点数组（SEG_SIZE 项）
```

```cpp
// ob_mt_hash.h:148-252 - doom-lsp 确认
template<int64_t PAGE_SIZE>
class ObMtArrayBase {
  static const int64_t DIR_SIZE = PAGE_SIZE / sizeof(ObHashNode*);
  static const int64_t SEG_SIZE = PAGE_SIZE / sizeof(ObHashNode);

  OB_INLINE int at(const int64_t idx, ObHashNode *&ret_node) {
    // 延迟分配：首次访问时才分配 dir_ 和 seg_
    load_dir(dir);                // @L191 — CAS 分配 dir
    load_seg(dir, idx/SEG_SIZE, seg);  // @L223 — CAS 分配 seg
    ret_node = seg + (idx % SEG_SIZE);
  }
};
```

**按需分配的好处**：一个空的 Memtable 几乎不占 Hash 表的内存（仅 `zero_node_` 和 `tail_node_`）。随着写入增多，布桶才逐步分配。`ObMtArrayBase` 使用 `PLACE_HOLDER`（`0x1`）作为 CAS 锁标记来序列化段分配。

### 2.5 insert 与哈希扩容

```cpp
// ob_mt_hash.h:603-687 - doom-lsp 确认
int insert_mt_node(const Key *insert_key, const int64_t insert_key_hash,
                   const ObMvccRow *insert_row, ObHashNode *bucket_node)
{
  ObMtHashNode target_node(*insert_key);
  ObHashNode *prev_node = NULL, *next_node = NULL;
  ObMtHashNode *new_mt_node = NULL;
  int ret = OB_EAGAIN;

  while (common::OB_EAGAIN == ret) {
    search_sub_range_list(bucket_node, &target_node, prev_node, next_node, cmp);
    if (0 == cmp) {
      ret = OB_ENTRY_EXIST;          // Key 已存在
    } else {
      if (NULL == new_mt_node) {     // 延迟分配结点
        buf = allocator_.alloc(sizeof(ObMtHashNode));
        new_mt_node = new (buf) ObMtHashNode(*insert_key, insert_row);
      }
      new_mt_node->next_ = next_node;
      if (ATOMIC_BCAS(&(prev_node->next_), next_node, new_mt_node)) {
        try_extend(insert_key_hash); // 概率性扩容
        ret = OB_SUCCESS;
      } // 否则 retry
    }
  }
}
```

**哈希扩容（`try_extend`, @L693-712）**：OceanBase 不走传统的 rehash 全局扩容，而是**渐进式扩容**——每次插入时以 `1/1024` 的概率增大 `arr_size_`：

```cpp
OB_INLINE void try_extend(const int64_t random_hash) {
  const int64_t FLUSH_LIMIT = (1 << 10);
  if (0 == ((random_hash >> 16) & (FLUSH_LIMIT - 1))) {
    ATOMIC_FAA(&arr_size_, FLUSH_LIMIT);  // 每次加 1024
  }
}
```

新布桶通过大于旧 `arr_size_` 的索引分配，当 `get_bucket_node` 发现 `arr_idx >= arr_size` 时，会自动减少 `bucket_count` 找到已填充的父布桶。**无需全局 rehash，无需停止服务**。

---

## 3. Key 编码：ObMemtableKey

### 3.1 数据结构

```cpp
// ob_memtable_key.h:28-289 - doom-lsp 确认
class ObMemtableKey {
  common::ObStoreRowkey *rowkey_;     // @L288 — 指向行键对象
  mutable uint64_t hash_val_;         // @L289 — 缓存哈希值（惰性计算）
};
```

`ObMemtableKey` 是一个非常轻量的封装——只持有一个指向 `ObStoreRowkey` 的指针和一个缓存哈希值。真正的行键由 `ObStoreRowkey` 管理，它包含一个 `ObObj` 数组。

### 3.2 哈希计算

```cpp
// ob_memtable_key.h:96-99 - doom-lsp 确认
uint64_t hash() const {
  return 0 == hash_val_ ? calc_hash() : hash_val_;
}

uint64_t calc_hash() const {
  hash_val_ = 0;
  if (OB_NOT_NULL(rowkey_)) {
    hash_val_ = rowkey_->murmurhash(0);  // MurmurHash
  }
  return hash_val_;
}
```

哈希值使用 **MurmurHash** 算法计算，首次访问时惰性计算并缓存到 `hash_val_`。这是 OceanBase 各存储层通用的哈希函数。

### 3.3 Key 比较与等价性

```cpp
// ob_memtable_key.h:64-91 - doom-lsp 确认
int compare(const ObMemtableKey &other, int &cmp) const {
  cmp = rowkey_->compare(*other.rowkey_);
  return ret;
}

int equal(const ObMemtableKey &other, bool &is_equal) const {
  if (hash() != other.hash()) {       // 先比较哈希值
    is_equal = false;                 // 哈希不等则快速返回
  } else {
    rowkey_->equal(*other.rowkey_, is_equal);  // 再逐列比较
  }
}
```

`equal` 的优化：**先比较缓存的哈希值**——绝大数情况下不同行的哈希值不同，比较 `uint64_t` 远快于逐列比较 `ObObj`。

### 3.4 Key 深拷贝

```cpp
// ob_memtable_key.h:124-152 - doom-lsp（dup_without_hash）
template <class Allocator>
int dup_without_hash(ObMemtableKey *&new_key, Allocator &allocator) const {
  // 1. 分配 ObMemtableKey 对象
  new_key = (ObMemtableKey *)allocator.alloc(sizeof(*new_key));
  // 2. 分配 ObStoreRowkey 对象
  new_key->rowkey_ = (ObStoreRowkey *)allocator.alloc(sizeof(ObStoreRowkey));
  // 3. deep_copy rowkey 内部的 ObObj 数组
  rowkey_->deep_copy(*(new_key->rowkey_), allocator);
  new_key->hash_val_ = hash_val_;
}
```

当 `ObMemtableKey` 要插入到 Hash 表时，需要通过 `dup` 创建一份**深拷贝**到 Memtable 的生命周期分配器中。这确保行键数据在行被删除前始终有效。

### 3.5 Key Generation

`ObMemtableKeyGenerator`（`ob_memtable_key.h:315-342`）用于批量写入时生成多个 `ObMemtableKey`：

```cpp
class ObMemtableKeyGenerator {
  ObMemtableKey memtable_key_;        // @L340
  char *memtable_key_buffer_;         // @L341 — Key 序列化缓冲区
  common::ObObj *obj_buf_;            // @L338 — Obj 数组缓冲区

  int generate_memtable_key(...);     // @L331 — 根据行数据生成 Key
  ObMemtableKey *get_memtable_key();  // @L332 — 获取生成的 Key
};
```

---

## 4. 行存格式：ObMemtableData

### 4.1 数据结构

当数据写入到 Memtable 时，行数据被编码为 `ObMemtableDataHeader` 并存储到 `MvccTransNode::buf_` 中。

```cpp
// ob_memtable_data.h:27-107 - doom-lsp 确认
class ObMemtableDataHeader {
  blocksstable::ObDmlFlag dml_flag_;  // @L102 — DML 类型（INSERT/UPDATE/DELETE）
  int64_t buf_len_;                    // @L103 — payload 长度
  char buf_[0];                        // @L104 — 柔性数组，实际行数据

  int64_t dup_size() const {
    return sizeof(ObMemtableDataHeader) + buf_len_;  // 总大小
  }

  static int build(ObMemtableDataHeader *new_data, const ObMemtableData *data) {
    MEMCPY(new_data->buf_, data->buf_, data->buf_len_);
  }
};

class ObMemtableData {
  blocksstable::ObDmlFlag dml_flag_;  // @L96 — 同 Header
  int64_t buf_len_;                    // @L97 — payload 长度
  const char *buf_;                    // @L98 — payload 指针

  int64_t dup_size() const {
    return sizeof(ObMemtableDataHeader) + buf_len_;
  }
};
```

### 4.2 写入路径中的编码

在 `ObMemtable::build_row_data_`（`ob_memtable.h:550`）中，行数据的编码流程为：

```
set() 入口
  ↓
build_row_data_(): 使用 ObCompatRowWriter 将行写入缓冲区
  ↓                   写入数据包括：所有列的 ObDatum 值和 DML 标志
  ↓                              ↓
ObMemtableData { dml_flag, buf_len, buf }
  ↓
mvcc_write_(): 将 ObMemtableData 编码为 ObMemtableDataHeader
  ↓            存储在 MvccTransNode::buf_（柔性数组）
  ↓
ObMtHash::insert(): Key 插入 Hash 表，value = ObMvccRow*
```

### 4.3 行存格式的物理布局

```
MvccTransNode (ob_mvcc_row.h:71-169)
┌─────────────────────────────┐
│ tx_id_ (8B)                 │  ← 事务 ID
│ trans_version_ (8B)         │  ← 提交版本号（可见性判断核心）
│ scn_ (8B)                   │  ← Paxos SCN
│ seq_no_ (8B)                │  ← 事务内序列号
│ prev_ / next_ (各 8B)       │  ← 版本链指针
│ flag_ (1B)                  │  ← 状态标志
│ ...                         │
├─────────────────────────────┤
│ ObMemtableDataHeader        │  ← buf_[0] 起点
│  ├── dml_flag_ (1B)        │
│  ├── buf_len_ (8B)         │
│  └── buf_ (flex array)     │  ← 实际列数据的编码
└─────────────────────────────┘
```

一个行在 Memtable 中可能有**多个** `MvccTransNode`（多个更新版本），通过 `prev_`/`next_` 构成双向版本链。

---

## 5. Iterator 体系

Memtable 提供五种迭代器，继承自统一的 `ObIMemtableIterator` 接口（`ob_memtable_iterator.h:45`）：

```
ObIMemtableIterator ← 根接口
  ├── ObMemtableGetIterator          (L68)  — 单行点查
  ├── ObMemtableScanIterator         (L104) — 范围扫描（最常用）
  ├── ObMemtableMGetIterator         (L150) — 多点查
  ├── ObMemtableMScanIterator        (L185) — 多范围扫描
  └── ObMemtableMultiVersionScanIterator (L213) — 多版本扫描
      └── 内部状态机：
            SCAN_BEGIN → SCAN_UNCOMMITTED_ROW → SCAN_COMPACT_ROW
            → SCAN_MULTI_VERSION_ROW → SCAN_END
```

### 5.1 ScanIterator 的关键实现

`ObMemtableScanIterator`（`ob_memtable_iterator.h:104-148`）是使用最频繁的迭代器。它包含以下核心组件：

```cpp
class ObMemtableScanIterator {
  ObMemtableBlockRowScanner mt_blk_scanner_;   // @L138 — 块级扫描器（用于 block scan 优化）
  ObSingleRowReader single_row_reader_;          // @L139 — 单行读取器

  ScanState scan_state_;                         // 扫描状态机
  bool is_scan_start_;                           // @L135 — 首次扫描标记
  ObStoreRange cur_range_;                       // @L140 — 当前扫描范围
};
```

### 5.2 MultiVersionScanIterator 的状态机

`ObMemtableMultiVersionScanIterator`（`ob_memtable_iterator.h:213-295`）通过一个有限状态机处理不同行格式的扫描：

```cpp
enum ScanState {
  SCAN_BEGIN,               // 扫描起始
  SCAN_UNCOMMITTED_ROW,     // 未提交行的扫描
  SCAN_COMPACT_ROW,         // 已压缩行的扫描（compact 后的单版本行）
  SCAN_MULTI_VERSION_ROW,   // 多版本行的扫描
  SCAN_END                  // 扫描结束
};
```

状态流转：
```
SCAN_BEGIN → SCAN_UNCOMMITTED_ROW → SCAN_COMPACT_ROW
                                       ↓ (有未压缩的多版本)
                                  SCAN_MULTI_VERSION_ROW
                                       ↓
                                  SCAN_END
```

### 5.3 读路径全流程

```
ObMemtable::get() → ObMemtableGetIterator::init()
  ↓
ObMemtable::get_begin()  ← MVCC 上下文初始化
  ↓
Hash 表查询 → ObMtHash::do_get()
  ├── 布桶定位（惰性填充） │
  ├── 链表中搜索 Key     │
  ├── 找到 ObMvccRow*   │
  ↓
MVCC 可见性判断 → ObMvccRow::get_trans_node()
  ├── 遍历版本链        │
  ├── snapshot_version 比较 │
  ├── 返回可见版本的行数据 │
  ↓
ObMemtable::get_end() ← 上下文清理
```

---

## 6. 内存分配：ObMemtableCtxObjPool

`ObMemtableCtxObjPool`（`ob_memtable_ctx_obj_pool.h:24-163`）是 Memtable 的缓存对象池，用于复用经常分配/释放的小对象。

```cpp
// ob_memtable_ctx_obj_pool.h - doom-lsp 确认
class ObMemtableCtxObjPool {
  ObOpFreeList lock_op_node_pool_;         // 锁操作结点缓存
  ObOpFreeList lock_callback_pool_;        // 锁回调缓存
  ObOpFreeList mvcc_callback_pool_;        // MVCC 回调缓存

  template <typename T>
  void *alloc();                           // 按类型从对应池分配

  template <typename T>
  void free(void *ptr);                    // 归还到对应池
};
```

三种池分别缓存不同用途的对象：

| 对象类型 | 池名称 | 用途 |
|---------|--------|------|
| `ObMemCtxLockOpLinkNode` | `lock_op_node_pool_` | 行锁的等待链结点 |
| `ObOBJLockCallback` | `lock_callback_pool_` | 锁回调 |
| `ObMvccRowCallback` | `mvcc_callback_pool_` | MVCC 回调 |

这种设计避免了对 `malloc` 的频繁调用，显著降低写路径的内存分配开销。

---

## 7. Memtable 全景结构图

```
ObMemtable
┌──────────────────────────────────────────────────────┐
│  ObITabletMemtable (freeze checkpoint)              │
│  ┌────────────────────────────────────────────────┐ │
│  │  ObMvccEngine                                  │ │
│  │  ┌──────────────────────────────────────────┐  │ │
│  │  │  ObMtHash (或者 ObKeyBtree, 默认 Hash)    │  │ │
│  │  │  ┌────────────────────────────────────┐  │  │ │
│  │  │  │ zero_node_ → tail_node_            │  │  │ │
│  │  │  │     │ (链表头)                      │  │  │ │
│  │  │  │     ├── ObMtHashNode {Key, MVCCRow}│  │  │ │
│  │  │  │     ├── ObMtHashNode {Key, MVCCRow}│  │  │ │
│  │  │  │     ├── bucket_node (填充的布桶)    │  │  │ │
│  │  │  │     │    ├── ObMtHashNode ...       │  │  │ │
│  │  │  │     │    └── ObMtHashNode ...       │  │  │ │
│  │  │  │     ├── bucket_node ...             │  │  │ │
│  │  │  │     └── ...                         │  │  │ │
│  │  │  └────────────────────────────────────┘  │  │ │
│  │  │                                           │  │ │
│  │  │  ObMtArray (底层存储)                      │  │ │
│  │  │  ├── small_arr_ (≈52万槽, 4KB/页)         │  │ │
│  │  │  └── large_arr_ (≈343亿槽, 1MB/页)       │  │ │
│  │  └──────────────────────────────────────────┘  │ │
│  │                                                 │ │
│  │  每个 ObMvccRow                                 │ │
│  │  ┌─────────────────────────────────────────┐    │ │
│  │  │ latch_ (行锁)                           │    │ │
│  │  │ trans_node_list_head_                   │    │ │
│  │  │   ├── MvccTransNode (v1) ← oldest      │    │ │
│  │  │   │     └── buf_: ObMemtableDataHeader  │    │ │
│  │  │   ├── MvccTransNode (v2)               │    │ │
│  │  │   │     └── buf_: ObMemtableDataHeader  │    │ │
│  │  │   └── MvccTransNode (v3) ← newest      │    │ │
│  │  │         └── buf_: ObMemtableDataHeader  │    │ │
│  │  └─────────────────────────────────────────┘    │ │
│  └──────────────────────────────────────────────────┘ │
│                                                        │
│  ObMemtableCtxObjPool                                  │
│  ├── lock_op_node_pool_  (缓存锁等待链结点)              │
│  ├── lock_callback_pool_ (缓存锁回调)                  │
│  └── mvcc_callback_pool_ (缓存 MVCC 回调)              │
│                                                        │
│  local_allocator_ ← 所有内存从这走                      │
└──────────────────────────────────────────────────────┘
```

---

## 8. 与前面文章的关联

### 8.1 01-MVCC Row

`ObMvccRow` 是 Memtable 的 **Value** 存储容器。它被 `ObMtHashNode::value_` 指针引用。每个 Hash 结点指向一个 `ObMvccRow`，该行通过 `ObMvccTransNode` 双向链保存所有历史版本。

### 8.2 02-MVCC Iterator

`ObMemtableIterator` 是 `ObMvccIterator` 的上层封装。读操作通过 Memtable 的 Iterator 进入 Hash 表查找 Key，然后通过 MVCC Iterator 遍历版本链确定可见版本。

### 8.3 05-MVCC Compact

`ObMemtable::row_compact()`（`ob_memtable.h:370`）扫描 `ObMvccRow` 的版本链，将多个连续的 `MvccTransNode` 合并为单个 COMPACT 节点。Compact 后 `ObMvccRow` 的版本链变短，**但 Hash 表的指向不动**——仍指向同一个 `ObMvccRow`，只是行内部的版本链被压缩了。

### 8.4 06-Freezer

冻结时，`ObMemtable::finish_freeze()`（`ob_memtable.h:456`）将 Memtable 标记为 `FROZEN` 状态（`state_` → `READY_FOR_FLUSH`）。此时 Hash 表变为**只读**——不再接受新的 insert/update，但已有数据仍可通过 Hash 表被扫描（用于 flush 到 SSTable）。

### 8.5 15-ObKeyBtree (下一篇)

`use_hash_index_ == false` 时，Memtable 会使用 `ObKeyBtree` 替代 `ObMtHash` 做行索引。BTree 擅长范围扫描（有序遍历），而 Hash 表擅长点查（O(1) 直接命中）。

---

## 9. 设计决策

### 9.1 为什么用 Hash 而不是 BTree 做 Memtable 索引？

| 维度 | Hash (ObMtHash) | BTree (ObKeyBtree) |
|------|----------------|-------------------|
| 点查 | O(1), 极快 | O(log n), 慢 3-5x |
| 范围扫描 | 需遍历整链表 | O(log n + m), 快 |
| 扩容 | 渐进式，无 pause | 页分裂有短暂锁 |
| 内存占用 | 较少（无冗余指针） | 较大（B+Tree 内部结点） |
| 并发 | 无锁链表，高吞吐 | 锁分裂，吞吐受限 |

**结论**：Memtable 的主要负载是**写密集型点查**（按主键 insert/get），Hash 表天然适配。BTree 主要在全表/范围扫描场景中优势更明显，这由 SSTable 承担。

### 9.2 Hash 碰撞解决策略

`ObMtHash` 采用**链地址法（separate chaining）**，同一条链上的结点按 `hash_`（bitrev 后）排序：

```
bucket_node → ObMtHashNode(hash=0x1234) → ObMtHashNode(hash=0x2345) → tail
```

链表中的结点**按 hash_ 递增有序**，保证线性搜索时可提前终止。`compare_node`（@L117-143）先比 `hash_` 再比 Key 内容——随机数据下几乎不触发 Key 比较。

### 9.3 Key 编码的设计考量

`ObMemtableKey` 的 `hash()` 使用 MurmurHash 进行惰性计算和缓存。选择 MurmurHash 的原因：

- **高效**：对短 Key（典型集群主键通常 1-4 列）的哈希计算极快
- **均匀**：MurmurHash 的雪崩效应保证不同 Key 的哈希值分布均匀
- **可移植**：相同输入在不同平台上产生相同结果

### 9.4 扩容策略：渐进式 vs 全局 rehash

传统 rehash：分配 2x 空间 → 全部数据重新 hash → 复用旧空间（暂停服务）

`ObMtHash` 的 `try_extend`（@L693-712）：

- 每次插入有 `1/1024` 概率触发 `arr_size_ += 1024`
- 新布桶通过 `ObMtArray` 按需分配（不是一次性全部分配）
- 布桶通过二分链接逐步插入链表，无需迁移已有数据
- **无需全局 rehash，零暂停**

### 9.5 写放大与读放大的权衡

| 场景 | 放大效应 | 缓解 |
|------|---------|------|
| 单行多次更新 | 写放大：Hash 表中只插一次，但版本链增长 | Compact 压缩版本链（05） |
| 范围扫描 | 读放大：Hash 遍历全部链表 | 可切换 BTree 索引 |
| 大行写入 | 写放大：ObMemtableDataHeader 编码全部列 | ObMemtableData 柔性数组紧凑编码 |

OceanBase 的设计选择是：**用 Hash 表降低点查的读放大，用 Compact 解决版本链的写放大，用 LSM-Tree 分层解决全局写放大**。

---

## 10. 源码索引

| 文件 | 关键行号 | 内容 |
|------|---------|------|
| `ob_memtable.h:184` | 类声明 | `ObMemtable` 顶级类 |
| `ob_memtable.h:477` | 方法 | `mvcc_write_` — MVCC 写入 |
| `ob_memtable.h:550` | 方法 | `build_row_data_` — 行数据编码 |
| `ob_memtable.h:585` | 字段 | `local_allocator_` — 本地分配器 |
| `ob_mt_hash.h:58` | 结构 | `ObHashNode` — 基础链表结点 |
| `ob_mt_hash.h:96` | 结构 | `ObMtHashNode` — 含 Key 和 Value 的数据结点 |
| `ob_mt_hash.h:117` | 函数 | `compare_node` — 结点比较（含 hash + key） |
| `ob_mt_hash.h:148` | 类 | `ObMtArrayBase` — 分段式动态数组 |
| `ob_mt_hash.h:258` | 类 | `ObMtArray` — 二级存储阵列 |
| `ob_mt_hash.h:307` | 类 | `ObMtHash` — 无锁 Hash 表 |
| `ob_mt_hash.h:336` | 方法 | `ObMtHash::ObMtHash` — 构造函数（零结点、尾哨兵） |
| `ob_mt_hash.h:369` | 方法 | `ObMtHash::get` — 点查入口 |
| `ob_mt_hash.h:394` | 方法 | `ObMtHash::insert` — 插入入口 |
| `ob_mt_hash.h:439` | 方法 | `get_bucket_node` — 布桶递归定位 |
| `ob_mt_hash.h:541` | 方法 | `fill_bucket` — 惰性布桶填充 |
| `ob_mt_hash.h:586` | 方法 | `do_get` — 实际查找逻辑 |
| `ob_mt_hash.h:603` | 方法 | `insert_mt_node` — 实际插入逻辑 |
| `ob_mt_hash.h:693` | 方法 | `try_extend` — 概率性扩容 |
| `ob_memtable_key.h:28` | 类 | `ObMemtableKey` — Key 封装 |
| `ob_memtable_key.h:94` | 方法 | `hash()` — MurmurHash 惰性计算 |
| `ob_memtable_key.h:124` | 方法 | `dup()` — 深拷贝 |
| `ob_memtable_key.h:293` | 类 | `ObStoreRowkeyWrapper` — 行键包装 |
| `ob_memtable_key.h:315` | 类 | `ObMemtableKeyGenerator` — 批量 Key 生成 |
| `ob_memtable_data.h:27` | 类 | `ObMemtableDataHeader` — 写入版本节点的 Header |
| `ob_memtable_data.h:77` | 类 | `ObMemtableData` — 行数据参数封装 |
| `ob_memtable_iterator.h:45` | 类 | `ObIMemtableIterator` — 迭代器基类 |
| `ob_memtable_iterator.h:68` | 类 | `ObMemtableGetIterator` — 点查迭代器 |
| `ob_memtable_iterator.h:104` | 类 | `ObMemtableScanIterator` — 范围扫描 |
| `ob_memtable_iterator.h:150` | 类 | `ObMemtableMGetIterator` — 多点查 |
| `ob_memtable_iterator.h:185` | 类 | `ObMemtableMScanIterator` — 多范围扫描 |
| `ob_memtable_iterator.h:213` | 类 | `ObMemtableMultiVersionScanIterator` — 多版本扫描 |
| `ob_memtable_ctx_obj_pool.h:24` | 类 | `ObMemtableCtxObjPool` — 对象池 |

---

## 11. 总结

`ObMtHash` 的惰性布桶填充 + 渐进式扩容设计是 OceanBase Memtable 在**写密集型负载**下保持高性能的关键。它通过：

1. **无锁链表 (CAS)** 实现高并发插入
2. **惰性布桶** 大幅降低空 Memtable 的内存占用
3. **概率性扩容** 避免全局 rehash 的暂停开销
4. **bitrev 编码 + 有序链表** 加速链表搜索，减少 Key 比较

与 BTree 的线程同步开销和页分裂开销相比，Hash 表在 Memtable 的写入场景下优势显著——这正是 OceanBase 在 Memtable 层选择 Hash 而非 BTree 的工程智慧。

下一篇文章 (15) 将剖析备用的 `ObKeyBtree` 实现，理解 OceanBase 为什么在 Memtable 保留了两种索引选项，以及 BTree 在哪些场景下表现更优。
