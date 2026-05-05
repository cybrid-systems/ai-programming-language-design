#!/usr/bin/env python3
"""
OceanBase 自适应调参脚本 — 动态调节 freeze_trigger_percentage /
writing_throttling_trigger_percentage / memstore_limit_percentage

原理:
  根据 memstore 写入速率和 freeze 耗时，动态计算安全间隙，
  提前触发 freeze 避免写限流，最大化吞吐。

适用于:
  - 高 QPS 写入 (读:写 ≈ 7:3)
  - 单租户内存受限 (20~40GB)
  - CPU 打满场景
  - OB 4.2.x

Author: Ani
"""

import os
import sys
import time
import json
import argparse
import logging
import subprocess
import re
from datetime import datetime
from typing import Optional

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("adaptive_tuner")


# ─── OceanBase 连接 ──────────────────────────────────────────────

class OBClient:
    """通过 mysql 命令行连接 OceanBase"""

    def __init__(self, host: str = "127.0.0.1", port: int = 2881,
                 user: str = "root@sys", password: str = "",
                 database: str = "oceanbase"):
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database

    def _build_cmd(self, sql: str) -> list[str]:
        base = [
            "mysql", "-h", self.host, "-P", str(self.port),
            "-u", self.user, "-D", self.database, "-N", "-B", "-e",
        ]
        if self.password:
            base.extend(["-p" + self.password])
        base.append(sql)
        return base

    def query(self, sql: str) -> list[dict]:
        """执行 SQL 并返回 [{col: val}, ...]"""
        cmd = self._build_cmd(sql)
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if result.returncode != 0:
            log.warning("SQL failed: %s\nstderr: %s", sql[:80], result.stderr.strip())
            return []

        # 解析 mysql tab-separated output
        rows = []
        for line in result.stdout.strip().split("\n"):
            if not line.strip():
                continue
            parts = line.split("\t")
            # Use column count from first row
            if not hasattr(self, "_col_count"):
                self._col_count = len(parts)
            row = {}
            for i, val in enumerate(parts):
                row[str(i)] = val.strip() if val else None
            rows.append(row)
        return rows

    def execute(self, sql: str) -> bool:
        """执行 DDL/DML"""
        cmd = self._build_cmd(sql)
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            log.warning("Exec failed: %s\nstderr: %s", sql[:80], result.stderr.strip())
            return False
        return True

    def query_one(self, sql: str) -> Optional[dict]:
        rows = self.query(sql)
        return rows[0] if rows else None

    def query_float(self, sql: str, default: float = 0.0) -> float:
        row = self.query_one(sql)
        if row and "0" in row:
            try:
                return float(row["0"])
            except (ValueError, TypeError):
                pass
        return default


# ─── 指标采集 ──────────────────────────────────────────────────

class MetricsCollector:
    """采集调参决策所需的指标"""

    def __init__(self, ob: OBClient, tenant_id: int = 0):
        self.ob = ob
        self.tenant_id = tenant_id
        self.prev_memstore_used = 0.0       # bytes
        self.prev_ts = time.time()
        self.write_rate_bytes_per_sec = 0.0
        self.history_write_rate: list[float] = []  # sliding window of write rates

    def collect(self) -> dict:
        """采集一轮指标，返回诊断字典"""
        metrics = {}
        now = time.time()

        # ── 1. Memstore 使用 ───────────────────────────────────
        rows = self.ob.query(f"""
            SELECT TENANT_ID,
                   ACTIVE_MEMSTORE_USED,
                   TOTAL_MEMSTORE_USED,
                   MEMSTORE_LIMIT,
                   FREEZE_TRIGGER_MEMSTORE_USED,
                   (TOTAL_MEMSTORE_USED / MEMSTORE_LIMIT * 100) as pct
            FROM oceanbase.GV$OB_MEMSTORE
            WHERE TENANT_ID = {self.tenant_id}
               OR TENANT_ID = (SELECT TENANT_ID FROM oceanbase.DBA_OB_TENANTS
                               WHERE TENANT_NAME = 'your_tenant')
            ORDER BY TENANT_ID
        """)
        mem = rows[0] if rows else {}
        metrics["active_memstore"] = float(mem.get("0", 0))
        metrics["total_memstore"] = float(mem.get("2", 0))
        metrics["memstore_limit"] = float(mem.get("3", 0))
        if metrics["memstore_limit"] > 0:
            metrics["memstore_pct"] = (
                metrics["total_memstore"] / metrics["memstore_limit"] * 100
            )
        else:
            metrics["memstore_pct"] = 0

        # ── 2. 写入速率 (通过 memstore 增长估算) ─────────────
        current_used = metrics["total_memstore"]
        elapsed = now - self.prev_ts
        if elapsed > 0 and self.prev_memstore_used > 0:
            delta = current_used - self.prev_memstore_used
            if delta > 0:
                rate = delta / elapsed
            else:
                rate = 0.0
            self.write_rate_bytes_per_sec = rate
            self.history_write_rate.append(rate)
            # 只保留最近 60s 的采样
            window = int(60 / elapsed) if elapsed > 0 else 10
            if len(self.history_write_rate) > max(window, 10):
                self.history_write_rate = self.history_write_rate[-max(window, 10):]
        self.prev_memstore_used = current_used
        self.prev_ts = now

        # 取最近 3 次采样的中位数（平滑突发波动）
        recent = self.history_write_rate[-3:] if len(self.history_write_rate) >= 3 else self.history_write_rate
        metrics["write_rate_bps"] = sorted(recent)[len(recent)//2] if recent else 0.0
        metrics["write_rate_mbps"] = metrics["write_rate_bps"] / 1024 / 1024

        # ── 3. Freeze 信息 ────────────────────────────────────
        freeze_rows = self.ob.query(f"""
            SELECT TENANT_ID, LS_ID, TABLET_ID,
                   FREEZE_TIME, IS_FREEZE, RETCODE
            FROM oceanbase.__all_virtual_freeze_info
            WHERE TENANT_ID = {self.tenant_id}
            ORDER BY FREEZE_TIME DESC LIMIT 5
        """)
        metrics["freeze_info"] = freeze_rows

        # ── 4. 是否正在限流 / 限流计数 ────────────────────────
        throttle_rows = self.ob.query(f"""
            SELECT COUNT(*) as cnt
            FROM oceanbase.GV$OB_SQL_AUDIT
            WHERE request_time > DATE_SUB(NOW(), INTERVAL 30 SECOND)
              AND ret_code = -4038
        """)
        metrics["throttle_count_30s"] = int(throttle_rows[0].get("0", 0)) if throttle_rows else 0

        # ── 5. 当前参数值 ──────────────────────────────────────
        params = self.ob.query("""
            SELECT NAME, VALUE
            FROM oceanbase.__all_tenant_parameter
            WHERE NAME IN (
                'freeze_trigger_percentage',
                'writing_throttling_trigger_percentage',
                'memstore_limit_percentage',
                'cpu_quota_concurrency'
            )
            AND TENANT_ID = %d
        """ % self.tenant_id)
        for p in params:
            metrics[f"param_{p['0'].lower()}"] = float(p["1"]) if p.get("1") else 0

        # ── 6. CPU 使用率 ──────────────────────────────────────
        cpu_rows = self.ob.query("""
            SELECT SVR_IP, CPU_CAPACITY_MAX, CPU_ASSIGNED_MAX,
                   (CPU_ASSIGNED_MAX / GREATEST(CPU_CAPACITY_MAX, 1) * 100) as cpu_pct
            FROM oceanbase.GV$OB_SERVERS
        """)
        metrics["cpu_servers"] = cpu_rows

        metrics["timestamp"] = datetime.now().isoformat()
        return metrics


# ── 自适应调参引擎 ────────────────────────────────────────────────

class AdaptiveTuner:
    """
    自适应调参核心逻辑

    核心思想:
        freeze_trigger = throttling_trigger - headroom_margin

    其中 headroom_margin  =  (write_rate × expected_freeze_duration) / memstore_limit × 100  +  buffer

    CPU 打满时还会调节 cpu_quota_concurrency 来控制系统并发度,
    防止过多请求同时涌入加重写放大。
    """

    def __init__(self, ob: OBClient, tenant_id: int = 0, dry_run: bool = False):
        self.ob = ob
        self.tenant_id = tenant_id
        self.dry_run = dry_run

        # 参数安全边界
        self.MIN_FREEZE_TRIGGER = 30       # 最低 30%，避免过于频繁触发
        self.MAX_FREEZE_TRIGGER = 85       # 最高 85%，留足给 throttling
        self.MIN_THROTTLING = 85           # 最低 85%
        self.MAX_THROTTLING = 100          # 最大 100% (即不限流)
        self.MIN_MEMSTORE_LIMIT = 50       # 最低 50%
        self.MAX_MEMSTORE_LIMIT = 90       # 最高 90%
        self.MIN_CPU_QUOTA_CONCURRENCY = 2
        self.MAX_CPU_QUOTA_CONCURRENCY = 20

        # 自适应状态
        self.freeze_duration_samples: list[float] = []  # freeze 耗时历史 (秒)
        self.estimated_freeze_duration = 60.0           # 初始估计 60s
        self.safety_buffer_pct = 5.0                    # 额外安全缓冲 (%)
        self.cooldown_until = 0.0                       # 调参冷却时间戳
        self.last_adjustments: list[dict] = []          # 最近调整记录

    def _estimate_freeze_duration(self, metrics: dict) -> float:
        """从当前指标估算 freeze 耗时"""
        # 从 freeze_info 推断: 看最近的 freeze 记录间隔
        freeze_rows = metrics.get("freeze_info", [])
        if len(freeze_rows) >= 2:
            try:
                # __all_virtual_freeze_info 中的时间列
                t1 = float(freeze_rows[0].get("3", 0))
                t2 = float(freeze_rows[1].get("3", 0))
                duration = abs(t1 - t2)
                if 2 < duration < 600:  # 合理范围 2s ~ 10min
                    self.freeze_duration_samples.append(duration)
                    if len(self.freeze_duration_samples) > 20:
                        self.freeze_duration_samples = self.freeze_duration_samples[-20:]
                    # 取 P90 避免低估
                    sorted_samples = sorted(self.freeze_duration_samples)
                    p90_idx = int(len(sorted_samples) * 0.9)
                    self.estimated_freeze_duration = sorted_samples[p90_idx]
            except (ValueError, IndexError, TypeError):
                pass

        # 如果 freeze 完成时间 > 预估，则自适应增加预估
        # 用 memstore_pct 的变化推算: 如果 memstore 还在涨，说明 freeze 没追上
        return self.estimated_freeze_duration

    def _calculate_ideal_params(self, metrics: dict) -> dict:
        """计算理想参数值"""
        memstore_limit = metrics.get("memstore_limit", 0)  # bytes
        memstore_pct = metrics.get("memstore_pct", 0)
        write_rate = metrics.get("write_rate_bps", 0)      # bytes/s
        freeze_duration = self._estimate_freeze_duration(metrics)

        # 当前参数
        current_freeze = metrics.get("param_freeze_trigger_percentage", 70)
        current_throttling = metrics.get("param_writing_throttling_trigger_percentage", 90)
        current_memstore_limit = metrics.get("param_memstore_limit_percentage", 60)
        current_cpu_quota = metrics.get("param_cpu_quota_concurrency", 4)

        # 计算需要的安全间隙
        if memstore_limit > 0 and write_rate > 0:
            # 在 freeze 持续期间，会写入多少数据
            write_during_freeze = write_rate * freeze_duration  # bytes
            # 这些数据占 memstore_limit 的百分比
            needed_headroom_pct = (write_during_freeze / memstore_limit * 100) + self.safety_buffer_pct
        else:
            needed_headroom_pct = 10.0  # 缺省 10%

        # 目标: throttling_trigger - freeze_trigger > needed_headroom_pct
        # 调整策略:
        #   - 如果发生过限流 → 优先提高 throttling_trigger
        #   - 如果 memstore 持续高位 (>70%) → 降低 freeze_trigger
        throttle_count = metrics.get("throttle_count_30s", 0)

        # ── 计算建议值 ─────────────────────────────────────
        suggested = {}

        # Throttling: 发生过限流就抬高, 没发生就维持
        if throttle_count > 0:
            new_throttling = min(current_throttling + 3, self.MAX_THROTTLING)
        else:
            new_throttling = current_throttling
        suggested["writing_throttling_trigger_percentage"] = new_throttling

        # Freeze: 确保 freeze_trigger + needed_headroom_pct <= throttling_trigger - 1
        target_freeze = new_throttling - needed_headroom_pct - 1
        target_freeze = max(self.MIN_FREEZE_TRIGGER,
                            min(self.MAX_FREEZE_TRIGGER, target_freeze))

        # 如果当前 memstore 已经 > 45% 但 freeze 还没触发, 说明 trigger 太高
        if memstore_pct > current_freeze - 5 and memstore_pct > 50:
            # 接近或超过 freeze trigger, 尝试降低
            target_freeze = min(target_freeze, current_freeze - 2)
        else:
            # memstore 还低, 可以稍微放松不要过早冻结浪费资源
            target_freeze = max(target_freeze, self.MIN_FREEZE_TRIGGER)

        suggested["freeze_trigger_percentage"] = round(target_freeze, 0)

        # Memstore limit: 根据写占比动态调节
        # 读 70% 写 30% → memstore 需要更多空间
        # 如果不限流但 CPU 打满, 可以考虑给 memstore 更多空间
        cpu_servers = metrics.get("cpu_servers", [])
        cpu_high = False
        for s in cpu_servers:
            pct = float(s.get("3", 0)) if len(s) > 3 else 0
            if pct > 90:
                cpu_high = True
                break

        if cpu_high:
            # CPU 打满: 增大 memstore limit → 减少 freeze 频率 → 减少 compaction CPU 开销
            suggested["memstore_limit_percentage"] = min(
                current_memstore_limit + 2, self.MAX_MEMSTORE_LIMIT
            )
        elif throttle_count > 0:
            # 限流时: 可能 memstore 不够, 适当增加
            suggested["memstore_limit_percentage"] = min(
                current_memstore_limit + 1, self.MAX_MEMSTORE_LIMIT
            )
        else:
            suggested["memstore_limit_percentage"] = current_memstore_limit

        # CPU quota concurrency: CPU 打满时逐步降低, 有空闲时提高
        if cpu_high:
            # CPU 打满 → 降低并发度, 减少争抢
            new_cpu_qc = max(self.MIN_CPU_QUOTA_CONCURRENCY, current_cpu_quota - 1)
        else:
            new_cpu_qc = min(self.MAX_CPU_QUOTA_CONCURRENCY, current_cpu_quota + 1)
        suggested["cpu_quota_concurrency"] = new_cpu_qc

        # 补充诊断信息
        suggested["_diagnostics"] = {
            "memstore_pct": round(memstore_pct, 1),
            "write_rate_mbps": round(write_rate / 1024 / 1024, 2),
            "estimated_freeze_duration": round(freeze_duration, 1),
            "needed_headroom_pct": round(needed_headroom_pct, 1),
            "throttle_count_30s": throttle_count,
            "cpu_high": cpu_high,
        }

        return suggested

    def _apply_params(self, params: dict, metrics: dict):
        """执行参数调整"""
        if self.dry_run:
            log.info("[DRY-RUN] 模拟调整参数:")
            for k, v in params.items():
                if k.startswith("_"):
                    continue
                log.info("  SET %s = %s", k, v)
            return

        for param, value in params.items():
            if param.startswith("_") or value is None:
                continue

            current = metrics.get(f"param_{param.lower()}", None)
            if current is not None and abs(float(value) - float(current)) < 1:
                continue  # 变化太小, 跳过

            sql = (
                f"ALTER SYSTEM SET {param} = {value} "
                f"TENANT = {self.tenant_id};"
            )
            if self.ob.execute(sql):
                log.info("  ✓ SET %s = %s (was: %s)", param, value, current)
            else:
                log.warning("  ✗ SET %s = %s FAILED", param, value)

        # 记录
        record = {
            "time": datetime.now().isoformat(),
            "params": {k: v for k, v in params.items() if not k.startswith("_")},
            "diagnostics": params.get("_diagnostics", {}),
        }
        self.last_adjustments.append(record)
        if len(self.last_adjustments) > 100:
            self.last_adjustments = self.last_adjustments[-100:]

    def _should_skip(self, metrics: dict) -> tuple[bool, str]:
        """判断是否应该跳过本次调参"""
        now = time.time()
        if now < self.cooldown_until:
            remaining = int(self.cooldown_until - now)
            return True, f"冷却中, 剩余 {remaining}s"

        memstore_limit = metrics.get("memstore_limit", 0)
        if memstore_limit == 0:
            return True, "memstore_limit 为 0, 数据不可用"

        return False, ""

    def tick(self, metrics: dict) -> dict:
        """一次调参决策循环, 返回调整结果"""
        skip, reason = self._should_skip(metrics)
        if skip:
            return {"adjusted": False, "reason": reason}

        suggested = self._calculate_ideal_params(metrics)
        freeze_trigger = suggested["freeze_trigger_percentage"]
        throttling = suggested["writing_throttling_trigger_percentage"]

        # 安全校验: freeze_trigger 必须 < throttling
        if freeze_trigger >= throttling - 2:
            freeze_trigger = throttling - 5
            log.warning("freeze_trigger 过高, 强制设为 %d (throttling=%d)",
                        freeze_trigger, throttling)
            suggested["freeze_trigger_percentage"] = freeze_trigger

        # 参数列表 (不含诊断)
        apply_params = {
            k: v for k, v in suggested.items() if not k.startswith("_")
        }

        # 检查是否有实质性变化
        has_change = False
        for k, v in apply_params.items():
            current = metrics.get(f"param_{k.lower()}", None)
            if current is None or abs(float(v) - float(current)) >= 1:
                has_change = True
                break

        if not has_change:
            return {
                "adjusted": False,
                "reason": "参数已接近最优, 无需调整",
                "diagnostics": suggested.get("_diagnostics", {}),
            }

        self._apply_params(apply_params, metrics)

        # 冷却 period: 调整后至少等待 30s
        self.cooldown_until = time.time() + 30

        return {
            "adjusted": True,
            "changes": apply_params,
            "diagnostics": suggested.get("_diagnostics", {}),
        }

    def save_state(self, path: str):
        """保存状态和调整历史"""
        state = {
            "freeze_duration_samples": self.freeze_duration_samples,
            "estimated_freeze_duration": self.estimated_freeze_duration,
            "last_adjustments": self.last_adjustments,
        }
        with open(path, "w") as f:
            json.dump(state, f, indent=2)
        log.info("状态已保存到 %s", path)

    def load_state(self, path: str):
        """加载之前保存的状态"""
        try:
            with open(path) as f:
                state = json.load(f)
            self.freeze_duration_samples = state.get("freeze_duration_samples", [])
            self.estimated_freeze_duration = state.get("estimated_freeze_duration", 60.0)
            self.last_adjustments = state.get("last_adjustments", [])
            log.info("已加载状态: %d 次采样, %d 次调整",
                     len(self.freeze_duration_samples), len(self.last_adjustments))
        except FileNotFoundError:
            log.info("未找到状态文件 %s, 从零开始", path)


# ── 诊断 SQL 工具 ────────────────────────────────────────────────

DIAGNOSTIC_SQLS = {
    "memstore_detail": """
        SELECT TENANT_ID, TABLET_ID,
               ROUND(ACTIVE_MEMSTORE_USED / 1024 / 1024, 1) AS active_mb,
               ROUND(TOTAL_MEMSTORE_USED / 1024 / 1024, 1) AS total_mb,
               ROUND(MEMSTORE_LIMIT / 1024 / 1024, 1) AS limit_mb,
               ROUND(FREEZE_TRIGGER_MEMSTORE_USED / 1024 / 1024, 1) AS freeze_trigger_mb,
               ROUND(ACTIVE_MEMSTORE_USED / MEMSTORE_LIMIT * 100, 1) AS active_pct
        FROM oceanbase.GV$OB_MEMSTORE
        WHERE TENANT_ID = %d
        ORDER BY TOTAL_MEMSTORE_USED DESC;
    """,
    "freeze_history": """
        SELECT TENANT_ID, LS_ID, TABLET_ID,
               FROM_UNIXTIME(FREEZE_TIME / 1000000) AS freeze_at,
               IS_FREEZE, RETCODE
        FROM oceanbase.__all_virtual_freeze_info
        WHERE TENANT_ID = %d
        ORDER BY FREEZE_TIME DESC LIMIT 10;
    """,
    "throttle_recent": """
        SELECT REQUEST_ID, USEC_TO_TIME(request_time) AS req_time,
               SVR_IP, SVR_PORT, RET_CODE, ELAPSED_TIME
        FROM oceanbase.GV$OB_SQL_AUDIT
        WHERE request_time > DATE_SUB(NOW(), INTERVAL 1 MINUTE)
          AND ret_code = -4038
        ORDER BY request_time DESC;
    """,
    "config_current": """
        SELECT NAME, VALUE
        FROM oceanbase.__all_tenant_parameter
        WHERE TENANT_ID = %d
          AND NAME IN ('freeze_trigger_percentage',
                       'writing_throttling_trigger_percentage',
                       'memstore_limit_percentage',
                       'cpu_quota_concurrency',
                       'minor_merge_concurrency',
                       'compaction_memory_limit');
    """,
    "cpu_usage": """
        SELECT SVR_IP, CPU_CAPACITY_MAX, CPU_ASSIGNED_MAX,
               ROUND(CPU_ASSIGNED_MAX / GREATEST(CPU_CAPACITY_MAX, 1) * 100, 1) AS cpu_pct,
               ROUND(MEM_CAPACITY_MAX / 1024 / 1024 / 1024, 1) AS mem_gb,
               ROUND(MEM_ASSIGNED_MAX / 1024 / 1024 / 1024, 1) AS mem_assigned_gb,
               ROUND(MEM_ASSIGNED_MAX / GREATEST(MEM_CAPACITY_MAX, 1) * 100, 1) AS mem_pct
        FROM oceanbase.GV$OB_SERVERS;
    """,
    "top_cpu_sql": """
        SELECT SQL_ID,
               ROUND(AVG(ELAPSED_TIME) / 1000, 1) AS avg_elapsed_ms,
               COUNT(*) AS executions,
               ROUND(SUM(ELAPSED_TIME) / 1000000, 1) AS total_cpu_sec
        FROM oceanbase.GV$OB_SQL_AUDIT
        WHERE request_time > DATE_SUB(NOW(), INTERVAL 1 MINUTE)
          AND TENANT_ID = %d
        GROUP BY SQL_ID
        ORDER BY total_cpu_sec DESC
        LIMIT 10;
    """,
    "merge_progress": """
        SELECT * FROM oceanbase.GV$OB_COMPACTION_PROGRESS
        WHERE STATUS = 'COMPACTING' OR STATUS = 'SCHEDULING';
    """,
    "memstore_throttle": """
        SELECT * FROM oceanbase.__all_virtual_memstore_throttle
        WHERE TENANT_ID = %d;
    """,
}


def run_diagnostics(ob: OBClient, tenant_id: int):
    """打印诊断信息"""
    log.info("╔══════════════════════════════════════════════╗")
    log.info("║          OceanBase 自适应诊断报告              ║")
    log.info("╚══════════════════════════════════════════════╝")

    for name, sql in DIAGNOSTIC_SQLS.items():
        log.info("─── %s ───", name)
        rows = ob.query(sql % tenant_id)
        if not rows:
            log.info("  (empty)")
            continue
        for r in rows[:20]:
            log.info("  %s", json.dumps(r, ensure_ascii=False))
        log.info("")


# ── 后台监护人 ────────────────────────────────────────────────────

class AdaptiveTunerDaemon:
    """
    后台守护进程：每隔 interval 秒采集 + 调参一次

    用法:
        tuner = AdaptiveTunerDaemon(ob, tenant_id=1004, dry_run=True)
        tuner.run(interval=15, max_cycles=0)  # 0 = 无限循环
    """

    def __init__(self, ob: OBClient, tenant_id: int,
                 state_file: str = "/tmp/ob_adaptive_tuner.json",
                 dry_run: bool = False):
        self.ob = ob
        self.tenant_id = tenant_id
        self.state_file = state_file
        self.collector = MetricsCollector(ob, tenant_id)
        self.tuner = AdaptiveTuner(ob, tenant_id, dry_run=dry_run)
        self.running = False

    def run(self, interval: int = 15, max_cycles: int = 0):
        """启动调参循环"""
        self.tuner.load_state(self.state_file)
        self.running = True
        cycle = 0

        log.info("🔄 自适应调参启动 (interval=%ds, max_cycles=%s)",
                 interval, max_cycles if max_cycles > 0 else "∞")

        try:
            while self.running:
                cycle += 1
                if 0 < max_cycles < cycle:
                    log.info("达到最大循环次数 %d, 退出", max_cycles)
                    break

                log.info("─── 周期 #%d ───", cycle)

                # 采集
                metrics = self.collector.collect()

                # 每 10 次完整输出一次诊断
                if cycle % 10 == 0:
                    self._print_status(metrics)

                # 调参
                result = self.tuner.tick(metrics)

                if result.get("adjusted"):
                    diag = result.get("diagnostics", {})
                    log.info("✅ 已调参: freeze=%s → %s",
                             metrics.get("param_freeze_trigger_percentage", "?"),
                             result["changes"].get("freeze_trigger_percentage", "?"))
                    log.info("   write_rate=%.1fMB/s  freeze_dur=%.0fs  headroom=%.1f%%",
                             diag.get("write_rate_mbps", 0),
                             diag.get("estimated_freeze_duration", 0),
                             diag.get("needed_headroom_pct", 0))
                else:
                    log.debug("跳过: %s", result.get("reason", ""))

                # 每轮保存状态
                self.tuner.save_state(self.state_file)

                # 等待
                time.sleep(interval)
        except KeyboardInterrupt:
            log.info("收到中断信号, 退出")
        finally:
            self.tuner.save_state(self.state_file)
            log.info("状态已保存, 调参守护退出")

    def _print_status(self, metrics: dict):
        """打印当前状态摘要"""
        log.info("─" * 50)
        log.info("当前状态:")
        log.info("  Memstore: %.1f%% (%.0fMB / %.0fMB)",
                 metrics.get("memstore_pct", 0),
                 metrics.get("total_memstore", 0) / 1024 / 1024,
                 metrics.get("memstore_limit", 0) / 1024 / 1024)
        log.info("  写入速率: %.1f MB/s", metrics.get("write_rate_mbps", 0))
        log.info("  限流(30s): %d", metrics.get("throttle_count_30s", 0))
        log.info("  参数: freeze_trigger=%s, throttling=%s, memstore_limit=%s, cpu_quota=%s",
                 metrics.get("param_freeze_trigger_percentage", "?"),
                 metrics.get("param_writing_throttling_trigger_percentage", "?"),
                 metrics.get("param_memstore_limit_percentage", "?"),
                 metrics.get("param_cpu_quota_concurrency", "?"))
        log.info("─" * 50)

    def stop(self):
        self.running = False


# ── 命令行入口 ──────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="OceanBase 自适应调参工具",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  # dry-run 模式 (不改参数, 只看建议)
  python3 adaptive_tuner.py --dry-run

  # 正常模式, 连接远程 OB
  python3 adaptive_tuner.py -H 10.0.0.1 -P 2881 -u root@sys -T 1004

  # 仅打印诊断报告
  python3 adaptive_tuner.py --diagnose

  # 后台守护模式, 每 30s 检查一次
  python3 adaptive_tuner.py --daemon --interval 30
        """,
    )
    parser.add_argument("-H", "--host", default="127.0.0.1", help="OB host")
    parser.add_argument("-P", "--port", type=int, default=2881, help="OB MySQL port")
    parser.add_argument("-u", "--user", default="root@sys", help="OB user")
    parser.add_argument("-p", "--password", default="", help="OB password")
    parser.add_argument("-T", "--tenant-id", type=int, default=0,
                        help="Tenant ID (默认: 自动检测)")
    parser.add_argument("--dry-run", action="store_true", help="模拟模式, 不执行修改")
    parser.add_argument("--diagnose", action="store_true", help="仅输出诊断报告")
    parser.add_argument("--daemon", action="store_true", help="后台守护模式")
    parser.add_argument("--interval", type=int, default=15, help="采集间隔 (s)")
    parser.add_argument("--max-cycles", type=int, default=0, help="最大循环次数 (0=无限)")
    parser.add_argument("--state-file", default="/tmp/ob_adaptive_tuner.json",
                        help="状态持久化文件")
    parser.add_argument("-v", "--verbose", action="store_true", help="详细日志")

    args = parser.parse_args()
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    ob = OBClient(host=args.host, port=args.port,
                  user=args.user, password=args.password)

    # 自动检测 tenant_id
    tid = args.tenant_id
    if tid == 0:
        rows = ob.query("""
            SELECT TENANT_ID, TENANT_NAME FROM oceanbase.DBA_OB_TENANTS
            WHERE TENANT_TYPE = 'USER' AND TENANT_ROLE = 'PRIMARY'
            ORDER BY TENANT_ID
        """)
        if rows:
            tid = int(rows[0].get("0", 0))
            log.info("自动检测到租户 ID: %d (%s)", tid, rows[0].get("1", "?"))
        else:
            log.error("未找到租户, 请使用 --tenant-id 指定")
            sys.exit(1)

    # 诊断模式
    if args.diagnose:
        run_diagnostics(ob, tid)
        return

    # 守护模式
    daemon = AdaptiveTunerDaemon(
        ob=ob, tenant_id=tid,
        state_file=args.state_file,
        dry_run=args.dry_run,
    )
    daemon.run(interval=args.interval, max_cycles=args.max_cycles)


if __name__ == "__main__":
    main()
