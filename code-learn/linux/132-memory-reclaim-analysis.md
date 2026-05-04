# 132-reclaim — 读 mm/vmscan.c：kswapd

---

## kswapd 的 PF_MEMALLOC 标志

（`mm/vmscan.c` L7438）

kswapd 线程在启动时设置了一个关键标志：

```c
tsk->flags |= PF_MEMALLOC | PF_KSWAPD;
```

PF_MEMALLOC 允许 kswapd 在内存分配器（`__alloc_pages`）中绕过水位检查。没有这个标志，kswapd 可能会在"为了释放内存而分配内存"的死循环中阻塞——kswapd 要写出脏页需要分配 BIO 请求，分配 BIO 请求需要内存，如果水位不足则触发 kswapd 唤醒，形成递归。

`PF_KSWAPD` 的标志在 shrink_folio_list 中使用：kswapd 发起的回收（`current_is_kswapd()` 为真）不会因为超过 dirty_ratio 而直接阻塞等待回写——kswapd 在后台写脏页，前台进程等脏页不够时才阻塞。

---

## kswapd_try_to_sleep——睡眠与唤醒的博弈

（`mm/vmscan.c` L7341）

```c
kswapd_try_to_sleep(pgdat, alloc_order, reclaim_order, highest_zoneidx)
  │
  ├─ 1. prepare_to_wait(&pgdat->kswapd_wait, ...)
  ├─ 2. if (prepare_kswapd_sleep(pgdat, reclaim_order, highest_zoneidx))
  │      → 所有 zone 的水位都 >= high
  │      → 重置 compaction isolation 缓存
  │      → wakeup_kcompactd()   // 让 kcompactd 在 kswapd 睡觉时做碎片整理
  │      → schedule_timeout(HZ/10)  // 睡 100ms
  │
  ├─ 3. 如果提前被唤醒（schedule_timeout 返回 remaining > 0）：
  │      → 保存 highest_zoneidx 和 order（用于下轮回收）
  │
  └─ 4. wait_event_freezable_timeout(..., HZ/10)
         // 等待 wakeup_kswapd() 唤醒或超时
```

kswapd 不直接睡到被 `wakeup_kswapd` 唤醒。它使用 100ms 超时的轮询——如果 100ms 内没有新的内存请求，kswapd 进入更深的休眠（通过 `wait_event_freezable`）。

---

## wakeup_kswapd——谁唤醒 kswapd

（`mm/vmscan.c` L7519）

`wakeup_kswapd` 在 `__alloc_pages_slowpath` 中调用——当快速路径（从 zone 的 freelist 直接分配）失败时：

```c
// mm/page_alloc.c — __alloc_pages_slowpath
// 如果快速路径失败，在进入慢路径时唤醒 kswapd
wake_all_kswapds(order, ac);

// 然后同步等待：
// __alloc_pages_direct_reclaim() — 直接回收（同步）
// 如果 kswapd 的异步回收不够快，同步回收插进来帮忙
```

---

## 直接回收 vs kswapd

| | kswapd | 直接回收 |
|--|--------|---------|
| 触发方式 | wakeup_kswapd（异步） | __alloc_pages 慢路径（同步） |
| PF_MEMALLOC | 是 | 否 |
| 回收时挂起 | 不挂起 IO 等待 | 可能挂起 |
| 目标 | 把水位恢复到 high | 分配成功即可 |
| 运行位置 | 内核线程 kswapd/N | 调用 __alloc_pages 的任意进程 |

直接回收比 kswapd 更危险——它发生在 **任何进程** 的分配路径中。一个持有的锁可能阻塞其他需要同一锁的进程。直接回收中的 IO 等待可能导致整个系统的连锁阻塞。
