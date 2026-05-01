# 45-cpufreq — CPU 频率调节深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**cpufreq** 动态调节 CPU 频率和电压，在性能和功耗之间平衡。核心驱动 cpufreq 调控器（governor）决定目标频率。

---

## 1. 核心路径

```
调度器发现 CPU 利用率高
  │
  └─ cpufreq_update_util(rq, flags)
       │
       └─ cpufreq governor -> 计算目标频率
            │
            ├─ 常见调控器：
            │    ├─ performance: 最高频率
            │    ├─ powersave:   最低频率
            │    ├─ userspace:   用户指定
            │    └─ schedutil:  基于调度器利用率
            │
            ├─ schedutil 算法：
            │    └─ sugov_update_single()
            │         ├─ 读取 Per-entity 负载跟踪（PELT）
            │         ├─ 利用率 = 当前 CPU 容量使用率
            │         └─ 目标频率 = 当前频率 × (利用率 + 余量)
            │
            └─ __cpufreq_driver_target(policy, target_freq, flags)
                 └─ cpufreq_driver->setpolicy() / target()
```

---

*分析工具：doom-lsp（clangd LSP）*
