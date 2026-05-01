# 57-sysfs-uevent — sysfs 与 uevent 深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**sysfs** 将内核对象以文件系统形式曝露给用户空间（/sys/）。**uevent** 是内核向用户空间发送设备事件（添加/移除）的机制，通过 netlink 发送到 udev。

---

## 1. 核心路径

```
创建 kobject：
  kobject_add(kobj, parent, "name")
    └─ create_dir(kobj)          ← 创建 sysfs 目录
    └─ kobject_uevent(kobj, KOBJ_ADD)
         │
         └─ kobject_uevent_env(kobj, action, envp)
              ├─ 调用 kset->uevent_ops 过滤
              ├─ 构建环境变量数组
              └─ uevent_send(kobj, ...)
                   └─ netlink_broadcast(uevent_sock, skb, ...)
                        └─ 用户空间 udev 接收
```

---

*分析工具：doom-lsp（clangd LSP）*
