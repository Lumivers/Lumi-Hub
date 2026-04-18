from __future__ import annotations

from html import escape

from .base import SpeechStylePlan


def _clamp_float(value: object, min_value: float, max_value: float, fallback: float) -> float:
    try:
        numeric = float(value)
    except (TypeError, ValueError):
        return fallback
    return max(min_value, min(max_value, numeric))


def _clamp_int(value: object, min_value: int, max_value: int, fallback: int) -> int:
    try:
        numeric = int(value)
    except (TypeError, ValueError):
        return fallback
    return max(min_value, min(max_value, numeric))


def _to_bool(value: object, fallback: bool) -> bool:
    if value is None:
        return fallback
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in ("1", "true", "yes", "on")
    return bool(value)


def _inject_auto_breaks(text: str, comma_break_ms: int, sentence_break_ms: int) -> str:
    if not text:
        return ""

    out: list[str] = []
    for ch in text:
        out.append(escape(ch, quote=False))
        if ch in (",", "，", "、", ";", "；", ":", "："):
            out.append(f'<break time="{comma_break_ms}ms"/>')
        elif ch in (".", "。", "!", "！", "?", "？"):
            out.append(f'<break time="{sentence_break_ms}ms"/>')
        elif ch == "\n":
            out.append(f'<break time="{sentence_break_ms}ms"/>')

    return "".join(out)


def build_style_plan(raw: dict | None) -> SpeechStylePlan:
    """将前端原始 style_plan 归一化为受控范围参数。"""
    raw = raw or {}
    return SpeechStylePlan(
        rate=_clamp_float(raw.get("rate", raw.get("speech_rate", 1.0)), 0.5, 2.0, 1.0),
        pitch=_clamp_float(raw.get("pitch", raw.get("pitch_rate", 1.0)), 0.5, 2.0, 1.0),
        volume=_clamp_int(raw.get("volume", 50), 0, 100, 50),
        effect=str(raw.get("effect", "") or "").strip(),
        effect_value=str(raw.get("effect_value", "") or "").strip(),
        leading_break_ms=_clamp_int(raw.get("leading_break_ms", 0), 0, 10000, 0),
        trailing_break_ms=_clamp_int(raw.get("trailing_break_ms", 0), 0, 10000, 0),
        auto_break=_to_bool(raw.get("auto_break", False), False),
        comma_break_ms=_clamp_int(raw.get("comma_break_ms", 120), 50, 10000, 120),
        sentence_break_ms=_clamp_int(raw.get("sentence_break_ms", 220), 50, 10000, 220),
        say_as=[item for item in raw.get("say_as", []) if isinstance(item, dict)],
        phoneme=[item for item in raw.get("phoneme", []) if isinstance(item, dict)],
    )


def compile_ssml(text: str, style_plan: SpeechStylePlan | None = None, voice_id: str = "") -> str:
    """将纯文本与风格参数编译成 DashScope 可消费的 SSML。"""
    style_plan = style_plan or SpeechStylePlan()
    attrs: list[str] = [
        f'rate="{style_plan.rate:g}"',
        f'pitch="{style_plan.pitch:g}"',
        f'volume="{style_plan.volume}"',
    ]

    if voice_id:
        attrs.append(f'voice="{escape(voice_id, quote=True)}"')
    if style_plan.effect:
        attrs.append(f'effect="{escape(style_plan.effect, quote=True)}"')
    if style_plan.effect_value:
        attrs.append(f'effectValue="{escape(style_plan.effect_value, quote=True)}"')

    # auto_break 开启时按标点插入 break 标签。
    if style_plan.auto_break:
        escaped_text = _inject_auto_breaks(text or "", style_plan.comma_break_ms, style_plan.sentence_break_ms)
    else:
        escaped_text = escape(text or "", quote=False)
    if style_plan.leading_break_ms > 0:
        escaped_text = f'<break time="{style_plan.leading_break_ms}ms"/>{escaped_text}'
    if style_plan.trailing_break_ms > 0:
        escaped_text = f'{escaped_text}<break time="{style_plan.trailing_break_ms}ms"/>'

    attrs_text = " ".join(attrs)
    return f"<speak {attrs_text}>{escaped_text}</speak>"
