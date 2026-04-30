# futex — 快速用户空间互斥锁深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/futex/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**futex（Fast Userspace Mutex）** 是 Linux 特有的机制，让用户空间程序实现高效的**进程/线程间同步**，无需每次都进入内核。

---

## 1. 核心思想

```
传统方式：
  lock(): syscall → 内核 → 阻塞
  unlock(): syscall → 内核 → 唤醒

futex 方式：
  lock(): 用户空间 CAS → 成功？继续 : syscall → 内核阻塞
  unlock(): 用户空间 CAS → 有等待者？syscall → 内核唤醒 : 结束
```

**优势**：无竞争时**零 syscall**，竞争时才进入内核。

---

## 2. 核心数据结构

### 2.1 futex_key — 标识共享内存区域

```c
// kernel/futex/futices.h — futex_key
struct futex_key {
    union {
        struct {
            u64 i_seq;       // inode 号序列
            unsigned long pgoff;  // 页内偏移
            unsigned int offset;   // 键类型
        } shared;
        struct {
            u32 *ptr;         // 用户空间地址
            pid_t pid;         // 进程 ID
        } private;
    } key;
};
```

---

## 3. 核心操作

### 3.1 FUTEX_WAIT — 等待

```c
// 用户空间：
int futex_wait(int *uaddr, int val, struct timespec *timeout)
{
    return syscall(SYS_futex, uaddr, FUTEX_WAIT, val, timeout, 0, 0);
}

// 内核：
futex_wait(uaddr, val)
    ↓
    // 1. 验证 uaddr
    // 2. 如果 *uaddr != val，返回 EAGAIN
    // 3. 将当前线程加入 futex 哈希表的等待队列
    // 4. schedule() 睡眠
```

### 3.2 FUTEX_WAKE — 唤醒

```c
// 用户空间：
int futex_wake(int *uaddr, int nr)
{
    return syscall(SYS_futex, uaddr, FUTEX_WAKE, nr, 0, 0, 0);
}

// 内核：
futex_wake(uaddr, nr)
    ↓
    // 1. 查找 uaddr 对应的 futex 哈希桶
    // 2. 唤醒最多 nr 个等待者
    // 3. 返回实际唤醒的数量
```

---

## 4. PI-futex（优先级继承）

**PI（Priority Inheritance）** 是 futex 的扩展，支持优先级继承：

```
普通 futex: 不支持优先级继承 → 高优先级任务可能饿死在低优先级持有者后
PI-futex:  内核追踪持有者优先级 → 提升持有者优先级防止反转
```

**FUTEX_LOCK_PI / FUTEX_UNLOCK_PI / FUTEX_WAIT_PI**

---

## 5. 参考

| 文件 | 内容 |
|------|------|
| `kernel/futex/futex.c` | 核心实现 |
| `kernel/futex/futices.h` | futex_key |
| `include/uapi/linux/futex.h` | FUTEX_* 常量 |
