# Linux Kernel dma-buf / scatterlist 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/dma-buf/` + `lib/scatterlist.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. dma-buf

**dma-buf** 实现**跨设备零拷贝缓冲区共享**——GPU、Camera、Encoder 通过dma-buf共享物理内存。

---

## 1. 核心结构

```c
// drivers/dma-buf/dma-buf.c — dma_buf
struct dma_buf {
    struct file           *file;          // 匿名文件
    struct device        *expoter;        // 导出者
    struct reservation_object *resv;       //  reservation/Fence
    struct list_head     attachments;      // 已附着的设备
    const struct dma_buf_ops *ops;        // 操作函数表
    size_t              size;
};

// scatterlist — 不连续物理页描述
struct scatterlist {
    unsigned long   page_link;          // 指向下一页/物理页
    unsigned int    offset;               // 页内偏移
    unsigned int    length;              // 长度
    dma_addr_t      dma_address;         // DMA 地址
};
```

---

## 2. 参考

| 文件 | 内容 |
|------|------|
| `drivers/dma-buf/dma-buf.c` | dma_buf 核心 |
| `lib/scatterlist.c` | scatterlist 分配/映射 |
