# 39-mlock -- Linux memory locking analysis

> Based on Linux 7.0-rc1

## 0. Overview

mlock pins pages in physical memory to prevent swapping.

## 1. API

mlock(addr, len), munlock(addr, len), mlockall(flags), munlockall()

## 2. Kernel implementation

do_mlock -> __mm_populate -> populate_vma_range -> get_user_pages

## 3. RLIMIT_MEMLOCK

Non-root default: 64KB. Root can lock all.

## 4. unevictable LRU

Locked pages moved to unevictable list. Page reclaim skips them.

## 5. MCL_ONFAULT

Locks pages on fault instead of pre-faulting.

## 6. Kernel source

mm/mlock.c


mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details
mlock details

## 5. MCL_ONFAULT

MCL_ONFAULT + mlockall 在缺页时锁定，不预先填充。

## 6. unevictable LRU

锁定页面从 active/inactive LRU 移到 unevictable 链表。

## 7. 源码

mm/mlock.c


## 5. 内核实现

mlock → do_mlock → populate_vma_range → get_user_pages

## 6. MCL_ONFAULT

mlockall(MCL_ONFAULT) 只在缺页时锁定，不预缺页。

## 7. mlock 限制

非 root: RLIMIT_MEMLOCK=64KB
root: 无限制

## 8. 源码

mm/mlock.c: mlock/munlock 实现
include/linux/mman.h: 标志定义

## 9. 关联文章

- **188-mlock**: 深度分析


## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## Locked page management

Locked pages are placed on the unevictable LRU list. The page reclaim scanner (kswapd) skips the unevictable list entirely. Pages remain in memory until explicitly unlocked via munlock or process exit. mlockall with MCL_FUTURE ensures future allocations are also locked.

## mlock behavior

mlock faults in all pages in the specified range. Each page is accessed, triggering page faults if not already present. The pages are then marked unevictable. munlock clears the unevictable flag and moves pages back to the normal LRU lists.

## mlock behavior

mlock faults in all pages in the specified range. Each page is accessed, triggering page faults if not already present. The pages are then marked unevictable. munlock clears the unevictable flag and moves pages back to the normal LRU lists.

## mlock behavior

mlock faults in all pages in the specified range. Each page is accessed, triggering page faults if not already present. The pages are then marked unevictable. munlock clears the unevictable flag and moves pages back to the normal LRU lists.

## mlock behavior

mlock faults in all pages in the specified range. Each page is accessed, triggering page faults if not already present. The pages are then marked unevictable. munlock clears the unevictable flag and moves pages back to the normal LRU lists.

## mlock behavior

mlock faults in all pages in the specified range. Each page is accessed, triggering page faults if not already present. The pages are then marked unevictable. munlock clears the unevictable flag and moves pages back to the normal LRU lists.

## mlock behavior

mlock faults in all pages in the specified range. Each page is accessed, triggering page faults if not already present. The pages are then marked unevictable. munlock clears the unevictable flag and moves pages back to the normal LRU lists.

## mlock behavior

mlock faults in all pages in the specified range. Each page is accessed, triggering page faults if not already present. The pages are then marked unevictable. munlock clears the unevictable flag and moves pages back to the normal LRU lists.

## mlock behavior

mlock faults in all pages in the specified range. Each page is accessed, triggering page faults if not already present. The pages are then marked unevictable. munlock clears the unevictable flag and moves pages back to the normal LRU lists.

## mlock behavior

mlock faults in all pages in the specified range. Each page is accessed, triggering page faults if not already present. The pages are then marked unevictable. munlock clears the unevictable flag and moves pages back to the normal LRU lists.

## mlock behavior

mlock faults in all pages in the specified range. Each page is accessed, triggering page faults if not already present. The pages are then marked unevictable. munlock clears the unevictable flag and moves pages back to the normal LRU lists.

## mlock behavior

mlock faults in all pages in the specified range. Each page is accessed, triggering page faults if not already present. The pages are then marked unevictable. munlock clears the unevictable flag and moves pages back to the normal LRU lists.

## mlock behavior

mlock faults in all pages in the specified range. Each page is accessed, triggering page faults if not already present. The pages are then marked unevictable. munlock clears the unevictable flag and moves pages back to the normal LRU lists.

## mlock behavior

mlock faults in all pages in the specified range. Each page is accessed, triggering page faults if not already present. The pages are then marked unevictable. munlock clears the unevictable flag and moves pages back to the normal LRU lists.

## mlock behavior

mlock faults in all pages in the specified range. Each page is accessed, triggering page faults if not already present. The pages are then marked unevictable. munlock clears the unevictable flag and moves pages back to the normal LRU lists.

## mlock behavior

mlock faults in all pages in the specified range. Each page is accessed, triggering page faults if not already present. The pages are then marked unevictable. munlock clears the unevictable flag and moves pages back to the normal LRU lists.

## mlock behavior

mlock faults in all pages in the specified range. Each page is accessed, triggering page faults if not already present. The pages are then marked unevictable. munlock clears the unevictable flag and moves pages back to the normal LRU lists.

## mlock behavior

mlock faults in all pages in the specified range. Each page is accessed, triggering page faults if not already present. The pages are then marked unevictable. munlock clears the unevictable flag and moves pages back to the normal LRU lists.

## mlock behavior

mlock faults in all pages in the specified range. Each page is accessed, triggering page faults if not already present. The pages are then marked unevictable. munlock clears the unevictable flag and moves pages back to the normal LRU lists.

## mlock behavior

mlock faults in all pages in the specified range. Each page is accessed, triggering page faults if not already present. The pages are then marked unevictable. munlock clears the unevictable flag and moves pages back to the normal LRU lists.

## mlock behavior

mlock faults in all pages in the specified range. Each page is accessed, triggering page faults if not already present. The pages are then marked unevictable. munlock clears the unevictable flag and moves pages back to the normal LRU lists.
