# 31-audit — Linux 内核审计深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**Linux Audit 子系统**提供系统级的安全事件审计日志。它捕获系统调用、文件访问、进程创建、网络连接等事件，生成结构化的审计记录（audit record），通过 netlink 发送给用户空间的 auditd 守护进程记录到磁盘。广泛应用于 SELinux、AppArmor、PCI DSS 合规等安全场景。

**doom-lsp 确认**：核心实现在 `kernel/audit.c`（主框架）、`kernel/auditsc.c`（系统调用审计）、`kernel/auditfilter.c`（规则过滤）。

---

## 1. 架构

```
用户空间
  auditd ←→ auditctl (规则管理)
     ↑
     │ netlink (AF_NETLINK, NETLINK_AUDIT)
     ↓
内核 audit 子系统
  │
  ├── audit_receive_msg()      ← 接收用户空间消息（规则加载、状态查询）
  ├── audit_log_start()        ← 开始记录审计事件
  ├── audit_log_format()       ← 格式化审计记录字段
  ├── audit_log_end()          ← 结束记录并发送到 auditd
  │
  └── audit_filter()           ← 规则匹配过滤器（决定是否记录）
```

---

## 2. 核心数据结构

```c
// kernel/audit.h
struct audit_buffer {
    struct sk_buff *skb;        // netlink 消息缓冲区
    gfp_t          gfp_mask;    // 内存分配标志
};

struct audit_context {
    int     major;               // 系统调用号
    int     serial;              // 审计事件序列号
    unsigned long argv[6];       // 系统调用参数
    long    return_code;         // 系统调用返回值
    int     name_count;          // 文件名计数
    struct audit_names *names;   // 文件名数组
    ktime_t ctime;               // 创建时间
};

struct audit_entry {
    struct list_head list;       // 规则链表
    struct audit_rule rule;      // 审计规则
    struct audit_watch *watch;   // 文件监视
};
```

---

## 3. 审计规则示例

```bash
# 记录所有 open 系统调用
auditctl -a always,exit -S open -F key=open_trace

# 记录某个用户的执行
auditctl -a always,exit -S execve -F uid=1000

# 记录特定文件的写操作
auditctl -w /etc/shadow -p wa

# 排除特定事件（减少日志量）
auditctl -a exclude,always -F msgtype=USER_START
```

---

## 4. 审计记录格式

```bash
# 典型的 audit.log 条目
type=SYSCALL msg=audit(1234567890.123:456):
  arch=c000003e syscall=2 success=yes exit=3
  a0=7ffd1234 a1=0 a2=1 a3=0 items=1 ppid=1234 pid=5678
  auid=1000 uid=0 gid=0 euid=0 suid=0 fsuid=0
  egid=0 sgid=0 fsgid=0 tty=pts0 ses=1
  comm="cat" exe="/usr/bin/cat"
  subj=unconfined_u:unconfined_r:unconfined_t:s0 key="open_trace"

type=PATH msg=audit(...): item=0 name="/etc/shadow"
  inode=123456 dev=08:01 mode=0100644 ouid=0 ogid=0
  rdev=00:00 obj=system_u:object_r:shadow_t:s0 nametype=NORMAL
```

---

## 5. 系统调用审计的数据流

```
系统调用入口（audit_syscall_entry）：
  │
  ├─ 记录系统调用号、参数
  ├─ 分配 audit_context（current->audit_context）
  └─ 保存到 task_struct

系统调用执行...

系统调用退出（audit_syscall_exit）：
  │
  ├─ audit_filter(type, ...)    ← 检查规则是否匹配
  │   ├─ 不匹配 → 释放 context，不记录
  │   └─ 匹配 → 继续
  │
  ├─ audit_log_start(GFP_KERNEL, AUDIT_SYSCALL)
  ├─ audit_log_format(ab, "syscall=%d arch=%x", ...)
  ├─ 记录路径名（for each name in context->names）
  └─ audit_log_end(ab) → nlmsg_multicast → auditd
```

---

## 6. 审计事件类型

| 事件类型 | 含义 |
|---------|------|
| AUDIT_SYSCALL | 系统调用 |
| AUDIT_PATH | 路径名 |
| AUDIT_EXECVE | execve 参数 |
| AUDIT_USER_START | 用户登录 |
| AUDIT_LOGIN | 登录成功 |
| AUDIT_AVC | SELinux 访问向量缓存 |
| AUDIT_MAC_* | MAC 策略事件 |
| AUDIT_IPC | IPC 对象操作 |
| AUDIT_FS_WATCH | 文件系统监视 |

---

## 7. 源码文件索引

| 文件 | 内容 |
|------|------|
| kernel/audit.c | 审计框架核心 |
| kernel/auditsc.c | 系统调用审计 |
| kernel/auditfilter.c | 规则过滤和匹配 |
| kernel/audit_watch.c | 文件系统监视 |
| include/linux/audit.h | 公共 API |
| include/uapi/linux/audit.h | 用户空间接口 |

---

## 8. 关联文章

- **33-audit-deep**：审计深度分析补充
- **93-apparmor-selinux**：LSM 与 audit 的集成

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
