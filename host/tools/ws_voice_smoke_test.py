from __future__ import annotations

import argparse
import asyncio
import base64
import json
import os
import time
import uuid

import websockets


def build_message(msg_type: str, payload: dict, message_id: str | None = None) -> dict:
    return {
        "message_id": message_id or str(uuid.uuid4())[:8],
        "type": msg_type,
        "source": "client",
        "target": "host",
        "timestamp": int(time.time() * 1000),
        "payload": payload,
    }


async def recv_json(ws: websockets.WebSocketClientProtocol, timeout: float = 20.0) -> dict:
    raw = await asyncio.wait_for(ws.recv(), timeout=timeout)
    data = json.loads(raw)
    return data


async def wait_for_type(
    ws: websockets.WebSocketClientProtocol,
    expected_types: set[str],
    timeout: float = 30.0,
) -> dict:
    deadline = time.time() + timeout
    while True:
        remain = deadline - time.time()
        if remain <= 0:
            raise TimeoutError(f"Timeout waiting for types: {sorted(expected_types)}")
        msg = await recv_json(ws, timeout=min(10.0, remain))
        msg_type = msg.get("type", "")
        print(f"[RECV] {msg_type} -> {json.dumps(msg.get('payload', {}), ensure_ascii=False)}")
        if msg_type in expected_types:
            return msg


async def ensure_connected(ws: websockets.WebSocketClientProtocol, access_key: str) -> None:
    connect_msg = build_message("CONNECT", {"client": "unity-smoke", "access_key": access_key})
    await ws.send(json.dumps(connect_msg, ensure_ascii=False))
    msg = await wait_for_type(ws, {"CONNECT", "ERROR_ALERT"}, timeout=15)
    if msg.get("type") != "CONNECT":
        raise RuntimeError(f"CONNECT failed: {msg}")


async def ensure_login(
    ws: websockets.WebSocketClientProtocol,
    username: str,
    password: str,
    auto_register: bool,
) -> None:
    login_msg = build_message("AUTH_LOGIN", {"username": username, "password": password})
    await ws.send(json.dumps(login_msg, ensure_ascii=False))
    auth_resp = await wait_for_type(ws, {"AUTH_RESPONSE", "ERROR_ALERT"}, timeout=20)

    if auth_resp.get("type") == "AUTH_RESPONSE" and auth_resp.get("payload", {}).get("status") == "success":
        return

    if not auto_register:
        raise RuntimeError(f"AUTH_LOGIN failed: {auth_resp}")

    register_msg = build_message("AUTH_REGISTER", {"username": username, "password": password})
    await ws.send(json.dumps(register_msg, ensure_ascii=False))
    register_resp = await wait_for_type(ws, {"AUTH_RESPONSE", "ERROR_ALERT"}, timeout=20)
    if register_resp.get("type") != "AUTH_RESPONSE" or register_resp.get("payload", {}).get("status") != "success":
        raise RuntimeError(f"AUTH_REGISTER failed: {register_resp}")


async def run_smoke_test(args: argparse.Namespace) -> int:
    chunk_count = 0
    chunk_bytes = 0
    tts_started = False
    tts_ended = False
    turn_format = "mp3"
    chunks_by_seq: dict[int, bytes] = {}

    async with websockets.connect(args.ws_url) as ws:
        await ensure_connected(ws, args.access_key)
        await ensure_login(ws, args.username, args.password, args.auto_register)

        if args.api_key or args.voice_id:
            cfg_msg = build_message(
                "VOICE_CONFIG_SET",
                {
                    "config": {
                        "provider": args.provider,
                        "voice_id": args.voice_id,
                        "api_key": args.api_key,
                        "clear_api_key": False,
                    }
                },
            )
            print("[SEND] VOICE_CONFIG_SET")
            await ws.send(json.dumps(cfg_msg, ensure_ascii=False))
            try:
                cfg_resp = await wait_for_type(ws, {"VOICE_CONFIG_SET_RESPONSE", "ERROR_ALERT"}, timeout=20)
            except TimeoutError as exc:
                raise RuntimeError(
                    "VOICE_CONFIG_SET timed out. Current host likely does not support this message type; "
                    "restart host with the latest Lumi-Hub adapter code."
                ) from exc
            if cfg_resp.get("type") != "VOICE_CONFIG_SET_RESPONSE":
                raise RuntimeError(f"VOICE_CONFIG_SET failed: {cfg_resp}")
            if cfg_resp.get("payload", {}).get("status") != "success":
                raise RuntimeError(f"VOICE_CONFIG_SET failed: {cfg_resp}")

        turn_id = str(uuid.uuid4())[:8]
        req_payload = {
            "text": args.text,
            "turn_id": turn_id,
            "provider": args.provider,
            "voice_id": args.voice_id,
            "use_ssml": args.use_ssml,
            "auto_style": args.auto_style,
            "style_plan": {
                "rate": args.rate,
                "pitch": args.pitch,
                "volume": args.volume,
                "auto_break": args.auto_break,
                "comma_break_ms": args.comma_break_ms,
                "sentence_break_ms": args.sentence_break_ms,
            },
        }

        if args.custom_ssml:
            req_payload["ssml"] = args.custom_ssml

        req_msg = build_message("VOICE_TTS_REQUEST", req_payload)
        print(f"[SEND] VOICE_TTS_REQUEST turn_id={turn_id}")
        await ws.send(json.dumps(req_msg, ensure_ascii=False))

        interrupt_task = None
        if args.interrupt_after_ms > 0:
            async def _interrupt_later() -> None:
                await asyncio.sleep(args.interrupt_after_ms / 1000.0)
                interrupt_msg = build_message("VOICE_INTERRUPT", {"turn_id": turn_id})
                print(f"[SEND] VOICE_INTERRUPT turn_id={turn_id}")
                await ws.send(json.dumps(interrupt_msg, ensure_ascii=False))

            interrupt_task = asyncio.create_task(_interrupt_later())

        deadline = time.time() + args.timeout_sec
        while time.time() < deadline:
            msg = await recv_json(ws, timeout=5)
            msg_type = msg.get("type", "")
            payload = msg.get("payload", {})

            if msg_type == "TTS_STREAM_START" and payload.get("turn_id") == turn_id:
                tts_started = True
                turn_format = str(payload.get("format") or turn_format or "mp3").strip().lower()
                print(f"[OK] TTS_STREAM_START format={payload.get('format')} sample_rate={payload.get('sample_rate')}")
            elif msg_type == "TTS_STREAM_CHUNK" and payload.get("turn_id") == turn_id:
                b64_text = payload.get("audio_base64", "")
                if not isinstance(b64_text, str) or not b64_text:
                    raise RuntimeError("Received empty audio_base64 in TTS_STREAM_CHUNK")
                try:
                    audio_chunk = base64.b64decode(b64_text)
                except Exception as exc:
                    raise RuntimeError(f"Failed decoding audio chunk: {exc}") from exc

                chunk_count += 1
                chunk_bytes += len(audio_chunk)
                seq = int(payload.get("seq", chunk_count - 1))
                chunks_by_seq[seq] = audio_chunk

                chunk_format = str(payload.get("format") or "").strip().lower()
                if chunk_format:
                    turn_format = chunk_format

                if chunk_count % 10 == 0:
                    print(f"[INFO] chunk_count={chunk_count}")
            elif msg_type == "VOICE_INTERRUPT_ACK" and payload.get("turn_id") == turn_id:
                print(f"[OK] VOICE_INTERRUPT_ACK status={payload.get('status')}")
            elif msg_type == "TTS_STREAM_END" and payload.get("turn_id") == turn_id:
                tts_ended = True
                print(
                    f"[OK] TTS_STREAM_END status={payload.get('status')} seq_count={payload.get('seq_count')} detail={payload.get('detail')}"
                )
                break
            elif msg_type == "ERROR_ALERT":
                raise RuntimeError(f"ERROR_ALERT: {payload}")

        if interrupt_task and not interrupt_task.done():
            interrupt_task.cancel()

        if not tts_started:
            raise RuntimeError("Did not receive TTS_STREAM_START")
        if not tts_ended:
            raise RuntimeError("Did not receive TTS_STREAM_END before timeout")

    saved_path = ""
    if args.save_audio:
        if not chunks_by_seq:
            raise RuntimeError("No audio chunks received; cannot save output file")

        safe_ext = turn_format if turn_format in {"mp3", "wav", "ogg"} else "mp3"
        if args.output_file:
            output_path = args.output_file
            root, ext = os.path.splitext(output_path)
            if not ext:
                output_path = f"{root}.{safe_ext}"
        else:
            os.makedirs(args.output_dir, exist_ok=True)
            output_path = os.path.join(args.output_dir, f"tts_{turn_id}.{safe_ext}")

        output_parent = os.path.dirname(output_path)
        if output_parent:
            os.makedirs(output_parent, exist_ok=True)

        with open(output_path, "wb") as f:
            for seq in sorted(chunks_by_seq.keys()):
                f.write(chunks_by_seq[seq])

        saved_path = os.path.abspath(output_path)
        print(f"[SAVE] audio_file={saved_path}")

    print(f"[DONE] chunks={chunk_count}, audio_bytes={chunk_bytes}")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Lumi-Hub voice WS smoke test")
    parser.add_argument("--ws-url", default="ws://127.0.0.1:8765", help="Host websocket url")
    parser.add_argument("--access-key", default="", help="Optional CONNECT access_key")
    parser.add_argument("--username", default="unity_smoke", help="Auth username")
    parser.add_argument("--password", default="unity_smoke_123", help="Auth password")
    parser.add_argument("--auto-register", action="store_true", help="Auto register if login fails")
    parser.add_argument("--provider", default="dashscope", help="TTS provider name")
    parser.add_argument("--api-key", default="", help="DashScope API key for runtime VOICE_CONFIG_SET")
    parser.add_argument("--voice-id", default="", help="Voice ID used by provider")
    parser.add_argument("--text", default="你好，这是一条语音链路烟雾测试。", help="Text for TTS")
    parser.add_argument("--use-ssml", dest="use_ssml", action="store_true", help="Enable SSML")
    parser.add_argument("--no-ssml", dest="use_ssml", action="store_false", help="Disable SSML")
    parser.add_argument("--auto-style", dest="auto_style", action="store_true", help="Enable auto style plan")
    parser.add_argument("--no-auto-style", dest="auto_style", action="store_false", help="Disable auto style plan")
    parser.add_argument("--rate", type=float, default=1.0)
    parser.add_argument("--pitch", type=float, default=1.0)
    parser.add_argument("--volume", type=int, default=50)
    parser.add_argument("--auto-break", dest="auto_break", action="store_true")
    parser.add_argument("--no-auto-break", dest="auto_break", action="store_false")
    parser.add_argument("--comma-break-ms", type=int, default=120)
    parser.add_argument("--sentence-break-ms", type=int, default=220)
    parser.add_argument("--custom-ssml", default="", help="Custom SSML text")
    parser.add_argument("--interrupt-after-ms", type=int, default=0, help="Send interrupt after N ms")
    parser.add_argument("--timeout-sec", type=int, default=60, help="Overall timeout seconds")
    parser.add_argument("--save-audio", dest="save_audio", action="store_true", help="Save merged TTS audio to file")
    parser.add_argument("--no-save-audio", dest="save_audio", action="store_false", help="Do not save TTS audio file")
    parser.add_argument("--output-dir", default="host/tools/output_audio", help="Output directory when --output-file is not set")
    parser.add_argument("--output-file", default="", help="Output audio file path, extension optional")
    parser.set_defaults(use_ssml=True, auto_style=True, auto_break=True)
    parser.set_defaults(save_audio=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        return asyncio.run(run_smoke_test(args))
    except Exception as exc:
        print(f"[FAIL] {type(exc).__name__}: {exc!r}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
