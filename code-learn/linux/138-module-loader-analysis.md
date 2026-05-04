# 138-module-loader — 读 kernel/module/main.c

---

## 系统调用入口

（`kernel/module/main.c` L3634）

三个系统调用驱动模块加载：

```
init_module(fd, umod, len, uargs)     // L3634 — 从用户空间地址加载
finit_module(fd, uargs, flags)         // L3799 — 从 fd 加载
delete_module(name, flags)             // L3832 — 卸载
```

它们最终汇聚到 `load_module(info, uargs)`（L3422）。

---

## load_module——模块加载核心

（`kernel/module/main.c` L3422）

模块加载的核心步骤：

```
load_module(info, uargs)
  │
  ├─ 1. layout_and_allocate(info, mod)     // 布局 + 分配
  │     → 识别 ELF 段（.text, .rodata, .data, .bss, .init.text）
  │     → 计算各段大小
  │     → module_alloc(text_size + ro_size + data_size)
  │       → __vmalloc_node_range(MODULES_VADDR, MODULES_END, ...)
  │     → 复制段内容到新内存
  │
  ├─ 2. simplify_symbols(mod, info)        // L1530 符号解析
  │     → 遍历所有外部符号引用
  │     → 对每个 SHN_UNDEF 的符号：
  │         查找内核符号表
  │         查找已加载模块的导出符号
  │         如果找不到 → 错误（ENOENT）
  │
  ├─ 3. apply_relocations(mod, info)       // L1608 重定位
  │     → 根据 ELF 重定位表修正地址
  │     → x86-64: R_X86_64_PC32, R_X86_64_64 等
  │
  ├─ 4. module_sig_check(info, flags)       // 签名验证
  │     → 如果内核启用了 CONFIG_MODULE_SIG
  │     → 检查模块末尾的 PKCS#7 签名
  │
  ├─ 5. module_enable_ro(mod) → set_memory_ro
  │     module_enable_nx(mod) → set_memory_nx
  │
  ├─ 6. mod->state = MODULE_STATE_COMING
  │     通知 MODULE_STATE_COMING 事件
  │
  └─ 7. mod->init()
       → 执行 module_init 指定的初始化函数
       → 如果成功 → MODULE_STATE_LIVE
       → 如果失败 → MODULE_STATE_GOING → 清理
```

---

## module_alloc——内核模块的地址空间

（`kernel/module/main.c` 相关）

```c
void *module_alloc(unsigned long size)
{
    return __vmalloc_node_range(size, 1, MODULES_VADDR, MODULES_END,
                                GFP_KERNEL, PAGE_KERNEL, ...);
}
```

x86-64 上 `MODULES_VADDR = 0xffffffffc0000000`，`MODULES_END = 0xfffffffffe000000`（约 960MB）。这个区域紧邻内核核心地址空间，使得模块代码可以通过短跳转（`call rel32`，±2GB 范围）调用内核函数。模块代码和内核代码之间的跳转只需要 5 字节的相对偏移，不需要通过函数指针间接调用。

---

## 卸载流程

```c
delete_module(name, flags)
  → mod->exit()                    // 调用模块的 cleanup 函数
  → module_unload_free(mod)        // 释放依赖计数
  → module_deallocate(mod)         // 释放 vmalloc 内存
  → list_del_rcu(&mod->list)       // 从全局模块链表移除
  → free_module(mod)               // 最终释放
```
