# 28. InnoDB 页面压缩 (Page Compression)

> 本文分析 InnoDB 的两种页面压缩机制：Transparent Page Compression（TPC，透明压缩）和 Compressed Row Format（COMPRESSED 行格式）。核心文件：`page0zip.cc`、`page0zip.h`、`buf0buf.h`、`page0cur.cc`。

---

## 1. 概述

InnoDB 支持两种独立的页面压缩方式，实现原理完全不同：

| 特性 | COMPRESSED 行格式 | TPC 透明压缩 |
|------|-------------------|-------------|
| 压缩算法 | zlib（固定） | lz4 / zlib（可选） |
| 技术实现 | 独立压缩页 + zlib | 文件系统 Punch Hole（fallocate） |
| 数据文件 | 独立压缩页文件 | 稀疏文件（holes） |
| 内存占用 | 压缩+解压两副本 | 仅解压副本 |
| 随机读取性能 | 差（每次需解压） | 好 |
| 文件系统要求 | 无 | 支持 `FALLOC_FL_PUNCH_HOLE` |
| 行格式 | REDUNDANT / COMPACT | DYNAMIC / COMPRESSED |

---

## 2. COMPRESSED 行格式

### 2.1 数据结构

```cpp
// page0zip.h — 压缩页描述符
struct page_zip_des_t {
  byte *data;           // 压缩数据缓冲区
  ulint m_size;         // 压缩后大小（~2KB）
  ulint m_n_blobs;      // 压缩后外部 blob 数
  ulint m_n_bits;       // 大小编码位数
};
```

每个 `buf_block_t` 在 COMPRESSED 行格式时包含 `page_zip_des_t`：

```cpp
// buf0buf.h:1764 — buf_block_t
struct buf_block_t {
  buf_page_t page;            // 基础页面（含 zip.data 指针）
  byte *frame;                // 解压页帧
  // zip 信息在 buf_page_t 中通过 zip.data 访问
};
```

### 2.2 压缩过程

```cpp
// page0zip.cc — 页面压缩入口
void page_zip_compress(page_zip_des_t *zip, const page_t *page,
                       dict_index_t *index, ulint n_dul, mtr_t *mtr) {
  // Step 1: 分析页内记录
  // Step 2: 对数据字段应用 zlib 压缩
  // Step 3: 对索引字段保持未压缩（用于索引比较）
  // Step 4: 存储压缩结果到 zip.data
  // Step 5: 更新页面类型为 FIL_PAGE_COMPRESSED
}
```

### 2.3 解压过程

```cpp
// page0cur.cc — 页访问时解压
void page_zip_decompress(page_zip_des_t *zip, page_t *page, bool all) {
  // Step 1: zlib 解压数据
  // Step 2: 重建页内 Slot、Record 偏移数组
  // Step 3: 填充 page->frame 供上层访问
}
```

### 2.4 COMPRESSED 行格式的限制

- **Buffer Pool 中同时存在压缩页和解压页**（两副本），内存占用翻倍
- DML 操作先在解压页上进行，然后重新压缩写入
- 适用于只读/低频写入场景
- `KEY_BLOCK_SIZE` 指定压缩页大小：1/2/4/8KB（默认是正常页的一半）

---

## 3. Transparent Page Compression (TPC)

### 3.1 原理

TPC 在页面写入磁盘后，使用 `fallocate(FALLOC_FL_PUNCH_HOLE)` 打孔删除未使用的文件区域：

```
写入前（完整 16KB 页）：
┌──────────────────────────────┐
│    page frame (16384 bytes)  │
└──────────────────────────────┘

压缩后（假设压缩率 5:1）：
┌────┬─────────────────────────┐
│meta│       hole              │ 文件大小 ~3KB
└────┴─────────────────────────┘
```

### 3.2 内核支持

```cpp
// fil0fil.h:160 — fil_node_t
struct fil_node_t {
  bool punch_hole;          // 是否支持打孔（基于 filesystem 检测）
  size_t block_size;        // 打孔对齐块大小（通常 4KB）
};
```

### 3.3 TPC 配置

```sql
CREATE TABLE t1 (c1 INT) COMPRESSION='lz4';
ALTER TABLE t1 COMPRESSION='zlib';
```

- `lz4`：CPU 开销低，压缩率中等
- `zlib`：CPU 开销高，压缩率更高

### 3.4 写入路径

```
buf_flush_write_page_low()
  ├─ 写完整解压页到磁盘（os_file_write）
  ├─ 应用压缩算法（lz4/zlib）
  ├─ 计算需要打孔的偏移量
  │   └─ punch_offset = round_up(compressed_size, block_size)
  ├─ 文件系统 fallocate(PUNCH_HOLE, punch_offset, ...)
  └─ 更新文件节点修改计数器
```

---

## 4. 性能对比

| 场景 | COMPRESSED | TPC |
|------|-----------|-----|
| 热读（Buffer Pool 命中） | 快（解压页已在内存） | 快 |
| 冷读（磁盘读取） | 慢（需解压） | 快（页缓存解压） |
| 大范围扫描 | 差 | 好 |
| 随机点查询 | 可接受 | 好 |
| 写入放大 | 少（仅压缩数据） | 较大（写完整页再打孔） |
| 表空间使用 | 固定压缩后大小 | 文件系统稀疏文件 |

---

## 5. 压缩与索引扫描

COMPRESSED 格式在索引比较时使用**未压缩的索引字段**（在 `page_zip_compress` 中保留），避免每次比较都需解压整页。TPC 则始终以完整解压页操作。

---

## 6. 总结

1. **COMPRESSED 行格式**：适合只读/低频写场景，Buffer Pool 需双倍内存。
2. **TPC 透明压缩**：适合各类工作负载，通过文件系统打孔减少存储。
3. **TPC 的文件系统依赖**：需要 `fallocate(PUNCH_HOLE)` 支持（ext4 / xfs / btrfs / ZFS）。
4. **压缩算法选择**：lz4 节省 CPU，zlib 节省空间。

### 源码引用汇总

| 文件 | 行号 | 关键内容 |
|------|------|----------|
| `page0zip.h` | — | `struct page_zip_des_t` |
| `fil0fil.h` | 160 | `struct fil_node_t`（punch_hole, block_size） |
| `buf0buf.h` | 1764 | `struct buf_block_t` 和 zip 信息 |
