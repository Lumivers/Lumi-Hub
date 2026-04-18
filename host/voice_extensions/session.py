from __future__ import annotations

import asyncio


class SpeechSessionController:
    def __init__(self) -> None:
        self._active_turn: dict[str, str] = {}
        self._cancelled_turns: set[tuple[str, str]] = set()
        self._lock = asyncio.Lock()

    async def activate_turn(self, ws_session_id: str, turn_id: str) -> str | None:
        async with self._lock:
            previous_turn = self._active_turn.get(ws_session_id)
            self._active_turn[ws_session_id] = turn_id
            if previous_turn and previous_turn != turn_id:
                self._cancelled_turns.add((ws_session_id, previous_turn))
                return previous_turn
            return None

    async def cancel_turn(self, ws_session_id: str, turn_id: str) -> None:
        async with self._lock:
            self._cancelled_turns.add((ws_session_id, turn_id))
            if self._active_turn.get(ws_session_id) == turn_id:
                self._active_turn.pop(ws_session_id, None)

    async def cancel_active_turn(self, ws_session_id: str) -> str | None:
        async with self._lock:
            turn_id = self._active_turn.pop(ws_session_id, None)
            if turn_id:
                self._cancelled_turns.add((ws_session_id, turn_id))
            return turn_id

    async def get_active_turn(self, ws_session_id: str) -> str | None:
        async with self._lock:
            return self._active_turn.get(ws_session_id)

    async def is_active(self, ws_session_id: str, turn_id: str) -> bool:
        async with self._lock:
            if (ws_session_id, turn_id) in self._cancelled_turns:
                return False
            return self._active_turn.get(ws_session_id) == turn_id

    async def finish_turn(self, ws_session_id: str, turn_id: str) -> None:
        async with self._lock:
            if self._active_turn.get(ws_session_id) == turn_id:
                self._active_turn.pop(ws_session_id, None)
            self._cancelled_turns.discard((ws_session_id, turn_id))

    async def clear_session(self, ws_session_id: str) -> str | None:
        async with self._lock:
            active_turn = self._active_turn.pop(ws_session_id, None)
            self._cancelled_turns = {
                key for key in self._cancelled_turns if key[0] != ws_session_id
            }
            return active_turn
