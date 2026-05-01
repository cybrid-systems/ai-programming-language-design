# 52-io_uring-deep — io_uring 深度应用分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

io_uring 的深层特性：fixed buffers、registered files、polled IO、链接请求。

---

| 特性 | 说明 |
|------|------|
| IORING_REGISTER_FILES | 预注册 fd，避免每次 atomic 转换 |
| IORING_REGISTER_BUFFERS | 预注册缓冲区，跳过 get_user_pages |
| IORING_SETUP_IOPOLL | 轮询模式（NVMe 最优） |
| IOSQE_IO_LINK | 请求链式依赖 |
| IOSQE_IO_HARDLINK | 硬链接（出错后不再执行后续请求） |

---

*分析工具：doom-lsp（clangd LSP）*
