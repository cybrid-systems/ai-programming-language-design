# 208-RCU_dentry — RCU锁保护的dentry深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/dcache.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**RCU-dentry** 使用 RCU 机制保护目录项缓存，允许无锁的并发查找。

---

## 1. dcache RCU

```c
// fs/dcache.c — dentry 数据
struct dentry {
    struct hlist_node d_hash;         // dcache 哈希表
    struct dentry *d_parent;
    struct qstr d_name;

    // RCU 保护
    struct rcu_head d_rcu;
    // 在 RCU 读临界区内可安全访问
}
```

---

## 2. d_lookup_rcu

```c
// fs/dcache.c — d_lookup_rcu
struct dentry *d_lookup_rcu(const struct dentry *parent, const qstr *name)
{
    // 在 RCU 读临界区（rcu_read_lock）内查找
    hlist_for_each_entry_rcu(dentry, &parent->d_subdirs, d_child)
        if (dentry->d_name == name)
            return dentry;
    return NULL;
}
```

---

## 3. dcache 回收

```c
// dentry 在 RCU 读临界区结束后才能真正释放：
call_rcu(&dentry->d_rcu, __d_free);
```

---

## 4. 西游记类喻

**RCU-dentry** 就像"天庭的目录册无锁查询"——

> dentry 的 RCU 保护就像天庭目录册的实时版本——查询员（读进程）可以无锁地翻阅目录册，只有在所有人都不看的时候（宽限期结束），才能更新册子上的内容。这就是 RCU 的优势——读可以完全并行，不用排队等锁。

---

## 5. 关联文章

- **RCU**（article 26）：RCU 基本原理
- **VFS**（article 19）：dentry 是 VFS 的一部分