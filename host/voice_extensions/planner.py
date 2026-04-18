from __future__ import annotations

import hashlib

from .base import SpeechStylePlan


def _hash_ratio(text: str, salt: str) -> float:
    digest = hashlib.sha1(f"{salt}:{text}".encode("utf-8")).digest()
    return digest[0] / 255.0


def _clamp(value: float, min_value: float, max_value: float) -> float:
    return max(min_value, min(max_value, value))


def plan_style_for_text(text: str) -> SpeechStylePlan:
    """根据文本内容生成稳定且可复现的风格参数。"""
    normalized = (text or "").strip()
    if not normalized:
        return SpeechStylePlan()

    # 保持确定性抖动：同一文本重复生成时风格一致。
    rate_jitter = (_hash_ratio(normalized, "rate") - 0.5) * 0.08
    pitch_jitter = (_hash_ratio(normalized, "pitch") - 0.5) * 0.10
    volume_jitter = int((_hash_ratio(normalized, "volume") - 0.5) * 6)

    base_rate = 1.0 + rate_jitter
    base_pitch = 1.0 + pitch_jitter
    base_volume = 52 + volume_jitter

    text_len = len(normalized)
    if text_len > 100:
        base_rate -= 0.03
    if text_len > 180:
        base_rate -= 0.03

    if "?" in normalized or "？" in normalized:
        base_pitch += 0.05
    if "!" in normalized or "！" in normalized:
        base_rate += 0.04
        base_volume += 3

    leading_break_ms = 0
    trailing_break_ms = 120
    if normalized.endswith(("。", ".", "!", "！", "?", "？")):
        trailing_break_ms = 220

    if "……" in normalized or "..." in normalized:
        trailing_break_ms = max(trailing_break_ms, 280)

    return SpeechStylePlan(
        rate=round(_clamp(base_rate, 0.88, 1.12), 3),
        pitch=round(_clamp(base_pitch, 0.9, 1.12), 3),
        volume=max(42, min(66, base_volume)),
        leading_break_ms=leading_break_ms,
        trailing_break_ms=trailing_break_ms,
        auto_break=True,
        comma_break_ms=120,
        sentence_break_ms=220,
    )
