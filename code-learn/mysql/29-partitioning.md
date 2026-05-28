# 29. MySQL 分区表 (Partitioning)

> 本文分析 MySQL 分区表的实现，包括分区类型、分区裁剪（Pruning）、分区选择算法、分区维护操作。核心文件：`sql/partitioning/`。

---

## 1. 概述

MySQL 分区表在 **SQL 层** 实现，存储引擎（InnoDB）看到的是多个独立的物理表（每个分区一个单独的 `dict_table_t`）。分区操作对用户透明，优化器在查询时通过 **分区裁剪** 排除不相关的分区。

| 类型 | 语法 | 说明 |
|------|------|------|
| RANGE | `PARTITION BY RANGE (expr)` | 按值范围分 |
| LIST | `PARTITION BY LIST (expr)` | 按值列表分 |
| HASH | `PARTITION BY HASH (expr)` | 按哈希函数取模 |
| KEY | `PARTITION BY KEY ()` | 按 MySQL 内置哈希 |
| RANGE COLUMNS | `PARTITION BY RANGE COLUMNS(col1,...)` | 多列范围 |
| LIST COLUMNS | `PARTITION BY LIST COLUMNS(col1,...)` | 多列列表 |
| SUBPARTITION | `SUBPARTITION BY HASH/KEY` | 复合分区（分区 → 子分区） |

---

## 2. 架构

```
MySQL SQL Layer
  └─ TABLE (分区表的逻辑表示)
       ├─ partition_info（分区元数据）
       └─ 实际存储引擎表列表
            ├─ partition#0 (ha_innopart handler → ha_innobase)
            ├─ partition#1 (ha_innopart handler → ha_innobase)
            ├─ ...
            └─ partition#N (ha_innopart handler → ha_innobase)
```

每个分区通过 `ha_innopart` handler 封装底层的 `ha_innobase`：

```cpp
// ha_innopart.cc — 分区 handler
class ha_innopart : public handler {
  // 每个分区一个 ha_innobase 实例
  // handle 数组：m_innodb_table[index]
  // 分区裁剪结果：m_part_iter.bitmap
};
```

---

## 3. 分区裁剪 (Partition Pruning)

### 3.1 裁剪流程

```
JOIN::optimize()
  └─ prune_table_partitions()        # sql_partition_admin.cc
      └─ partition_info::prune_scan_partitions()
          ├─ 读取 WHERE 条件中的分区键值
          ├─ 根据分区类型计算匹配分区
          │   ├─ RANGE: 二分查找
          │   ├─ LIST: bitmap 查找
          │   ├─ HASH: hash_value % num_partitions
          │   └─ KEY: 内置 hash 函数
          └─ 生成需要扫描的 partition bitmap
```

### 3.2 分区信息结构

```cpp
// partition_element.h — 分区元素
struct partition_element {
  List<partition_element> subpartitions;  // 子分区列表
  longlong range_value;                   // RANGE 分区上限值
  const char *list_value;                 // LIST 分区值列表
  uint32_t partition_index;               // 分区号
  bool is_sub_partition;                  // 是否为子分区
};

// partition_info.h — 分区元数据
class partition_info {
  List<partition_element> partitions;    // 分区列表
  uint num_partitions;                   // 分区总数
  uint num_subpartitions;                // 子分区数
  partitioning_func *part_func;          // 分区函数
};
```

### 3.3 RANGE 分区选择算法

RANGE 分区通过**二分查找**快速定位：

```
假设分区定义：
  p0: VALUES LESS THAN (100)
  p1: VALUES LESS THAN (200)
  p2: VALUES LESS THAN (300)
  p3: VALUES LESS THAN MAXVALUE

查询 WHERE id = 150
  → 二分查找 [100, 200, 300, MAX] 找到 150
  → 落在 p1 范围（100 ≤ 150 < 200）
  → 需要扫描的 partitions = {1}
```

---

## 4. 分区维护操作

| 操作 | SQL | 实现方式 |
|------|-----|----------|
| TRUNCATE | `ALTER TABLE t TRUNCATE PARTITION p1` | 直接删除分区数据文件 |
| DROP | `ALTER TABLE t DROP PARTITION p1` | 删除分区及其数据 |
| ADD | `ALTER TABLE t ADD PARTITION p4` | 创建新分区（不涉及已有数据） |
| REORGANIZE | `ALTER TABLE t REORGANIZE PARTITION p1,p2 INTO ...` | 重建分区（类似 COPY DDL） |
| EXCHANGE | `ALTER TABLE t EXCHANGE PARTITION p1 WITH TABLE t2` | 元数据交换（快） |
| ANALYZE/CHECK/OPTIMIZE | `ALTER TABLE t ANALYZE PARTITION p1` | 作用于单个分区 |

---

## 5. 分区表的限制

- **外键**：分区表不支持外键约束
- **全文索引**：分区表不支持 FTS
- **唯一索引**：仅当包含所有分区键列时才支持唯一约束
- **空间索引**：分区表不支持空间索引
- **分区键列**：`RANGE/LIST` 分区键必须为整数或 COLUMNS 指定类型

---

## 6. 总结

1. **SQL 层实现**：分区逻辑在 SQL 层的 `partition_info` 中，InnoDB 不感知分区。
2. **独立物理表**：每个分区对应一个独立的 InnoDB 表空间/表。
3. **分区裁剪**：`prune_scan_partitions` 在优化阶段通过 bitmap 排除不相关分区。
4. **二分查找优化**：RANGE 分区通过 `range_value` 数组二分查找实现 O(log N) 裁剪。
5. **EXCHANGE 操作**：元数据级别快速交换分区与表。

### 源码引用汇总

| 文件 | 行号 | 关键内容 |
|------|------|----------|
| `partition_info.h` | — | `class partition_info` |
| `partition_element.h` | — | `struct partition_element` |
| `ha_innopart.cc` | — | `class ha_innopart` 分区 handler |
