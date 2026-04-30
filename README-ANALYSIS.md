# Linux Kernel 数据结构与同步原语 — 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 内核源码：`~/code/linux`
> 编译数据库：`~/code/linux/compile_commands.json`

---

## 📚 分析笔记索引

### 基础数据结构（第 1-4 天）

| 文件 | 主题 | 核心要点 |
|------|------|---------|
| `01-list_head-analysis.md` | `list_head` 双向循环链表 | `container_of` / `list_for_each_entry` / `WRITE_ONCE` / RCU |
| `02-hlist-analysis.md` | `hlist` 哈希链表 | `pprev` 技巧 / 单指针桶头 / 1111 处使用 |
| `03-rbtree-analysis.md` | `rbtree` 红黑树 | `__rb_parent_color` 压缩 / 旋转平衡 / CFS 调度 |
| `04-xarray-analysis.md` | `xarray` 可扩展基数树 | 低 2 位 tagging / xas_for_each O(n) / 1426 处使用 |

### 映射器与设备模型（第 5-6 天）

| 文件 | 主题 | 核心要点 |
|------|------|---------|
| `05-idr-ida-analysis.md` | `idr` / `ida` 整数 ID 映射 | radix_tree 底层 / xarray + 位图 / minor 号 |
| `06-kobject-kset-analysis.md` | `kobject` + `kset` | kref 引用计数 / sysfs 目录树 / uevent 热插拔 |

### 同步原语（第 7-11 天）

| 文件 | 主题 | 核心要点 |
|------|------|---------|
| `07-wait-queue-analysis.md` | `wait_queue_head` 等待队列 | `spinlock` + `list_head` / EXCLUSIVE 避免惊群 / `prepare_to_wait` + `schedule` |
| `08-mutex-analysis.md` | `mutex` 可睡眠互斥锁 | owner 原子变量 / `__mutex_trylock_fast` / MCS osq / FIFO 唤醒 |
| `09-spinlock-analysis.md` | `spinlock` 自旋锁 | qspinlock / MCS 队列 / `local_irq_save` / 不可睡眠 |
| `10-rwsem-analysis.md` | `rwsem` 读写信号量 | `atomic_long_t count` / OWNER_STATE / `rwsem_optimistic_spin` |
| `11-rwsem-v70-improvements.md` | rwsem v7.0 强化 | Clang Context Analysis / F2FS trace / spinning 受益 |

### 条件等待与异步执行（第 12-15 天）

| 文件 | 主题 | 核心要点 |
|------|------|---------|
| `12-completion-analysis.md` | `completion` 一次性完成信号 | `done` 计数器 / `complete()` / `complete_all()` / `swait_queue_head` |
| `13-futex-analysis.md` | `futex` 用户态快速互斥 | 用户态原子抢锁 / 内核哈希表 / PI 优先级继承 / `FUTEX_LOCK_PI` |
| `14-wait-event-analysis.md` | `wait_event` 可睡眠条件等待 | `___wait_event` 宏 / `prepare_to_wait` / `WQ_FLAG_EXCLUSIVE` / `wake_up` |
| `15-workqueue-analysis.md` | `workqueue` 异步工作队列 | `work_struct` / `worker_pool` / `delayed_work` / `WQ_UNBOUND` |
| `16-kthread-analysis.md` | `kthread` 内核持久线程 | `kthread_run` / `kthread_should_stop` / `kthreadd_task` / park/unpark |
| `17-get-user-pages-analysis.md` | `get_user_pages` 用户页获取 | `follow_page_mask` / `faultin_page` / `FOLL_PIN` / `gup_fast_fallback` |

---

## 🔑 每篇核心速查

### list_head
```c
struct list_head { next, prev };  // 16B
container_of(ptr, type, member)  // ptr - offsetof
list_for_each_entry(pos, head, member)  // 最常用遍历
WRITE_ONCE / READ_ONCE  // 编译器屏障
LIST_POISON1/2          // 删除后置毒，fail-fast
```

### hlist
```c
struct hlist_head { *first };       // 8B/桶（比 list_head 少 8B）
struct hlist_node { *next, **pprev }; // pprev = 前驱 next 指针的地址
__hlist_del(n): *n->pprev = n->next  // O(1) 删除，无需头指针
hlist_for_each_entry  // 与 list_head 相同模式
hlist_nulls         // 防 ABA 的 nulls marker
```

### rbtree
```c
struct rb_node { __rb_parent_color, *rb_right, *rb_left }; // parent + color 合并存储
rb_parent(r) = r->__rb_parent_color & ~3
rb_color(r) = r->__rb_parent_color & 1
__rb_insert()       // 插入平衡（3 情况）
____rb_erase_color() // 删除双黑修复（4 情况）
rb_root_cached     // 最左节点缓存（O(1) 找 min）
rb_augment_callbacks  // 旋转时维护派生数据
```

### xarray
```c
struct xarray { spinlock, xa_flags, *xa_head }
struct xa_node { shift, offset, count, *slots[64], marks[3][1] }
低位 tagging: (ptr << 2) | 2 = 内部条目
XA_CHUNK_SHIFT = 6 → 64 槽/节点
xas_for_each: O(n) 线性遍历
小索引优化: index < 64 → xa_head 直接存储 entry
xa_mark_0/1/2: 3 个位图标记
```

### idr / ida
```c
struct idr { radix_tree_root, idr_base, idr_next }  // radix_tree 底层
struct ida { xarray }                                // xarray + 位图
IDA_BITMAP_BITS = 1024 // 每 bitmap 1024 bits = 128 bytes
ida: 1 bit/ID，省内存 90%+
```

### kobject / kset
```c
struct kobject { *name, entry, *parent, *kset, *ktype, *sd, kref }
struct kset { list_head, *kobj, *uevent_ops }  // kset 自身也是 kobject
kref: refcount_t 原子引用计数
kobject_put → kref_put → ktype->release()  // 延迟释放
sysfs 目录树 ← parent 指针链
uevent: KOBJ_ADD/REMOVE/CHANGE... → udev
```

### wait_queue
```c
struct wait_queue_head { spinlock, list_head }
struct wait_queue_entry { flags, *private, func, entry }
WQ_FLAG_EXCLUSIVE: 独占等待，尾插，wake 时只唤醒一个
prepare_to_wait() → set_current_state() → schedule()
wake_up() → __wake_up() → func() → try_to_wake_up()
default_wake_function(*private) = try_to_wake_up(task)
```

### mutex
```c
struct mutex { atomic_long_t owner, wait_lock, *first_waiter, osq }
owner = current | MUTEX_FLAGS  // task_struct* + flag 合并
__mutex_trylock_fast: cmpxchg(owner, 0, current) → O(1) 无锁
__mutex_unlock_fast: cmpxchg(owner, current, 0) → O(1) 无锁
争用: add_wait_queue + schedule() 睡眠
MCS osq: 减少多核 cacheline 竞争
```

### spinlock
```c
struct spinlock { raw_spinlock rlock }
struct raw_spinlock { arch_spinlock_t }  // qspinlock
qspinlock: locked(1B) + pending(1B) + tail(2B) = 4B 状态
MCS per-cpu: 锁传递只涉及相邻节点，无 cacheline 颠簸
spin_lock_irqsave: local_irq_save + spin_lock
不可睡眠、不可抢占、中断上下文专用
```

### rwsem
```c
struct rw_semaphore { atomic_long_t count, owner, osq, wait_lock, wait_list }
count: 正数=读者数, bit0=WRITER_LOCKED
owner: OWNER_NULL/OWNER_WRITER/OWNER_READER/OWNER_NONSPINNABLE
down_read: count++，读者可并发
down_write: 独占，阻塞所有读者和写者
rwsem_optimistic_spin: osq + 检查 owner 是否在运行 → cmpxchg 抢锁
up_read: count--，最后一个读者唤醒队首（写者优先）
up_write: 唤醒队首（如果是写者）
```

---

## 🛠 工具使用

```bash
SKILL_DIR=~/code/workspace/skills/doom-lsp/scripts
PROJECT=~/code/linux

# 文件概览
$SKILL_DIR/doom-query.sh $PROJECT summary path/to/file.h

# 上下文查看（关键行号）
$SKILL_DIR/doom-query.sh $PROJECT context path/file.h 123

# 符号搜索
$SKILL_DIR/doom-query.sh $PROJECT sym symbolName

# 项目健康检查
$SKILL_DIR/doom-query.sh $PROJECT ping
```

### completion
```c
struct completion { unsigned int done; struct swait_queue_head wait; }
done = 0 → 未完成，done++ → 唤醒一个
complete(): done++，swake_up_locked() 唤醒一个
complete_all(): done = UINT_MAX，唤醒全部
wait_for_completion(): 检查 done > 0，否则 schedule 睡眠
swait_queue_head: RT 优先级继承版 wait_queue_head
```

### futex
```c
// 用户态：cmpxchg 抢锁，零系统调用
// 内核：futex_hash[256] → futex_q（plist_node + task_struct）
FUTEX_WAIT: 如果 uaddr == val 则睡眠
FUTEX_WAKE: 唤醒 hash bucket 中等待者
FUTEX_LOCK_PI: rt_mutex 优先级继承，防优先级反转
FUTEX_REQUEUE: 移动等待者到另一个 futex，避免惊群
union futex_key: {i_seq, pgoff, offset} 或 {ptr, word, bitshift}
```

### wait_event
```c
wait_event(wq, condition): TASK_UNINTERRUPTIBLE 睡眠
wait_event_interruptible(wq, condition): 可被信号打断
___wait_event: 循环检查 condition，防虚假唤醒
prepare_to_wait: 将 task 加入 wait_queue，set_current_state()
WQ_FLAG_EXCLUSIVE: 尾插，wake 时只唤醒一个
finish_wait: list_del，set_current_state(RUNNING)
```

### workqueue
```c
struct work_struct { atomic_long_t data; struct list_head entry; work_func_t func; }
struct delayed_work { work_struct work; struct timer_list timer; }
struct worker_pool { spinlock_t lock; list_head worklist; list_head workers; }
queue_work(wq, work): insert_work + wake_up_idle_worker
worker_thread: for(;;) { schedule(); work = list_first_entry(&pool->worklist); work->func(); }
WQ_UNBOUND: NUMA 友好，不绑 CPU
system_wq: 快捷方式，默认 unbound
```

### kthread
```c
struct kthread { flags, cpu, node, threadfn, data, completion parked/exited }
kthread_run(threadfn, data, name): kthread_create + wake_up_process
kthread_should_stop(): test_bit(KTHREAD_SHOULD_STOP)
kthread_stop(k): set_bit + wake_up + wait_for_completion(&exited)
kthread_park/unpark: KTHREAD_SHOULD_PARK + completion 同步
kthreadd_task (PID=2): 所有 kthread 的祖先
```

### get_user_pages
```c
get_user_pages(start, nr_pages, gup_flags, pages)
  → __get_user_pages_locked(current->mm, ...)
    → __get_user_pages(mm, start, nr_pages, gup_flags, pages, locked)
      → do { follow_page_mask(vma, addr) → hit? → get_page/pin
                        miss? → faultin_page() → handle_mm_fault()
                        retry } while(nr_pages--)

follow_page_mask: pgd→pud→pmd→pte 页表遍历，O(1) per page
faultin_page: handle_mm_fault() → do_fault / do_anonymous_page
FOLL_GET: put_page() 释放
FOLL_PIN: unpin_user_page() 释放（DMA/RDMA 用）
gup_fast_fallback: 架构特定快速页表遍历，不触发 fault
```
