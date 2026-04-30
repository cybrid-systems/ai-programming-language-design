# 194-module — 内核模块深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/module/*.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**Linux 模块** 是运行时加载的内核代码，扩展内核功能无需重启。

---

## 1. 模块加载

```c
// kernel/module/main.c — load_module
static int load_module(struct load_info *info, const char __user *uargs)
{
    // 1. 分配模块内存
    mod = module_alloc(size);
    copy_from_user(mod->module_core, info->hdr, size);

    // 2. 解析符号表
    mod->syms = info->syms;

    // 3. 重定位
    apply_relocations(mod);

    // 4. 执行 init 函数
    do_one_initcall(mod->init);
}
```

---

## 2. 模块结构

```c
// include/linux/module.h — module
struct module {
    enum module_state state;
    const char *name;
    // .ko 文件信息
    struct list_head list;
    // 符号表
    struct module_kobject *mkobj;
    // init/exit
    int (*init)(void);
    void (*exit)(void);
    // 引用计数
    struct module_ref {
        atomic_t decs;
        atomic_t incs;
    } refptr;
};
```

---

## 3. 西游记类喻

**module** 就像"天庭的临时借调神仙"——

> module 像从其他部门临时借调来的神仙（模块），不需要常驻天庭（内核）。借调协议（init 函数）完成后，神仙开始工作；任务结束后，神仙离开（exit 函数）。如果借调的神仙还在工作时天庭需要用他（module_ref > 0），就不能卸载。

---

## 4. 关联文章

- **kallsyms**（article 175）：模块符号导出到 /proc/kallsyms