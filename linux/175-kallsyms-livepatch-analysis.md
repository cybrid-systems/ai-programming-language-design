# 175-kallsyms_livepatch — 内核符号与热补丁深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/kallsyms.c` + `kernel/livepatch/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**kallsyms** 导出内核符号供用户空间使用（perf、systemtap）。**Livepatch** 允许在运行时替换内核函数，实现热补丁，无需重启。

---

## 1. kallsyms

### 1.1 内核符号表

```c
// kernel/kallsyms.c — 内核符号
// /proc/kallsyms 包含所有内核函数和数据的地址

// 符号类型：
//   t = text（代码）
//   T = 全局文本
//   d = data
//   D = 全局数据

// /proc/kallsyms 示例：
//   0000000000001234 t tcp_sendmsg  [tcp]
//   0000000000005678 T sys_sendto      [vmlinux]
```

### 1.2 kallsyms_lookup

```c
// kernel/kallsyms.c — kallsyms_lookup
const char *kallsyms_lookup(unsigned long addr, char **namebuf,
                            size_t *nameLen, ...)
{
    // 1. 二分查找符号表
    // 2. 返回符号名和偏移
    return symbol_name;
}
```

---

## 2. Livepatch

### 2.1 klp_patch — 补丁结构

```c
// kernel/livepatch/patch.c — klp_patch
struct klp_patch {
    struct list_head        list;              // 全局补丁链表
    char                  *modname;         // 模块名
    struct klp_object       *objs;           // 补丁对象

    struct klp_func        *funcs;           // 替换函数
};

struct klp_func {
    const char            *old_name;        // 原函数名
    void                  *new_func;        // 新函数
    unsigned long          old_addr;         // 原函数地址
    unsigned long          new_addr;         // 新函数地址
};
```

### 2.2 klp_enable_patch — 启用补丁

```c
// kernel/livepatch/core.c — klp_enable_patch
int klp_enable_patch(struct klp_patch *patch)
{
    // 1. 解析补丁对象
    klp_init_patch(patch);

    // 2. 替换函数（Ftrace）
    for (each_func in patch->funcs) {
        klp_hook_func(func);
    }

    // 3. 启用补丁
    patch->enabled = true;
}
```

---

## 3. Ftrace 函数钩子

```c
// Livepatch 使用 Ftrace 替换函数：
// 1. ftrace_set_filter_ip(func->old_addr)
// 2. 注册 trampoline
// 3. 旧函数被调用时，跳转到新函数

// trampoline：
//   保存上下文
//   跳转到 new_func
//   返回后恢复
```

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/kallsyms.c` | `kallsyms_lookup` |
| `kernel/livepatch/core.c` | `klp_enable_patch` |

---

## 5. 西游记类喻

**kallsyms + Livepatch** 就像"天庭的热修复系统"——

> kallsyms 像天庭的职位表，记录了每个神仙的职位和位置（函数名和地址），这样天庭能随时找到某个神仙（perf 能看到函数调用栈）。Livepatch 像天庭的"法术替换"——某个神仙（函数）如果出了问题，不用重新建天庭（重启内核），直接施法把他换成另一个能力更强的神仙（新函数）。这个替换通过 ftrace 魔术钩子实现，让所有调用旧函数的代码自动跳转到新函数。这就是为什么生产环境的 Linux 可以热修复，不用中断服务。

---

## 6. 关联文章

- **ftrace**（相关）：Livepatch 依赖 ftrace
- **module**（相关）：kallsyms 也包含模块符号