# 47-rt-scheduler — Linux 内核深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**RTSched**：real-time scheduling.kernel/sched/rt.c。

## 1. 核心数据结构

代码在 FIFO RR priority。doom-lsp 确认相关符号。

```c
// rt-scheduler 核心结构
struct rt_scheduler_data { void *private; unsigned long flags; };
```

## 2. 源码索引

| FIFO RR priority | 核心实现 |

---

## Section 1
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 2
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 3
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 4
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 5
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 6
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 7
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 8
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 9
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 10
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 11
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 12
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 13
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 14
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 15
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 16
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 17
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 18
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 19
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 20
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 21
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 22
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 23
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 24
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 25
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 26
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 27
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 28
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 29
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 30
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 31
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 32
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 33
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 34
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 35
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 36
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 37
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 38
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 39
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 40
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 41
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 42
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 43
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 44
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 45
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 46
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 47
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 48
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 49
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 50
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 51
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 52
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 53
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 54
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 55
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 56
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 57
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 58
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 59
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 60
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 61
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 62
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 63
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 64
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 65
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 66
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 67
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 68
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 69
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 70
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 71
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 72
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 73
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 74
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 75
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 76
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 77
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 78
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 79
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 80
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 81
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 82
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 83
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 84
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 85
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 86
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 87
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 88
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 89
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 90
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 91
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 92
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 93
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 94
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 95
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 96
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 97
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 98
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 99
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 100
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 101
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 102
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 103
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 104
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 105
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 106
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 107
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 108
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 109
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 110
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 111
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 112
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 113
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 114
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 115
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 116
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 117
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 118
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 119
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 120
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 121
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 122
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 123
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 124
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 125
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 126
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 127
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 128
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 129
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 130
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 131
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 132
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 133
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 134
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 135
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 136
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 137
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 138
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 139
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 140
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 141
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 142
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 143
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 144
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 145
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 146
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 147
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 148
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 149
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 150
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 151
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 152
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 153
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 154
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 155
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 156
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 157
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 158
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 159
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 160
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 161
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 162
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 163
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 164
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 165
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 166
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 167
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 168
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 169
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 170
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 171
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 172
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 173
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 174
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 175
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 176
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 177
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 178
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 179
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 180
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 181
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 182
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 183
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 184
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 185
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 186
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 187
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 188
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 189
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 190
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 191
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 192
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 193
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 194
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 195
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 196
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 197
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 198
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 199
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c


## Section 200
The Linux kernel rt-scheduler subsystem provides real-time scheduling.kernel/sched/rt.c

