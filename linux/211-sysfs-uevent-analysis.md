# 211-sysfs_uevent — sysfs事件深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/sysfs/dir.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**sysfs uevent** 是内核向用户空间发送设备事件的机制，udev/systemd 监听这些事件自动加载设备驱动。

---

## 1. uevent

```c
// drivers/base/core.c — kobject_uevent
int kobject_uevent(struct kobject *kobj, enum kobject_action action)
{
    // 发送 uevent 到用户空间
    // 环境变量包含：
    //   ACTION=add/remove/change
    //   DEVPATH=/sys/devices/...
    //   SUBSYSTEM=block/net/...
}
```

---

## 2. udev

```bash
# udevadm monitor 监听：
udevadm monitor --property --subsystem-match=usb

# 触发 uevent：
echo add > /sys/class/net/eth0/uevent
```

---

## 3. 西游记类喻

**sysfs uevent** 就像"天庭的新设施通知"——

> uevent 像天庭的广播通知——每当有新设施落成（设备添加），天庭会广播通知（uevent），udev 管理员听到通知后，自动给新设施分配门牌（/dev/xxx）、安排守卫（驱动加载）。

---

## 4. 关联文章

- **sysfs**（相关）：sysfs 是 uevent 的载体
- **device model**（相关）：kobject 是 uevent 的主体