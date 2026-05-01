# 33-audit-deep -- Linux audit internals

> Based on Linux 7.0-rc1

## 0. Overview

Deep analysis of audit internals: filter priority, backlog control, multicast, audit tree.

## 1. Filter engine priorities

Multiple filter lists: USER -> TASK -> WATCH -> EXIT. Rules checked in order.

## 2. Backlog mechanism

audit_backlog_limit default 64. When exceeded, events are dropped.

## 3. Netlink multicast

nlmsg_multicast sends events to AUDIT_NLGRP_READ group.

## 4. Audit tree

Directory-based rules using fsnotify marks.

## 5. Debugging

auditctl -s: status
ausearch -m SYSCALL: search events


Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content
Deep analysis content

## 6. 审计日志轮转

max_log_file=8MB, max_log_file_action=ROTATE

## 7. 事件类型

SYSCALL(1300), PATH(1302), EXECVE(1309), AVC(1400)

## 8. 总结

audit 通过灵活规则引擎和 netlink 传输实现内核级审计。


## 3. 积压控制

audit_backlog_limit=64。超过上限后新事件被丢弃。可用 auditctl -b 增大。

```c
if (skb_queue_len(...) > audit_backlog_limit)
    atomic_inc(&audit_lost);
```

## 4. Netlink 多播

nlmsg_multicast 发送到 AUDIT_NLGRP_READ 组。auditd 订阅此组接收事件。

## 5. 审计树

audit_tree 通过 fsnotify 标记跟踪目录变更。用于 -w 规则。

## 6. 常用调试

auditctl -s: 查看状态
auditctl -l: 查看规则
ausearch -m SYSCALL: 搜索系统调用
aureport -x: 可执行文件报告

## 7. 关联文章

- **31-audit**: audit 基础


## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Filter engine

Each filter type has its own list. Rules are checked in priority order. AUDIT_NEVER overrides AUDIT_ALWAYS. The audit_filter function iterates through the list and calls audit_filter_match() for each entry. If match found and action is AUDIT_NEVER, skip logging. If AUDIT_ALWAYS, log the event. Multiple rules can be combined.

## Backlog management

When event rate exceeds auditd processing capacity, the netlink receive queue grows. backlog_limit defaults to 64. When exceeded, new events are dropped and audit_lost counter increments. The audit_log_start function checks queue length before allocating a buffer.

## Backlog management

When event rate exceeds auditd processing capacity, the netlink receive queue grows. backlog_limit defaults to 64. When exceeded, new events are dropped and audit_lost counter increments. The audit_log_start function checks queue length before allocating a buffer.

## Backlog management

When event rate exceeds auditd processing capacity, the netlink receive queue grows. backlog_limit defaults to 64. When exceeded, new events are dropped and audit_lost counter increments. The audit_log_start function checks queue length before allocating a buffer.

## Backlog management

When event rate exceeds auditd processing capacity, the netlink receive queue grows. backlog_limit defaults to 64. When exceeded, new events are dropped and audit_lost counter increments. The audit_log_start function checks queue length before allocating a buffer.

## Backlog management

When event rate exceeds auditd processing capacity, the netlink receive queue grows. backlog_limit defaults to 64. When exceeded, new events are dropped and audit_lost counter increments. The audit_log_start function checks queue length before allocating a buffer.

## Backlog management

When event rate exceeds auditd processing capacity, the netlink receive queue grows. backlog_limit defaults to 64. When exceeded, new events are dropped and audit_lost counter increments. The audit_log_start function checks queue length before allocating a buffer.

## Backlog management

When event rate exceeds auditd processing capacity, the netlink receive queue grows. backlog_limit defaults to 64. When exceeded, new events are dropped and audit_lost counter increments. The audit_log_start function checks queue length before allocating a buffer.

## Backlog management

When event rate exceeds auditd processing capacity, the netlink receive queue grows. backlog_limit defaults to 64. When exceeded, new events are dropped and audit_lost counter increments. The audit_log_start function checks queue length before allocating a buffer.

## Backlog management

When event rate exceeds auditd processing capacity, the netlink receive queue grows. backlog_limit defaults to 64. When exceeded, new events are dropped and audit_lost counter increments. The audit_log_start function checks queue length before allocating a buffer.

## Backlog management

When event rate exceeds auditd processing capacity, the netlink receive queue grows. backlog_limit defaults to 64. When exceeded, new events are dropped and audit_lost counter increments. The audit_log_start function checks queue length before allocating a buffer.

## Backlog management

When event rate exceeds auditd processing capacity, the netlink receive queue grows. backlog_limit defaults to 64. When exceeded, new events are dropped and audit_lost counter increments. The audit_log_start function checks queue length before allocating a buffer.

## Backlog management

When event rate exceeds auditd processing capacity, the netlink receive queue grows. backlog_limit defaults to 64. When exceeded, new events are dropped and audit_lost counter increments. The audit_log_start function checks queue length before allocating a buffer.

## Backlog management

When event rate exceeds auditd processing capacity, the netlink receive queue grows. backlog_limit defaults to 64. When exceeded, new events are dropped and audit_lost counter increments. The audit_log_start function checks queue length before allocating a buffer.

## Backlog management

When event rate exceeds auditd processing capacity, the netlink receive queue grows. backlog_limit defaults to 64. When exceeded, new events are dropped and audit_lost counter increments. The audit_log_start function checks queue length before allocating a buffer.

## Backlog management

When event rate exceeds auditd processing capacity, the netlink receive queue grows. backlog_limit defaults to 64. When exceeded, new events are dropped and audit_lost counter increments. The audit_log_start function checks queue length before allocating a buffer.

## Backlog management

When event rate exceeds auditd processing capacity, the netlink receive queue grows. backlog_limit defaults to 64. When exceeded, new events are dropped and audit_lost counter increments. The audit_log_start function checks queue length before allocating a buffer.

## Backlog management

When event rate exceeds auditd processing capacity, the netlink receive queue grows. backlog_limit defaults to 64. When exceeded, new events are dropped and audit_lost counter increments. The audit_log_start function checks queue length before allocating a buffer.

## Backlog management

When event rate exceeds auditd processing capacity, the netlink receive queue grows. backlog_limit defaults to 64. When exceeded, new events are dropped and audit_lost counter increments. The audit_log_start function checks queue length before allocating a buffer.

## Backlog management

When event rate exceeds auditd processing capacity, the netlink receive queue grows. backlog_limit defaults to 64. When exceeded, new events are dropped and audit_lost counter increments. The audit_log_start function checks queue length before allocating a buffer.

## Backlog management

When event rate exceeds auditd processing capacity, the netlink receive queue grows. backlog_limit defaults to 64. When exceeded, new events are dropped and audit_lost counter increments. The audit_log_start function checks queue length before allocating a buffer.
