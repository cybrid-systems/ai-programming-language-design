# 139-printk — 读 kernel/printk/printk.c + nbcon.c

---

## 无锁环形缓冲区

（`kernel/printk/printk_ringbuffer.c`）

printk 使用一个**基于描述符的环形缓冲区**。每条日志记录由一个固定大小的描述符（`struct prb_desc`）和一个可变大小的数据块（日志文本）组成：

```c
struct prb {
    struct prb_desc_ring  desc_ring;     // 描述符环（固定大小）
    struct prb_data_ring  data_ring;     // 数据环（可变大小文本）
};
```

每个描述符的状态通过其 `id` 字段原子的编码：

```
desc_miss → desc_reserved → desc_committed → desc_reusable → desc_miss
保留 slot     写入数据       已提交（控制台待输出）   可重用

状态转换全部通过 cmpxchg 实现——无需锁。
```

---

## console_lock 的问题与 nbcon 的解决方案

传统的 `console_lock` 是一个全局自旋锁，持有该锁时：

1. 所有 CPU 的 printk 必须自旋等待
2. 中断上下文中的 printk 可能死锁（如果持有锁的中断被另一个中断打断）
3. NMI 上下文中的 printk 几乎不可能（自旋锁在 NMI 中是禁止的）

**NBCon（Non-Blocking Console）** 的解决方案是 per-console 的原子状态机：

```c
struct nbcon_state {
    unsigned int prio;       // 当前打印优先级（NONE/NORMAL/EMERGENCY/PANIC）
    // 优先级决定谁能抢占当前打印者
    // PANIC > EMERGENCY > NORMAL > NONE
    bool migratable;         // 是否可迁移
};
```

NBCon 使用 `try_cmpxchg` 获取控制台的拥有权——如果当前拥有者的优先级低于请求者，请求者可以抢占。panic 时的打印有最高优先级，因此 panic 消息总是能输出。

---

## /dev/kmsg 的读写路径

`/dev/kmsg`（主设备 1, 次设备 11）是用户空间读取内核日志的标准接口：

```c
static const struct file_operations proc_kmsg_operations = {
    .read  = devkmsg_read,    // 从 ringbuffer 读取
    .write = devkmsg_write,   // 用户空间写日志（通过 printk 输出）
    .open  = devkmsg_open,
    .poll  = devkmsg_poll,    // 支持 poll（dmesg -w 实时跟踪）
};
```

`devkmsg_read` 从 ringbuffer 中读取下一个未读的日志记录，支持 `poll` 等待新日志到达。
