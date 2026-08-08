# 105-atomic-refcount-hazard — OceanBase 原子变量应用 (3/4): Refcount / Hazard Pointer 模式

> 基于 OceanBase 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")
> 源码锚点:`deps/oblib/src/lib/atomic/ob_atomic.h` + `deps/oblib/src/lib/hash/ob_link_hashmap.{h}` + `deps/oblib/src/lib/hash/ob_multi_mod_ref_mgr.h` + `deps/oblib/src/lib/tc/deps/drwlock.h` + `deps/oblib/src/lib/hash/ob_hazard_pointer.h` + `src/share/cache/ob_kvcache_hazard_pointer.{h,cpp}` + `src/share/cache/ob_kvcache_hazard_domain.{h,cpp}` + `deps/oblib/src/lib/allocator/ob_hazard_ref.{h,cpp}`
> 使用 doom-lsp (clangd LSP) 做符号解析与数据流追踪
> 接续 #103 Counter / #104 Flag — 本系列 4 篇拆 OB 所有原子变量应用

---

## 0. 全文导读

OB 1024 个 atomic 文件中, **Refcount / Hazard Pointer 模式** 是第三大类。语义是 "对象生命周期管理", 与 Counter / Flag 的关键区别是 **ABA 问题** — refcount 从 1 减到 0 再加回 1, 看上去没变, 但中间对象已被销毁 / 重建。

| 模式 | 本系列 | 状态 |
|------|--------|------|
| Counter / Metric | #103 | ✅ 已发布 |
| Flag / State Machine | #104 | ✅ 已发布 |
| **Refcount / Hazard Pointer** | **#105 (本篇)** | 📝 |
| Lock-free Data Structure | #106 | 待 |

### Refcount 在 OB 中的分布

| 子模块 | 代表 | ABA 风险 |
|--------|------|---------|
| 简单对象引用 | `ObTenantCtxAllocator::ref_cnt_` | 低 (长生命周期) |
| 简单对象引用 | `ObIODevice::ref_cnt_` | 低 |
| Hash node 生命周期 | `ob_link_hashmap uref_/href_` | 高 (用 BORN_REF 解决) |
| 跨模块共享引用 | `ob_multi_mod_ref_mgr` | 中 (带 BCAS spinlock) |
| RWLock reader 计数 | `drwlock::ref` | 低 (单调递增区间) |
| KV cache lock-free 指针 | `HazardPointer + SharedHazptr` | 高 (完整 hazard pointer 域) |
| Hazard Pointer Map | `ob_concurrent_hash_map_with_hazard_value` | 高 |
| Hash node ref count | `ObStockCtrl` (slice_alloc) | 中 (用 BORN_REF) |

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| #51 Block Cache | KV cache 用 HazardPointer 管理 block handle 生命周期 |
| #74 Thread Model | drwlock 是多线程读少写的简化 RWLock |
| #15 ObKeyBTree | `ob_link_hashmap` 是 memtable 索引的核心 |
| #25 Memory Management | `ObTenantCtxAllocator::ref_cnt_` 是 allocator 生命周期管理 |

---

## 1. 背景 / 概念

### 1.1 ABA 问题

```
时刻 t0:  ref = 1,  obj@0x1000
时刻 t1:  thread A 读 ref = 1, 准备 dec
时刻 t2:  thread A 被抢占
时刻 t3:  thread B dec ref = 0, 销毁 obj@0x1000, 释放内存
时刻 t4:  thread C alloc 新对象 obj@0x2000 (内核复用 0x1000 地址)
时刻 t5:  thread C inc ref = 1 (新对象的 ref)
时刻 t6:  thread A 恢复, 看到 ref = 1, 以为 obj@0x1000 还活着, 但其实是 obj@0x2000
```

**后果**: thread A 拿到的是新对象的引用, 但**以为是旧对象** — 可能类型错误、逻辑错误。

### 1.2 Refcount vs Flag

| 维度 | Refcount | Flag |
|------|---------|------|
| 业务 | 对象生命周期 | 状态机 |
| ABA 风险 | **高** | 低 |
| 性能 | FAA 累加 ~30 cycles | BCAS 自旋 |
| 同步 | 多线程并发 inc/dec | 单写多读 |

### 1.3 OB 解决 ABA 的两种思路

| 思路 | 实现 | 适用 |
|------|------|------|
| **BORN_REF 魔法值** | 把"出生"和"使用"分开, 让 ref 用 magic value | 短生命周期 (memtable hash node) |
| **Hazard Pointer 域** | 全局 HP 数组 + retire list | 中等生命周期 (KV cache block) |
| **epoch-based reclamation** | 全局 epoch counter, 读路径声明 epoch | 长生命周期 |
| **RCU** | 读路径无开销, 写路径等 grace period | Linux kernel 风格 |

OB 主要用 **BORN_REF** (简单) 和 **Hazard Pointer** (完整)。

---

## 2. 实现细节

### 2.1 简单 refcount — ObTenantCtxAllocator

[`deps/oblib/src/lib/alloc/ob_tenant_ctx_allocator.h:165-180`](deps/oblib/src/lib/alloc/ob_tenant_ctx_allocator.h):

```cpp
class ObTenantCtxAllocator {
public:
  ...
  int64_t inc_ref_cnt(int64_t cnt) {
    return ATOMIC_FAA(&ref_cnt_, cnt);   // ★ FAA 累加, 返回旧值
  }
  int64_t dec_ref_cnt(int64_t cnt) {
    return ATOMIC_FAA(&ref_cnt_, -cnt);   // ★ FAA 减
  }
  int64_t get_ref_cnt() const {
    return ATOMIC_LOAD(&ref_cnt_);
  }
private:
  int64_t ref_cnt_;   // 引用计数
};
```

**特点**:
- 单调累加, 不防 ABA (因为对象是长生命周期, 不会短时间被销毁重建)
- FAA 返回旧值, 用于"取增量前的 snapshot"

### 2.2 简单 refcount — ObIODevice

[`deps/oblib/src/common/storage/ob_io_device.cpp:170-180`](deps/oblib/src/common/storage/ob_io_device.cpp):

```cpp
int ObIODevice::inc_ref() {
  IGNORE_RETURN ATOMIC_FAA(&ref_cnt_, 1);
  return OB_SUCCESS;
}
int ObIODevice::dec_ref() {
  int ret = OB_SUCCESS;
  int64_t ref_cnt = ATOMIC_FAA(&ref_cnt_, -1);
  if (0 == ref_cnt) {
    // 最后一个引用, 销毁
    delete this;
  }
  return ret;
}
```

**特点**:
- FAA + 0 检查 — 单调 dec, 不防 ABA
- IO 设备生命周期长, 不需要防 ABA

### 2.3 BORN_REF 魔法值 — ob_link_hashmap

[`deps/oblib/src/lib/hash/ob_link_hashmap.h:60-85`](deps/oblib/src/lib/hash/ob_link_hashmap.h):

```cpp
class DefaultUrefDecFunc {
public:
  // ★ 关键常量: "出生"占 N 个 ref, 表示"对象还活着但尚未发布"
  static const int32_t BORN_REF = 1024;   // 2^10, 远大于最大并发用户数

  // 把 ref 从 BORN_REF 减到 0 — 表示销毁
  void born(Node* node) {
    (void)ATOMIC_AAF(&node->uref_, BORN_REF);     // ★ 初始 ref = BORN_REF
  }
  int32_t end(Node* node) {
    return ATOMIC_AAF(&node->uref_, -BORN_REF);   // ★ ref -= BORN_REF, 表示"不再使用"
  }
  // 每次使用 +1, 释放 -1
  int32_t inc(Node* node) {
    return ATOMIC_AAF(&node->uref_, 1);
  }
  int32_t dec(Node* node) {
    return ATOMIC_AAF(&node->uref_, -1);
  }
private:
  int32_t uref_;   // use ref
};
```

**BORN_REF 工作原理**:

```
初始:  ref = BORN_REF (1024)      ← born()
inc:   ref += 1                   ← 每次使用
dec:   ref -= 1                   ← 每次释放
end:   ref -= BORN_REF            ← 标记销毁

等待销毁条件: ref == 0  (说明所有使用都释放了)
```

**为什么这样能防 ABA**:
- 假设 BORN_REF = 1024, 最大并发用户数 1000
- 一个用户 inc 后 ref = 1025, 然后释放 dec → ref = 1024
- 然后对象"销毁" end → ref = 0
- 如果另一个新对象**复用 uref_ 字段**, 它从 born() 开始 ref = BORN_REF = 1024
- **关键**: 即使并发线程读到旧 ref (1024), 它也知道"这不是合法的 in-use ref, 是 end 后的 0 + BORN_REF, 或新对象的 0 + BORN_REF"
- 实际上, OB 在用户 inc 时检查 `ref >= BORN_REF` 才允许使用, 否则说明对象已销毁

[`ob_link_hashmap.h:80-90`](deps/oblib/src/lib/hash/ob_link_hashmap.h) 的 `href_` (hash ref) 类似, 用于跨模块共享 ref。

### 2.4 drwlock reader 计数 — 简化 RWLock

[`deps/oblib/src/lib/tc/deps/drwlock.h:75-100`](deps/oblib/src/lib/tc/deps/drwlock.h):

```cpp
// rdlock / rdunlock
bool try_rdlock() {
  bool lock_succ = false;
  int64_t *ref = &get_read_ref().value_;
  if (0 == ATOMIC_LOAD(&write_uid_)) {       // 先看 write_uid_ 是否 0
    ATOMIC_FAA(ref, 1);                       // ref += 1 (reader +1)
    if (0 == ATOMIC_LOAD(&write_uid_)) {      // double-check: 没有 wrlock 抢进
      lock_succ = true;
    } else {
      ATOMIC_FAA(ref, -1);                    // 回滚
    }
  }
  return lock_succ;
}

void rdlock() {
  while (!try_rdlock()) {
    PAUSE();
  }
}

void rdunlock() {
  int64_t *ref = &get_read_ref().value_;
  ATOMIC_FAA(ref, -1);
}

// wrlock
void wrlock() {
  while (!ATOMIC_BCAS(&write_uid_, 0, 1))     // ★ BCAS 抢 write_uid_
    ;
  // 等待所有 reader 退出
  for (int64_t i = 0; i < (int64_t)arrlen(read_ref_); i++) {
    while (ATOMIC_LOAD(&read_ref_[i].value_) > 0) {
      PAUSE();
    }
  }
}
```

**特点**:
- `write_uid_` 是 BCAS spinlock (0 / 1)
- `ref` 是 FAA 累加 reader 计数
- `wrlock` 先抢 `write_uid_`, 再等所有 reader 退出

**ABA 风险**: 低 — reader 计数单调递增 (只在同一 wrlock 周期内), wrlock 周期间隔足够长。

### 2.5 ob_multi_mod_ref_mgr — 跨模块共享

[`deps/oblib/src/lib/hash/ob_multi_mod_ref_mgr.h:20-50`](deps/oblib/src/lib/hash/ob_multi_mod_ref_mgr.h):

```cpp
class ObMultiModRefMgr {
public:
  int inc_ref() {
    ObDisableDiagnoseGuard guard;
    // ★ 先取 spinlock 防止 ABA: 多模块并发 inc/dec
    while (!ATOMIC_BCAS(&lock_, 0, 1)) { PAUSE(); }
    ATOMIC_INC(&ref_);   // ref_ 累加
    ATOMIC_STORE(&lock_, 0);   // 释放 spinlock
    return OB_SUCCESS;
  }
  int dec_ref() {
    ObDisableDiagnoseGuard guard;
    while (!ATOMIC_BCAS(&lock_, 0, 1)) { PAUSE(); }
    ATOMIC_DEC(&ref_);
    int64_t ref = ATOMIC_LOAD(&ref_);
    ATOMIC_STORE(&lock_, 0);
    if (0 == ref) {
      // 销毁对象
      ...
    }
    return OB_SUCCESS;
  }
private:
  int64_t ref_;     // 引用计数
  int64_t lock_;    // ★ spinlock 防 ABA
};
```

**特点**:
- `lock_` BCAS spinlock 防止 dec-then-inc 之间的 ABA
- 不像 BORN_REF 用魔法值, 这里直接 spinlock
- 适用于: 跨模块共享对象, 生命周期中等

### 2.6 HazardPointer — KV cache block handle

[`src/share/cache/ob_kvcache_hazard_pointer.h:18-32`](src/share/cache/ob_kvcache_hazard_pointer.h):

```cpp
class HazardPointer final {
public:
  DISABLE_COPY_ASSIGN(HazardPointer);
  bool protect(ObKVMemBlockHandle* mb_handle, int32_t seq_num);
  bool protect(ObKVMemBlockHandle* mb_handle);
  ObKVMemBlockHandle* get_mb_handle() const;
  void reset_protect(ObKVMemBlockHandle* mb_handle);
  void release();
  HazardPointer* get_next() const;
  HazardPointer* get_next_atomic() const;
  void set_next(HazardPointer* next);
  void set_next_atomic(HazardPointer* next);

private:
  template <typename T>
  friend class FixedTinyAllocator;

  HazardPointer() : next_{nullptr}, mb_handle_(nullptr) {}

  HazardPointer* next_;
  ObKVMemBlockHandle* mb_handle_;
};
```

[`src/share/cache/ob_kvcache_hazard_pointer.cpp:18-90`](src/share/cache/ob_kvcache_hazard_pointer.cpp):

```cpp
// 1. 保护 mb_handle (写 HP)
bool HazardPointer::protect(ObKVMemBlockHandle* mb_handle, int32_t seq_num) {
  ObKVMemBlockHandle* old = nullptr;
  do {
    old = ATOMIC_LOAD_RLX(&mb_handle_);   // 读当前 HP
    // 如果 mb_handle 已被 free (status=FREE), 失败
    if (seq_num != ATOMIC_LOAD_RLX(&mb_handle->seq_num_) ||
        ObKVMBHandleStatus::FREE == ATOMIC_LOAD_RLX(&mb_handle->status_)) {
      return false;
    }
  } while (!ATOMIC_BCAS(&mb_handle_, old, mb_handle));   // BCAS 写入 HP
  return true;
}

// 2. 读取 mb_handle (读 HP)
ObKVMemBlockHandle* HazardPointer::get_mb_handle() const {
  return ATOMIC_LOAD_RLX(addr);   // ★ RLX load, 见下面说明
}

// 3. 释放 HP (写 null)
void HazardPointer::release() {
  ATOMIC_STORE_RLX(addr, nullptr);   // ★ RLX store, 见下面说明
}
```

**Hazard Pointer 协议**:
1. **读路径**: 1. 写 HP 指向 mb_handle; 2. 检查 mb_handle 状态 (FREE?); 3. 读 mb_handle; 4. 释放 HP
2. **写路径 (free mb_handle)**: 1. 把 mb_handle 放进 retire_list; 2. scan 所有 HP, 确认没有线程还在用; 3. 真销毁

**memory order 选择**: HP 用 **`_RLX`** 因为:
- HP 的写 / 读不需要和 mb_handle 的字段同步 (mb_handle 字段是 SEQ_CST 读写的, 本身有完整可见性)
- HP 只是"声明"我正在用, 不需要同步 mb_handle 内容

**为什么 BCAS 而不是普通 STORE**: 多线程并发写 HP, 必须确保写的 mb_handle 是 "我刚 check 过 valid 的那个" — 否则可能写了一个已被 free 的 mb_handle。

### 2.7 HazardDomain — HP 集合 + retire list

[`src/share/cache/ob_kvcache_hazard_domain.h`](src/share/cache/ob_kvcache_hazard_domain.h):

```cpp
class HazardDomain {
public:
  // 1. 注册 HP
  HazptrList& get_hp_list() { return hp_list_; }   // 全局 HP 链表
  // 2. 把对象放进 retire list (推迟释放)
  void retire(ObKVMemBlockHandle* mb_handle, int64_t retire_size);
  // 3. 扫描 + 清理
  void scan_and_reclaim();
private:
  HazptrList hp_list_;          // 全局 HP 链表
  ObLink* retire_list_ CACHE_ALIGNED;   // 待销毁队列
  int64_t retired_memory_size_; // 累计 retire 的内存
};
```

[`src/share/cache/ob_kvcache_hazard_domain.cpp:110-130`](src/share/cache/ob_kvcache_hazard_domain.cpp):

```cpp
// retire: 把 mb_handle 加入 retire_list_
ObLink* retire_list = ATOMIC_LOAD_RLX(&retire_list_);
ObLink* head = ...;   // mb_handle 包装成 ObLink
do {
  tail->next_ = retire_list;
} while (tail->next_ != (retire_list = ATOMIC_VCAS(&retire_list_, retire_list, head)));   // ★ VCAS 原子插队头
ATOMIC_FAA(&retired_memory_size_, retire_size);

// scan: 遍历所有 HP, 找出不在 HP 里的对象, 销毁
void HazardDomain::scan_and_reclaim() {
  // 1. 收集所有 HP 指向的 mb_handle (active set)
  // 2. 遍历 retire_list_, 不在 active set 的就销毁
  // 3. 更新统计
  IGNORE_RETURN ATOMIC_LOAD_RLX(&retired_memory_size_);
}
```

**lock-free retire list**:
- 多个线程并发 retire, 用 VCAS 把新元素插到 list 头
- VCAS retry 直到成功 (和 Treiber stack 类似)
- 单生产者多消费者的 scan_and_reclaim

### 2.8 SharedHazptr — atomic shared_ptr like

[`src/share/cache/ob_kvcache_hazard_pointer.h:46-80`](src/share/cache/ob_kvcache_hazard_pointer.h):

```cpp
class SharedHazptr final {
public:
  static int make(HazardPointer& hazptr, SharedHazptr& shared_hazptr);
  SharedHazptr(const SharedHazptr& other);   // ★ copy ctor 拷贝 refcnt
  ~SharedHazptr();                            // ★ dtor 减 refcnt
  SharedHazptr& operator=(const SharedHazptr& other);
  void move_from(SharedHazptr& other);
  void reset();
  ObKVMemBlockHandle* get_mb_handle() const;
private:
  struct ControlPointer {
    ControlPointer(HazardPointer& hazptr) : refcnt_(1), hazptr_(&hazptr) {}
    ~ControlPointer();   // ★ refcnt-- 到 0 销毁 HazardPointer
    uint64_t refcnt_;     // ★ 控制块 refcnt (FAA)
    HazardPointer* hazptr_;
  };
  ControlPointer* ctrl_ptr_;
  static lib::ObMemAttr attr_;
};
```

**SharedHazptr 是 std::shared_ptr for HazardPointer**:
- `ctrl_ptr_->refcnt_` 用 FAA 累加 (跨线程共享)
- copy ctor 增 refcnt, dtor 减 refcnt
- refcnt = 0 时销毁 ctrl_ptr_ 和 HazardPointer

**std::shared_ptr 的对比**:
- `std::shared_ptr<T>::use_count()` 用 FAA, 但 OB 用 HazardPointer 是为了**延迟销毁**, 不是 refcnt 到 0 立即销毁
- HazardPointer 把 refcnt 到 0 的对象放进 retire list, 等 HP scan 确认无引用后才真销毁

### 2.9 ob_concurrent_hash_map_with_hazard_value — 完整 HP 化 hash map

[`deps/oblib/src/lib/hash/ob_concurrent_hash_map_with_hazard_value.h`](deps/oblib/src/lib/hash/ob_concurrent_hash_map_with_hazard_value.h):

```cpp
class ObConcurrentHashMapWithHazardValue {
public:
  ...
private:
  ObHazardPointerSet<HashNode> hp_set_;   // ★ HP 集
  ...
};
```

[`deps/oblib/src/lib/hash/ob_hazard_pointer.h`](deps/oblib/src/lib/hash/ob_hazard_pointer.h):

```cpp
template <typename T>
class ObHazardPointerSet {
public:
  ...
  bool protect(T* ptr);       // 把 ptr 写进 HP
  void release();             // 清空 HP
  void retire(T* ptr);        // 把 ptr 推迟释放
private:
  HazardPointer* hp_arr_;    // ★ 全局 HP 数组
  ...
};
```

**HP-based hash map**:
- 读路径: protect(node) → 读 node 字段 → release
- 写路径 (delete node): retire(node) → 进 retire list → 后台 scan → 真销毁
- 完全 lock-free (除 scan 的临界区)

### 2.10 ObStockCtrl — 跨段 refcount

[`deps/oblib/src/lib/allocator/ob_slice_alloc.h:155-180`](deps/oblib/src/lib/allocator/ob_slice_alloc.h):

```cpp
class ObStockCtrl {
public:
  enum { K = INT32_MAX/2 };
  bool acquire() { return dec_if_gt(K, K) > K; }    // shared → private
  bool release() { return faa(-K) > 0; }           // private → shared
  bool recycle() { return inc_if_lt(2 * K, -K + total) == -K + total; }
  bool alloc_stock() { return dec_if_gt(1, 0) > 0; }
  bool free_stock(bool& first_free) {
    int32_t total = total_;
    int32_t ov = cas_or_inc(K + total - 1, -K + total, 1);
    first_free = (ov == -K);
    return ov == K + total - 1;
  }
private:
  int32_t faa(int32_t x) { return ATOMIC_FAA(&stock_, x); }
  int32_t aaf(int32_t x) { return ATOMIC_AAF(&stock_, x); }
  int32_t dec_if_gt(int32_t x, int32_t b) {
    int32_t ov = ATOMIC_LOAD(&stock_);
    int32_t nv = 0;
    while(ov > b && ov != (nv = ATOMIC_VCAS(&stock_, ov, ov - x))) {   // ★ VCAS 自旋减
      ov = nv;
    }
    return ov;
  }
  int32_t inc_if_lt(int32_t x, int32_t b) {
    int32_t ov = ATOMIC_LOAD(&stock_);
    int32_t nv = 0;
    while(ov < b && ov != (nv = ATOMIC_VCAS(&stock_, ov, ov + x))) {   // ★ VCAS 自旋加
      ov = nv;
    }
    return ov;
  }
  int32_t cas_or_inc(int32_t cmpv, int32_t newv, int32_t incy);
private:
  int32_t total_;
  int32_t stock_;
};
```

**ObStockCtrl 状态**:

```
[K, K+N]  ← shared (空闲)
[K-N, K]  ← private (在用)
[-K, -K+N] ← flying (刚 free, 准备回收)
```

**特点**:
- 一个 int32_t 同时编码了状态和计数
- `K = INT32_MAX/2` 是分界点
- 用 VCAS 做有界加 / 减 (dec_if_gt / inc_if_lt)

---

## 3. 性能优化

### 3.1 BORN_REF vs spinlock 的对比

| 维度 | BORN_REF | spinlock |
|------|---------|----------|
| 加减开销 | FAA 一次 (~30 cycles) | BCAS 一次 (~30 cycles) + 可能 spin |
| ABA 防护 | 魔法值 + 区间检查 | spinlock 防并发 |
| 适用 | 高频 inc/dec (memtable hash node) | 中频 (cross module) |
| 复杂度 | 需 magic value 假设 (max users < BORN_REF) | 简单 |

### 3.2 Hazard Pointer vs RCU vs Epoch-based

| 维度 | Hazard Pointer | Epoch | RCU |
|------|---------------|-------|-----|
| 读开销 | 1 个 atomic store + 1 个 atomic load | 1 个 atomic load | 0 (no atomic) |
| 写开销 | retire + scan (O(n) HP) | 等 epoch 翻转 | 等 grace period |
| 适用 | 中等读延迟 (μs 级) | 中等 | 长读路径 (> ms) |
| 内存开销 | O(threads × HP) | O(1) | O(1) |

OB KV cache 选 HP 因为 KV block 的读路径是 ~100 ns, 比 RCU 的 grace period 等待时间短。

### 3.3 HP scan 的开销

scan_and_reclaim 是 O(N_HPS) — 遍历所有 thread 的所有 HP。OB 的策略:
- **触发式 scan**: 仅当 retire list 长度超过阈值时才 scan
- **批量 scan**: 一次扫描清理多个 retire 对象
- **后台 thread**: scan 跑在后台, 不阻塞业务

### 3.4 SharedHazptr 的 refcnt 优化

`ctrl_ptr_->refcnt_` 用 FAA (非 BCAS), 因为 refcnt 累加不会冲突 — 每个 +1 独立原子, 即使两个 thread 同时 copy 也不会丢失 (因为 FAA 是 RMW)。

### 3.5 cache line 对齐

[`src/share/cache/ob_kvcache_hazard_domain.h`](src/share/cache/ob_kvcache_hazard_domain.h):

```cpp
ObLink* retire_list_ CACHE_ALIGNED;   // ★ cache line 对齐
int64_t retired_memory_size_;          // 累计统计
```

`retire_list_` 是 hot write 路径, `retired_memory_size_` 是 hot read 路径 (监控), 必须分开避免 false sharing。

### 3.6 PAUSE() 在 refcount 自旋中的重要性

[`deps/oblib/src/lib/hash/ob_multi_mod_ref_mgr.h:30-40`](deps/oblib/src/lib/hash/ob_multi_mod_ref_mgr.h):

```cpp
while (!ATOMIC_BCAS(&lock_, 0, 1)) {
  PAUSE();   // ★ 必须: 自旋不烧 CPU
}
```

refcount 路径多用 spinlock 防 ABA, PAUSE 是必备。

---

## 4. 与 v2 主线的连接

| v2 文章 | Refcount / Hazard 维度 |
|---------|----------------------|
| #14 (MemTable) | `ob_link_hashmap uref_/href_` BORN_REF 是 memtable hash node 生命周期 |
| #15 (ObKeyBTree) | 同上, BTree node 用相同 refcount |
| #51 (Block Cache) | KV cache 用完整 HazardPointer 管理 block handle |
| #74 (Thread Model) | drwlock ref 是多线程 reader 计数 |
| #25 (Memory Management) | ObTenantCtxAllocator::ref_cnt_ 是 allocator 生命周期 |
| #36 (Concurrency Control) | ob_multi_mod_ref_mgr 是跨模块共享 |

### 主线架构图 (Refcount / Hazard 层)

```
┌──────────────────────────────────────────────────────────┐
│  Refcount / Hazard 集群                                 │
│                                                          │
│  ObTenantCtxAllocator::ref_cnt_  (简单 FAA)              │  ← 长生命周期
│  ObIODevice::ref_cnt_            (简单 FAA)              │
│  ob_link_hashmap uref_/href_     (BORN_REF 魔法值)      │  ← 短生命周期 (memtable node)
│  drwlock::ref                    (FAA reader count)      │
│  ob_multi_mod_ref_mgr            (FAA + BCAS spinlock)   │  ← 中等生命周期
│  ObStockCtrl                     (VCAS 区间编码)        │
│  KV cache HazardPointer          (完整 HP 协议)         │  ← 中等生命周期 + 复杂访问
│  SharedHazptr                    (atomic SP-like)        │
│  ob_concurrent_hash_map          (HP-based hash map)     │  ← 完全 lock-free
└──────────────────────────────────────────────────────────┘
                    ▲                       │
                    │ FAA / BCAS / VCAS     │ FAA / BCAS / RELEASE_HP
                    │ (inc/dec)             │ (free/retire)
                    ▼                       │
┌──────────────────────────────────────────────────────────┐
│  调用方                                                  │
│  - 业务线程 (memtable insert / KV cache lookup)          │
│  - GC / cleanup (retire + scan)                         │
│  - 监控 (读 ref_cnt_ 用于 v$memory_info)                │
└──────────────────────────────────────────────────────────┘
```

---

## 5. 调优 Checklist

| 项 | 检查方法 | 推荐 |
|----|---------|------|
| refcount 模式是否选对 (FAA vs BORN_REF vs HP) | grep ref_count 类型 | 长用 FAA, 短用 BORN_REF, 复杂用 HP |
| spinlock 是否带 PAUSE | grep `while.*BCAS` | 必须 |
| BORN_REF 是否足够大 | 算 max users × BORN_REF | 应 ≥ 2^10 |
| HP 域 scan 频率 | `v$kvcache_hazard_status` | 应 < 1/s |
| drwlock ref 字段是否 CACHE_ALIGNED | grep `CACHE_ALIGNED` | 是 |
| SharedHazptr use_count | leak 检测 | 应平衡 |
| retire list 是否无限增长 | `retired_memory_size_` | 应在 scan 后归零 |

---

## 6. 常见故障 case

### Case 1: BORN_REF 用尽

**现象**: memtable hash node ref 超过 BORN_REF, 出现 ABA 误判
**原因**: BORN_REF 假设最大并发用户数 < BORN_REF, 实际超了 (1024)
**排查**: 监控 max_concurrent_users, 设 BORN_REF 为 2 倍最大值
**修复**: 调大 BORN_REF 常量, 或换 hazard pointer

### Case 2: HP 域 scan 不及时

**现象**: 内存持续增长, `retired_memory_size_` 一直涨, scan 没触发
**原因**: scan 触发条件设太大, 或 scan thread 没运行
**排查**:
```bash
# 查 HP scan 频率
grep "scan_and_reclaim" observer.log
```
**修复**: 调小 scan 阈值, 或重启 observer 触发初始 scan

### Case 3: drwlock 写饥饿

**现象**: writer 一直抢不到锁 (ref 一直 > 0)
**原因**: reader 持续进入 (long critical section), writer busy-spin
**修复**:
1. 减小 reader critical section
2. 换 OS futex (有排队)
3. 用 read-copy-update (RCU)

### Case 4: SharedHazptr 内存泄漏

**现象**: `ctrl_ptr_->refcnt_` 不到 0, 内存泄漏
**原因**: copy ctor 配对漏掉了 dtor (e.g. early return)
**排查**: 看 code path, 用 `std::shared_ptr` 替代 SharedHazptr 排查
**修复**: RAII 保证 copy / dtor 配对

### Case 5: multi_mod_ref_mgr spin 死锁

**现象**: 多线程调 inc_ref 全 hang
**原因**: inc_ref spinlock 与另一处锁有 lock order 反
**排查**: 看栈, 检查 lock order
**修复**: 改 lock order, 或换 HazardPointer

---

## 7. 参考 (可执行源码锚点)

| 路径 | 行 | 锚点 |
|------|---|------|
| `deps/oblib/src/lib/atomic/ob_atomic.h` | 23-79 | atomic macro 定义 |
| `deps/oblib/src/lib/alloc/ob_tenant_ctx_allocator.h` | 165-180 | ObTenantCtxAllocator::ref_cnt_ FAA |
| `deps/oblib/src/common/storage/ob_io_device.cpp` | 170-180 | ObIODevice::inc_ref/dec_ref |
| `deps/oblib/src/lib/hash/ob_link_hashmap.h` | 60-85 | BORN_REF = 1024 魔法值 |
| `deps/oblib/src/lib/hash/ob_link_hashmap_deps.h` | 62 | href_ (hash ref) |
| `deps/oblib/src/lib/hash/ob_multi_mod_ref_mgr.h` | 20-50 | FAA + BCAS spinlock 防 ABA |
| `deps/oblib/src/lib/tc/deps/drwlock.h` | 75-110 | drwlock ref + write_uid |
| `deps/oblib/src/lib/hash/ob_hazard_pointer.h` | (full) | ObHazardPointerSet 模板 |
| `deps/oblib/src/lib/hash/ob_concurrent_hash_map_with_hazard_value.h` | (full) | HP-based hash map |
| `src/share/cache/ob_kvcache_hazard_pointer.h` | 18-80 | HazardPointer + SharedHazptr |
| `src/share/cache/ob_kvcache_hazard_pointer.cpp` | 18-90 | HP protect / get_mb_handle / release |
| `src/share/cache/ob_kvcache_hazard_domain.h` | (full) | HazardDomain (HP 域 + retire list) |
| `src/share/cache/ob_kvcache_hazard_domain.cpp` | 110-130 | retire VCAS + scan |
| `deps/oblib/src/lib/allocator/ob_hazard_ref.{h,cpp}` | (full) | HazardRef 通用模板 |
| `deps/oblib/src/lib/allocator/ob_slice_alloc.h` | 155-180 | ObStockCtrl (区间编码 refcount) |

---

## 8. Cross-cutting 列表

- **ABA 风险等级**: 长生命周期对象 (ObTenantCtxAllocator) 低, 短生命周期 (memtable hash node) 高, KV cache block 中等
- **三种防 ABA 思路**: 简单 FAA (refcnt 不防 ABA, 信任长生命周期) / BORN_REF (魔法值 + 区间检查) / HazardPointer (完整协议)
- **BORN_REF 假设**: 最大并发用户数 < BORN_REF (默认 1024), 超过会 ABA
- **HP 三 操作**: protect (写 HP) / get_mb_handle (读 HP) / release (清 HP), 配合 retire + scan 形成完整协议
- **HP memory order**: HP 字段用 RLX, mb_handle 字段用 SEQ_CST — 因为 mb_handle 的 SEQ_CST 同步已保证 HP 看到的有效性
- **SharedHazptr**: std::shared_ptr for HazardPointer, ctrl_ptr_->refcnt_ 用 FAA 跨线程共享
- **ObStockCtrl 区间编码**: 一个 int32_t 同时编码状态和计数, 用 K = INT32_MAX/2 做分界
- **drwlock 三态**: 0 (无锁) / write_uid_ = 1 (writer 持锁) / ref > 0 (reader 计数)
- **PAUSE() 在 spinlock**: 所有 `while(!BCAS) PAUSE()` 必须有 PAUSE, 否则烧 CPU
- **observability**: refcnt 对应 `v$memory_info.ref_cnt` / `v$kvcache_hazard_status.retired_memory_size`

---

## 9. 下一篇预告

#106 — 原子变量应用 (4/4): **Lock-free Data Structure 模式** —
`ob_latch` (BCAS + WAIT_MASK 自旋 latch) / `ob_qsync_lock` (BCAS write_flag_ 简化 mutex) / `ob_bucket_qsync_lock` (per-bucket qsync) / `ob_darray` (BCAS write_uid 可重入锁) / `batch_pop_queue` (Treiber stack + VCAS top_) / `ob_link_hashmap` (VCAS 链 + BORN_REF) / `ob_slice_alloc` (VCAS stock_ + BCAS addr) / `ob_clock_generator` (BCAS cur_ts_ 单调时间) / `ob_stat_template` (BCAS lock_) / `ob_multi_mod_ref_mgr` (BCAS spinlock) / `ob_sp_link_queue` (lock-free SPSC/MPMC queue) / `atomic128` (128-bit CAS for table version)。

揭晓: 同一份 atomic 宏, 当业务是"无锁数据结构"时, BCAS / VCAS 用于构造 lock-free primitive, OB 多种 latch 和 queue 都基于这些原语, 是 #74 Thread Model 和 #75 Latch System 的底层基石。