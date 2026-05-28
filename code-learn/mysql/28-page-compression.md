# 28. InnoDB 页面压缩（Page Compression）— 源码分析

> 本文分析 InnoDB 页面压缩的机制，包括 COMPRESSED 行格式（Zip）、透明页压缩（Transparent Page Compression）、打孔（Punch Hole）和压缩算法的实现。核心源文件：`rem/rem0comp.cc`、`fil0fil.cc`、`buf0buf.cc`、`zlib`/`lz4`/`zstd` 集成。

---

## 0. 概述

InnoDB 支持两种页面压缩机制：

| 机制 | MySQL 版本 | 压缩算法 | 特点 |
|------|-----------|---------|------|
| COMPRESSED 行格式（Zip） | 5.1+ | zlib | 固定压缩页大小，BP 中存压缩页 |
| 透明页压缩（TPC） | 5.7+ | zlib / LZ4 / Zstandard | 使用文件打孔，BP 中存全页 |

---

## 1. COMPRESSED 行格式（Zip）

### 1.1 原理

`COMPRESSED` 行格式的表将数据页压缩后存储在磁盘上，Buffer Pool 中同时保留压缩页和解压页：

```
KEY_BLOCK_SIZE = N (1KB, 2KB, 4KB, 8KB)
  → 磁盘页面大小 = N (实际存储压缩数据)
  → Buffer Pool 页面大小 = N 和 16KB (解压时)
  → 缓冲池中每个压缩页对应一个解压页帧
```

### 1.2 创建

```sql
CREATE TABLE t (a INT) ROW_FORMAT=COMPRESSED KEY_BLOCK_SIZE=4;
-- KEY_BLOCK_SIZE=4 → 磁盘压缩页 4KB，BP 中维护 4KB + 16KB
```

### 1.3 实现

```cpp
// rem/rem0comp.cc
bool page_zip_compress(page_zip_t *page_zip, page_t *page,
                       dict_index_t *index, ulint level, mtr_t *mtr) {

  /* ──── 步骤 1：收集页面中所有记录 ──── */
  /* 遍历 infimum → supremum 之间的所有记录 */

  /* ──── 步骤 2：选择压缩策略 ──── */
  /* 如果页面只有少量记录 → 用 trivial 压缩（只存偏移量表）*/
  /* 否则 → 使用 zlib 压缩 */

  /* ──── 步骤 3：写入压缩格式 ──── */
  /* 压缩格式 = 偏移量表 + 记录数据 + 额外信息 */
  /* 压缩后大小 ≤ KEY_BLOCK_SIZE */

  return true;
}
```

### 1.4 压缩页在 BP 中的管理

```cpp
// buf0buf.cc
struct buf_block_t {
  /* 压缩页（只读时从磁盘读取） */
  page_zip_t page_zip;
  /* 解压页（DML 操作时使用）*/
  page_t frame;    /* 16KB 或 KEY_BLOCK_SIZE */
};

void buf_page_get_zip_compact(page_id_t page_id, ...) {
  /* 读时：磁盘 → 压缩页 */
  /* 如果解压页不在 BP → 从压缩页解压 */
  if (!block->zip_has_uncompressed) {
    page_zip_decompress(&block->page_zip, block->frame);
    block->zip_has_uncompressed = true;
  }
}

void buf_page_flush_zip(...) {
  /* 写回时：压缩页 → 磁盘 */
  /* 如果只有压缩页修改 → 只写压缩页 */
  page_zip_compress(&block->page_zip, block->frame, ...);
}
```

### COMPRESSED 格式的优缺点

| 优点 | 缺点 |
|------|------|
| BP 节省（压缩页 + 解压页） | BP 占用两倍空间（压缩+解压） |
| 磁盘空间节省 50-70% | 更新需要解压再压缩（CPU 开销） |
| 适合只读或低频更新的热数据 | AHI 对压缩页支持有限 |

---

## 2. 透明页压缩（TPC）

### 2.1 原理

使用文件系统打孔（punch hole）机制：先写入完整页面，然后压缩并通知文件系统释放未使用的空间。

```
写入流程:
  1. 在 BP 中正常修改 16KB 页面
  2. 刷盘时: 写入完整 16KB 到磁盘
  3. 压缩为 8KB（举例）
  4. fallocate(FALLOC_FL_PUNCH_HOLE, offset+8KB, 16KB-8KB)
     → 文件系统释放 8KB 空间
  5. 磁盘上实际占用 8KB（但对应用透明）
```

### 2.2 使用

```sql
CREATE TABLE t (a INT) COMPRESSION='zlib';
-- 或
ALTER TABLE t COMPRESSION='lz4';
```

支持的算法：

| 算法 | 参数值 | 特点 |
|------|--------|------|
| zlib | `'zlib'` | 压缩率高，CPU 开销大 |
| LZ4 | `'lz4'` | 压缩率低，解压极快 |
| Zstandard (zstd) | `'zstd'` | MySQL 8.0.18+，压缩率和速度平衡 |

### 2.3 实现

```cpp
// fil0fil.cc — 压缩写路径
dberr_t fil_io(IORequest &request, ...) {
  if (request.is_write() && 
      tablespace->has_page_compression()) {

    /* ──── 步骤 1：正常写入完整页 ──── */
    os_file_write(path, block, n, ...);

    /* ──── 步骤 2：压缩页面数据（除 FIL_HEADER 外）──── */
    ulint compressed_len = UNIV_PAGE_SIZE;
    byte *compressed_buf = ...;

    if (algorithm == COMPRESSION_ZLIB) {
      compress2(compressed_buf, &compressed_len,
                page + FIL_PAGE_DATA,
                UNIV_PAGE_SIZE - FIL_PAGE_DATA, Z_BEST_SPEED);
    } else if (algorithm == COMPRESSION_LZ4) {
      compressed_len = LZ4_compress_default(
          page + FIL_PAGE_DATA,
          compressed_buf,
          UNIV_PAGE_SIZE - FIL_PAGE_DATA,
          LZ4_compressBound(...));
    }

    /* ──── 步骤 3：计算需要打孔的字节数 ──── */
    ulint pages_to_punch = UNIV_PAGE_SIZE - compressed_len;

    if (pages_to_punch >= UNIV_PAGE_SIZE) {
      /* 压缩无效或负增益 → 不打孔 */
      return;
    }

    /* ──── 步骤 4：执行打孔 ──── */
    os_file_punch_hole(path, offset + compressed_len,
                       pages_to_punch);

    /* 实际磁盘占用 = compressed_len 字节 */
  }
}
```

**打孔的要求**：

```
文件系统必须支持:
  Linux: FALLOC_FL_PUNCH_HOLE (ext4 / xfs / btrfs)
  Windows: FSCTL_SET_ZERO_DATA (NTFS)

否则: 压缩退化为完整写入（不节省空间，只增加 CPU 开销）
```

### 2.4 读取路径

```cpp
// fil0fil.cc — 压缩页读取
dberr_t fil_io_read(IORequest &request, ...) {
  /* ──── 步骤 1：读取完整 16KB 页面 ──── */
  os_file_read(path, block, offset, UNIV_PAGE_SIZE);

  /* ──── 步骤 2：检查是否压缩页 ──── */
  /* FIL_PAGE_COMPRESSED 标记在页头 */
  if (page[FIL_PAGE_TYPE] == FIL_PAGE_TYPE_COMPRESSED) {
    /* ──── 步骤 3：解压 ──── */
    /* FIL_HEADER 在打孔时保留，所以可以从头部读取 */
    ulint src_len = page_get_compressed_len(page);
    ulint dst_len = UNIV_PAGE_SIZE;

    if (algorithm == COMPRESSION_ZLIB) {
      uncompress(page, &dst_len, page + FIL_PAGE_DATA, src_len);
    }
  }

  /* 应用程序获得完整 16KB 页面 */
}
```

### TPC 的优缺点

| 优点 | 缺点 |
|------|------|
| BP 中只存 16KB（无压缩页副本） | 需要文件系统打孔支持 |
| 更新不需要解压（BP 中总是全页） | 压缩后在磁盘上不连续（碎片） |
| 支持所有行格式 | 写入 I/O 加倍（全写 + 打孔） |
| 解压快（LZ4 尤其快） | 读时仍需解压 |

---

## 3. 压缩效果对比

```
表 t (100MB 数据, 5 个 VARCHAR(255) 列, 100 万行):

                    磁盘占用     BP 占用    写入速度       读取速度
────────────────────────────────────────────────────────────────
None（无压缩）       100 MB     100 MB      100%            100%
Compressed (4KB)    35-40 MB   70-80 MB*    40-50%        70-80%  
TPC zlib            30-35 MB   100 MB**    50-60%         85-90%
TPC LZ4             40-50 MB   100 MB**    80-90%         95-100%

* COMPRESSED 格式 BP 中同时存压缩页和解压页
** TPC 只在磁盘上压缩，BP 中始终为完整 16KB 页
```

---

## 4. 源码索引

| 函数/结构 | 文件 | 关键作用 |
|-----------|------|---------|
| `page_zip_compress()` | `rem/rem0comp.cc` | COMPRESSED 格式压缩 |
| `page_zip_decompress()` | `rem/rem0comp.cc` | COMPRESSED 格式解压 |
| `page_zip_t` | `rem/rem0types.h` | 压缩页内存结构 |
| `fil_io()` 的压缩路径 | `fil0fil.cc` | TPC 压缩写 |
| `os_file_punch_hole()` | `os0file.cc` | 文件系统打孔 |
| `buf_page_get_zip_compact()` | `buf0buf.cc` | BP 中压缩页获取 |
