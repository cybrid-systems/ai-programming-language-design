# 192-kexec — 内核崩溃恢复深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/kexec.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**kexec** 允许不经过引导加载程序直接启动新内核，kdump 利用此机制在崩溃时保存内存快照。

---

## 1. kexec

```c
// kernel/kexec.c — sys_kexec_load
long sys_kexec_load(unsigned long entry, unsigned long nr_segments,
                    struct kexec_segment *segments, unsigned long flags)
{
    // 1. 将新内核加载到预留的内存
    for (each segment) {
        copy_from_user(dest, src, size);
    }

    // 2. 设置跳转地址
    kexec_image.entry = entry;

    // 3. 崩溃时自动跳转到新内核
}
```

---

## 2. kdump

```
kdump 流程：

系统启动时：
  boot kernel → kexec 加载 crash kernel 到预留内存

系统崩溃时：
  panic()
    → machine_crash_shutdown()
    → machine_kexec()
    → 跳转到 crash kernel

crash kernel：
  → 保存主内核内存到 disk（/var/crash）
  → reboot
```

---

## 3. 西游记类喻

**kexec/kdump** 就像"天庭的备用天庭"——

> 主天庭（主内核）崩溃时，备用天庭（crash kernel）已经在另一个地方准备好了。机器一崩溃，备用天庭立即接管，而不是等bootloader慢慢启动。备用天庭负责记录主天庭崩溃前的状态（dump），然后主天庭重启。

---

## 4. 关联文章

- **kgdb/kdump**（article 180）：kdump 使用 kexec
- **panic**（相关）：panic 触发 kdump