# MySQL 内核深度源码分析

> 基于 MySQL 8.4 (latest) 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 源码路径：`~/code/mysql`

## 文章列表

| # | 标题 | 核心文件 | 状态 |
|---|------|---------|------|
| 01 | InnoDB 架构总览与核心数据结构 | `storage/innobase/include/` | 📝 规划 |
| 02 | InnoDB Buffer Pool — 页面管理与 LRU 淘汰 | `storage/innobase/buf/buf0buf.cc`, `buf0lru.cc` | 📝 规划 |
| 03 | InnoDB Redo Log — WAL 与 Crash Recovery | `storage/innobase/log/log0log.cc`, `log0recv.cc` | 📝 规划 |
| 04 | InnoDB Undo Log — MVCC 与回滚段 | `storage/innobase/trx/`, `row/row0undo.cc` | 📝 规划 |
| 05 | InnoDB 锁系统 — 行锁、Gap 锁、Next-Key | `storage/innobase/lock/lock0lock.cc` | 📝 规划 |
| 06 | InnoDB B+Tree 索引 — 页分裂、合并、AHI | `storage/innobase/btr/btr0btr.cc`, `btr0cur.cc` | 📝 规划 |
| 07 | InnoDB 事务系统 — ACID 实现 | `storage/innobase/trx/trx0trx.cc`, `trx0purge.cc` | 📝 规划 |
| 08 | InnoDB 数据页格式与行格式 | `storage/innobase/data/data0type.cc`, `page/page0page.cc` | 📝 规划 |
| 09 | MySQL SQL 层 — 解析、优化、执行 | `sql/sql_lexer.cc`, `sql/sql_optimizer.cc`, `sql/sql_executor.cc` | 📝 规划 |
| 10 | MySQL 复制 — Binlog 与 Group Commit | `sql/binlog.cc`, `sql/rpl_*` | 📝 规划 |

## 写作标准（参考 OceanBase 分析质量）

每篇文章 v1 标准：
- **行数**：300-500 行（先出骨架，不要追求一步到位）
- **源码引用**：至少 5 处 doom-lsp 确认的 `file.cc:line` 引用
- **核心数据结构**：完整贴出关键 struct 定义
- **调用链**：至少一条完整的数据流追踪
- **代码块**：3-5 个真实源码片段

不接受伪代码。不接受无行号的函数名。

## 目录结构

```
mysql/
├── README.md          ← 本文
├── 01-innodb-arch.md
├── 02-innodb-buffer-pool.md
├── ... 
