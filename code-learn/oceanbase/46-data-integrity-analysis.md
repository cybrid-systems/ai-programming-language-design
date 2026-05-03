# 46 — 数据完整性 — Checksum 体系与数据验证

> 基于 OceanBase CE 主线源码
> 分析范围：
> - `src/storage/memtable/mvcc/ob_mvcc_row.h/cpp`——行级累积校验和
> - `src/storage/blocksstable/ob_micro_block_checksum_helper.h`——微块级行/列校验和
> - `src/storage/blocksstable/ob_major_checksum_info.h`——宏块级校验信息
> - `src/storage/blocksstable/ob_column_checksum_struct.h`——列校验和结构
> - `src/storage/compaction/ob_column_checksum_calculator.h/cpp`——合并过程的列校验和计算
> - `src/logservice/palf/log_checksum.h/cpp`——PALF 日志校验和
> - `src/storage/concurrency_control/ob_data_validation_service.h/cpp`——数据验证服务
> - `src/share/datum/ob_datum.h`——单 Datum 校验和
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与代码结构分析

---

## 0. 概述

**数据完整性是数据库系统的生命线。** 数据在写入、传输、复制、合并的漫长生命周期中，任何一比特的静默损坏都可能导致用户数据丢失、查询结果错误、系统崩溃。OceanBase 设计了一套覆盖多个存储层级的 Checksum 体系：

```
┌──────────────────────────────────────────────────────────────┐
│  Checksum 层次体系                                            │
│                                                              │
│  ┌────────────┐     ┌──────────────────┐                     │
│  │ 行级 Checksum│     │ 微块级 Checksum   │                    │
│  │ acc_checksum_ │     │ row_checksum     │                    │
│  │ modify_count_  │     │ column_checksum  │                    │
│  └──────┬───────┘     └────────┬─────────┘                    │
│         │                      │                              │
│         v                      v                              │
│  ┌────────────────────────────────────────────┐               │
│  │         宏块级 Checksum                      │               │
│  │   ObMajorChecksumInfo                       │               │
│  │   - data_checksum_                          │               │
│  │   - ObColumnCkmStruct (列级校验和数组)        │               │
│  └────────────────────┬───────────────────────┘               │
│                       │                                       │
│                       v                                       │
│  ┌────────────────────────────────────────────┐               │
│  │         日志级 Checksum                      │               │
│  │   LogChecksum                               │               │
│  │   - accum_checksum_ (累积校验和)              │               │
│  │   - verify_checksum_ (验证校验和)             │               │
│  └──────┬─────────────────────────────────────┘               │
│         │                                                      │
│         v                                                      │
│  ┌────────────────────────────────────────────┐               │
│  │   数据验证服务 (定期校验)                     │               │
│  │   ObDataValidationService                   │               │
│  │   - need_delay_resource_recycle()           │               │
│  └────────────────────────────────────────────┘               │
└──────────────────────────────────────────────────────────────┘
```

**设计原则：**
1. **分层验证**——每个存储层次拥有独立的校验和，损坏能精确定位到行/块/列/日志
2. **链式信任**——下层的校验和由上层累积构建，形成不可篡改的校验链
3. **性能 vs 安全权衡**——行级校验和仅在 MVCC 行操作时计算；微块级提供 SSE4.2 硬件加速路径；日志级使用 crc64

---

## 1. 行级校验和（ObMvccTransNode）

### 1.1 数据结构

行级 checksum 定义在 `ObMvccTransNode` 中（`ob_mvcc_row.h:142-160`）：

```cpp
// ob_mvcc_row.h:142-160
struct ObMvccTransNode {
  uint32_t modify_count_;   // 修改计数
  uint32_t acc_checksum_;   // 累积校验和
  int64_t version_;
  int64_t snapshot_version_barrier_;
  uint8_t type_;
  TransNodeFlag flag_;
  char buf_[0];             // 柔性数组，存储实际的 Memtable 数据
  // ...

  void checksum(common::ObBatchChecksum &bc) const;
  uint32_t m_cal_acc_checksum(const uint32_t last_acc_checksum) const;
  void cal_acc_checksum(const uint32_t last_acc_checksum);
  int verify_acc_checksum(const uint32_t last_acc_checksum) const;
};
```

**两个核心字段：**
- **`modify_count_`**（`ob_mvcc_row.h:159`）——事务修改计数，每次对节点的修改都会增加
- **`acc_checksum_`**（`ob_mvcc_row.h:160`）——累积校验和，基于**前一个节点**的校验和计算得到

### 1.2 校验和计算

`ObMvccTransNode::m_cal_acc_checksum()`（`ob_mvcc_row.cpp:38-45`）：

```cpp
uint32_t ObMvccTransNode::m_cal_acc_checksum(
    const uint32_t last_acc_checksum) const
{
  uint32_t acc_checksum = 0;
  ObBatchChecksum bc;
  bc.fill(&last_acc_checksum, sizeof(last_acc_checksum));
  ((ObMemtableDataHeader *)buf_)->checksum(bc);
  acc_checksum = static_cast<uint32_t>((bc.calc() ? : 1) & 0xffffffff);
  return acc_checksum;
}
```

**计算过程：**
1. 创建一个 `ObBatchChecksum` 实例
2. 填入前一个节点的校验和 `last_acc_checksum`
3. 将当前节点的实际数据（`ObMemtableDataHeader`）的 checksum 级联进去
4. 最终结果与 `0xffffffff` 按位与，得到 32 位校验和

**关键设计：链式校验。** 每个节点的校验和不是独立计算的，而是 `crc(last_acc_checksum + data)`。这意味着：
- 任何中间节点的数据损坏都会破坏**所有后续节点**的校验和
- 验证时不需要独立的校验和日志，只需从第一个节点开始顺序计算

### 1.3 设置与验证

```cpp
// ob_mvcc_row.cpp:48-53
void ObMvccTransNode::cal_acc_checksum(
    const uint32_t last_acc_checksum)
{
  acc_checksum_ = m_cal_acc_checksum(last_acc_checksum);
  if (0 == last_acc_checksum) {
    TRANS_LOG(DEBUG, "calc first trans node checksum", ...);
  }
}

// ob_mvcc_row.cpp:56-68
int ObMvccTransNode::verify_acc_checksum(
    const uint32_t last_acc_checksum) const
{
  int ret = OB_SUCCESS;
  if (0 != last_acc_checksum) {
    const uint32_t acc_checksum = m_cal_acc_checksum(last_acc_checksum);
    if (acc_checksum_ != acc_checksum) {
      ret = OB_CHECKSUM_ERROR;
      TRANS_LOG(ERROR, "row checksum error", K(ret), ...);
    }
  }
  return ret;
}
```

**验证只在 `last_acc_checksum != 0` 时执行。** 这是因为第一个节点（`modify_count_ == 0`）的 `acc_checksum` 总是被初始化为 0，所以 `last_acc_checksum = 0` 表示这是初始节点，不需要验证。

`ObMvccTransNode::checksum()`（`ob_mvcc_row.cpp:32-35`）还提供了一种轻量级校验方式，只对 `modify_count_` 和 `type_` 字段进行校验：

```cpp
void ObMvccTransNode::checksum(ObBatchChecksum &bc) const
{
  bc.fill(&modify_count_, sizeof(modify_count_));
  bc.fill(&type_, sizeof(type_));
}
```

### 1.4 调用场景

在 `ob_mvcc_trans_ctx.cpp` 中可以看到校验和的实际使用（`2090` 行）：

```cpp
// 事务写入时计算校验和
tnode_->cal_acc_checksum(last_acc_checksum);
```

这表明校验和是**在事务写入行数据时实时计算**的，而不是异步或定期计算的。

---

## 2. 微块级校验和（ObMicroBlockChecksumHelper）

### 2.1 类结构

`ObMicroBlockChecksumHelper`（`ob_micro_block_checksum_helper.h:24-94`）是微块（Micro Block）级别的校验和助手类：

```cpp
class ObMicroBlockChecksumHelper final {
public:
  ObMicroBlockChecksumHelper()
    : col_descs_(nullptr),
      integer_col_idx_(nullptr),
      integer_col_buf_(nullptr),
      integer_col_cnt_(0),
      allocator_("CkmHelper"),
      micro_block_row_checksum_(0) {}

  int init(const common::ObIArray<share::schema::ObColDesc> *col_descs,
           const bool need_opt_row_chksum);
  void reset();
  inline void reuse() { micro_block_row_checksum_ = 0; }

  // 行级校验和
  template <typename Iter> int cal_row_checksum(Iter begin, Iter end);

  // 列级校验和
  int cal_column_checksum(const ObDatumRow &row,
                          int64_t *curr_micro_column_checksum);
  int cal_rows_checksum(const common::ObArray<ObColDatums *> &all_col_datums,
                        const int64_t row_count);
  int cal_column_checksum(const common::ObIArray<ObIVector *> &vectors,
                          const int64_t start, const int64_t row_count,
                          int64_t *curr_micro_column_checksum);

private:
  int cal_column_checksum_normal(...);
  int cal_column_checksum_sse42(...);

  // 魔术常量
  static const int64_t MAGIC_NOP_NUMBER = 0xa1b;
  static const int64_t MAGIC_NULL_NUMBER = 0xce75;
  static const int64_t LOCAL_INTEGER_COL_CNT = 64;

  int64_t micro_block_row_checksum_;          // 微块的行校验和
  int16_t local_integer_col_idx_[64];         // 本地整数列索引缓存
  int64_t local_integer_col_buf_[64];         // 本地整数列值缓存
};
```

### 2.2 行校验和计算

核心逻辑是 `cal_row_checksum(Iter begin, Iter end)`（`ob_micro_block_checksum_helper.h:98-130`）：

```cpp
template <typename Iter>
int ObMicroBlockChecksumHelper::cal_row_checksum(Iter begin, Iter end) {
  if (OB_ISNULL(integer_col_buf_) || OB_ISNULL(integer_col_idx_)) {
    // 简单路径：逐行调用 datum.checksum() 累加
    for (Iter iter = begin; iter < end; ++iter) {
      micro_block_row_checksum_ = datum.checksum(micro_block_row_checksum_);
    }
  } else {
    // 优化路径：整数列批量用 CRC64 SSE4.2
    // 非整数列逐 datum 计算，整数列收集后批量 crc64
    // ...
    micro_block_row_checksum_ = ob_crc64_sse42(micro_block_row_checksum_,
        static_cast<void*>(integer_col_buf_),
        sizeof(int64_t) * integer_col_cnt_);
  }
}
```

**两条路径：**
- **无优化路径**——当 `integer_col_buf_` 或 `integer_col_idx_` 为 NULL 时，逐个 datum 调用 `ObDatum::checksum()` 累加
- **优化路径**——识别整数列，将整数列的值批量收集到 `integer_col_buf_` 中，然后用 `ob_crc64_sse42` 一次性计算。非整数列仍然逐 datum 计算

**优化原理：** 整数列的 checksum 需要反复调用 datum 的 pack 和解包操作。通过将整数列值批量收集并一次性 CRC，可以减少函数调用开销并利用 SSE4.2 指令的批处理能力。

### 2.3 列校验和

两种列校验和计算方式：

**基于 DatumRow 的逐行计算**（`ob_micro_block_checksum_helper.h:49-60`）：

```cpp
int cal_column_checksum(const ObDatumRow &row,
                        int64_t *curr_micro_column_checksum)
{
  for (int64_t i = 0; i < row.get_column_count(); ++i) {
    curr_micro_column_checksum[i] += row.storage_datums_[i].checksum(0);
  }
}
```

**基于 Vector 的批量计算**（`ob_micro_block_checksum_helper.h:64`）：

提供两条路径：
- `cal_column_checksum_normal`——通用的列校验和计算
- `cal_column_checksum_sse42`——使用 SSE4.2 硬件加速的列校验和计算

### 2.4 单 Datum 校验和

`ObDatum::checksum()`（`ob_datum.h:849-856`）：

```cpp
inline int64_t ObDatum::checksum(const int64_t current) const
{
  int64_t result = ob_crc64_sse42(current, &pack_, sizeof(pack_));
  if (len_ > 0) {
    result = ob_crc64_sse42(result, ptr_, len_);
  }
  return result;
}
```

**计算方式：**
1. 对 `pack_` 字段（类型/长度编码）计算 CRC64
2. 如果数据长度 `len_ > 0`，继续对实际数据 `ptr_` 计算 CRC64
3. 当前校验和 `current` 作为初始值传入，支持链式累积

---

## 3. 宏块级校验和（ObMajorChecksumInfo）

### 3.1 数据结构

`ObMajorChecksumInfo`（`ob_major_checksum_info.h:27-84`）管理宏块级别的校验和，是**合并过程的最终产出**：

```cpp
class ObMajorChecksumInfo {
public:
  // 从合并结果初始化
  int init_from_merge_result(
    ObArenaAllocator &allocator,
    const compaction::ObBasicTabletMergeCtx &ctx,
    const blocksstable::ObSSTableMergeRes &res);

  // 从已有 SSTable 初始化
  int init_from_sstable(
    ObArenaAllocator &allocator,
    const compaction::ObExecMode exec_mode,
    const storage::ObStorageSchema &storage_schema,
    const blocksstable::ObSSTable &sstable);

  int64_t get_data_checksum() const { return data_checksum_; }
  const ObColumnCkmStruct &get_column_checksum_struct() const {
    return column_ckm_struct_;
  }

private:
  union {
    uint64_t info_;
    struct {
      uint64_t version_   : 8;  // 版本号
      uint64_t exec_mode_ : 4;  // 合并执行模式
      uint64_t reserved_  : 52; // 保留位
    };
  };
  int64_t compaction_scn_;           // 合并 SCN
  int64_t row_count_;                // 行数
  int64_t data_checksum_;            // 数据总校验和
  ObColumnCkmStruct column_ckm_struct_;  // 列级校验和数组
};
```

**扩展版本** `ObCOMajorChecksumInfo`（`ob_major_checksum_info.h:87-103`）为列组（Column Group）场景提供了额外的初始化接口，并添加了互斥锁保护。

### 3.2 结构编码

`info_` 字段使用位域编码（`ob_major_checksum_info.h:57-63`）：
- **version_**（8 bits）——版本号，当前为 `MAJOR_CHECKSUM_INFO_VERSION_V1 = 1`
- **exec_mode_**（4 bits）——合并执行模式，用于区分是全量合并还是增量合并
- **reserved_**（52 bits）——保留位，未来扩展用

### 3.3 列校验和结构

`ObColumnCkmStruct`（`ob_column_checksum_struct.h:20-58`）：

```cpp
struct ObColumnCkmStruct {
  int64_t *column_checksums_;   // 列校验和数组
  int64_t count_;               // 列数

  int assign(common::ObArenaAllocator &allocator,
             const common::ObIArray<int64_t> &column_checksums);
  int serialize(char *buf, const int64_t buf_len, int64_t &pos) const;
  int deserialize(common::ObArenaAllocator &allocator,
                  const char *buf, const int64_t data_len, int64_t &pos);
};
```

这是一个轻量结构，仅持有：
- 指向列校验和数组的指针 `column_checksums_`
- 列数 `count_`

**特点：** `column_checksums_` 本身是堆分配的，因此需要自定义的 `serialize/deserialize` 和 `deep_copy` 方法来处理。

---

## 4. 合并过程的列校验和计算

### 4.1 ObColumnChecksumCalculator

`ObColumnChecksumCalculator`（`ob_column_checksum_calculator.h:20-40`）是合并（Compaction）过程中**逐行计算列校验和**的核心类：

```cpp
class ObColumnChecksumCalculator {
public:
  int init(const int64_t column_cnt); // 按列数分配数组
  int calc_column_checksum(
      const ObIArray<share::schema::ObColDesc> &col_descs,
      const blocksstable::ObDatumRow *new_row,
      const blocksstable::ObDatumRow *old_row,
      const bool *is_column_changed);
  int64_t *get_column_checksum() const { return column_checksum_; }

private:
  int64_t *column_checksum_;  // 每列的独立校验和
  int64_t column_cnt_;
};
```

**增量计算逻辑**（`ob_column_checksum_calculator.cpp:42-88`）：

```cpp
int ObColumnChecksumCalculator::calc_column_checksum(
    const ObIArray<ObColDesc> &col_descs,
    const blocksstable::ObDatumRow *new_row,
    const blocksstable::ObDatumRow *old_row,
    const bool *is_column_changed)
{
  if (new_row->row_flag_.is_delete()) {
    // 删除行：从旧行中减去校验和
    if (old_row->row_flag_.is_exist_without_delete()) {
      calc_column_checksum(col_descs, *old_row, false, NULL, column_checksum_);
    }
  } else if (new_row->row_flag_.is_exist_without_delete()) {
    // 存在行：先减旧行，再加新行（增量差异）
    if (nullptr != old_row && old_row->row_flag_.is_exist_without_delete()) {
      calc_column_checksum(col_descs, *old_row, false, is_column_changed, ...);
      calc_column_checksum(col_descs, *new_row, true, is_column_changed, ...);
    } else {
      calc_column_checksum(col_descs, *new_row, true, is_column_changed, ...);
    }
  }
}
```

**关键设计：加减法语义。** 列校验和的计算使用增量模式：
- `new_row = true`：列校验和 `+=` 行数据的 checksum
- `new_row = false`：列校验和 `-=` 行数据的 checksum

这允许在**行替换**场景中直接计算差异，而不需要重算整个 SSTable。

**列变更过滤：** 通过 `is_column_changed[]` 数组可以跳过未变更的列（`ob_column_checksum_calculator.cpp:120-127`）：

```cpp
for (int64_t i = 0; i < row.count_; ++i) {
  if ((NULL != column_changed && !column_changed[i])
      || col_desc.col_type_.is_lob_storage()) {
    continue;  // 未变更的列或 LOB 列跳过
  }
  tmp_checksum = row.storage_datums_[i].checksum(0);
  if (new_row) {
    column_checksum[i] += tmp_checksum;
  } else {
    column_checksum[i] -= tmp_checksum;
  }
}
```

**LOB 列始终跳过**校验和计算，因为 LOB 数据通常存在专门的 LOB 存储中，其完整性由 LOB 存储系统独立保障。

### 4.2 ObColumnChecksumAccumulator

`ObColumnChecksumAccumulator`（`ob_column_checksum_calculator.h:43-55`）是**线程安全**的列校验和累加器：

```cpp
class ObColumnChecksumAccumulator {
public:
  int add_column_checksum(const int64_t column_cnt,
                          const int64_t *column_checksum);
  int64_t *get_column_checksum() const { return column_checksum_; }

private:
  int64_t *column_checksum_;
  lib::ObMutex lock_;  // 互斥锁保护并发累加
};
```

核心实现（`ob_column_checksum_calculator.cpp:149-162`）：

```cpp
int ObColumnChecksumAccumulator::add_column_checksum(
    const int64_t column_cnt, const int64_t *column_checksum)
{
  lib::ObMutexGuard guard(lock_);
  for (int64_t i = 0; i < column_cnt; ++i) {
    column_checksum_[i] += column_checksum[i];
  }
}
```

### 4.3 ObSSTableColumnChecksum

`ObSSTableColumnChecksum`（`ob_column_checksum_calculator.h:58-78`）是高层统筹类，管理多个并发计算器的累加：

```cpp
class ObSSTableColumnChecksum {
public:
  int get_checksum_calculator(      // 获取第 idx 个计算器
      const int64_t idx,
      ObColumnChecksumCalculator *&checksum_calc);
  int accumulate_task_checksum();   // 汇总所有计算器的结果到累加器

private:
  common::ObSEArray<ObColumnChecksumCalculator *, ...> checksums_;
  ObColumnChecksumAccumulator accumulator_;
};
```

**合并流程：**
1. 创建多个 `ObColumnChecksumCalculator`，每个处理一个并行子任务
2. 每个子任务计算出自己的列校验和数组
3. `accumulate_task_checksum()` 将所有子任务的结果累加到 `ObColumnChecksumAccumulator`

---

## 5. 日志级校验和（LogChecksum）

### 5.1 数据结构

`LogChecksum`（`log_checksum.h:20-42`）是 PALF（Paxos-based ALF）日志系统的校验和管理器：

```cpp
class LogChecksum {
public:
  int init(const int64_t id, const int64_t accum_checksum);
  void destroy();

  // 获取累积校验和（写入日志时调用）
  int acquire_accum_checksum(const int64_t data_checksum,
                             int64_t &accum_checksum);

  // 验证累积校验和（读取/回放日志时调用）
  int verify_accum_checksum(const int64_t data_checksum,
                            const int64_t accum_checksum);

  // 回滚校验和（日志写入失败时）
  int rollback_accum_checksum(const int64_t curr_accum_checksum);

private:
  int64_t palf_id_;
  int64_t prev_accum_checksum_;  // 前一个校验和（用于回滚）
  int64_t accum_checksum_;       // 当前累积校验和
  int64_t verify_checksum_;      // 验证校验和
};
```

### 5.2 写入时的校验和计算

`acquire_accum_checksum()`（`log_checksum.cpp:53-67`）：

```cpp
int LogChecksum::acquire_accum_checksum(
    const int64_t data_checksum, int64_t &accum_checksum)
{
  prev_accum_checksum_ = accum_checksum_;
  accum_checksum_ = common::ob_crc64(
      accum_checksum_, const_cast<int64_t *>(&data_checksum),
      sizeof(data_checksum));
  accum_checksum = accum_checksum_;
}
```

**链式累积：** 与行级 checksum 一样，日志校验和也是链式的——每个新的日志条目的 `accum_checksum_` 由 `crc64(前一个累积校验和, 当前数据校验和)` 计算。

**`prev_accum_checksum_`** 的保存是为了支持 **校验和回滚**——当日志写入失败时，可以恢复到写入前的状态。

### 5.3 读取/回放时的校验验证

`verify_accum_checksum()`（`log_checksum.cpp:72-90`）：

```cpp
int LogChecksum::verify_accum_checksum(
    const int64_t data_checksum, const int64_t accum_checksum)
{
  int ret = OB_SUCCESS;
  int64_t new_verify_checksum = -1;
  int64_t old_verify_checksum = verify_checksum_;
  if (OB_FAIL(verify_accum_checksum(
          old_verify_checksum, data_checksum,
          accum_checksum, new_verify_checksum))) {
    PALF_LOG(ERROR, "verify_accum_checksum failed", ...);
  } else {
    verify_checksum_ = new_verify_checksum;
  }
}
```

**关键设计：双重校验和。** `LogChecksum` 维护两个校验和状态：
- **`accum_checksum_`**——写入路径使用的累积校验和（不断追加）
- **`verify_checksum_`**——验证路径使用的校验和（独立累积）

这允许 **写入和验证同时进行而互不干扰**。写入路径可以持续产生新的日志条目，而验证路径可以独立地回放和验证历史日志。

静态验证方法（`log_checksum.cpp:88-101`）：

```cpp
int LogChecksum::verify_accum_checksum(
    const int64_t old_accum_checksum,
    const int64_t data_checksum,
    const int64_t expected_accum_checksum,
    int64_t &new_accum_checksum)
{
  new_accum_checksum = common::ob_crc64(
      old_accum_checksum, const_cast<int64_t *>(&data_checksum),
      sizeof(data_checksum));
  if (new_accum_checksum != expected_accum_checksum) {
    ret = common::OB_CHECKSUM_ERROR;
    LOG_DBA_ERROR(OB_CHECKSUM_ERROR, "msg", "log checksum error", ...);
    LOG_DBA_ERROR_V2(OB_LOG_CHECKSUM_MISMATCH, ret, "log checksum error");
  }
}
```

**校验失败处理：** 当校验和不匹配时：
1. 返回 `OB_CHECKSUM_ERROR` 错误码
2. 记录 DBA 级别的错误日志：`"log checksum error"`
3. 触发 `OB_LOG_CHECKSUM_MISMATCH` 的 DBA 告警

### 5.4 回滚机制

`rollback_accum_checksum()`（`log_checksum.cpp:103-116`）：

```cpp
int LogChecksum::rollback_accum_checksum(
    const int64_t curr_accum_checksum)
{
  if (curr_accum_checksum != accum_checksum_) {
    ret = OB_STATE_NOT_MATCH; // 状态不匹配，拒绝回滚
  } else {
    accum_checksum_ = prev_accum_checksum_;
    prev_accum_checksum_ = 0;
  }
}
```

**安全保护：** 只有当前累积校验和与期望值匹配时才执行回滚，防止并发写入导致状态不一致。

---

## 6. 数据验证服务（ObDataValidationService）

### 6.1 设计意图

`ObDataValidationService`（`ob_data_validation_service.h/cpp`）是 OceanBase 的**数据验证与保护服务**。该服务的核心职责是：

> **在检测到数据正确性问题（checksum 校验失败等）后，延迟资源回收，为诊断和修复争取时间。**

### 6.2 接口

```cpp
class ObDataValidationService {
public:
  // 检查是否需要延迟资源回收
  static bool need_delay_resource_recycle(const ObLSID ls_id);

  // 设置延迟资源回收标志
  static void set_delay_resource_recycle(const ObLSID ls_id);
};
```

### 6.3 实现分析

`need_delay_resource_recycle()`（`ob_data_validation_service.cpp:20-49`）：

```cpp
bool ObDataValidationService::need_delay_resource_recycle(
    const ObLSID ls_id)
{
  const bool need_delay_opt =
      GCONF._delay_resource_recycle_after_correctness_issue;
  // ...

  if (OB_LIKELY(!GCONF._delay_resource_recycle_after_correctness_issue)) {
    // 配置关闭，不做延迟
  } else if (OB_FAIL(ls_service->get_ls(ls_id, handle, ...))) {
    // 日志流不存在，跳过
  } else {
    need_delay_ret = ls->need_delay_resource_recycle() && need_delay_opt;
  }

  return need_delay_ret;
}
```

`set_delay_resource_recycle()`（`ob_data_validation_service.cpp:51-77`）：

```cpp
void ObDataValidationService::set_delay_resource_recycle(
    const ObLSID ls_id)
{
  const bool need_delay_opt =
      GCONF._delay_resource_recycle_after_correctness_issue;
  if (OB_LIKELY(!need_delay_opt)) {
    // do nothing
  } else {
    ls->set_delay_resource_recycle();
  }
}
```

**配置控制：** 通过隐藏配置项 `_delay_resource_recycle_after_correctness_issue` 控制是否启用该功能。这在生产环境中由 DBA 按需开启。

### 6.4 与 Checksum 校验的协作

数据验证服务与 checksum 系统的协作流程：

```
校验失败检测（Checksum 层）
    │
    v
ObDataValidationService::set_delay_resource_recycle(ls_id)
    │
    v
日志流（LS）标记需要延迟资源回收
    │
    v
资源回收线程检查 ObDataValidationService::need_delay_resource_recycle()
    │
    v
延迟回收 → 保留数据用于诊断/修复
```

---

## 7. 设计决策

### 7.1 多级校验的层次设计

| 层次 | 位置 | 校验范围 | 算法 | 粒度 | 计算时机 |
|------|------|----------|------|------|----------|
| **行级** | MVCC 事务节点 | 单个行数据 + 前驱校验和 | ObBatchChecksum (CRC) | 行 | 事务提交时 |
| **微块级** | MicroBlock | 行数据 + 列数据 | ob_crc64_sse42 | 行/列 | SSTable 写入时 |
| **宏块级** | ObSSTableMeta | 整块数据 + 列校验和数组 | CRC64 | 块 | 合并完成时 |
| **日志级** | PALF 日志 | 日志条目链 | ob_crc64 | 日志条目 | 日志写入/回放时 |

**为什么需要多层？**

- **行级**——最早发现内存表中的数据损坏，在写入 Memtable 时即刻检测
- **微块级**——覆盖持久化到磁盘的数据块，检测 I/O 路径的比特翻转
- **宏块级**——合并场景的端到端数据完整性保证
- **日志级**——Paxos 日志复制的数据完整性，保证主从一致性

### 7.2 链式校验的设计哲学

行级和日志级校验和都采用了**链式设计**：

```
acc_checksum_N = crc(acc_checksum_{N-1} + data_N)
```

**优势：**
- 任何中间节点的损坏都会导致后续所有节点的校验失败
- 无需额外的校验和字典或索引
- 天然支持追加写入场景（日志、MVCC 节点链）

**代价：**
- 只能发现最近的完整链中存在的问题，无法独立校验单个节点
- 回滚时需要恢复前一个状态（LogChecksum 通过 `prev_accum_checksum_` 支持）

### 7.3 性能优化

**SSE4.2 硬件加速：**

微块级校验和使用了 `ob_crc64_sse42`（基于 Intel SSE4.2 CRC32 指令）：

```cpp
micro_block_row_checksum_ = ob_crc64_sse42(
    micro_block_row_checksum_,
    static_cast<void*>(integer_col_buf_),
    sizeof(int64_t) * integer_col_cnt_);
```

同时存在：
- `cal_column_checksum_normal()`——通用路径
- `cal_column_checksum_sse42()`——SSE4.2 硬件加速路径

**整数列优化路径：** `ObMicroBlockChecksumHelper` 将整数列的值批量收集到一个连续缓冲区后一次性 CRC，减少函数调用和间接寻址开销。

**增量计算：** `ObColumnChecksumCalculator` 使用加减法语义，只对变更的行计算校验和差异，避免全量重算。

### 7.4 校验失败的处理策略

| 层次 | 失败处理 | 恢复措施 |
|------|---------|---------|
| 行级 | `OB_CHECKSUM_ERROR`，日志 ERROR | 测试校验和检测是否确实损坏 |
| 微块/宏块级 | 校验失败可能触发数据修复流程 | 从副本读取恢复 |
| 日志级 | `OB_CHECKSUM_ERROR` + DBA 告警 | 从其他 PALF 成员拉取日志修复 |
| 数据验证服务 | 延迟资源回收 | 保留数据用于诊断，等待 DBA 介入 |

### 7.5 分布式一致性校验

OceanBase 的 checksum 体系支持分布式场景：

- **列校验和传播**：合并过程的列校验和会随 SSTable 元数据一起持久化，在副本间复制
- **LogChecksum 的复制**：PALF 日志的累积校验和随日志条目在 Paxos 组中复制，从节点验证时比对
- **数据验证服务**：检测到正确性问题后延迟资源回收，给分布式修复留出时间窗口

---

## 8. 源码索引

| 文件 | 关键内容 | 行号 |
|------|---------|------|
| `src/storage/memtable/mvcc/ob_mvcc_row.h` | `ObMvccTransNode` 结构体定义（`modify_count_`、`acc_checksum_`） | 142-160 |
| `src/storage/memtable/mvcc/ob_mvcc_row.h` | `checksum()`、`m_cal_acc_checksum()`、`cal_acc_checksum()`、`verify_acc_checksum()` 声明 | 173-178 |
| `src/storage/memtable/mvcc/ob_mvcc_row.cpp` | `checksum()` 实现（`modify_count_` + `type_`） | 32-35 |
| `src/storage/memtable/mvcc/ob_mvcc_row.cpp` | `m_cal_acc_checksum()` 链式校验和计算 | 38-45 |
| `src/storage/memtable/mvcc/ob_mvcc_row.cpp` | `cal_acc_checksum()` 设置校验和 | 48-53 |
| `src/storage/memtable/mvcc/ob_mvcc_row.cpp` | `verify_acc_checksum()` 校验和验证 | 56-68 |
| `src/storage/blocksstable/ob_micro_block_checksum_helper.h` | `ObMicroBlockChecksumHelper` 类（行/列校验和） | 24-94 |
| `src/storage/blocksstable/ob_micro_block_checksum_helper.h` | `cal_row_checksum()` 微块行校验和 | 98-130 |
| `src/storage/blocksstable/ob_micro_block_checksum_helper.h` | `cal_column_checksum()` 列校验和（DatumRow） | 49-60 |
| `src/storage/blocksstable/ob_micro_block_checksum_helper.h` | `cal_column_checksum_sse42()` SSE4.2 路径 | 76 |
| `src/storage/blocksstable/ob_major_checksum_info.h` | `ObMajorChecksumInfo` 宏块校验信息类 | 27-84 |
| `src/storage/blocksstable/ob_major_checksum_info.h` | `ObCOMajorChecksumInfo` 列组扩展类 | 87-103 |
| `src/storage/blocksstable/ob_column_checksum_struct.h` | `ObColumnCkmStruct` 列校验和结构 | 20-58 |
| `src/storage/compaction/ob_column_checksum_calculator.h` | `ObColumnChecksumCalculator` 类 | 20-40 |
| `src/storage/compaction/ob_column_checksum_calculator.h` | `ObColumnChecksumAccumulator` 线程安全累加器 | 43-55 |
| `src/storage/compaction/ob_column_checksum_calculator.h` | `ObSSTableColumnChecksum` 高层统筹类 | 58-78 |
| `src/storage/compaction/ob_column_checksum_calculator.cpp` | `calc_column_checksum()` 增量差异计算 | 42-88 |
| `src/storage/compaction/ob_column_checksum_calculator.cpp` | 列级增量计算（加减法） | 117-128 |
| `src/storage/compaction/ob_column_checksum_calculator.cpp` | `add_column_checksum()` 线程安全累加 | 149-162 |
| `src/logservice/palf/log_checksum.h` | `LogChecksum` 日志校验和类（双状态设计） | 20-42 |
| `src/logservice/palf/log_checksum.cpp` | `acquire_accum_checksum()` 写入校验和 | 53-67 |
| `src/logservice/palf/log_checksum.cpp` | `verify_accum_checksum()` 验证校验和 | 72-90 |
| `src/logservice/palf/log_checksum.cpp` | `verify_accum_checksum()` 静态验证（含 DBA 告警） | 88-101 |
| `src/logservice/palf/log_checksum.cpp` | `rollback_accum_checksum()` 校验和回滚 | 103-116 |
| `src/storage/concurrency_control/ob_data_validation_service.h` | `ObDataValidationService`（延迟资源回收） | 20-32 |
| `src/storage/concurrency_control/ob_data_validation_service.cpp` | `need_delay_resource_recycle()` 实现 | 20-49 |
| `src/storage/concurrency_control/ob_data_validation_service.cpp` | `set_delay_resource_recycle()` 实现 | 51-77 |
| `src/share/datum/ob_datum.h` | `ObDatum::checksum()` 单 Datum CRC64 校验 | 849-856 |
| `src/storage/memtable/mvcc/ob_mvcc_trans_ctx.cpp` | 行级 checksum 的实际调用场景 | 2090 |

---

## 9. 总结

OceanBase 的 Checksum 体系是一个**多层次、链式累积、硬件加速**的数据完整性保护系统：

1. **行级**（`ObMvccTransNode`）——事务粒度的链式校验和，在 Memtable 写入时实时检测数据损坏
2. **微块级**（`ObMicroBlockChecksumHelper`）——SSTable 块级别的行/列校验和，支持 SSE4.2 批量加速
3. **宏块级**（`ObMajorChecksumInfo`）——合并过程的端到端数据完整性校验，包含行列完整的校验和信息
4. **列级**（`ObColumnChecksumCalculator`）——合并时列粒度的增量差异计算，支持并发累加
5. **日志级**（`LogChecksum`）——PALF 日志的链式校验和，写入/验证双状态独立管理，支持回滚
6. **数据验证服务**（`ObDataValidationService`）——检测到正确性问题后的保护机制，延迟资源回收

**四个关键设计模式：**

- **链式累积**——行级和日志级都采用 CRC(prev_checksum, data) 模式，形成不可篡改的校验链
- **增量差异**——列校验和计算使用加减法语义，只计算变更数据的差异
- **双状态独立**——日志级校验和分离写入状态（`accum_checksum_`）和验证状态（`verify_checksum_`），支持并发读写
- **硬件加速**——SSE4.2 CRC32 指令集用于微块级批量校验，`ObDatum::checksum()` 也使用 `ob_crc64_sse42`
