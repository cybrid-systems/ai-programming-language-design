# 106-tap-tun — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**tun/tap** 是虚拟网络设备。tun 工作于 L3（IP），tap 工作于 L2（以太网），用户空间程序通过字符设备接口读写网络数据包。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
