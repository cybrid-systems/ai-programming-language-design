# Linux 内核模块加载器深度分析

## 概述

Linux 内核模块系统允许在运行时动态加载和卸载内核代码。模块系统是驱动开发的主要方式：大多数设备驱动、文件系统和网络协议都是以模块形式存在。

核心入口点：
- `init_module()` / `finit_module()` — 加载 ELF 格式的 `.ko` 文件
- `delete_module()` — 卸载模块

## 核心数据结构

### struct module — 模块描述符

（`include/linux/module.h` — 核心结构）

```c
struct module {
    /* 模块状态 */
    enum module_state      state;      // MODULE_STATE_LIVE / COMING / GOING

    /* 链表 */
    struct list_head       list;       // 所有模块的链表

    /* 模块名称和 ELF 信息 */
    char                   name[MODULE_NAME_LEN];
    struct module_kobject  mkobj;      // sysfs 表示
    struct module_attribute *modinfo_attrs;
    const char             *version;
    const char             *srcversion;

    /* 符号导出 */
    const struct kernel_symbol *syms;       // 导出的符号表
    const s32                  *crcs;       // CRC 校验值
    unsigned int               num_syms;
    const struct kernel_symbol *gpl_syms;   // GPL-only 符号
    ...

    /* 依赖关系 */
    const struct kernel_symbol *dep_syms;
    unsigned int               num_dep_syms;
    struct module_use          *targets;    // 依赖哪些模块

    /* 参数 */
    struct kernel_param        *kp;
    unsigned int               num_kp;

    /* 代码段 */
    unsigned int               text_size;   // .text 段大小
    unsigned int               ro_size;     // .rodata 段大小
    unsigned int               ro_after_init_size;
    unsigned int               data_size;   // .data 段大小

    /* 模块初始化/退出函数 */
    int (*init)(void);                       // init_module
    void (*exit)(void);                      // cleanup_module

    /* 架构相关 */
    unsigned long              mce_flags;
    ...
};
```

### 模块状态机

```
           init_module() / finit_module()
               │
               ▼
        MODULE_STATE_UNFORMED
               │
          布局并复制
               │
               ▼
        MODULE_STATE_COMING
               │
          调用 init()
        ┌──────┴──────┐
        │ 成功        │ 失败
        ▼              ▼
 MODULE_STATE_LIVE  清理并释放
        │
        │ delete_module()
        │ 或 module_put()
        ▼
 MODULE_STATE_GOING
        │
       调用 exit()
        │
        释放
```

## 完整加载流程

### 系统调用入口

```
SYSCALL_DEFINE3(init_module, void __user *, umod, unsigned long, len, ...)
    └─ load_module(umod, len, uargs)
         └─ 核心加载函数

SYSCALL_DEFINE3(finit_module, int, fd, const char __user *, uargs, int, flags)
    └─ load_module_from_fd(fd, uargs, flags)
         └─ load_module(umod, len, uargs)
```

### load_module() — 模块加载核心

（`kernel/module/main.c`）

```
load_module(umod, len, uargs)
  │
  ├─ 1. 复制模块到内核
  │     mod = kzalloc(sizeof(*mod), GFP_KERNEL);
  │     info->hdr = copy_module_from_user(umod, len);
  │     // 从用户空间复制完整的 ELF 文件到内核
  │
  ├─ 2. ELF 验证
  │     module_valid(info);                    // 检查魔数、架构
  │     需要与当前内核架构匹配（x86-64 模块不能加载到 arm64 内核）
  │
  ├─ 3. 布局模块段
  │     layout_and_allocate(info, mod)
  │       ├─ 识别特殊段：.text, .rodata, .data, .bss, .init.text
  │       ├─ 计算各段大小
  │       │    text_size = 代码段大小
  │       │    ro_size = 只读数据段
  │       │    data_size = 数据段 + .bss
  │       ├─ 分配物理内存
  │       │    module_alloc(text_size + data_size + ro_size)
  │       │    // module_alloc 使用 __vmalloc_node_range
  │       │    // 在 MODULES_VADDR ~ MODULES_END 内分配
  │       └─ 复制段内容到新的内存区域
  │
  ├─ 4. 字符串表解析
  │     setup_strtab(info, mod);
  │     // 解析 .strtab / .modinfo 等字符串段
  │
  ├─ 5. 符号解析与重定位
  │     simplify_symbols(info, mod);           // 简化外部符号引用
  │     apply_relocations(info, sec);           // 应用重定位
  │       ├─ 遍历所有需要重定位的段
  │       └─ 对每个重定位条目：
  │             └─ resolve_symbol(wfl, info, ...)
  │                   └─ 在以下位置查找符号：
  │                       1. 本模块导出的符号
  │                       2. 其他已加载模块导出的符号
  │                       3. 内核符号表（kallsyms）
  │                       4. 如果找不到 → 错误（ENOENT）
  │
  ├─ 6. 依赖关系建立
  │     use_module(mod, dep);
  │     // 增加依赖模块的引用计数
  │     // 确保 unload 时依赖模块不会先于本模块卸载
  │
  ├─ 7. 模块参数解析
  │     parse_args(mod->name, ..., mod->kp, mod->num_kp, ...);
  │     // 从 uargs 解析 `param=value` 格式的参数
  │
  ├─ 8. 安全检查
  │     module_sig_check(info, ...)
  │     // 如果内核启用了 module.sig_enforce
  │     // 验证模块的数字签名（MODULE_SIG_FORMAT 段）
  │
  ├─ 9. 设置内存保护
  │     module_enable_ro(mod, false);       // .rodata 设为只读
  │     module_enable_nx(mod);              // 设置 NX 位
  │     // 使用 set_memory_ro/nx 等页表级别操作
  │
  ├─ 10. 将模块加入全局链表
  │      list_add_rcu(&mod->list, &modules);
  │      // 模块对其他模块可见（模块可以通过 find_module() 查找）
  │
  ├─ 11. 状态切换为 COMING
  │      mod->state = MODULE_STATE_COMING;
  │      blocking_notifier_call_chain(&module_notify_list,
  │                                    MODULE_STATE_COMING, mod);
  │
  ├─ 12. 调用模块的初始化函数
  │      mod->init = 模块入口点;
  │      ret = do_mod_init(mod, ...);
  │      └─ __do_mod_init(mod)
  │           └─ mod->init();              // 执行 module_init 指定的函数
  │
  ├─ 13. 如果初始化成功
  │      mod->state = MODULE_STATE_LIVE;
  │      通知 MODULE_STATE_LIVE 事件
  │      return 0;
  │
  └─ 14. 如果初始化失败
         mod->state = MODULE_STATE_GOING;
         通知 MODULE_STATE_GOING 事件
         module_deallocate(mod);
         return ret;
```

## 符号解析细节

`simplify_symbols()` 是加载的关键步骤。每个需要外部引用的符号必须被解析：

```c
// kernel/module/main.c
static int simplify_symbols(struct module *mod, const struct load_info *info)
{
    // 遍历所有符号
    for (i = 0; i < info->sechdrs[symindex].sh_size / sizeof(Elf_Sym); i++) {
        // 如果是外部符号（SHN_UNDEF）
        if (sym[i].st_shndx == SHN_UNDEF) {
            // 尝试解析
            ret = resolve_symbol_wait(mod, info, symname);
            if (ret < 0) {
                // 如果内核启用了 CONFIG_MODULE_SIG
                // 并且是可选依赖 → 可以延迟解决
                continue;
            }
        }
    }
}
```

`resolve_symbol_wait()` 在找不到符号时会：
1. 检查 `MODULE_SOFTDEP` —— 是否是声明了但尚未加载的依赖模块
2. 如果是，通过 `request_module("symbol:%s", symname)` 请求自动加载依赖模块
3. 再次尝试解析

## 模块卸载流程

```
delete_module(name, flags)
  │
  ├─ 1. 查找模块
  │     mod = find_module(name);
  │
  ├─ 2. 检查是否可以卸载
  │     └─ module_refcount(mod) == 0
  │        - 检查依赖该模块的其他模块的引用计数
  │        - 检查 try_module_get() 是否仍有效
  │
  ├─ 3. 设置状态为 GOING
  │     mod->state = MODULE_STATE_GOING;
  │     通知 MODULE_STATE_GOING 事件
  │
  ├─ 4. 调用模块退出函数
  │     if (mod->exit)
  │         mod->exit();
  │
  ├─ 5. 释放资源
  │     module_unload_free(mod);       // 释放依赖计数
  │     module_deallocate(mod);        // 释放内存
  │     list_del_rcu(&mod->list);      // 从全局链表移除
  │
  └─ 6. 回收
       free_module(mod);
```

## 模块签名与安全

### 签名格式

模块签名存储在 ELF 文件的末尾（`MODULE_SIG_FORMAT` 段）：

```
┌─────────────────────┐
│ ELF 文件（.ko）      │
├─────────────────────┤
│ 普通 Elf 段          │
├─────────────────────┤
│ MODULE_SIG_FORMAT    │
│ ┌──────────────────┐│
│ │签名算法标识       ││  ← enum pkey_id_type
│ │密钥 ID           ││
│ │签名数据           ││  ← PKCS#7 签名
│ │签名长度           ││
│ └──────────────────┘│
└─────────────────────┘
```

### 验证流程

```c
// kernel/module/signing.c
int module_sig_check(struct load_info *info, int flags)
{
    // 1. 检查 ELF 文件末尾是否有签名尾
    // 2. 如果有签名，使用系统密钥环验证
    //    verify_pkcs7_signature(mod, modlen, mod->sig, sig_len,
    //                            VERIFY_USE_SECONDARY_KEYRING, ...)
    // 3. 如果启用了 sig_enforce 且签名无效 → 拒绝加载
    // 4. 如果 sig_enforce 未启用且签名无效 → 允许加载但标记为 TAINT_CRAP
}
```

签名验证使用 Linux 内核的内置密钥环：由内核构建时签署的密钥（MOK 或内置密钥）签名模块。

## 模块的内存布局

```
模块内存分配区域（MODULES_VADDR ~ MODULES_END）：
  x86-64: 0xffffffffc0000000 ~ 0xfffffffffe000000（约 960MB）
  arm64:  可配置，通常与 vmalloc 区域共享

每个模块的内存布局：
  ┌─────────────────┐  ← module_alloc() 返回
  │ .text（代码段）  │  可执行，只读
  ├─────────────────┤
  │ .rodata         │  只读
  ├─────────────────┤
  │ .ro_after_init  │  初始化后只读
  ├─────────────────┤
  │ .data           │  读写
  ├─────────────────┤
  │ .bss            │  零初始化
  └─────────────────┘
```

### module_alloc() 实现

```c
// kernel/module/main.c
void *module_alloc(unsigned long size)
{
    // x86-64: 调用 __vmalloc_node_range(size, 1,
    //     MODULES_VADDR, MODULES_END, GFP_KERNEL, ...)
    // arm64: 类似，在 vmalloc 区域内
    return __vmalloc_node_range(size, 1, MODULES_VADDR, MODULES_END,
                                GFP_KERNEL, PAGE_KERNEL, VM_DEFER_KMEMLEAK,
                                NUMA_NO_NODE, __builtin_return_address(0));
}
```

## 关键设计决策

### 1. MODULES_VADDR ~ MODULES_END

x86-64 的模块区域在 `0xffffffffc0000000 ~ 0xfffffffffe000000`（约 960MB）。这个区域紧邻内核核心的 `__va` 地址空间，使得模块代码可以通过短跳转（`call rel32` ±2GB 范围）访问内核函数。

如果模块区域溢出，可以通过 `vmalloc` 在更大的地址范围内分配（`MODULES_VADDR` 是优先区域）。

### 2. GPL-only 符号

`EXPORT_SYMBOL_GPL()` 导出的符号只能被 GPL 兼容的模块使用。实现：在模块加载时检查模块的 license 声明（`MODULE_LICENSE`）。

```c
// kernel/params.c
static int check_modlicense(const struct module *mod,
                            const struct kernel_symbol *sym)
{
    // 如果符号是 GPL_ONLY，检查模块许可证
    if (sym->license == GPL_ONLY && !license_is_gpl_compatible(mod->license))
        return -EPERM;
    return 0;
}
```

### 3. taint 标记

模块加载可能导致内核被标记为 "tainted"（污染）：

| TAINT 标志 | 含义 | 触发条件 |
|-----------|------|---------|
| TAINT_PROPRIETARY_MODULE | 非 GPL 模块 | 非 GPL 兼容许可证 |
| TAINT_FORCED_MODULE | 强制加载 | `insmod -f` |
| TAINT_CRAP | 未签名模块 | 签名验证失败但继续加载 |
| TAINT_OUT_OF_TREE | 非内核主线模块 | 缺少 `KernelVersion` 字段 |

## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct module` | include/linux/module.h | 核心结构 |
| `load_module()` | kernel/module/main.c | 358 附近 |
| `simplify_symbols()` | kernel/module/main.c | 相关 |
| `resolve_symbol_wait()` | kernel/module/main.c | 相关 |
| `layout_and_allocate()` | kernel/module/main.c | 相关 |
| `module_sig_check()` | kernel/module/signing.c | 相关 |
| `module_alloc()` | kernel/module/main.c | 相关 |
| `free_module()` | kernel/module/main.c | 相关 |
| `SYSCALL_DEFINE3(init_module)` | kernel/module/main.c | (syscall 入口) |
| `SYSCALL_DEFINE3(delete_module)` | kernel/module/main.c | (syscall 入口) |
| `find_module()` | kernel/module/main.c | 相关 |
| `do_mod_init()` | kernel/module/main.c | 相关 |
| `MODULE_SIG_FORMAT` | include/linux/module.h | (签名段标识) |
| `module_enable_ro()` | kernel/module/strict_rwx.c | 相关 |
| `module_enable_nx()` | kernel/module/strict_rwx.c | 相关 |
