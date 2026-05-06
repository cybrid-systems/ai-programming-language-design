# InnoDB Buffer Pool: A Deep Dive into the Code

The Buffer Pool is InnoDB's central memory cache — every page read or written passes through it. It's the largest consumer of memory in a MySQL server and the most performance-critical subsystem. This article walks through every major function and data structure with real source code from MySQL 8.4.

## 1. Architecture Overview

```
                  ┌──────────────────────────┐
                  │     buf_page_get_gen()    │
                  │   (the public entry point)│
                  └──────────┬───────────────┘
                             │
                  ┌──────────▼───────────────┐
                  │   Buf_fetch::lookup()     │
                  │   (page_hash lookup)      │
                  └──────┬──────────┬────────┘
                         │ found    │ not found
                         ▼          ▼
                  ┌──────────┐  ┌──────────────────┐
                  │ fix page │  │ Buf_fetch::      │
                  │ & return │  │ read_page()       │
                  └──────────┘  └────────┬─────────┘
                                         │
                                  ┌──────▼──────┐
                                  │ buf_read_   │
                                  │ page_low()  │
                                  └──────┬──────┘
                                         │
                                  ┌──────▼──────┐
                                  │  fil_io()    │
                                  │  (AIO path)  │
                                  └─────────────┘
```

The Buffer Pool consists of **multiple instances** (`buf_pool_t`), each managing its own LRU list, flush list, free list, page hash, and mutexes. This reduces contention on multicore systems.

---

## 2. The `buf_pool_t` Structure

The central data structure. Located in `buf0buf.h:2293`, it contains everything needed to manage one buffer pool instance.

`buf0buf.h:2293`:
```c
/** @brief The buffer pool structure.
NOTE! The definition appears here only for other modules of this
directory (buf) to see it. Do not use from outside! */
struct buf_pool_t {
  /** @name General fields */
  /** @{ */
  /** protects (de)allocation of chunks */
  BufListMutex chunks_mutex;
  /** LRU list mutex */
  BufListMutex LRU_list_mutex;
  /** free and withdraw list mutex */
  BufListMutex free_list_mutex;
  /** buddy allocator mutex */
  BufListMutex zip_free_mutex;
  /** zip_hash mutex */
  BufListMutex zip_hash_mutex;
  /** Flush state protection mutex */
  ib_mutex_t flush_state_mutex;
  /** Zip mutex of this buffer pool instance, protects compressed only pages */
  BufPoolZipMutex zip_mutex;

  /** Array index of this buffer pool instance */
  ulint instance_no;

  /** Current pool size in bytes */
  ulint curr_pool_size;
  /** Reserve this much of the buffer pool for "old" blocks */
  ulint LRU_old_ratio;

  /** Number of buffer pool chunks */
  volatile ulint n_chunks;
  /** New number of buffer pool chunks */
  volatile ulint n_chunks_new;
  /** buffer pool chunks */
  buf_chunk_t *chunks;
  /** old buffer pool chunks to be freed after resizing buffer pool */
  buf_chunk_t *chunks_old;

  /** Current pool size in pages */
  ulint curr_size;
  /** Previous pool size in pages */
  ulint old_size;

  /** Size in pages of the read-ahead area */
  page_no_t read_ahead_area;

  /** Hash table of buf_page_t or buf_block_t file pages,
  indexed by (space_id, offset). page_hash is protected by
  an array of mutexes. */
  hash_table_t *page_hash;

  /** Hash table of buf_block_t blocks whose frames are allocated
  to the zip buddy system, indexed by block->frame */
  hash_table_t *zip_hash;

  /** Number of pending read operations. Accessed atomically */
  std::atomic<ulint> n_pend_reads;
  /** number of pending decompressions. Accessed atomically. */
  std::atomic<ulint> n_pend_unzip;

  /** Last time buf_print_io was called. */
  std::chrono::steady_clock::time_point last_printout_time;

  /** Statistics of buddy system, indexed by block size */
  buf_buddy_stat_t buddy_stat[BUF_BUDDY_SIZES_MAX + 1];

  /** Current statistics */
  buf_pool_stat_t stat;
  /** Old statistics */
  buf_pool_stat_t old_stat;
  /** @} */
```

`buf0buf.h:2344` — Flush-related fields:
```c
  /** @name Page flushing algorithm fields */
  /** @{ */
  /** Mutex protecting the flush list access */
  BufListMutex flush_list_mutex;
  /** "Hazard pointer" used during scan of flush_list */
  FlushHp flush_hp;
  /** Entry pointer to scan the oldest page except for system temporary */
  FlushHp oldest_hp;
  /** Base node of the modified block list */
  UT_LIST_BASE_NODE_T(buf_page_t, list) flush_list;

  /** true when a flush of the given type is being initialized.
  Protected by flush_state_mutex. */
  bool init_flush[BUF_FLUSH_N_TYPES];
  /** number of pending writes in the given flush type. */
  std::array<size_t, BUF_FLUSH_N_TYPES> n_flush;
  /** Set when there is no flush batch of the given type running. */
  os_event_t no_flush[BUF_FLUSH_N_TYPES];

  /** Count of buffer blocks removed from end of LRU list */
  ulint freed_page_clock;
  /** Set to false when an LRU scan for free block fails. */
  bool try_LRU_scan;

  /** Page Tracking start LSN. */
  lsn_t track_page_lsn;
  /** Maximum LSN for which write io has already started. */
  lsn_t max_lsn_io;
  /** @} */
```

`buf0buf.h:2402` — LRU replacement fields:
```c
  /** @name LRU replacement algorithm fields */
  /** @{ */
  /** Base node of the free block list */
  UT_LIST_BASE_NODE_T(buf_page_t, list) free;
  /** base node of the withdraw block list */
  UT_LIST_BASE_NODE_T(buf_page_t, list) withdraw;
  /** Target length of withdraw block list */
  ulint withdraw_target;

  /** "hazard pointer" used during scan of LRU while doing LRU list batch */
  LRUHp lru_hp;
  /** Iterator used to scan the LRU list when searching for replaceable victim */
  LRUItr lru_scan_itr;
  /** Iterator used to scan the LRU list for single page flushing victim */
  LRUItr single_scan_itr;

  /** Base node of the LRU list */
  UT_LIST_BASE_NODE_T(buf_page_t, LRU) LRU;
  /** Pointer to the about LRU_old_ratio oldest blocks in the LRU list */
  buf_page_t *LRU_old;
  /** Length of the LRU list from the block to which LRU_old points onward */
  ulint LRU_old_len;

  /** Base node of the unzip_LRU list. */
  UT_LIST_BASE_NODE_T(buf_block_t, unzip_LRU) unzip_LRU;
  /** @} */

  /** @name Buddy allocator fields */
  /** @{ */
  /** Buddy free lists */
  UT_LIST_BASE_NODE_T(buf_buddy_free_t, list) zip_free[BUF_BUDDY_SIZES_MAX];
  /** Sentinel records for buffer pool watches */
  buf_page_t *watch;
  /** @} */
};
```

**Key observations:**
- **6 mutexes** protect different subsystems: `LRU_list_mutex`, `free_list_mutex`, `flush_list_mutex`, `zip_free_mutex`, `zip_hash_mutex`, `flush_state_mutex`
- The `page_hash` is a **hash table** keyed by `(space_id, page_no)` — the most critical lookup path
- `LRU_old_ratio` controls the **midpoint insertion** strategy (37.5% by default)
- Each flush type (`BUF_FLUSH_LRU`, `BUF_FLUSH_LIST`, `BUF_FLUSH_SINGLE_PAGE`) has its own `init_flush`/`n_flush` tracking

---

## 3. The `buf_page_t` Page Descriptor

Every page in the buffer pool — whether a full `buf_block_t` (with decompressed frame) or a compressed-only `buf_page_t` — is represented by a `buf_page_t`.

`buf0buf.h:1164`:
```c
class buf_page_t {
  /** Page id. */
  page_id_t id;
  /** Page size. */
  page_size_t size;
  /** Count of how many fold this block is currently bufferfixed. */
  buf_fix_count_atomic_t buf_fix_count;

 private:
  /** Type of pending I/O operation. */
  copyable_atomic_t<buf_io_fix> io_fix;

  /** State of the block (BUF_BLOCK_FILE_PAGE, BUF_BLOCK_ZIP_DIRTY, etc.) */
  buf_page_state state;

  /** Flush type (BUF_FLUSH_LRU, BUF_FLUSH_LIST, etc.) */
  buf_flush_t flush_type;

  /** Index of the buffer pool instance this page belongs to. */
  ulint buf_pool_index;

  /** hash chain node for page_hash */
  hash_node_t hash;
  /** list node for flush_list, free_list, or withdraw list */
  UT_LIST_NODE_T(buf_page_t, list) list;

  /** LSN of the most recent modification */
  lsn_t newest_modification;
  /** LSN of the first modification since the last flush */
  lsn_t oldest_modification;

  /** LRU list node */
  UT_LIST_NODE_T(buf_page_t, LRU) LRU;

  /** Compressed page data (NULL if uncompressed) */
  page_zip_t zip;

  /** Flush observer for bulk operations */
  Flush_observer *m_flush_observer;
  /** Pointer to the tablespace object */
  fil_space_t *m_space;
  /** Version of the tablespace when this page ID was set */
  uint64_t m_version;
  /** Doublewrite buffer batch ID */
  uint16_t m_dblwr_id;
  /** Is this page in the "old" block portion of the LRU list */
  bool old;
  /** Access time (for heuristics) */
  copyable_atomic_t<std::chrono::steady_clock::time_point> access_time;
};
```

**`buf_page_state` enum** — `buf0buf.h:130`:
```c
enum buf_page_state : uint8_t {
  BUF_BLOCK_POOL_WATCH = 200,   /** Sentinel for watched page slot */
  BUF_BLOCK_ZIP_PAGE,           /** Compressed page, no uncompressed frame */
  BUF_BLOCK_ZIP_DIRTY,          /** Compressed page, dirty */
  BUF_BLOCK_NOT_USED,           /** Not used */
  BUF_BLOCK_READY_FOR_USE,      /** Ready for allocation */
  BUF_BLOCK_FILE_PAGE,          /** Normal page with frame */
  BUF_BLOCK_MEMORY,             /** Used for non-data memory allocation */
  BUF_BLOCK_REMOVE_HASH         /** Temp state during page removal */
};
```

---

## 4. Buffer Pool Initialization: `buf_pool_init()`

When InnoDB starts, `buf_pool_init()` allocates and initializes all buffer pool instances. It divides available memory equally among instances and creates them in parallel for speed.

`buf0buf.cc:1506`:
```c
dberr_t buf_pool_init(ulint total_size, ulint n_instances) {
  ulint i;
  const ulint size = total_size / n_instances;

  ut_ad(n_instances > 0);
  ut_ad(n_instances <= MAX_BUFFER_POOLS);
  ut_ad(n_instances == srv_buf_pool_instances);

  NUMA_MEMPOLICY_INTERLEAVE_IN_SCOPE;

  buf_flush_list_added = Buf_flush_list_added_lsns::create();

  buf_pool_should_madvise = innobase_should_madvise_buf_pool();
  buf_pool_resizing = false;

  buf_pool_ptr = (buf_pool_t *)ut::zalloc_withkey(
      UT_NEW_THIS_FILE_PSI_KEY, n_instances * sizeof *buf_pool_ptr);

  buf_chunk_map_reg =
      ut::new_withkey<buf_pool_chunk_map_t>(UT_NEW_THIS_FILE_PSI_KEY);

  std::vector<dberr_t> errs;
  errs.assign(n_instances, DB_SUCCESS);

#ifdef UNIV_LINUX
  ulint n_cores = sysconf(_SC_NPROCESSORS_ONLN);
  if (n_cores > 8) {
    n_cores = 8;
  }
#else
  ulint n_cores = 4;
#endif

  dberr_t err = DB_SUCCESS;

  for (i = 0; i < n_instances; /* no op */) {
    ulint n = i + n_cores;
    if (n > n_instances) {
      n = n_instances;
    }

    std::vector<IB_thread> threads;
    std::mutex m;

    for (ulint id = i; id < n; ++id) {
      threads.emplace_back(os_thread_create(buf_pool_create_thread_key, 0,
                                            buf_pool_create, &buf_pool_ptr[id],
                                            size, id, &m, std::ref(errs[id])));
      threads[id - i].start();
    }
    // wait for all to complete
    for (ulint id = i; id < n; ++id) {
      threads[id - i].join();
      if (errs[id] != DB_SUCCESS) err = errs[id];
    }
    if (err != DB_SUCCESS) { /* cleanup and return */ }
    i = n; // do next block of instances
  }

  buf_pool_set_sizes();
  buf_LRU_old_ratio_update(100 * 3 / 8, false);  // 37.5% old block ratio

  btr_search_sys_create(buf_pool_get_curr_size() / sizeof(void *) / 64);

  buf_stat_per_index = ut::new_withkey<buf_stat_per_index_t>(...);

  return (DB_SUCCESS);
}
```

**Key details:**
- Instances are created **in parallel** (up to 8 at a time) using OS threads
- The **old block ratio** is set to 3/8 = **37.5%** — this is the famous midpoint insertion strategy
- Each instance gets `total_size / n_instances` bytes of memory
- The `buf_pool_create()` function allocates the memory chunks (via `buf_chunk_t`) and initializes the page hash, mutexes, lists, and buddy allocator

---

## 5. Page Hash: The Lookup Roadmap

The page hash is a `hash_table_t` that maps `(space_id, page_no)` → `buf_page_t*`. It's the fastest path into the buffer pool — every page fetch starts here.

### 5.1 `buf_page_hash_get_low()` — The Core Lookup

`buf0buf.ic:849`:
```c
static inline buf_page_t *buf_page_hash_get_low(buf_pool_t *buf_pool,
                                                const page_id_t &page_id) {
  buf_page_t *bpage;

#ifdef UNIV_DEBUG
  rw_lock_t *hash_lock;
  hash_lock = hash_get_lock(buf_pool->page_hash, page_id.hash());
  ut_ad(rw_lock_own(hash_lock, RW_LOCK_X) || rw_lock_own(hash_lock, RW_LOCK_S));
#endif

  HASH_SEARCH(hash, buf_pool->page_hash, page_id.hash(), buf_page_t *, bpage,
              ut_ad(bpage->in_page_hash && !bpage->in_zip_hash &&
                    buf_page_in_file(bpage)),
              page_id == bpage->id);
  if (bpage) {
    ut_a(buf_page_in_file(bpage));
    ut_ad(bpage->in_page_hash);
    ut_ad(!bpage->in_zip_hash);
    ut_ad(buf_pool_from_bpage(bpage) == buf_pool);
  }
  return (bpage);
}
```

The `HASH_SEARCH` macro iterates the hash chain at the bucket `page_id.hash()` and compares the full `page_id`. In debug builds, it verifies invariant flags.

### 5.2 `buf_page_hash_get_locked()` — The Wrapper With Locking

`buf0buf.ic:929`:
```c
static inline buf_page_t *buf_page_hash_get_locked(buf_pool_t *buf_pool,
                                                   const page_id_t &page_id,
                                                   rw_lock_t **lock,
                                                   ulint lock_mode,
                                                   bool watch) {
  buf_page_t *bpage = nullptr;
  rw_lock_t *hash_lock;
  ulint mode = RW_LOCK_S;

  if (lock != nullptr) {
    *lock = nullptr;
    ut_ad(lock_mode == RW_LOCK_X || lock_mode == RW_LOCK_S);
    mode = lock_mode;
  }

  hash_lock = hash_get_lock(buf_pool->page_hash, page_id.hash());

  ut_ad(!rw_lock_own(hash_lock, RW_LOCK_X) &&
        !rw_lock_own(hash_lock, RW_LOCK_S));

  if (mode == RW_LOCK_S) {
    rw_lock_s_lock(hash_lock, UT_LOCATION_HERE);
    hash_lock =
        hash_lock_s_confirm(hash_lock, buf_pool->page_hash, page_id.hash());
  } else {
    rw_lock_x_lock(hash_lock, UT_LOCATION_HERE);
    hash_lock =
        hash_lock_x_confirm(hash_lock, buf_pool->page_hash, page_id.hash());
  }

  bpage = buf_page_hash_get_low(buf_pool, page_id);

  if (!bpage || buf_pool_watch_is_sentinel(buf_pool, bpage)) {
    if (!watch) {
      // ... release lock
    }
  }
  // ... return with or without lock
}
```

### 5.3 Convenience Wrappers

`buf0buf.h:1038`:
```c
inline buf_page_t *buf_page_hash_get_s_locked(buf_pool_t *b,
                                              const page_id_t &page_id,
                                              rw_lock_t **l) {
  return buf_page_hash_get_locked(b, page_id, l, RW_LOCK_S);
}
inline buf_page_t *buf_page_hash_get_x_locked(buf_pool_t *b,
                                              const page_id_t &page_id,
                                              rw_lock_t **l) {
  return buf_page_hash_get_locked(b, page_id, l, RW_LOCK_X);
}
inline buf_page_t *buf_page_hash_get(buf_pool_t *b, const page_id_t &page_id) {
  return buf_page_hash_get_locked(b, page_id, nullptr, 0);
}
inline buf_block_t *buf_block_hash_get_s_locked(buf_pool_t *b,
                                                const page_id_t &page_id,
                                                rw_lock_t **l) {
  return buf_block_hash_get_locked(b, page_id, l, RW_LOCK_S);
}
```

The hash lock is obtained from the hash table itself, allowing **fine-grained concurrent access** — different buckets can be searched simultaneously:

`buf0buf.h:2487`:
```c
inline rw_lock_t *buf_page_hash_lock_get(const buf_pool_t *buf_pool,
                                         const page_id_t page_id) {
  return hash_get_lock(buf_pool->page_hash, page_id.hash());
}
```

### 5.4 Watch Sentinel Pages

When a thread needs to read a page from disk, it sets a **watch sentinel** in the page hash. This prevents other threads from also reading the same page (a "thundering herd" avoidance mechanism). The sentinel is a `BUF_BLOCK_POOL_WATCH` state entry that returns NULL to normal lookups but is recognized by `buf_pool_watch_is_sentinel()`.

`buf0buf.ic:929` — The `watch` parameter controls this:
```c
  if (!bpage || buf_pool_watch_is_sentinel(buf_pool, bpage)) {
    if (!watch) {
      // caller doesn't want watches; return NULL
      if (mode == RW_LOCK_S) rw_lock_s_unlock(hash_lock);
      else rw_lock_x_unlock(hash_lock);
      if (lock) *lock = nullptr;
      return nullptr;
    }
  }
```

---

## 6. The Page Fetch Path

The main entry point is `buf_page_get_gen()`, which creates a `Buf_fetch` object and calls its `single_page()` method.

### 6.1 `buf_page_get_gen()` — Public Entry Point

`buf0buf.cc:4439`:
```c
buf_block_t *buf_page_get_gen(const page_id_t &page_id,
                              const page_size_t &page_size, ulint rw_latch,
                              buf_block_t *guess, Page_fetch mode,
                              ut::Location location, mtr_t *mtr,
                              bool dirty_with_no_latch) {
  // Debug validation of parameters
  ut_ad(mtr->is_active());
  ut_ad(rw_latch == RW_S_LATCH || rw_latch == RW_X_LATCH ||
        rw_latch == RW_SX_LATCH || rw_latch == RW_NO_LATCH);

  if (mode == Page_fetch::NORMAL && !fsp_is_system_temporary(page_id.space())) {
    Buf_fetch_normal fetch(page_id, page_size);
    fetch.m_rw_latch = rw_latch;
    fetch.m_guess = guess;
    fetch.m_mode = mode;
    fetch.m_file = location.filename;
    fetch.m_line = location.line;
    fetch.m_mtr = mtr;
    fetch.m_dirty_with_no_latch = dirty_with_no_latch;

    return (fetch.single_page());
  } else {
    Buf_fetch_other fetch(page_id, page_size);
    // ... same setup, different class
    return (fetch.single_page());
  }
}
```

### 6.2 `Buf_fetch_normal::get()` — The Main Loop

`buf0buf.cc:3690`:
```c
struct Buf_fetch_normal : public Buf_fetch<Buf_fetch_normal> {
  Buf_fetch_normal(const page_id_t &page_id, const page_size_t &page_size)
      : Buf_fetch(page_id, page_size) {}

  dberr_t get(buf_block_t *&block) noexcept;
};

dberr_t Buf_fetch_normal::get(buf_block_t *&block) noexcept {
  /* Keep this path as simple as possible. */
  for (;;) {
    /* Lookup the page in the page hash. If it doesn't exist in the
    buffer pool then try and read it in from disk. */

    ut_ad(
        !rw_lock_own(buf_page_hash_lock_get(m_buf_pool, m_page_id), RW_LOCK_S));

    block = lookup();

    if (block != nullptr) {
      if (block->page.was_stale()) {
        if (!buf_page_free_stale(m_buf_pool, &block->page, m_hash_lock)) {
          std::this_thread::sleep_for(std::chrono::microseconds(100));
        }
        continue;
      }

      buf_block_fix(block);
      rw_lock_s_unlock(m_hash_lock);
      break;
    }

    /* Page not in buf_pool: needs to be read from file */
    read_page();
  }

  return DB_SUCCESS;
}
```

The `for(;;)` loop is the **heart of buffer pool access**: either find it in the hash or read it from disk. Stale pages (belonging to a dropped/resized tablespace) are freed and retried.

### 6.3 `Buf_fetch::lookup()` — Hash Lookup With Guess Optimization

`buf0buf.cc:3804`:
```c
template <typename T>
buf_block_t *Buf_fetch<T>::lookup() {
  m_hash_lock = buf_page_hash_lock_get(m_buf_pool, m_page_id);

  auto block = m_guess;

  rw_lock_s_lock(m_hash_lock, UT_LOCATION_HERE);

  m_hash_lock =
      buf_page_hash_lock_s_confirm(m_hash_lock, m_buf_pool, m_page_id);

  if (block != nullptr) {
    /* If the m_guess is a compressed page descriptor that has been
    allocated by buf_page_alloc_descriptor(), it may have been freed
    by buf_relocate(). Also, the buffer pool could get resized and
    m_guess's chunk could get freed, so we need to check the `block`
    pointer is still within one of the chunks before dereferencing it
    to verify it still contains the same m_page_id */

    if (!buf_is_block_in_instance(m_buf_pool, block) ||
        m_page_id != block->page.id ||
        buf_block_get_state(block) != BUF_BLOCK_FILE_PAGE) {
      block = m_guess = nullptr;
    } else {
      ut_ad(!block->page.in_zip_hash);
    }
  }

  if (block == nullptr) {
    block = reinterpret_cast<buf_block_t *>(
        buf_page_hash_get_low(m_buf_pool, m_page_id));
  }

  if (block == nullptr) {
    rw_lock_s_unlock(m_hash_lock);
    return (nullptr);
  }

  const auto bpage = &block->page;

  if (buf_pool_watch_is_sentinel(m_buf_pool, bpage)) {
    rw_lock_s_unlock(m_hash_lock);
    return (nullptr);
  }

  return (block);
}
```

The **guess optimization** (`m_guess`) is critical: if the same page is accessed repeatedly (common for index root pages), the caller can pass the pointer directly. The function validates it's still valid (same pool instance, same page ID, file page state) before using it.

### 6.4 `Buf_fetch::read_page()` — Triggering Disk Read

`buf0buf.cc:4107`:
```c
template <typename T>
void Buf_fetch<T>::read_page() {
  if (buf_read_page(m_page_id, m_page_size)) {
    /* Avoid doing read-ahead for parallel scans */
    if (m_mode != Page_fetch::SCAN) {
      buf_read_ahead_random(m_page_id, m_page_size, ibuf_inside(m_mtr));
    }
    m_retries = 0;
  } else if (m_retries < BUF_PAGE_READ_MAX_RETRIES) {
    ++m_retries;
  } else {
    ib::fatal(UT_LOCATION_HERE, ER_IB_MSG_74)
        << "Unable to read page " << m_page_id
        << " into the buffer pool after " << BUF_PAGE_READ_MAX_RETRIES
        << " attempts...";
  }
}
```

After reading the page, it triggers **random read-ahead** (`buf_read_ahead_random`) — InnoDB predicts sequential access patterns and prefetches neighboring pages.

### 6.5 `single_page()` — The Outer Loop

`buf0buf.cc:4337`:
```c
template <typename T>
buf_block_t *Buf_fetch<T>::single_page() {
  buf_block_t *block;
  Counter::inc(m_buf_pool->stat.m_n_page_gets, m_page_id.page_no());

  for (;;) {
    if (static_cast<T *>(this)->get(block) == DB_NOT_FOUND) {
      return (nullptr);
    }
    ut_a(!block->page.was_stale());

    if (is_optimistic()) {
      const auto bpage = &block->page;
      auto block_mutex = buf_page_get_mutex(bpage);

      mutex_enter(block_mutex);
      const auto state = buf_page_get_io_fix(bpage);
      // ... handle IO state transitions
      mutex_exit(block_mutex);
    }

#if defined UNIV_DEBUG || defined UNIV_IBUF_DEBUG
    /* change buffer debug: try to evict the block */
    auto ret = static_cast<T *>(this)->debug_check(block);
    if (ret != DB_SUCCESS) {
      // wait and retry
      continue;
    }
#endif

    if (buf_page_belongs_to_unzip_LRU(&block->page)) {
      auto ret = zip_page_handler(block);
      if (ret != DB_SUCCESS) {
        continue;
      }
    }

    /* Make young if needed (midpoint promotion) */
    if (m_mode != Page_fetch::SCAN) {
      buf_page_make_young_if_needed(&block->page);
    }

    static_cast<T *>(this)->mtr_add_page(block);
    return (block);
  }
}
```

This loop handles:
1. **IO state validation** — making sure no other thread is doing I/O on this page
2. **Change buffer debug** — optional eviction to test change buffer
3. **Compressed page decompression** — via `zip_page_handler`
4. **Midpoint promotion** — `buf_page_make_young_if_needed`
5. **mtr registration** — `mtr_add_page` attaches the page to the mini-transaction

---

## 7. The Disk Read Path: `buf_read_page_low()`

When a page is not in the buffer pool, the read path goes through `buf_read_page()`, which calls `buf_read_page_low()`.

`buf0rea.cc:66`:
```c
ulint buf_read_page_low(dberr_t *err, bool sync, ulint type, ulint mode,
                        const page_id_t &page_id, const page_size_t &page_size,
                        bool unzip) {
  buf_page_t *bpage;

  *err = DB_SUCCESS;

  if (page_id.space() == TRX_SYS_SPACE &&
      dblwr::v1::is_inside(page_id.page_no())) {
    ib::error(ER_IB_MSG_139)
        << "Trying to read legacy doublewrite buffer page " << page_id;
    return (0);
  }

  if (ibuf_bitmap_page(page_id, page_size) || trx_sys_hdr_page(page_id)) {
    /* Special pages must always be read synchronously to avoid
    thread deadlocks. */
    sync = true;
  }

  /* The following call will check if the tablespace does not exist
  or is being dropped. If we succeed in initing the page in the buffer
  pool for read, then DISCARD cannot proceed until the read completes */
  bpage = buf_page_init_for_read(mode, page_id, page_size, unzip);

  ut_a(bpage == nullptr || bpage->get_space()->id == page_id.space());

  if (bpage == nullptr) {
    return (0);
  }

  if (sync) {
    thd_wait_begin(nullptr, THD_WAIT_DISKIO);
  }

  void *dst;
  if (page_size.is_compressed()) {
    dst = bpage->zip.data;
  } else {
    ut_a(buf_page_get_state(bpage) == BUF_BLOCK_FILE_PAGE);
    dst = ((buf_block_t *)bpage)->frame;
  }

  IORequest request(type | IORequest::READ);
  *err = fil_io(request, sync, page_id, page_size, 0,
                page_size.physical(), dst, bpage);

  if (sync) {
    thd_wait_end(nullptr);
  }

  if (*err != DB_SUCCESS) {
    if (IORequest::ignore_missing(type) || *err == DB_TABLESPACE_DELETED) {
      buf_read_page_handle_error(bpage);
      return (0);
    }
    ut_error;
  }

  if (sync) {
    /* The i/o is already completed when we arrive from fil_read */
    if (!buf_page_io_complete(bpage, false)) {
      // ... log error
    }
  }

  return (1);
}
```

**Key flow:**
1. `buf_page_init_for_read()` — allocates a buffer pool slot for the incoming page (sets up page_hash, LRU position, I/O fix)
2. `fil_io()` — the actual I/O call. If `sync=true`, it's synchronous; otherwise, an AIO request is posted
3. For async requests, completion occurs in the **AIO completion callback** via `buf_page_io_complete()`
4. Special pages (ibuf bitmap, trx sys header) are always read **synchronously** to avoid deadlocks

`buf0rea.h:58` — The function signature:
```c
ulint buf_read_page_low(dberr_t *err, bool sync, ulint type, ulint mode,
                        const page_id_t &page_id, const page_size_t &page_size,
                        bool unzip);
```

The return value is the number of pages read (0 or 1).

---

## 8. LRU Management

The LRU list is the heart of buffer pool replacement. InnoDB uses a **midpoint insertion strategy** (the "old block" trick): new pages go into the "old" portion (tail 37.5%), and only if they're accessed again do they move to the "young" portion (head). This prevents large table scans from polluting the cache.

### 8.1 LRU Statistics Tracking

`buf0lru.h:244`:
```c
struct buf_LRU_stat_t {
  ulint io;    /**< Counter of buffer pool I/O operations. */
  ulint unzip; /**< Counter of page_zip_decompress operations. */
};

extern buf_LRU_stat_t buf_LRU_stat_cur;
extern buf_LRU_stat_t buf_LRU_stat_sum;

inline void buf_LRU_stat_inc_io() { buf_LRU_stat_cur.io++; }
inline void buf_LRU_stat_inc_unzip() { buf_LRU_stat_cur.unzip++; }
```

These counters are incremented by `buf_LRU_stat_inc_io()` — called after every buffer pool write (in `buf_flush_write_block_low()`) and after every page read. They feed into the `buf_LRU_stat_update()` heuristics that decide whether to scan more aggressively for free blocks.

### 8.2 Adding a Page: `buf_LRU_add_block()`

`buf0lru.cc:1656`:
```c
static inline void buf_LRU_add_block_low(buf_page_t *bpage, bool old) {
  buf_pool_t *buf_pool = buf_pool_from_bpage(bpage);

  ut_ad(mutex_own(&buf_pool->LRU_list_mutex));
  ut_a(buf_page_in_file(bpage));
  ut_ad(!bpage->in_LRU_list);

  if (!old || (UT_LIST_GET_LEN(buf_pool->LRU) < BUF_LRU_OLD_MIN_LEN)) {
    /* Put at the head (young end) */
    UT_LIST_ADD_FIRST(buf_pool->LRU, bpage);
    bpage->freed_page_clock = buf_pool->freed_page_clock;
  } else {
    /* Insert after the current LRU_old pointer (into old portion) */
#ifdef UNIV_LRU_DEBUG
    ut_a(buf_pool->LRU_old->old);
    ut_a(!UT_LIST_GET_PREV(LRU, buf_pool->LRU_old) ||
         !UT_LIST_GET_PREV(LRU, buf_pool->LRU_old)->old);
    ut_a(!UT_LIST_GET_NEXT(LRU, buf_pool->LRU_old) ||
         UT_LIST_GET_NEXT(LRU, buf_pool->LRU_old)->old);
#endif
    UT_LIST_INSERT_AFTER(buf_pool->LRU, buf_pool->LRU_old, bpage);
    buf_pool->LRU_old_len++;
  }

  ut_d(bpage->in_LRU_list = true);
  incr_LRU_size_in_bytes(bpage, buf_pool);

  if (UT_LIST_GET_LEN(buf_pool->LRU) > BUF_LRU_OLD_MIN_LEN) {
    ut_ad(buf_pool->LRU_old);
    buf_page_set_old(bpage, old);
    buf_LRU_old_adjust_len(buf_pool);
  } else if (UT_LIST_GET_LEN(buf_pool->LRU) == BUF_LRU_OLD_MIN_LEN) {
    buf_LRU_old_init(buf_pool);
  } else {
    buf_page_set_old(bpage, buf_pool->LRU_old != nullptr);
  }

  /* If this is a compressed page with decompressed frame,
  also put it on the unzip_LRU list */
  if (buf_page_belongs_to_unzip_LRU(bpage)) {
    buf_unzip_LRU_add_block((buf_block_t *)bpage, old);
  }
}

void buf_LRU_add_block(buf_page_t *bpage, bool old) {
  buf_LRU_add_block_low(bpage, old);
}
```

**Key points:**
- If `old=false`, the page goes to the **head** (young end) — used for pages that already proved useful
- If `old=true`, the page goes **after LRU_old** — used for freshly read pages
- Once the LRU reaches `BUF_LRU_OLD_MIN_LEN`, `buf_LRU_old_init()` sets up the LRU_old pointer
- After every addition, `buf_LRU_old_adjust_len()` recalibrates the old block boundary

### 8.3 Midpoint Adjustment: `buf_LRU_old_adjust_len()`

`buf0lru.cc:1449`:
```c
static inline void buf_LRU_old_adjust_len(buf_pool_t *buf_pool) {
  ulint old_len;
  ulint new_len;

  ut_a(buf_pool->LRU_old);
  ut_ad(mutex_own(&buf_pool->LRU_list_mutex));

  old_len = buf_pool->LRU_old_len;
  new_len = calculate_desired_LRU_old_size(buf_pool);

  for (;;) {
    buf_page_t *LRU_old = buf_pool->LRU_old;
    ut_a(LRU_old);
    ut_ad(LRU_old->in_LRU_list);

    if (old_len + BUF_LRU_OLD_TOLERANCE < new_len) {
      /* Need to move more pages into the old portion */
      buf_pool->LRU_old = LRU_old = UT_LIST_GET_PREV(LRU, LRU_old);
      old_len = ++buf_pool->LRU_old_len;
      buf_page_set_old(LRU_old, true);

    } else if (old_len > new_len + BUF_LRU_OLD_TOLERANCE) {
      /* Need to move pages out of the old portion */
      buf_pool->LRU_old = UT_LIST_GET_NEXT(LRU, LRU_old);
      old_len = --buf_pool->LRU_old_len;
      buf_page_set_old(LRU_old, false);
    } else {
      return;  // Within tolerance, done
    }
  }
}
```

This function incrementally adjusts the boundary between young and old blocks. The tolerance (`BUF_LRU_OLD_TOLERANCE`) prevents constant oscillation when the LRU length changes by a small amount.

### 8.4 Making Pages Young: `buf_LRU_make_block_young()`

When a page in the old portion is accessed and it was previously accessed too (i.e., it passed the **young-making access threshold**), it gets promoted to the head.

`buf0lru.cc:1736`:
```c
void buf_LRU_make_block_young(buf_page_t *bpage) {
  buf_pool_t *buf_pool = buf_pool_from_bpage(bpage);
  ut_ad(mutex_own(&buf_pool->LRU_list_mutex));

  if (bpage->old) {
    buf_pool->stat.n_pages_made_young++;
  }

  buf_LRU_remove_block(bpage);
  buf_LRU_add_block_low(bpage, false);  // Add to head (young)
}
```

### 8.5 Making Pages Old: `buf_LRU_make_block_old()`

`buf0lru.cc:1747`:
```c
void buf_LRU_make_block_old(buf_page_t *bpage) {
  ut_d(buf_pool_t *buf_pool =) buf_pool_from_bpage(bpage);
  ut_ad(mutex_own(&buf_pool->LRU_list_mutex));

  buf_LRU_remove_block(bpage);
  buf_LRU_add_block_low(bpage, true);  // Add to old portion
}
```

### 8.6 Freeing Pages: `buf_LRU_free_page()`

When the buffer pool needs space, it frees pages from the LRU tail.

`buf0lru.cc:1750`:
```c
bool buf_LRU_free_page(buf_page_t *bpage, bool zip) {
  auto buf_pool = buf_pool_from_bpage(bpage);
  auto block_mutex = buf_page_get_mutex(bpage);
  auto hash_lock = buf_page_hash_lock_get(buf_pool, bpage->id);

  ut_ad(bpage->in_LRU_list);
  ut_ad(mutex_own(&buf_pool->LRU_list_mutex));
  ut_ad(mutex_own(block_mutex));
  ut_ad(buf_page_in_file(bpage));

  if (!buf_page_can_relocate(bpage)) {
    /* Do not free buffer fixed and I/O-fixed blocks. */
    return (false);
  }

  buf_page_t *b{};
  auto is_dirty = bpage->is_dirty();

  if (zip || bpage->zip.data == nullptr) {
    /* This would completely free the block. Do not free dirty blocks. */
    if (is_dirty) {
      return (false);
    }
  } else if (is_dirty && buf_page_get_state(bpage) != BUF_BLOCK_FILE_PAGE) {
    ut_ad(buf_page_get_state(bpage) == BUF_BLOCK_ZIP_DIRTY);
    return (false);
  } else if (buf_page_get_state(bpage) == BUF_BLOCK_FILE_PAGE) {
    /* Compressed page with uncompressed frame: only free the frame */
    b = buf_page_alloc_descriptor();
    ut_a(b);
  }

  // ... double-check with hash_lock held X-mode

  if (!buf_LRU_block_remove_hashed(bpage, zip, false)) {
    mutex_exit(&buf_pool->LRU_list_mutex);
    if (b != nullptr) buf_page_free_descriptor(b);
    return true;
  }

  // If we kept the compressed page descriptor (b != nullptr),
  // reinsert it as a ZIP_PAGE or ZIP_DIRTY
  if (b != nullptr) {
    // ... reinsert into LRU and page_hash as compressed page
  }

  // ... update statistics
  return true;
}
```

**Critical behavior:**
- **Dirty pages** are never freed — they must be flushed first
- For compressed pages with decompressed frames (`b != nullptr`), only the **uncompressed frame** is freed, keeping the compressed descriptor
- The function acquires the X hash lock to ensure exclusive access during removal
- `buf_LRU_block_remove_hashed()` handles the actual removal from LRU list and page hash

### 8.7 LRU Scan for Free Blocks: `buf_LRU_free_from_common_LRU_list()`

`buf0lru.cc:1094`:
```c
static bool buf_LRU_free_from_common_LRU_list(buf_pool_t *buf_pool,
                                              bool scan_all) {
  ut_ad(mutex_own(&buf_pool->LRU_list_mutex));

  bool freed{};
  ulint scanned{};

  for (buf_page_t *bpage = buf_pool->lru_scan_itr.start();
       bpage != nullptr && !freed &&
       (scan_all || scanned < BUF_LRU_SEARCH_SCAN_THRESHOLD);
       ++scanned, bpage = buf_pool->lru_scan_itr.get()) {
    ut_ad(mutex_own(&buf_pool->LRU_list_mutex));
    auto prev = UT_LIST_GET_PREV(LRU, bpage);
    auto block_mutex = buf_page_get_mutex(bpage);

    buf_pool->lru_scan_itr.set(prev);

    ut_ad(bpage->in_LRU_list);
    ut_ad(buf_page_in_file(bpage));

    const auto accessed = buf_page_is_accessed(bpage);

    if (bpage->was_stale()) {
      freed = buf_page_free_stale(buf_pool, bpage);
    } else {
      mutex_enter(block_mutex);

      if (buf_flush_ready_for_replace(bpage)) {
        freed = buf_LRU_free_page(bpage, true);
      }

      if (!freed) {
        mutex_exit(block_mutex);
      }
    }

    if (freed && accessed == std::chrono::steady_clock::time_point{}) {
      ++buf_pool->stat.n_ra_pages_evicted;
    }

    if (freed) break;
  }
  return (freed);
}
```

The scan uses `lru_scan_itr` — a hazard pointer that walks the LRU list from the tail. It checks `buf_flush_ready_for_replace()` which verifies the page is clean and not buffer-fixed or I/O-fixed.

### 8.8 Unzip LRU: `buf_LRU_free_from_unzip_LRU_list()`

Compressed pages can have decompressed frames that we can free before the compressed descriptor itself. The unzip LRU list tracks these.

`buf0lru.cc:1046`:
```c
static bool buf_LRU_free_from_unzip_LRU_list(buf_pool_t *buf_pool,
                                             bool scan_all) {
  ut_ad(mutex_own(&buf_pool->LRU_list_mutex));

  if (!buf_LRU_evict_from_unzip_LRU(buf_pool)) {
    return (false);
  }

  ulint scanned = 0;
  bool freed = false;

  for (buf_block_t *block = UT_LIST_GET_LAST(buf_pool->unzip_LRU);
       block != nullptr && !freed &&
       (scan_all || scanned < srv_LRU_scan_depth);
       ++scanned) {
    buf_block_t *prev_block = UT_LIST_GET_PREV(unzip_LRU, block);

    mutex_enter(&block->mutex);
    ut_ad(buf_block_get_state(block) == BUF_BLOCK_FILE_PAGE);
    ut_ad(block->in_unzip_LRU_list);
    ut_ad(block->page.in_LRU_list);

    freed = buf_LRU_free_page(&block->page, false);
    if (!freed) mutex_exit(&block->mutex);

    block = prev_block;
  }
  return (freed);
}
```

### 8.9 Getting a Free Block: `buf_LRU_get_free_block()`

This is the **last resort** — called when a user thread needs a buffer slot and the free list is empty.

`buf0lru.cc:1311`:
```c
buf_block_t *buf_LRU_get_free_block(buf_pool_t *buf_pool) {
  buf_block_t *block = nullptr;
  bool freed = false;
  ulint n_iterations = 0;
  ulint flush_failures = 0;
  bool started_monitor = false;

  ut_ad(!mutex_own(&buf_pool->LRU_list_mutex));
  MONITOR_INC(MONITOR_LRU_GET_FREE_SEARCH);

loop:
  buf_LRU_check_size_of_non_data_objects(buf_pool);

  /* If there is a block in the free list, take it */
  block = buf_LRU_get_free_only(buf_pool);

  if (block != nullptr) {
    // ... reset and return
    return block;
  }

  // Wake up simulated AIO threads to avoid deadlock
  os_aio_simulated_wake_handler_threads();

  freed = false;
  os_rmb;
  if (buf_pool->try_LRU_scan || n_iterations > 0) {
    freed = buf_LRU_scan_and_free_block(buf_pool, n_iterations > 0);
    if (!freed && n_iterations == 0) {
      buf_pool->try_LRU_scan = false;  // Don't scan again until flush
      os_wmb;
    }
  }

  if (freed) goto loop;

  // ... if stuck for >20 iterations, print warning

  if (!srv_read_only_mode) {
    os_event_set(buf_flush_event);  // Wake page cleaner
  }

  if (n_iterations > 1) {
    MONITOR_INC(MONITOR_LRU_GET_FREE_WAITS);
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }

  // Try flushing a single page from LRU
  if (!buf_flush_single_page_from_LRU(buf_pool)) {
    MONITOR_INC(MONITOR_LRU_SINGLE_FLUSH_FAILURE_COUNT);
    ++flush_failures;
  }

  // ... increment counters and retry
  n_iterations++;
  goto loop;
}
```

This function is the **bottleneck detector** for buffer pool pressure. If it loops 20+ times without finding a free block, InnoDB issues a warning suggesting to increase `innodb_buffer_pool_size`.

---

## 9. Flush List Management

Dirty pages are tracked in the **flush list**, which is ordered by `oldest_modification` LSN (ascending). This ensures pages are written to disk in LSN order, maintaining crash recovery consistency.

### 9.1 Adding a Dirty Page: `buf_flush_insert_into_flush_list()`

`buf0flu.cc:395`:
```c
/** Inserts a modified block into the flush list. */
void buf_flush_insert_into_flush_list(
    buf_pool_t *buf_pool,  /*!< buffer pool instance */
    buf_block_t *block,    /*!< in/out: block which is modified */
    lsn_t lsn)             /*!< in: oldest modification */
{
  ut_ad(mutex_own(buf_page_get_mutex(&block->page)));
  ut_ad(log_sys != nullptr);

  buf_flush_list_mutex_enter(buf_pool);

  ut_ad(buf_block_get_state(block) == BUF_BLOCK_FILE_PAGE);
  ut_ad(!block->page.in_flush_list);
  ut_d(block->page.in_flush_list = true);

  if (lsn == 0) {
    /* This is no-redo dirtied page. Borrow the lsn. */
    lsn = buf_flush_borrow_lsn(buf_pool);
    ut_ad(log_is_data_lsn(lsn));
    // ... safeguard for no-redo pages
    block->page.set_newest_lsn(
        std::max(lsn, log_sys->flushed_to_disk_lsn.load()));
  }

  ut_ad(log_is_data_lsn(lsn));
  ut_ad(!block->page.is_dirty());
  ut_ad(block->page.get_newest_lsn() >= lsn);

  block->page.set_oldest_lsn(lsn);

  UT_LIST_ADD_FIRST(buf_pool->flush_list, &block->page);

  incr_flush_list_size_in_bytes(block, buf_pool);

  buf_flush_list_mutex_exit(buf_pool);
}
```

The flush list is ordered by `oldest_modification` — smallest LSN first (at the tail). New modifications with larger LSNs are inserted at the **head** (`ADD_FIRST`). Wait... this is `ADD_FIRST`, not `ADD_LAST`. Let me check the traversal direction.

Looking at the page cleaner code, it traverses from the tail (oldest LSN) to head, which makes `ADD_FIRST` correct: new pages with higher LSN go at the head, and the tail has the oldest.

### 9.2 The Write Path: `buf_flush_write_block_low()`

`buf0flu.cc:924`:
```c
static void buf_flush_write_block_low(buf_page_t *bpage, buf_flush_t flush_type,
                                      bool sync) {
  page_t *frame = nullptr;

  DBUG_PRINT("ib_buf", ("flush %s %u page " UINT32PF ":" UINT32PF,
                        sync ? "sync" : "async", (unsigned)flush_type,
                        bpage->id.space(), bpage->id.page_no()));

  ut_ad(buf_page_in_file(bpage));
  ut_ad(!buf_flush_list_mutex_own(buf_pool));
  ut_ad(!buf_page_get_mutex(bpage)->is_owned());
  ut_ad(bpage->is_io_fix_write());
  ut_ad(bpage->is_dirty());

  /* Force the log to the disk before writing the modified block */
  if (!srv_read_only_mode) {
    const lsn_t flush_to_lsn = bpage->get_newest_lsn();

    if (log_sys->flushed_to_disk_lsn.load() < flush_to_lsn) {
      Wait_stats wait_stats;
      wait_stats = log_write_up_to(*log_sys, flush_to_lsn, true);
      MONITOR_INC_WAIT_STATS_EX(MONITOR_ON_LOG_, _PAGE_WRITTEN, wait_stats);
    }
  }

  switch (buf_page_get_state(bpage)) {
    case BUF_BLOCK_POOL_WATCH:
    case BUF_BLOCK_ZIP_PAGE:
    case BUF_BLOCK_NOT_USED:
    case BUF_BLOCK_READY_FOR_USE:
    case BUF_BLOCK_MEMORY:
    case BUF_BLOCK_REMOVE_HASH:
      ut_error;  // These states shouldn't be dirty
      break;
    case BUF_BLOCK_ZIP_DIRTY: {
      frame = bpage->zip.data;
      // Write LSN to page header
      mach_write_to_8(frame + FIL_PAGE_LSN, bpage->get_newest_lsn());
      break;
    }
    case BUF_BLOCK_FILE_PAGE:
      frame = bpage->zip.data;
      if (!frame) {
        frame = ((buf_block_t *)bpage)->frame;
      }
      buf_flush_init_for_writing(
          reinterpret_cast<const buf_block_t *>(bpage),
          reinterpret_cast<const buf_block_t *>(bpage)->frame,
          bpage->zip.data ? &bpage->zip : nullptr,
          bpage->get_newest_lsn(),
          fsp_is_checksum_disabled(bpage->id.space()),
          false /* do not skip lsn check */);
      break;
  }

  dberr_t err = dblwr::write(flush_type, bpage, sync);
  ut_a(err == DB_SUCCESS || err == DB_TABLESPACE_DELETED);

  /* Increment the counter of I/O operations used for selecting LRU policy. */
  buf_LRU_stat_inc_io();
}
```

**Critical steps before writing:**
1. `log_write_up_to()` — ensures the redo log is flushed to at least the page's `newest_modification`. This is the **Write-Ahead Logging (WAL)** guarantee
2. `buf_flush_init_for_writing()` — calculates and writes the page checksum and LSN into the page header
3. `dblwr::write()` — writes through the **doublewrite buffer** (see next section)

### 9.3 Page Cleaner Coordinator Thread

The page cleaner runs as a dedicated background thread that coordinates flushing across all buffer pool instances.

`buf0flu.cc:2875`:
```c
static void buf_flush_page_coordinator_thread() {
  auto loop_start_time = std::chrono::steady_clock::now();
  ulint n_flushed = 0;
  ulint last_activity = srv_get_activity_count();
  ulint last_pages = 0;

  THD *thd = create_internal_thd();

  // Set high priority if possible
#ifdef UNIV_LINUX
  if (buf_flush_page_cleaner_set_priority(buf_flush_page_cleaner_priority)) {
    ib::info(ER_IB_MSG_126) << "page_cleaner coordinator priority: "
                            << buf_flush_page_cleaner_priority;
  }
#endif

  // Start worker threads
  for (size_t i = 1; i < srv_threads.m_page_cleaner_workers_n; ++i) {
    srv_threads.m_page_cleaner_workers[i] = os_thread_create(
        page_flush_thread_key, i, buf_flush_page_cleaner_thread);
    srv_threads.m_page_cleaner_workers[i].start();
  }

  // ... recovery portion (flushing during recovery)

  os_event_wait(buf_flush_event);

  // Main loop
  while (srv_shutdown_state.load() < SRV_SHUTDOWN_CLEANUP) {
    // ... determine if server is active
    // ... sleep decision based on server activity
    // ... pc_sleep_if_needed() for rate limiting

    // Calculate how much to flush
    // ... pc_request() sets up flush targets per instance
    // ... pc_flush_slot() processes each slot
    // ... pc_wait_finished() waits for workers

    // ... statistics gathering
  }
}
```

The coordinator sleeps for **1 second** between iterations (controlled by `innodb_io_capacity` and server activity). During idle periods, it may skip sleeping if work is pending.

### 9.4 Neighbor Flushing: `buf_flush_try_neighbors()`

`buf0flu.cc:1217`:
```c
static ulint buf_flush_try_neighbors(const page_id_t &page_id,
                                     buf_flush_t flush_type, ulint n_flushed,
                                     ulint n_to_flush) {
  page_no_t i;
  page_no_t low;
  page_no_t high;
  ulint count = 0;
  buf_pool_t *buf_pool = buf_pool_get(page_id);

  if (UT_LIST_GET_LEN(buf_pool->LRU) < BUF_LRU_OLD_MIN_LEN ||
      srv_flush_neighbors == 0) {
    low = page_id.page_no();
    high = page_id.page_no() + 1;
  } else {
    // Search in neighborhoods, configurable by innodb_flush_neighbors
    low = page_id.page_no() - (page_id.page_no() % srv_flush_neighbors);
    high = low + srv_flush_neighbors;
  }

  for (i = low; i < high; i++) {
    if (buf_flush_check_neighbor(page_id, flush_type)) {
      // ... flush the neighbor
    }
  }
  return count;
}
```

Neighbor flushing is controlled by `innodb_flush_neighbors` (default 0 in MySQL 8.0+ — disabled for SSDs).

---

## 10. Doublewrite Buffer

The doublewrite buffer protects against **partial page writes** (torn writes). Before writing a page to its final location, InnoDB writes it to the doublewrite buffer first. If the server crashes during a write, InnoDB can recover the page from the doublewrite buffer during recovery.

### 10.1 The Write Entry Point

`buf0dblwr.cc:2481`:
```c
dberr_t dblwr::write(buf_flush_t flush_type, buf_page_t *bpage,
                     bool sync) noexcept {
  dberr_t err;
  const space_id_t space_id = bpage->id.space();

  ut_ad(bpage->current_thread_has_io_responsibility());

  if (bpage->was_stale()) {
    bpage->set_dblwr_batch_id(std::numeric_limits<uint16_t>::max());
    buf_page_free_stale_during_write(bpage, ...);
    return DB_SUCCESS;
  }

  if (srv_read_only_mode || fsp_is_system_temporary(space_id) ||
      !dblwr::is_enabled() || Double_write::s_instances == nullptr ||
      mtr_t::s_logging.dblwr_disabled()) {
    /* Skip the double-write buffer for temporary tablespaces
    (never recovered) */
    bpage->set_dblwr_batch_id(std::numeric_limits<uint16_t>::max());
    err = Double_write::write_to_datafile(bpage, sync, nullptr);
    // ... handle errors
  } else {
    IORequest type(IORequest::WRITE);
    file::Block *e_block = dblwr::get_encrypted_frame(bpage, type);

    if (!sync && flush_type != BUF_FLUSH_SINGLE_PAGE) {
      MONITOR_INC(MONITOR_DBLWR_ASYNC_REQUESTS);
      ut_d(bpage->release_io_responsibility());
      Double_write::submit(flush_type, bpage, e_block);
      err = DB_SUCCESS;
    } else {
      MONITOR_INC(MONITOR_DBLWR_SYNC_REQUESTS);
      bpage->set_dblwr_batch_id(std::numeric_limits<uint16_t>::max());
      err = Double_write::sync_page_flush(bpage, e_block);
    }
  }
  return err;
}
```

**Key decisions:**
- **Temporary tablespaces** skip the doublewrite buffer — they're never recovered
- **Async writes** (`!sync && flush_type != BUF_FLUSH_SINGLE_PAGE`) are batched via `Double_write::submit()`
- **Sync writes** (single page flush or explicit sync) go directly through `Double_write::sync_page_flush()`

### 10.2 Write Completion

`buf0dblwr.cc:2614`:
```c
void Double_write::write_complete(buf_page_t *bpage,
                                  buf_flush_t flush_type) noexcept {
  const auto batch_id = bpage->get_dblwr_batch_id();

  switch (flush_type) {
    case BUF_FLUSH_LRU:
    case BUF_FLUSH_LIST:
    case BUF_FLUSH_SINGLE_PAGE:
      if (batch_id != std::numeric_limits<uint16_t>::max()) {
        ut_ad(batch_id < s_segments.size());
        auto batch_segment = s_segments[batch_id];

        if (batch_segment->write_complete()) {
          // All pages in the batch have been written
          batch_segment->completed();
          srv_stats.dblwr_pages_written.add(batch_segment->batch_size());
          batch_segment->reset();

          // Flush data files and recycle batch segment
          fil_flush_file_spaces();

          while (!segments->enqueue(batch_segment)) {
            std::this_thread::yield();
          }
        }
      }
      bpage->set_dblwr_batch_id(std::numeric_limits<uint16_t>::max());
      break;

    case BUF_FLUSH_N_TYPES:
      ut_error;
  }
}
```

### 10.3 Recovery

During crash recovery, InnoDB reads the doublewrite buffer pages and compares them with the actual data files. If a page in the data file has a valid LSN that matches the redo log, it's skipped. Otherwise, the doublewrite copy is used to fix the torn page.

The recovery path uses `dblwr::recv::recover()`:
```c
void dblwr::recv::recover(recv::Pages *pages, fil_space_t *space) noexcept {
#ifndef UNIV_HOTBACKUP
  pages->recover(space);
#endif
}
```

---

## 11. The Compressed Page Path: `buf_relocate`

When using compressed tables (`ROW_FORMAT=COMPRESSED`), InnoDB may keep only the compressed page in memory. When a user needs to access the data, the page is decompressed into a `buf_block_t`. The `zip_page_handler()` in Buf_fetch handles this:

`buf0buf.cc:3944` (key excerpt from `Buf_fetch::zip_page_handler`):
```c
  // Allocate a free block for the decompressed frame
  auto block = buf_LRU_get_free_block(m_buf_pool);

  mutex_enter(&m_buf_pool->LRU_list_mutex);
  m_hash_lock = buf_page_hash_lock_get(m_buf_pool, m_page_id);
  rw_lock_x_lock(m_hash_lock, UT_LOCATION_HERE);

  // Double-check nothing changed
  ut_ad(bpage == buf_page_hash_get_low(m_buf_pool, m_page_id));

  buf_block_unfix(fix_block);
  // ... acquire mutexes

  // Move the compressed page from bpage to block, and uncompress it
  buf_relocate(bpage, &block->page);
  buf_block_init_low(block);

  // ... update list pointers, flush list references
  block->page.state = BUF_BLOCK_FILE_PAGE;

  // Insert at the front of unzip_LRU list
  buf_unzip_LRU_add_block(block, false);
```

The `buf_relocate()` function moves the compressed page descriptor and frame into the new `buf_block_t`, essentially upgrading a `BUF_BLOCK_ZIP_PAGE` to a `BUF_BLOCK_FILE_PAGE`. The old compressed-only descriptor is freed, and the new full block is available for concurrent access.

---

## 12. Buffer Pool Resize

Buffer pool resizing (via `SET GLOBAL innodb_buffer_pool_size`) is done online. The `buf_pool_resize()` function:

1. Decides which instances to shrink or grow
2. Withdraws chunks from shrinking instances (`buf_pool_withdraw_blocks()`)
3. Allocates new chunks for growing instances
4. Rebalances the workload

**Withdraw field in buf_pool_t:**
```c
  /** base node of the withdraw block list. It is only used during shrinking
  buffer pool size, not to reuse the blocks will be removed.  Protected by
  free_list_mutex */
  UT_LIST_BASE_NODE_T(buf_page_t, list) withdraw;
  /** Target length of withdraw block list, when withdrawing */
  ulint withdraw_target;
```

During withdrawal, blocks are moved to the `withdraw` list and checked for relocation. The `buf_page_realloc()` function handles moving control blocks between chunks during resizing.

---

## 13. Putting It All Together: A Complete Page Access

Here's the full trace of what happens when a user thread reads page `(space=5, page_no=42)`:

```
1. buf_page_get_gen(5, 42, RW_S_LATCH, ...)
   ↓
2. Buf_fetch_normal::get()
   │  for (;;) {
   ↓
3. Buf_fetch::lookup()
   ├─ Acquire page_hash S-lock (fine-grained bucket lock)
   ├─ Check m_guess (optimization for repeated accesses)
   ├─ buf_page_hash_get_low() → hash_table lookup
   │  └─ HASH_SEARCH on page_hash[hash(5,42)]
   ├─ Miss → release S-lock, return NULL
   ↓
4. Buf_fetch::read_page()
   └─ buf_read_page(5, 42)
      └─ buf_read_page_low()
         ├─ buf_page_init_for_read()
         │  ├─ Check tablespace exists and not being dropped
         │  ├─ buf_LRU_get_free_block() ← may evict!
         │  ├─ buf_page_init() → set state, page_hash insert
         │  ├─ buf_LRU_add_block(bpage, true) → midpoint insertion
         │  └─ Set BUF_IO_READ, return descriptor
         └─ fil_io(READ, ..., dst, bpage)
            └─ AIO: os_aio_func() → port submission
   
   [I/O completion thread fires]
   ↓
5. buf_page_io_complete(bpage)
   ├─ Verify checksum (BlockReporter)
   ├─ Update page state → BUF_BLOCK_FILE_PAGE
   ├─ Decompress if compressed
   ├─ Release I/O fix (BUF_IO_NONE)
   └─ Wake any waiters

   [Back in Buf_fetch::read_page()]
   ↓
6. read_page() returns → read_ahead_random() triggered
   ↓
7. Buf_fetch_normal::get() loops back → lookup() succeeds
   ├─ Check was_stale()
   ├─ buf_block_fix() → increment fix count
   └─ Release hash_lock
   ↓
8. Buf_fetch::single_page() continues
   ├─ Check IO state (BUF_IO_NONE, proceed)
   ├─ zip_page_handler if compressed
   ├─ buf_page_make_young_if_needed()
   │   └─ buf_LRU_make_block_young() if access time threshold met
   └─ mtr_add_page() → register in mini-transaction
   ↓
9. Return buf_block_t * to caller
```

---

## Summary Table

| Component | File | Key Function | Purpose |
|---|---|---|---|
| Main struct | `buf0buf.h:2293` | `buf_pool_t` | Per-instance buffer pool state |
| Page descriptor | `buf0buf.h:1164` | `buf_page_t` | Metadata for one cached page |
| Public entry | `buf0buf.cc:4439` | `buf_page_get_gen()` | Main fetch API |
| Hash lookup | `buf0buf.cc:3804` | `Buf_fetch::lookup()` | Page hash search with guess |
| Main fetch loop | `buf0buf.cc:3703` | `Buf_fetch_normal::get()` | Find-or-read loop |
| Read trigger | `buf0buf.cc:4107` | `Buf_fetch::read_page()` | Initiate disk read |
| Disk read | `buf0rea.cc:66` | `buf_read_page_low()` | AIO setup via fil_io |
| Init for read | `buf0rea.cc:-` | `buf_page_init_for_read()` | Allocate slot, set hash/LRU |
| Add to LRU | `buf0lru.cc:1656` | `buf_LRU_add_block_low()` | Midpoint insertion |
| Free page | `buf0lru.cc:1750` | `buf_LRU_free_page()` | Evict from buffer pool |
| Get free block | `buf0lru.cc:1311` | `buf_LRU_get_free_block()` | Free list → LRU scan → flush |
| Old adjust | `buf0lru.cc:1449` | `buf_LRU_old_adjust_len()` | Midpoint boundary maintenance |
| Make young | `buf0lru.cc:1736` | `buf_LRU_make_block_young()` | Promote to head of LRU |
| Add to flush | `buf0flu.cc:395` | `buf_flush_insert_into_flush_list()` | Register dirty page |
| Write page | `buf0flu.cc:924` | `buf_flush_write_block_low()` | Log flush + prepare + dblwr |
| Coordinator | `buf0flu.cc:2875` | `buf_flush_page_coordinator_thread()` | Page cleaner main loop |
| Dblwr write | `buf0dblwr.cc:2481` | `dblwr::write()` | Doublewrite buffer entry |
| Init | `buf0buf.cc:1506` | `buf_pool_init()` | Multi-instance parallel init |
| Hash get low | `buf0buf.ic:849` | `buf_page_hash_get_low()` | Raw page hash search |
| Hash get locked | `buf0buf.ic:929` | `buf_page_hash_get_locked()` | Hash search with lock acquire |

## Further Reading

- InnoDB source: `<mysql>/storage/innobase/buf/` — all 14 buffer pool source files
- `buf0lru.h` — LRU list constants and structures
- `buf0flu.h` — Flush list and cleaner API
- `buf0dblwr.cc` — Doublewrite buffer full implementation
- `srv0srv.cc` — Server activity detection for the page cleaner
