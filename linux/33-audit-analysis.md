# 33-audit-deep — Linux 审计深度分析

## 0. 概述
系统调用审计的深入实现。

## 1. 审计上下文
```c
struct audit_context {
    int major, serial;
    unsigned long argv[6];
    long return_code;
    struct audit_names *names;
};
```

## 2. 系统调用入口
```c
// kernel/auditsc.c
void __audit_syscall_entry(int major, unsigned long a0, ...);
void __audit_syscall_exit(int success, long return_code);
```

## 3. 关联文章
- **31-audit**: audit 基础
