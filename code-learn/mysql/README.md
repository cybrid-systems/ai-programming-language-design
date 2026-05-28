# MySQL 内核深度源码分析

> 基于 MySQL 8.4 (latest) 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 源码路径：`~/code/mysql`

## 文章列表

| # | 标题 | 核心文件 | 行数 | 状态 |
|---|------|---------|------|------|
| 01 | InnoDB 架构总览与核心数据结构 | `storage/innobase/include/` | 1552 | ✅ |
| 02 | InnoDB Buffer Pool — 页面管理与 LRU 淘汰 | `storage/innobase/buf/buf0buf.cc`, `buf0lru.cc` | 1640 | ✅ |
| 03 | InnoDB Redo Log — WAL 与 Crash Recovery | `storage/innobase/log/log0log.cc`, `log0recv.cc` | 1972 | ✅ |
| 04 | InnoDB Undo Log — MVCC 与回滚段 | `storage/innobase/trx/`, `row/row0undo.cc` | 1464 | ✅ |
| 05 | InnoDB 锁系统 — 行锁、Gap 锁、Next-Key | `storage/innobase/lock/lock0lock.cc` | 1559 | ✅ |
| 06 | InnoDB B+Tree 索引 — 页分裂、合并、AHI | `storage/innobase/btr/btr0btr.cc`, `btr0cur.cc` | 1555 | ✅ |
| 07 | InnoDB 事务系统 — ACID 实现 | `storage/innobase/trx/trx0trx.cc`, `trx0purge.cc` | 1390 | ✅ |
| 08 | InnoDB 数据页格式与行格式 | `storage/innobase/data/data0type.cc`, `page/page0page.cc` | 1116 | ✅ |
| 09 | MySQL SQL 层 — 解析、优化、执行 | `sql/sql_lexer.cc`, `sql/sql_optimizer.cc`, `sql/sql_executor.cc` | 1039 | ✅ |
| 10 | MySQL 复制 — Binlog 与 Group Commit | `sql/binlog.cc`, `sql/rpl_*` | 1171 | ✅ |
| 11 | EXPLAIN 与执行计划分析 | `sql/sql_explain.cc` | 1894 | ✅ |
| 12 | 索引设计与优化策略 | — | 1660 | ✅ |
| 13 | InnoDB 性能调优 | — | 1348 | ✅ |
| 14 | 锁诊断与死锁分析 | `storage/innobase/lock/lock0lock.cc` | 1423 | ✅ |
| 15 | 备份与恢复 | `storage/innobase/log/log0recv.cc` | 1281 | ✅ |
| 16 | InnoDB Change Buffer | `storage/innobase/ibuf/ibuf0ibuf.cc` | ~500 | ✅ |
| 17 | InnoDB 自适应哈希索引 (AHI) | `btr0sea.cc`, `btr0sea.h` | 389 | ✅ |
| 18 | InnoDB 数据字典 | `dict0mem.h`, `dict0dict.cc`, `dict0dd.cc` | 408 | ✅ |
| 19 | InnoDB 文件空间管理 | `fil0fil.cc`, `fsp0fsp.cc` | 398 | ✅ |
| 20 | InnoDB 内存管理 | `mem0mem.h`, `mem0mem.ic` | 381 | ✅ |
| 21 | InnoDB 外键与约束 | `dict0dict.cc`, `row0ins.cc`, `row0upd.cc` | 337 | ✅ |
| 22 | MySQL 查询优化器 | `sql/sql_optimizer.cc`, `sql/sql_planner.cc` | 832 | ✅ |
| 23 | MySQL 存储过程 | `sql/sp_head.cc`, `sql/sp_instr.h`, `sql/sp_pcontext.h`, `sql/sp.cc` | 917 | ✅ |
| 24 | InnoDB 全文索引 | `storage/innobase/fts/fts0fts.cc`, `fts0opt.cc` | 907 | ✅ |
| 25 | InnoDB 在线 DDL | `storage/innobase/handler/handler0alter.cc`, `row0log.cc`, `log0ddl.cc` | 738 | ✅ |
| 26 | MySQL 连接与线程池 | `sql/sql_connect.cc`, `sql/sql_parse.cc`, `sql/mysqld.cc` | 631 | ✅ |
| 27 | MySQL Performance Schema | `storage/perfschema/pfs.cc`, `pfs_instr.h` | 633 | ✅ |
| 28 | InnoDB 页面压缩 | `page0zip.cc` | 166 | ✅ |
| 29 | MySQL 分区表 | `sql/partitioning/` | 143 | ✅ |
| 30 | InnoDB 检查点 | `log0chkp.cc`, `log0log.cc` | 231 | ✅ |

## 写作标准

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
