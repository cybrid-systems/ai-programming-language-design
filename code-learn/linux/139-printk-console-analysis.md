# Linux printk 与控制台子系统深度分析

## 概述

printk 是 Linux 内核的日志输出核心。它是最常用的内核接口（几乎每个驱动和子系统都使用它），也是调试的**最后手段**——需要在系统崩溃时也能工作。

printk 子系统在 Linux 近几年经历了重大重构：
1. **无锁环形缓冲区（lockless ringbuffer）**：替代了旧的 `log_buf` + 大锁设计
2. **NBCon（Non-Blocking Console）**：新型非阻塞控制台框架，解决 `console_lock` 瓶颈
3. **printk index**：printk 格式字符串索引，供工具解析

## 核心数据结构

### printk_ringbuffer — 无锁环形缓冲区

（`kernel/printk/printk_ringbuffer.h`）

printk 使用一种**基于描述符的环形缓冲区**（descriptor-based ring buffer），替代了传统的字节数组。

```
数据结构层级：
  struct prb  (printk ringbuffer)
    ├── struct prb_desc_ring      — 描述符环（描述每条日志的元数据）
    │     └── struct prb_desc[]   — 描述符数组，每个包含：
    │           ├── id: 状态和序列号编码
    │           ├── info: struct printk_info（时间戳、flags、调用者等）
    │           └── text_blk_lpos: 文本数据位置
    │
    ├── struct prb_data_ring     — 数据环（实际文本内容）
    │     └── char data[]         — 环形字节数组
    │
    └── atomic_long_t fail        — 失败计数
```

每个日志记录通过一个**描述符**和一个**数据块**表示。描述符是固定大小的（`sizeof(struct prb_desc)`），数据块是可变大小的（日志文本）。

```c
struct printk_info {
    u64         seq;            // 单调递增的序列号
    u64         ts_nsec;        // 时间戳（CLOCK_MONOTONIC）
    u16         text_len;       // 文本长度
    u8          facility;       // LOG_KERN / LOG_USER 等
    u8          flags;          // LOG_NEWLINE / LOG_CONT 等
    u8          level;          // KERN_EMERG / KERN_ALERT 等
    u8          caller_id;      // 调用者标识（task/irq）
    char        reserved[24];   // 未来扩展
};
```

### 无锁操作的核心

环形缓冲区的关键是 **state machine**，每个描述符通过其 `id` 字段编码状态：

```c
// 描述符的 id 编码状态：
#define DESC_COMMIT_MASK    (3UL << 0)     // 低 2 位是状态
#define DESC_ID_MASK        (~DESC_COMMIT_MASK)

enum desc_state {
    desc_miss,          // 描述符不可用（被覆盖或从未使用）
    desc_reserved,      // 描述符已保留，正在写入数据
    desc_committed,     // 数据已写入，但尚未刷新到控制台
    desc_reusable,      // 已完全处理，可重用
};
// 状态迁移：
// desc_miss → desc_reserved（保留一个新的日志槽）
// desc_reserved → desc_committed（日志写入完成）
// desc_committed → desc_reusable（所有控制台已输出）
// desc_reusable → desc_miss（被其他 CPU 重用）
```

所有状态转换使用 **cmpxchg** 原子操作，不需要锁：

```c
// 保留描述符（atomic reserve）
static int prb_reserve(struct prb *rb, struct printk_record *r, u32 size)
{
    struct prb_desc_ring *desc_ring = &rb->desc_ring;
    
    // 1. 在描述符环中找到可用的 desc（状态为 desc_miss 或 desc_reusable）
    // 2. 通过 cmpxchg 将状态从 desc_miss → desc_reserved
    // 3. 在数据环中分配对应大小的空间
    // 4. 填充 printk_info（时间戳、level 等）
}
```

### struct console — 控制台驱动

（`include/linux/console.h`）

```c
struct console {
    char            name[8];                    // 控制台名称（"ttyS", "tty0" 等）
    int             index;                      // 索引（ttyS0 → index=0）
    void (*write)(struct console *, const char *, unsigned);  // 输出函数
    int (*read)(struct console *, char *, unsigned);          // 输入函数
    struct device   *device;                    // 关联的设备
    struct list_head head;                      // 全局 console_drivers 链表
    
    // 控制台标志
    short           flags;
    // CON_ENABLED: 控制台已启用
    // CON_CONSDEV: 默认控制台
    // CON_BOOT: 启动早期控制台
    // CON_ANYTIME: 可在任何时间打印（包括 NMI 上下文）
    // CON_NBCON: 该控制台使用 nbcon 框架

    short           cflag;                      // 终端控制标志
    uint            seq;                        // 已输出的最大序列号
    ...
};
```

控制台通过 `register_console()` 注册，形成一个全局链表 `console_drivers`。典型的控制台驱动：

| 名称 | 后端 | 典型使用 |
|------|------|---------|
| `ttyS0` | UART 串口 | 嵌入式/服务器控制台 |
| `tty0` | VGA/framebuffer | 桌面系统 |
| `netcon` | UDP 网络 | 远程调试 |
| `hvc0` | HV console | 虚拟化环境 |

## printk 完整数据流

```
printk(fmt, ...)
  │
  ├─ 1. 格式化
  │     vscnprintf(buf, sizeof(buf), fmt, args);
  │     // 在内核临时缓冲区中格式化日志字符串
  │     // 最多 LOG_LINE_MAX（1024 - PREFIX_MAX）字节
  │
  ├─ 2. 记录到环形缓冲区
  │     printk_get_next_message(&pmsg, ...)
  │     └─ prb_reserve(&prb, &r, text_len)
  │           ← 使用 cmpxchg 保留一个描述符
  │         prb_final_commit(&prb, &r)
  │           ← 使用 cmpxchg 将状态改为 desc_committed
  │
  ├─ 3. 唤醒 log_wait 等待队列
  │     wake_up_klogd() 或 wake_up_interruptible(&log_wait)
  │     // 通知 klogd/syslogd 有新日志
  │
  └─ 4. 输出到控制台
        console_unlock()
          ├─ 遍历 console_drivers 链表
          │    for each console in console_drivers:
          │        __console_write(con, msg, text_len);
          │        // 通过 console->write() 输出
          │
          ├─ 从 ringbuffer 读取新记录
          │    prb_first_valid_seq() → 获取下一个未输出的 seq
          │    prb_read_valid_seq(&prb, seq, r) → 读取记录
          │
          └─ 如果输出时被新的 printk 打断
               continue（递归输出——旧的 printk 机制）
```

## NBCon 非阻塞控制台

（`kernel/printk/nbcon.c` — 2002 行）

传统的 `console_lock` 是一个全局自旋锁，持有该锁时：
- 所有 CPU 的 printk 必须等待
- 中断和 NMI 上下文中的 printk 会死锁
- 高延迟（串口输出 100ms / 行）

NBCon 解决这个问题的方式是**无锁 + 每控制台独立锁 + 紧急输出**：

```c
// nbcon 上下文（per-console）
struct nbcon_context {
    struct console      *console;    // 目标控制台
    enum nbcon_prio     prio;        // 请求优先级
    unsigned int        seq;         // 期望输出的最大 seq
};

// 优先级层次（越高越可以抢占）
enum nbcon_prio {
    NBCON_PRIO_NONE,        // 无拥有者
    NBCON_PRIO_NORMAL,      // 普通 printk
    NBCON_PRIO_EMERGENCY,   // 紧急消息（panic）
    NBCON_PRIO_PANIC,       // panic 输出
};

// 使用 cmpxchg 获取控制台的拥有权
// 分配三步走：try_direct → try_handover → try_requested
static int nbcon_context_try_acquire_direct(struct nbcon_context *ctxt)
{
    // 如果当前拥有者的 prio < 请求的 prio → 可以抢占
    // 通过 cmpxchg 原子更新 nbcon_state
}
```

```
传统 console_lock 的瓶颈：
  CPU 0: printk → lock console_lock → write("Hello") → [串口输出 100ms] → ... 
  CPU 1: printk → 等待 console_lock → [阻塞 100ms] → ...
  CPU 2: 在中断中 printk → spin_lock(console_lock) → DEADLOCK

NBCon 的设计：
  CPU 0: printk → nbcon_try_acquire(con, NORMAL) → write("Hello") → (不阻塞其他 CPU)
  CPU 1: printk → nbcon_try_acquire(con, NORMAL) → 失败 → 记录到环形缓冲区（可等待）
  CPU 2: 在中断中 printk → nbcon_try_acquire(con, EMERGENCY) → 成功（抢占 CPU 0）
          → 紧急输出 → 完成后释放
```

## /dev/kmsg 与 syslog 路径

用户空间通过以下方式访问内核日志：

```
              printk()
                │
                ▼
      ┌─────────────────┐
      │ ringbuffer      │  ← 内核维护的环形缓冲区
      └────────┬────────┘
               │
    ┌──────────┼──────────┐
    │          │          │
    ▼          ▼          ▼
  /dev/kmsg  syslog()  dmesg
   (系统调用) (系统调用) (用户工具)
```

`/dev/kmsg` 是字符设备（`miscdevice`，主设备号 1，次设备号 11）：

```c
static const struct file_operations proc_kmsg_operations = {
    .read       = devkmsg_read,      // 读取日志
    .write      = devkmsg_write,     // 写入日志（用户空间可写）
    .open       = devkmsg_open,
    .release    = devkmsg_release,
};
```

`devkmsg_read()` 从 ringbuffer 中读取日志，支持 `poll`（`POLLIN | POLLRDNORM`），所以 `dmesg -w` 可以实时跟踪日志。

## printk index 子系统

（`kernel/printk/index.c` — 194 行）

printk index 是相对较新的特性，它为内核中每个 `printk()` 格式字符串建立索引：

```c
// 在编译时，每个 printk 的格式字符串被记录到 .printk_index 段
// 在内核启动后，可以通过 /sys/kernel/debug/printk/index/ 查看

// 生成索引：
PI_KN(pr_info("Hello %s\n", name))
→ 记录到 .printk_index 段 → 在内核中被索引
→ /sys/kernel/debug/printk/index/<module>/<id>: "Hello %s"
```

这个索引使系统管理工具可以 grep 日志格式字符串而不是实际内容，对故障诊断很有价值。

## 控制台注册与层级

```
系统启动时的控制台注册流程：
  start_kernel()
    └─ console_init()
         └─ 注册早期控制台（通常是通过 BASE_BOOT 或没有硬件依赖的）
             early_console = struct console {... .flags = CON_BOOT, ...}

  ...

  do_initcalls()
    └─ 驱动初始化 → 注册实际控制台
         └─ register_console(con)
              └─ 如果 cons 的 flags & CON_CONSDEV
                  将其设为 console_drivers 链表的第一个
              └─ 如果之前有 boot console，注销它
```

控制台输出的优先级：
1. **Boot console**（最早，没有驱动的控制台）
2. **Preferred console**（`console=` 内核参数指定的）
3. **其他控制台**（按注册顺序）

## printk 级别与日志控制

```c
#define KERN_EMERG    "<0>"    // 紧急（系统不可用）
#define KERN_ALERT    "<1>"    // 需要立即处理
#define KERN_CRIT     "<2>"    // 严重条件
#define KERN_ERR      "<3>"    // 错误
#define KERN_WARNING  "<4>"    // 警告
#define KERN_NOTICE   "<5>"    // 正常但重要
#define KERN_INFO     "<6>"    // 信息
#define KERN_DEBUG    "<7>"    // 调试

// 通过 /proc/sys/kernel/printk 控制控制台输出级别：
// 文件内容：console_loglevel default_loglevel minimum_loglevel default_console_level
// 例如： "4 4 1 7"
//   console_loglevel: > 此级别的消息才输出到控制台
//   default_loglevel: 未指定级别的 printk 使用此级别
//   minimum_loglevel: 允许设置的最低级别
//   default_console_level: 启动时的默认 console_loglevel
```

## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `printk()` | kernel/printk/printk.c | 入口 |
| `vprintk_store()` | kernel/printk/printk.c | 格式化+存储 |
| `console_unlock()` | kernel/printk/printk.c | 控制台输出 |
| `register_console()` | kernel/printk/printk.c | 控制台注册 |
| `struct console` | include/linux/console.h | 核心结构 |
| `struct prb` | kernel/printk/printk_ringbuffer.h | ringbuffer |
| `struct printk_info` | kernel/printk/printk_ringbuffer.h | 日志元数据 |
| `prb_reserve()` | kernel/printk/printk_ringbuffer.c | 原子保留 |
| `prb_final_commit()` | kernel/printk/printk_ringbuffer.c | 原子提交 |
| `prb_first_valid_seq()` | kernel/printk/printk_ringbuffer.c | 读取 |
| `nbcon_context_try_acquire_direct()` | kernel/printk/nbcon.c | 243 |
| `nbcon_release()` | kernel/printk/nbcon.c | 相关 |
| `devkmsg_read()` | kernel/printk/printk.c | /dev/kmsg 读取 |
| `devkmsg_write()` | kernel/printk/printk.c | /dev/kmsg 写入 |
| `printk_index_init()` | kernel/printk/index.c | printk index |
| `console_init()` | kernel/printk/printk.c | 启动早期控制台 |
