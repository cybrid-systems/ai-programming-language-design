# 57-sysfs-uevent — 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析
> Linux 7.0-rc1

---

**sysfs** 通过 kobject 暴露内核对象到 /sys/。**uevent** 通过 netlink 发送设备事件到 udev。

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01*
