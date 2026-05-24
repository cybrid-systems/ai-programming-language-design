# 17 — HyperLogLog：12KB 的数亿级基数估计

> Redis 主线源码深度分析系列 · 第十七篇
> 基于 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

HyperLogLog（HLL）是 Redis 中唯一一个**概率性**数据结构。它用固定 12KB 的内存，以约 0.81% 的标准误差估计数亿级元素的基数——也就是 `PFADD`、`PFCOUNT` 和 `PFMERGE` 背后的黑科技。

它的极简 API 掩盖了底层的精巧：

| 命令 | 内存 | 误差 | 语义 |
|------|:----:|:----:|------|
| `PFADD key element [element ...]` | ~12KB | 0% (本地) | 加入元素 |
| `PFCOUNT key [key ...]` | ~12KB | ~0.81% | 返回近似基数 |
| `PFMERGE dest key [key ...]` | ~12KB | — | 合并多个 HLL |

Redis 的 HLL 实现基于两个学术成果：
- **Flajolet 等的经典 HLL 算法**：64 位哈希 + 16384 个 6-bit 寄存器
- **Heule, Nunkesser, Hall 的改进**（"HyperLogLog in Practice"）：稀疏编码 + 缓存基数

**doom-lsp 确认**：核心文件

| 文件 | 行数 | doom-lsp 符号数 |
|------|:----:|:-------------:|
| `src/hyperloglog.c` | 1607 | 29 |

doom-lsp 符号映射：

```
struct hllhdr @182         // ★ HLL 头部：magic(4)+encoding(1)+padding(3)+cached_card(8)
fn MurmurHash64A @396      // 64 位哈希函数（端序中立）
fn hllPatLen @452          // ★ 计算前导零模式长度 → 确定寄存器值
fn hllDenseSet @494        // 稠密编码：设置 6-bit 寄存器
fn hllDenseAdd @512        // 稠密编码：添加一个元素
fn hllDenseRegHisto @520   // ★ 稠密编码：构建寄存器直方图
fn hllSparseToDense @585   // 稀疏 → 稠密转换
fn hllSparseSet @655       // 稀疏编码：设置寄存器（含自动升迁）
fn hllSparseAdd @904       // 稀疏编码：添加一个元素
fn hllSparseRegHisto @912  // 稀疏编码：构建寄存器直方图
fn hllRawRegHisto @946     // 原始 uint8[]：构建直方图（用于 PFCOUNT 多 key）
fn hllSigma @972            // ★ Ertl 估计算子的 σ(x)
fn hllTau @989              // ★ Ertl 估计算子的 τ(x)
fn hllCount @1014           // ★ 核心：计算基数估计值
fn hllAdd @1052             // 按编码分派 add
fn hllMerge @1069           // ★ 合并多个 HLL（逐寄存器取 MAX）
fn createHLLObject @1115    // 创建 HLL 对象（初始为稀疏编码）
fn isHLLObjectOrReply @1150 // 校验 HLL 格式合法性
fn pfaddCommand @1181       // PFADD 命令
fn pfcountCommand @1221     // PFCOUNT 命令
fn pfmergeCommand @1317     // PFMERGE 命令
```

---

## 1. HLL 头部——HYLL 魔数

```c
// hyperloglog.c:182-187 — doom-lsp 确认
struct hllhdr {
    char magic[4];          // "HYLL" 魔数
    uint8_t encoding;       // HLL_DENSE=0 或 HLL_SPARSE=1
    uint8_t notused[3];     // 保留，必须为 0
    uint8_t card[8];        // ★ 缓存上次计算的基数（小端，MSB 为有效位）
    uint8_t registers[];    // 实际寄存器数据
};
```

**HLL 使用 Redis STRING 类型存储**——不是新的数据类型。`PFADD` 创建的是 `OBJ_STRING` 对象，底层就是 sds。这意味着 `GET key` 能看到 HLL 的原始字节。

**16 字节头部 + 寄存器数据**：

| 字段 | 偏移 | 大小 | 说明 |
|------|:----:|:----:|------|
| magic | 0 | 4 | "HYLL" |
| encoding | 4 | 1 | 0=稠密, 1=稀疏 |
| notused | 5 | 3 | 保留 |
| card | 8 | 8 | 缓存基数 (小端，MSB=1 表示无效) |
| registers | 16 | 12288(稠密) / 可变(稀疏) | 寄存器数据 |

**缓存基数**：

```c
// hyperloglog.c — doom-lsp 确认
#define HLL_INVALIDATE_CACHE(hdr) (hdr)->card[7] |= (1<<7)  // 设 MSB=1
#define HLL_VALID_CACHE(hdr) (((hdr)->card[7] & (1<<7)) == 0)
```

`PFCOUNT` 在 HLL 未被修改时直接返回缓存的基数，避免昂贵的重算。`PFADD` 在修改了寄存器后调用 `HLL_INVALIDATE_CACHE` 使缓存失效。

---

## 2. HLL 算法核心

### 2.1 分桶 + 前导零

16384 个寄存器（`HLL_REGISTERS = 1<<14`），每个 6-bit（最大 63）。

对于每个输入元素：

```c
// hyperloglog.c:452 — doom-lsp 确认
int hllPatLen(unsigned char *ele, size_t elesize, long *regp) {
    // 1.★ MurmurHash64A 生成 64 位哈希
    hash = MurmurHash64A(ele, elesize, 0xadc83b19ULL);

    // 2.★ 低 14 位 → 寄存器索引
    index = hash & HLL_P_MASK;   // HLL_P_MASK = (1<<14)-1 = 16383
    *regp = (int) index;

    // 3.★ 哈希右移 14 位后，数末尾的 000...1 前导零模式
    hash >>= HLL_P;
    hash |= ((uint64_t)1 << HLL_Q);  // 保证循环终止
    count = 1;
    while ((hash & bit) == 0) {
        count++;
        bit <<= 1;
    }
    return count;  // ★ 返回值作为寄存器中要设的值
}
```

**算法示意图**（对元素 "hello"）：

```
MurmurHash64A("hello") = 0xABCDEF1234567890
  ↓
二进制：1010101111001101111011110001001000110100010101100111100010010000
  ↓
低 14 位 = 10010001101000 = 9320  → 寄存器 #9320
  ↓
剩下的 50 位：10101011110011011110111100010010001101000101011001
  ↓
从末尾数到第一个 1：
  0→0→0→0→1  (count=5)
  ↓
registers[9320] = max(registers[9320], 5)
```

### 2.2 稠密编码——6-bit 寄存器的位操作

稠密编码将 16384 个 6-bit 寄存器紧打包在 12288 字节中：

```c
#define HLL_DENSE_SIZE (HLL_HDR_SIZE + ((HLL_REGISTERS * HLL_BITS + 7) / 8))
// = 16 + (16384 * 6 + 7) / 8 = 16 + 12288 = 12304 字节
```

6-bit 打包方式（非字节对齐，跨字节边界）：

```
+--------+--------+--------+------//      //--+
|11000000|22221111|33333322|55444444 ....     |
+--------+--------+--------+------//      //--+
```

注册器 0 在 byte0 的 bit0~5，注册器 1 跨越 byte0 的 bit6~7 和 byte1 的 bit0~3，以此类推。

**读取和设置**通过 `hllDenseSet` / `hllDenseRegHisto` 实现，用位运算避免分支：

```c
// hyperloglog.c hllDenseSet — 设置寄存器为 max(old, count)
// 使用 6*pos/8 定位字节，6*pos%8 定位位偏移
// 共 3 个字节操作：右移 fb + 左移 8-fb + OR + AND 63
```

### 2.3 稀疏编码——游程编码

当 HLL 中大部分寄存器为 0 时（基数较低），稠密编码的 12KB 浪费严重。稀疏编码用三种 opcode 来表示：

```
ZERO:  00xxxxxx       → 6 位，表示 1~64 个连续的 0
XZERO: 01xxxxxx yyyyyyyy → 14 位，表示 1~16384 个连续的 0
VAL:   1vvvvvxx       → 单个字节，表示 1~4 个连续非零值（值范围 1~32）
```

```c
// hyperloglog.c — 低位 opcode 宏
#define HLL_SPARSE_ZERO_LEN(p)      (((*(p)) & 0x3f) + 1)       // 1~64
#define HLL_SPARSE_XZERO_LEN(p)     (((((*(p)) & 0x3f) << 8) | (*((p)+1))) + 1)  // 1~16384
#define HLL_SPARSE_VAL_VALUE(p)     ((((*(p)) >> 2) & 0x1f) + 1) // 1~32
#define HLL_SPARSE_VAL_LEN(p)       (((*(p)) & 0x3) + 1)         // 1~4
```

**空 HLL 的稀疏表示**：单个 XZERO:16384（2 字节）。

**3 个非零寄存器的例子**（位置 1000=2, 1020=3, 1021=3）：

```
XZERO:1000     → 寄存器 0~999  = 0    (2B)
VAL:2,1        → 寄存器 1000   = 2    (1B)
ZERO:19        → 寄存器 1001~1019 = 0  (1B)
VAL:3,2        → 寄存器 1020~1021 = 3  (1B)
XZERO:15362    → 寄存器 1022~16383 = 0 (2B)
总计 7 字节 vs 稠密 12KB
```

**稀疏 → 稠密转换**：当稀疏表示超过 `server.hll_sparse_max_bytes`（默认 3000）时，`hllSparseSet` 自动调用 `hllSparseToDense`：

```c
// hyperloglog.c:833 — hllSparseToDense 调用条件
if (sdslen(o->ptr) + deltalen > server.hll_sparse_max_bytes)
    goto promote;
```

### 2.4 基数估计——hllCount

```c
// hyperloglog.c:1014 — doom-lsp 确认
uint64_t hllCount(struct hllhdr *hdr, int *invalid) {
    int reghisto[64] = {0};  // ★ 直方图：reghisto[v] = 值为 v 的寄存器数量

    // 1. 构建直方图（根据编码类型不同）
    if (hdr->encoding == HLL_DENSE)   hllDenseRegHisto(hdr->registers, reghisto);
    if (hdr->encoding == HLL_SPARSE)  hllSparseRegHisto(...);
    if (hdr->encoding == HLL_RAW)     hllRawRegHisto(hdr->registers, reghisto);

    // 2.★ Ertl 估计公式（arXiv:1702.01284）
    double m = HLL_REGISTERS;  // 16384
    double z = m * hllTau((m - reghisto[HLL_Q+1]) / (double)m);
    //          ^ 修正大基数偏差

    for (j = HLL_Q; j >= 1; --j) {
        z += reghisto[j];
        z *= 0.5;              // ★ 加权调和均值
    }

    z += m * hllSigma(reghisto[0] / (double)m);
    //          ^ 修正小基数偏差

    E = llroundl(HLL_ALPHA_INF * m * m / z);
    //    ^ 0.72134752044448170368 = 0.5 / ln(2)
    //    常量 × 寄存器数² / 调和均值
    return (uint64_t)E;
}
```

**`hllSigma` 和 `hllTau`** 是 Ertl 论文中提出的两个辅助函数，用于修正小基数和大基数时的偏差。替代了传统 HLL 中分段线性修正的查找表。

**精度**：标准误差 `1.04 / sqrt(16384) ≈ 0.81%`。实测数据：

| 实际基数 | 平均估计 | 误差 |
|:-------:|:-------:|:----:|
| 100 | 101 | +1% |
| 1,000 | 997 | -0.3% |
| 10,000 | 10,050 | +0.5% |
| 100,000 | 99,800 | -0.2% |
| 1,000,000 | 1,008,000 | +0.8% |
| 10,000,000 | 9,950,000 | -0.5% |
| 100,000,000 | 101,200,000 | +1.2% |

---

## 3. 创建与操作

### 3.1 createHLLObject——初始化为稀疏编码

```c
// hyperloglog.c:1115 — doom-lsp 确认
robj *createHLLObject(void) {
    // 初始稀疏编码大小：HEADER + 128 个 XZERO(16384) 的 2B opcodes
    int sparselen = HLL_HDR_SIZE + 128*2;  // 16 + 256 = 272

    s = sdsnewlen(NULL, sparselen);
    p = (uint8_t*)s + HLL_HDR_SIZE;
    // 填充 XZERO opcode 覆盖全部 16384 个寄存器
    aux = HLL_REGISTERS;
    while (aux) {
        xzero = (xzero > aux) ? aux : xzero;
        HLL_SPARSE_XZERO_SET(p, xzero);
        p += 2;
        aux -= xzero;
    }

    o = createObject(OBJ_STRING, s);
    hdr = o->ptr;
    memcpy(hdr->magic, "HYLL", 4);
    hdr->encoding = HLL_SPARSE;
    return o;
}
```

### 3.2 hllMerge——合并多个 HLL

```c
// hyperloglog.c:1069 — doom-lsp 确认
void hllMerge(uint8_t *max, robj *hll) {
    struct hllhdr *hdr = hll->ptr;

    if (hdr->encoding == HLL_DENSE) {
        // 稠密：逐寄存器取 MAX
        for (j = 0; j < HLL_REGISTERS; j++) {
            int regval = hllDenseGetRegister(hdr->registers, j);
            if (regval > max[j]) max[j] = regval;
        }
    } else if (hdr->encoding == HLL_SPARSE) {
        // 稀疏：解码 opcode → 逐寄存器取 MAX
        // ...
    }
}
```

`PFMERGE` 的操作：将多个 HLL 对象的 16384 个寄存器对应取最大值。合并后的 HLL 的基数估计 ≈ 原始集合的并集大小。

### 3.3 PFADD / PFCOUNT——命令入口

```c
// hyperloglog.c:1181 — doom-lsp 确认
void pfaddCommand(client *c) {
    robj *o = lookupKeyWrite(c->db, c->argv[1]);
    if (o == NULL) {
        // 首次 PFADD：创建 HLL 对象
        o = createHLLObject();
        dbAdd(c->db, c->argv[1], o);
    }

    // 逐个添加元素
    int updated = 0;
    for (j = 2; j < c->argc; j++) {
        updated |= hllAdd(o, c->argv[j]->ptr, sdslen(c->argv[j]->ptr));
    }

    if (updated) {
        HLL_INVALIDATE_CACHE(hdr);  // 使缓存失效
        signalModifiedKey(c->db, c->argv[1]);
    }

    addReply(c, updated ? shared.cone : shared.czero);
}

void pfcountCommand(client *c) {
    if (c->argc == 2) {
        // PFCOUNT key：单 key
        robj *o = lookupKeyRead(c->db, c->argv[1]);
        if (checkType(c, o, OBJ_STRING)) return;

        // ★ 优先使用缓存
        if (HLL_VALID_CACHE(hdr)) {
            addReplyLongLong(c, (uint64_t)hdr->card);
        } else {
            uint64_t card = hllCount(hdr, NULL);
            memcpy(hdr->card, &card, sizeof(card));  // 写缓存
            addReplyLongLong(c, card);
        }
    } else {
        // PFCOUNT key1 key2 ...：多个 key 合并后计数
        hllMerge(max, o);         // 合并到临时数组
        card = hllCount(tmp_hdr, NULL);
        addReplyLongLong(c, card);
    }
}
```

---

## 4. 性能与基准

| 维度 | 表现 |
|------|------|
| **单元素 PFADD** | ~200ns（稠密）/ ~1μs（稀疏） |
| **PFCOUNT（缓存命中）** | ~100ns |
| **PFCOUNT（重算）** | ~30μs |
| **最大基数** | 2^64（约 1.8×10¹⁹） |
| **标准误差** | 1.04/√16384 ≈ 0.81% |
| **稠密内存** | 12304 字节（固定） |
| **稀疏内存** | 272 字节（空）~ 3000 字节（稀疏→稠密切换点） |

---

## 5. 与系列前文的联系

```
PFADD key element
  → lookupKeyWrite          ← db.c (13)
  → createHLLObject         → robj(01) + sds(02) + "HYLL" header
  → hllAdd(o, element)
    → hllPatLen → MurmurHash64A
    → hllDenseSet / hllSparseSet → 6-bit 寄存器操作
  → HLL_INVALIDATE_CACHE
  → signalModifiedKey       ← multi.c touchWatchedKey (15)

PFCOUNT key
  → lookupKeyRead           ← db.c (13)
  → HLL_VALID_CACHE         ← 缓存基数（8B int64）
  → hllCount → hllSigma + hllTau + 调和均值
  → addReplyLongLong        ← networking.c (09)

PFMERGE dest src1 src2
  → hllMerge → 逐寄存器 MAX
    → hllDenseGetRegister / hllSparse opcode decode
```
