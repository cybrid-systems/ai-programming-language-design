# ARMv9 指令亲和优化：Redis 全热点分析

> 基于 doom-lsp 逐行追踪的 Redis 21 篇系列 — 性能优化篇
> 分析 `src/*.c` 中所有可受益于 ARMv9 SVE/SVE2/NEON/SHA/CRC 指令的热点路径

---

## 0. ARMv9 相关指令集概述

| 指令集 | 特性 | 适合场景 |
|--------|------|---------|
| **NEON** (ARMv7+) | 128-bit SIMD，LD4/ST4 解交织 | HLL 6-bit 打包/解包、memcpy |
| **CRC32** (ARMv8.0+) | `crc32cb` / `crc32ch` 单指令 | SipHash、CRC16、CRC64 |
| **SHA256** (ARMv8.2+) | `sha256h` / `sha256su0` | ACL 密码验证 |
| **SVE** (ARMv8.2+) | 可变宽度向量 (128~2048bit) | 字符串比较、排序向量加载 |
| **SVE2** (ARMv9) | SVE + DSP/密码学扩展 | 位图操作、HLL 直方图、位打包 |
| **SVE WHILELT** | 向量化循环控制 | 任意长度的字符串操作 |
| **SVE LD1/ST1** | 分散加载/连续存储 | listpack/ziplist 内存操作 |

---

## 1. CRC 与哈希——最高优先级（每操作调用）

### 1.1 CRC16 → Cluster keyHashSlot

```c
// cluster.c:939 — doom-lsp 确认 — 每次 key 操作
unsigned int keyHashSlot(char *key, int keylen) {
    return crc16(key, keylen) & 0x3FFF;
}

// crc16.c:86 — 查表法
uint16_t crc16(const char *buf, int len) {
    for (int i = 0; i < len; i++)
        crc = (crc<<8) ^ crc16tab[((crc>>8) ^ *buf++) & 0x00FF];
}
```

**ARMv9 优化**：
```
ARMv8.0 CRC32 指令：crc32cb(crc, byte) — 单周期，避免查表
  → 64 位并行 CRC 计算

潜在加速：3~5×
影响范围：每个 Redis Cluster 命令（GET/SET/DEL 等）
```

### 1.2 CRC64 → RDB 校验和

```c
// rio.c:424 — doom-lsp 确认 — 每次 RDB 写入
void rioGenericUpdateChecksum(rio *r, const void *buf, size_t len) {
    r->cksum = crc64(r->cksum, buf, len);
}

// crc64.c:88 — slicing-by-8 查表
uint64_t _crc64(uint64_t crc, void *data, uint64_t len) {
    while (len >= 8) {
        crc = crc64_table[7][data[7] ^ (crc>>56)] ^ ... ;  // 8 次查表
    }
}
```

**ARMv9 优化**：ARMv8.0 没有原生 CRC64 指令。但 SVE2 的 `pmull` (polynomial multiply) 可实现 CRC64 的 Barrett 约简——单指令计算 128 位多项式乘法。

### 1.3 SipHash → dict HashFunction

```c
// siphash.c:127 — doom-lsp 确认 — 每次 dict 操作
uint64_t siphash(const uint8_t *in, size_t inlen, const uint8_t *k) {
    // SIPROUND: 4 次 64 位旋转 + 2 次 XOR + 2 次 ADD
    // SipHash 1-2 变体
}
```

**ARMv9 优化**：SVE2 的 SM4 加密扩展可加速 SipHash 的轮函数——`sm4e` 单指令完成 SM4 轮函数，SipHash 的 64-bit 旋转和 XOR 结构与 SM4 兼容。

### 1.4 SHA256 → ACL 密码认证

```c
// acl.c:169 — doom-lsp 确认 — 每次 AUTH 命令
int ACLHashPassword(char *password) {
    SHA256_CTX ctx;
    sha256_init(&ctx);
    sha256_update(&ctx, password, strlen(password));  // ★ 每次 AUTH
    sha256_final(&ctx, hash);
}
```

**ARMv9 优化**：ARMv8.2+ `sha256h` / `sha256su0` 指令——单轮 SHA256 压缩函数用 4 条指令完成（ARM 标准库已使用此优化）。

---

## 2. 内存操作——最高频代码路径

### 2.1 memcpy → listpack/ziplist memmove（插入/删除）

```c
// listpack.c:860 — doom-lsp 确认 — XADD, LPUSH 等
memmove(dst + enclen + backlen_size, dst, old_listpack_bytes - poff);
```

Ziplist 和 listpack 的插入/删除全部依赖 `memmove` 移动数据。ziplist.c 有 30 处 memcpy/memmove，listpack.c 有 16 处。

**ARMv9 优化**：
```
NEON: 128-bit 对齐 memmove — 常规编译器已自动向量化
SVE: 可变宽度向量 LD1/ST1 — 任意长度非对齐时仍有最佳性能
```

编译器（GCC 12+ / LLVM 15+）在 `-march=armv9-a+sve` 下自动将 `memmove` 替换为 SVE LD1/ST1。但 `__builtin_memcpy` 阈值设置和 `-ftree-vectorize` 开关影响效果。

**影响范围**：所有写入操作（SET、HSET、LPUSH、XADD 等）。

### 2.2 sdscmp → zset 插入/删除

```c
// t_zset.c:146 — doom-lsp 确认 — ZADD, ZREM
sdscmp(x->level[i].forward->ele, ele) < 0)

// sds.c:953 — doom-lsp 确认
int sdscmp(const sds s1, const sds s2) {
    minlen = (l1 < l2) ? l1 : l2;
    cmp = memcmp(s1, s2, minlen);  // ★ 核心比较
}
```

ZSet 的插入路径中每个层级都做 `sdscmp`（skyplist 查找），ZADD 一个 100 万个元素的 ZSet 大约做 1.33×log₂(1M) ≈ 26 次比较。

**ARMv9 优化**：SVE `whilelo` + `ld1b` + `cmpeq` 向量化 `memcmp`——一次处理 VL×8 字节。给定 SVE 512-bit 宽度可一次比较 64 字符。

### 2.3 string2ll → RESP 协议解析

```c
// util.c:422 — doom-lsp 确认 — 每个 RESP 命令
// 每次 SET/GET/DEL/ZADD... 都会调用来解析 *N、$N 等
int string2ll(const char *s, size_t slen, long long *value);
```

每次 RESP 命令解析时，`*<N>` 和 `$<N>` 都需将 ASCII 数字串转为整数。每个字符逐个乘 10 累加。

**ARMv9 优化**：SVE `ld1b` 一次加载 16~64 字节，`sub` 减 '0'，`cmphs` 溢出检查，再向量化乘 10 累加——一条 SVE 指令处理多个数字字符。

---

## 3. 位操作——密集计算路径

### 3.1 HyperLogLog 6-bit 寄存器直方图

```c
// hyperloglog.c:520 — doom-lsp 确认 — 每次 PFCOUNT
void hllDenseRegHisto(uint8_t *registers, int* reghisto) {
    // 24 字节跨边界的 6-bit 解包：每次读 12 字节解 16 个寄存器
    for (j = 0; j < 1024; j++) {
        r0  = r[0] & 63;              // 字节内 6-bit
        r1  = (r[0]>>6 | r[1]<<2) & 63;  // 跨字节边界
        r2  = (r[1]>>4 | r[2]<<4) & 63;
        r3  = (r[2]>>2) & 63;
        // ... 16 个寄存器 ...
    }
}
```

这是 HLL 中最热的路径——扫描 12KB 寄存器并构建直方图。16384 个 6-bit 寄存器跨字节边界的位操作无法被编译器自动向量化。

**ARMv9 优化**：

```
SVE2 BEXT (Bit Extract): 一条指令从两个寄存器中提取任意位域
  → 替代 4 次移位 + 1 次 OR + 1 次 AND
  → 连续 6-bit 提取可流水线化

SVE2 BDEP (Bit Deposit): 将 6-bit 值写入连续位置
  → 构建直方图的加速

NEON LD4/ST4 (de-interleave): 如果有另一种编码——
  可以用 4×32-bit 交错存储，LD4 一次加载并解交织
```

**潜在加速**：~4×（完全向量化版本 vs 标量逐位操作）

### 3.2 Cluster Slot 位图

```c
// cluster.c:68-70 — doom-lsp 确认
int bitmapTestBit(unsigned char *bitmap, int pos) {
    return bitmap[pos >> 3] & (1 << (pos & 7));
}
void bitmapSetBit(unsigned char *bitmap, int pos) {
    bitmap[pos >> 3] |= (1 << (pos & 7));
}
```

每次 key 操作都需要检查 `clusterNodeGetSlotBit`——用位图判断 slot 归属。Cluster 节点数的增加使 slot 查找成为瓶颈。

**ARMv9 优化**：SVE2 `match` / `nmatch` 指令可以一次比较 2048-bit 位图的所有位。但更实际的是：SVE `ld1b` 加载 2048-byte slot 位图到向量寄存器，然后用 `cmpeq` 一次检查多个 slot。

### 3.3 HLL Sparse 编码 Opcode 解析

```c
// hyperloglog.c:370-373 — doom-lsp 确认
#define HLL_SPARSE_IS_ZERO(p)  (((*(p)) & 0x80) == 0)
#define HLL_SPARSE_IS_XZERO(p) (((*(p)) & 0xc0) == 0x40)
#define HLL_SPARSE_IS_VAL(p)   ((*(p)) & 0x80)
```

稀疏编码解码需要逐个字节解析 opcode，是纯标量的位模式匹配。

**ARMv9 优化**：SVE2 `match`（位模式匹配）——可在单指令中检查 VL 字节中所有字节是否匹配 ZERO/XZERO/VAL 模式。

---

## 4. 压缩/解压——存储密集型

### 4.1 LZF 压缩 → Quicklist 中间节点

```c
// quicklist.c:232 — doom-lsp 确认
lzf_compress(node->entry, node->sz, lzf->compressed, node->sz);
```

LZF 压缩用于 quicklist 的中间节点。LZF 算法大量使用 `memcpy` 回引复制和哈希查找。

**ARMv9 优化**：LZF 以字节为单位操作，依赖哈希查找和模式匹配。SVE2 `histcnt`（直方图计数）可用于加速 LZF 的哈希阶段。但更有效的路径可能是用 zstd 替代 LZF（zstd 有 ARM SVE 加速的硬件实现）。

---

## 5. 内存分配与缓存——架构级优化

### 5.1 SDS header 的 packed 布局

```c
// sds.h — doom-lsp 确认
struct __attribute__((__packed__)) sdshdr8 {
    uint8_t len; uint8_t alloc; unsigned char flags; char buf[];
};
```

**ARMv9 内存标记 (MTE)**：ARMv8.5+ / ARMv9 的 MTE 可以为 `buf[]` 之后的边界设置标记——检测 sds 缓冲区溢出。适合开发/测试环境（4-bit 内存标记，~3% 运行时开销）。

### 5.2 Zmalloc 与 jemalloc arena

jemalloc 在 arm64 上的 arena 大小为 64 字节（最小槽位）。EMBSTR 优化（`sizeof(robj)+sizeof(sdshdr8)+len+1 ≤ 64`，即 `len ≤ 44`）完美对齐 64B arena。

**ARMv9 优化**：MTE 可检测 jemalloc 分配后的越界访问——ARMv9 的 `stgm`/`ldgm` 指令操作分配粒度标签。

---

## 6. 优先级矩阵

| # | 热点 | 文件 | ARMv9 指令 | 加速预期 | 影响命令 |
|:-:|------|------|-----------|:--------:|---------|
| 1 | **CRC16 keyHashSlot** | cluster.c:939 | ARMv8 CRC32 `crc32cb` | 3~5× | 所有 Cluster 命令 |
| 2 | **SipHash dict** | siphash.c:127 | SVE2 SM4 `sm4e` | 2~3× | 所有 dict 操作 |
| 3 | **HLL 6-bit 解包** | hyperloglog.c:520 | SVE2 `bext`/`bdep` | 3~4× | PFCOUNT |
| 4 | **string2ll 协议解析** | util.c:422 | SVE `ld1b`+向量化 | 2~4× | 每个 RESP 命令 |
| 5 | **CRC64 RDB** | crc64.c:88 | SVE2 `pmull` | 2~3× | BGSAVE/BGREWRITEAOF |
| 6 | **sdscmp zset** | sds.c:953 | SVE `whilelo`+`cmpeq` | 2~3× | ZADD/ZREM/ZRANK |
| 7 | **memmove listpack** | listpack.c:860 | SVE `ld1`/`st1` | 1.5× | XADD/LPUSH/HSET |
| 8 | **SHA256 ACL** | acl.c:169 | `sha256h` | 4~5× | AUTH |
| 9 | **LZF 压缩** | lzf_c.c | SVE `histcnt` | 1.5× | Quicklist 节点 |
| 10 | **slot 位图** | cluster.c:68 | SVE `ld1b`+`cmpeq` | 2× | Cluster 路由 |

---

## 7. 实现建议

### 优先级 1：CRC16（最快见效，改动最小）

```c
// 当前查表法：
static inline uint16_t crc16_armv9(const char *buf, int len) {
    uint64_t crc = 0;
#if defined(__ARM_FEATURE_CRC32)
    // ARMv8.0+: 单指令循环，自动流水线
    for (int i = 0; i < len; i++)
        crc = __builtin_arm_crc32cb(crc, buf[i]);
#else
    // 回退查表
    for (int i = 0; i < len; i++)
        crc = (crc<<8) ^ crc16tab[((crc>>8) ^ buf[i]) & 0xFF];
#endif
    return crc & 0xFFFF;
}
```

**改动量**：1 个函数（crc16.c），编译时 `-march=armv8-a+crc`。

### 优先级 2：SipHash 轮函数（SVE2 SM4）

SipHash 的 2-4 轮函数需要 64 位加法和循环移位，如果硬件支持 SM4，可替代为 `sm4e`。但 SipHash 的 1-2 变体本身已经很快（antirez 在注释中说速度与 MurmurHash2 相当），优化优先级较低。

### 优先级 3：HLL 直方图向量化

HLL 的 `hllDenseRegHisto` 手动解包了 1024 次迭代——这是手动标量优化，但无法自动向量化。用 SVE2 `bext` 重写：

```c
// SVE2 伪代码：一次处理 VL/2 个 6-bit 寄存器
for (j = 0; j < 16384; j += svcntb()*8/6) {
    svuint8_t data = svld1_u8(svptrue_b8(), &r[bit_offset/8]);
    // SVE2 BEXT: 从 data 中提取 6 个连续 bit
    svuint8_t vals = svextb(data, bit_offset % 8, 6);
    // 直方图累加
    svst1_scatter_u64base(reghisto, svptrue_b8(), vals, 1);
}
```

### 通用的编译标志

```makefile
# ARMv9 SVE2 优化
ifeq ($(ARCH),armv9-a)
    OPTIMIZATION += -march=armv9-a+sve2+sve2-sm4+fp16+rcpc
    OPTIMIZATION += -ftree-vectorize -fvect-cost-model=unlimited
    # OpenSSL 已提供 ARMv8.2+ SHA256 加速
    OPTIMIZATION += -DUSE_OPENSSL
endif
```

---

## 8. 总结

ARMv9（特别是 SVE2）与 Redis 的热点有多个高度的指令亲和重叠：

- **CRC/SipHash/SHA256** 的密码学指令可直接加速三种哈希操作
- **SVE2 BEXT** 完美适配 HyperLogLog 的跨字节 6-bit 解包——其他 SIMD 架构（x86 AVX2）做不到
- **SVE 可变宽度向量**适配字符串操作（sdscmp、memcpy）——x86 需 AVX-512，SVE 天然支持
- **LD1/ST1** 非对齐向量化 memmove——在 listpack/ziplist 上尤其有效
- **MTE** 内存标记为 jemalloc/SDS 提供内存安全保护

综合来看，CRC16（Cluster）、HLL 6-bit 解包（PFCOUNT）、string2ll（RESP 解析）是改动最小、收益最大的三个优化点。
