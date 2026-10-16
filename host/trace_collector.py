"""
Lumi-Hub 2.0 — Agent 执行过程追踪器 (Step Trace Collector)
参考现代 Harness 规范，采集单次对话内每一步 (Step) 的生命周期、耗时、工具 I/O 与执行状态。
用于向前端实时推流，并在调试时提供可观测性。
"""
import time
import json
from typing import Any, Optional
from dataclasses import dataclass, field, asdict


@dataclass
class StepTrace:
    step_id: int
    tool_name: str
    tool_args: dict = field(default_factory=dict)
    start_time: float = field(default_factory=time.time)
    end_time: Optional[float] = None
    duration_ms: int = 0
    status: str = "running"  # "running", "success", "error", "auth_waiting"
    exit_code: Optional[int] = None
    output_summary: str = ""
    error_message: Optional[str] = None

    def finish(self, success: bool, output: str, exit_code: Optional[int] = None, error: Optional[str] = None):
        self.end_time = time.time()
        self.duration_ms = int((self.end_time - self.start_time) * 1000)
        self.status = "success" if success else "error"
        self.exit_code = exit_code
        self.error_message = error
        
        # 裁剪输出摘要以避免 Trace 消息过重 (保留前 300 字符)
        clean_out = output.strip() if output else ""
        if len(clean_out) > 300:
            self.output_summary = clean_out[:300] + f"... (截断，共 {len(clean_out)} 字符)"
        else:
            self.output_summary = clean_out

    def to_dict(self) -> dict:
        return {
            "step_id": self.step_id,
            "tool_name": self.tool_name,
            "tool_args": self.tool_args,
            "duration_ms": self.duration_ms,
            "status": self.status,
            "exit_code": self.exit_code,
            "output_summary": self.output_summary,
            "error_message": self.error_message,
        }


class TraceCollector:
    """会话级 Trace 收集器。"""

    def __init__(self, session_id: str, msg_id: str):
        self.session_id = session_id
        self.msg_id = msg_id
        self.steps: list[StepTrace] = []
        self._current_step_id = 0

    def start_step(self, tool_name: str, tool_args: dict) -> StepTrace:
        self._current_step_id += 1
        step = StepTrace(
            step_id=self._current_step_id,
            tool_name=tool_name,
            tool_args=tool_args,
        )
        self.steps.append(step)
        return step

    def get_latest_step(self) -> Optional[StepTrace]:
        return self.steps[-1] if self.steps else None

    def export_summary(self) -> dict:
        total_duration = sum(s.duration_ms for s in self.steps)
        return {
            "session_id": self.session_id,
            "msg_id": self.msg_id,
            "step_count": len(self.steps),
            "total_tool_duration_ms": total_duration,
            "steps": [s.to_dict() for s in self.steps],
        }
