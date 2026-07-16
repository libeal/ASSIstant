"""Timeline views backed exclusively by persisted protocol turns.

The audit log is an evidence stream, not a business-state database.  This
module deliberately contains no audit-event reconstruction logic: callers
either provide immutable turns written from ``protocol.sh`` results or receive
an explicit unavailable response for legacy sessions.
"""


LEGACY_TIMELINE_REASON = "legacy_session_no_persisted_turns"


class TimelineDataError(ValueError):
    """Raised when persisted protocol turns violate the domain contract."""


def timeline_from_turns(session_id, turns, contract=None):
    """Return the workbench envelope for a session's persisted turns."""

    persisted = [turn for turn in turns if isinstance(turn, dict)]
    if len(persisted) != len(turns):
        raise TimelineDataError("persisted turns must contain only objects")
    if contract is not None:
        for index, turn in enumerate(persisted):
            try:
                contract.validate_turn(turn)
            except (TypeError, ValueError) as exc:
                raise TimelineDataError(f"invalid persisted turn {index + 1}: {exc}") from exc
    last_turn = persisted[-1] if persisted else {}
    last_result = last_turn.get("result")
    if not isinstance(last_result, dict):
        last_result = {}
    envelope = {
        "ok": True,
        "status": last_result.get("status") or last_turn.get("status") or "restored",
        "source": "persisted",
        "session_id": str(session_id or ""),
        "input": str(last_turn.get("input") or last_result.get("input") or ""),
        "response": last_result.get("response")
        if isinstance(last_result.get("response"), dict)
        else {},
        "timeline": last_result.get("timeline")
        if isinstance(last_result.get("timeline"), list)
        else [],
        "approval_card": last_result.get("approval_card"),
        "output_blocks": last_result.get("output_blocks")
        if isinstance(last_result.get("output_blocks"), list)
        else [],
        "turns": persisted,
    }
    if contract is not None:
        envelope.update(contract.protocol_metadata())
    return envelope


def legacy_timeline_unavailable(session_id):
    """Describe a legacy audit session without inventing business state."""

    return {
        "web_timeline": None,
        "timeline_unavailable_reason": LEGACY_TIMELINE_REASON,
        "timeline_session_id": str(session_id or ""),
    }


__all__ = [
    "LEGACY_TIMELINE_REASON",
    "TimelineDataError",
    "legacy_timeline_unavailable",
    "timeline_from_turns",
]
