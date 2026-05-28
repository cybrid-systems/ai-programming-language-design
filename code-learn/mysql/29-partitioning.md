# 29. InnoDB 分区表（Partitioning）— 源码分析

> 本文分析 InnoDB 分区表的实现机制，包括分区类型、分区裁剪（pruning）、分区通信（partition exchange）和分区管理（ADD/DROP/TRUNCATE）。核心源文件：`sql/sql_partition.cc`、`sql/partition_info.h`、`ha_partition.cc`。

---

## 0. 概述

MySQL 的分区表实现位于 **SQL 层**，而不是 InnoDB 层。每个分区实际上是一个独立的 InnoDB 表（有自己的 `.ibd` 文件），SQL 层负责路由查询到正确的分区。

### 分区表的逻辑模型

```
CREATE TABLE t (a INT, b DATE) ENGINE=InnoDB
  PARTITION BY RANGE (YEAR(b)) (
    PARTITION p0 VALUES LESS THAN (1990),
    PARTITION p1 VALUES LESS THAN (2000),
    PARTITION p2 VALUES LESS THAN (2010),
    PARTITION p3 VALUES LESS THAN MAXVALUE
  );

逻辑: t (单个表)
物理:
  t#p0.ibd  (分区 p0)
  t#p1.ibd  (分区 p1)
  t#p2.ibd  (分区 p2)
  t#p3.ibd  (分区 p3)
```

---

## 1. 分区类型

### 1.1 RANGE 分区

```sql
PARTITION BY RANGE (expr) (
  PARTITION p0 VALUES LESS THAN (10),
  PARTITION p1 VALUES LESS THAN (20),
  PARTITION p2 VALUES LESS THAN (30)
);
```

### 1.2 LIST 分区

```sql
PARTITION BY LIST (expr) (
  PARTITION p_north VALUES IN ('CN','JP','KR'),
  PARTITION p_europe VALUES IN ('DE','FR','UK'),
  PARTITION p_other VALUES IN (DEFAULT)
);
```

### 1.3 HASH 分区

```sql
PARTITION BY HASH (expr) PARTITIONS 8;
-- 使用 expr % 8 将行路由到不同分区
```

### 1.4 KEY 分区

```sql
PARTITION BY KEY (col) PARTITIONS 8;
-- 使用 MySQL 内置 hash 函数（不是用户定义的表达式）
```

### 1.5 子分区

```sql
PARTITION BY RANGE (YEAR(date))
  SUBPARTITION BY HASH (TO_DAYS(date)) SUBPARTITIONS 4 (
    PARTITION p2020 VALUES LESS THAN (2021),
    PARTITION p2021 VALUES LESS THAN (2022)
  );
```

---

## 2. 分区裁剪（Pruning）

分区裁剪是分区表性能的关键：优化器通过 WHERE 条件只访问匹配的分区，而不是扫描所有分区。

### 2.1 编译时裁剪

```cpp
// sql/partition_info.h
class Partition_info {
 public:
  /* 分区裁剪结果 */
  Bitmap<64> m_partition_bitmap;  /* 需要访问的分区位图 */
  Bitmap<64> m_subpartition_bitmap; /* 需要访问的子分区位图 */

  /* 条件分析 */
  Item *m_partition_func;  /* 分区函数表达式 */
  List<partition_element> m_templates; /* 分区模板 */

  /* 裁剪 */
  bool prune_by_conditions(THD *thd);
  bool prune_by_partition_column(Field *field, Item *cond);
};
```

**裁剪示例**：

```sql
SELECT * FROM t WHERE b >= '2000-01-01' AND b < '2010-01-01'
  └─ 分区函数: YEAR(b)
  └─ 索引: 从条件推出 YEAR(b) ∈ [2000, 2009]
  └─ 匹配分区: p1 (2000) 和 p2 (2000-2009)
  └─ 不匹配: p0 (1990-1999) 和 p3 (2010+)
  → 只扫描 p1 和 p2 两个分区文件
```

### 2.2 运行时裁剪

```cpp
// ha_partition.cc — 分区表处理函数
int ha_partition::rnd_next(uchar *buf) {
  while (true) {
    /* 先尝试当前分区的 rnd_next */
    result = m_curr_part_file->rnd_next(buf);
    if (result != HA_ERR_END_OF_FILE) {
      return result;  /* 当前分区有下一行 */
    }

    /* 当前分区读取完毕 → 切换到下一个需要访问的分区 */
    m_curr_part_id = m_partition_bitmap.get_next_set(m_curr_part_id + 1);
    if (m_curr_part_id == Bitmap::END) {
      return HA_ERR_END_OF_FILE;  /* 所有分区都读完了 */
    }

    /* 打开下一个分区文件 */
    open_partition_file(m_curr_part_id);
  }
}
```

### 2.3 TRUNCATE/ALTER 的裁剪

```sql
ALTER TABLE t TRUNCATE PARTITION p0;
  → 只删除 p0 对应的 .ibd 文件，其他分区不受影响

ALTER TABLE t ADD PARTITION (PARTITION p4 VALUES LESS THAN (2040));
  → 只创建新的 .ibd 文件，不涉及已有数据
```

---

## 3. 分区表限制

| 限制 | 说明 |
|------|------|
| 最大分区数 | 8192 个分区（含子分区） |
| 分区列 | 必须是**整数**或返回整数的表达式（RANGE/LIST/HASH）|
| KEY 分区 | 可以使用其他类型（BLOB/TEXT 除外） |
| 外键 | 分区表**不支持**外键 |
| 全文索引 | 分区表**不支持**全文索引 |
| 唯一索引 | 分区键必须在所有唯一索引中 |
| 空间索引 | 分区表**不支持**空间索引 |
| 分区表上的 DDL | 某些 DDL（如 MODIFY PARTITION BY）会阻塞 |

### 分区键与唯一索引的限制

```sql
CREATE TABLE t (a INT, b INT, UNIQUE KEY (a))
  PARTITION BY RANGE (b) (              -- 错误！
    PARTITION p0 VALUES LESS THAN (10),
    PARTITION p1 VALUES LESS THAN (20)
  );
-- 错误: 唯一键 a 不包含分区键 b
-- 因为 a 的全局唯一性在分区上无法保证

-- 正确:
CREATE TABLE t (a INT, b INT, PRIMARY KEY (a, b))
  PARTITION BY RANGE (b) (...);  -- 分区键 b 在主键中
```

---

## 4. 分区管理操作

| 操作 | 锁 | 说明 |
|------|----|------|
| `ADD PARTITION` | X | 新增分区（RANGE/LIST 的末尾） |
| `DROP PARTITION` | X | 删除分区及其数据 |
| `TRUNCATE PARTITION` | X | 清空分区数据 |
| `REORGANIZE PARTITION` | X | 分区分裂/合并 |
| `EXCHANGE PARTITION` | X | 分区与非分区表交换 |
| `COALESCE PARTITION` | X | 减少 HASH/KEY 分区数 |
| `REBUILD PARTITION` | X | 重建分区（压缩/行格式变化） |

---

## 5. 与 InnoDB 的交互

分区表使用 `ha_partition` 作为 `handler` 层，它将操作委托给每个分区的 `ha_innodb` 实例：

```cpp
// ha_partition.cc
class ha_partition : public handler {
  /* 每个分区对应一个底层 handler 实例 */
  handler **m_file;           /* 长度 = total_partitions */
  uint m_tot_parts;           /* 总分区数 */

  /* 当前操作的分区 */
  uint m_curr_part_id;

  /* 分区裁剪结果 */
  Bitmap<64> m_partitions_to_scan;

  /* 委托操作 */
  int write_row(uchar *buf) override {
    /* 计算行属于哪个分区 */
    m_curr_part_id = get_partition_id(buf);

    /* 委托给对应分区的 handler */
    return m_file[m_curr_part_id]->write_row(buf);
  }

  int update_row(uchar *old_data, uchar *new_data) override {
    old_part = get_partition_id(old_data);
    new_part = get_partition_id(new_data);
    if (old_part == new_part) {
      /* 同分区更新 → 直接委派 */
      return m_file[old_part]->update_row(old_data, new_data);
    } else {
      /* 跨分区更新 → DELETE + INSERT */
      m_file[old_part]->delete_row(old_data);
      m_file[new_part]->insert_row(new_data);
    }
  }
};
```

---

## 6. 源码索引

| 函数/结构 | 文件 | 关键作用 |
|-----------|------|---------|
| `Partition_info` | `sql/partition_info.h` | 分区定义与裁剪 |
| `ha_partition` | `ha_partition.cc` | 分区表 handler |
| `prune_by_conditions()` | `sql/partition_info.cc` | 分区裁剪 |
| `get_partition_id()` | `sql/sql_partition.cc` | 计算行所属分区 ID |
| `partition_element` | `sql/partition_info.h` | 单个分区描述 |
