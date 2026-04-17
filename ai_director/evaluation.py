from __future__ import annotations

import json
from copy import deepcopy
from pathlib import Path
from typing import Any

from ai_director.decision import (
    MAX_SCALE,
    MAX_SKILL_LEVEL,
    MIN_SCALE,
    MIN_SKILL_LEVEL,
    PatchRecommendation,
    clamp_float,
    clamp_int,
    materialize_patch,
    recommend_patch,
)
from ai_director.tuning import resolve_tuning_profile, tuning_profile_summary

EPSILON = 1e-3
DEFAULT_MIN_HUMAN_SNAPSHOTS = 2
DEFAULT_MIN_HUMAN_PRESENCE_SECONDS = 40.0
DEFAULT_MIN_PATCH_EVENTS_FOR_USABLE_LANE = 1
MEANINGFUL_IMBALANCE_MOMENTUM = 4.0
STRONG_IMBALANCE_MOMENTUM = 8.0


def _as_int(payload: dict[str, Any], key: str, default: int = 0) -> int:
    try:
        return int(payload.get(key, default))
    except (TypeError, ValueError):
        return default


def _as_float(payload: dict[str, Any], key: str, default: float = 0.0) -> float:
    try:
        return float(payload.get(key, default))
    except (TypeError, ValueError):
        return default


def _active_balance(telemetry: dict[str, Any]) -> dict[str, Any]:
    value = telemetry.get("active_balance")
    return value if isinstance(value, dict) else {}


def momentum_from_telemetry(telemetry: dict[str, Any]) -> float:
    frag_gap = _as_int(telemetry, "frag_gap_top_human_minus_top_bot", 0)
    human_kpm = _as_int(telemetry, "recent_human_kills_per_minute", 0)
    bot_kpm = _as_int(telemetry, "recent_bot_kills_per_minute", 0)
    return float(frag_gap) + ((human_kpm - bot_kpm) * 0.75)


def load_ndjson(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []

    records: list[dict[str, Any]] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        records.append(json.loads(line))
    return records


def _patch_core_tuple(payload: dict[str, Any]) -> tuple[int, int, float, float]:
    return (
        clamp_int(_as_int(payload, "target_skill_level", 3), MIN_SKILL_LEVEL, MAX_SKILL_LEVEL),
        clamp_int(_as_int(payload, "bot_count_delta", 0), -1, 1),
        round(
            clamp_float(
                _as_float(payload, "pause_frequency_scale", 1.0), MIN_SCALE, MAX_SCALE
            ),
            3,
        ),
        round(
            clamp_float(
                _as_float(payload, "battle_strafe_scale", 1.0), MIN_SCALE, MAX_SCALE
            ),
            3,
        ),
    )


def _recommendation_core_tuple(recommendation: PatchRecommendation) -> tuple[int, int, float, float]:
    clamped = recommendation.clamped()
    return (
        clamped.target_skill_level,
        clamped.bot_count_delta,
        round(clamped.pause_frequency_scale, 3),
        round(clamped.battle_strafe_scale, 3),
    )


def state_matches_recommendation(
    telemetry: dict[str, Any], recommendation: PatchRecommendation
) -> bool:
    active_balance = _active_balance(telemetry)
    current_skill = clamp_int(
        _as_int(telemetry, "current_default_bot_skill_level", 3),
        MIN_SKILL_LEVEL,
        MAX_SKILL_LEVEL,
    )
    current_pause = round(
        clamp_float(
            _as_float(active_balance, "pause_frequency_scale", 1.0), MIN_SCALE, MAX_SCALE
        ),
        3,
    )
    current_battle = round(
        clamp_float(
            _as_float(active_balance, "battle_strafe_scale", 1.0), MIN_SCALE, MAX_SCALE
        ),
        3,
    )
    recommendation_core = _recommendation_core_tuple(recommendation)
    return (
        current_skill == recommendation_core[0]
        and recommendation_core[1] == 0
        and current_pause == recommendation_core[2]
        and current_battle == recommendation_core[3]
    )


def build_patch_event(
    telemetry: dict[str, Any],
    recommendation: PatchRecommendation,
    candidate_patch: dict[str, Any],
    previous_patch: dict[str, Any] | None,
) -> dict[str, Any]:
    emitted = True
    skip_reason = ""
    waiting_for_participants = (
        _as_int(telemetry, "human_player_count", 0) == 0
        or _as_int(telemetry, "bot_count", 0) == 0
    )
    if state_matches_recommendation(telemetry, recommendation) and not (
        previous_patch is None and waiting_for_participants
    ):
        emitted = False
        skip_reason = "state_already_matches"
    elif (
        previous_patch
        and str(previous_patch.get("match_id", "")) == str(candidate_patch.get("match_id", ""))
        and _patch_core_tuple(previous_patch) == _patch_core_tuple(candidate_patch)
    ):
        emitted = False
        skip_reason = "duplicate_recommendation"

    active_balance = _active_balance(telemetry)
    event = {
        "schema_version": 1,
        "event_type": "patch_recommendation",
        "match_id": str(telemetry.get("match_id", "unknown-match")),
        "patch_id": str(candidate_patch.get("patch_id", "")),
        "telemetry_sequence": _as_int(telemetry, "telemetry_sequence", 0),
        "timestamp_utc": str(telemetry.get("timestamp_utc", "")),
        "server_time_seconds": round(
            _as_float(telemetry, "server_time_seconds", 0.0), 2
        ),
        "map_name": str(telemetry.get("map_name", "unknown")),
        "tuning_profile": str(candidate_patch.get("tuning_profile", "")),
        "momentum": round(momentum_from_telemetry(telemetry), 3),
        "current_human_player_count": max(0, _as_int(telemetry, "human_player_count", 0)),
        "current_default_bot_skill_level": clamp_int(
            _as_int(telemetry, "current_default_bot_skill_level", 3),
            MIN_SKILL_LEVEL,
            MAX_SKILL_LEVEL,
        ),
        "current_bot_count": max(0, _as_int(telemetry, "bot_count", 0)),
        "current_pause_frequency_scale": round(
            _as_float(active_balance, "pause_frequency_scale", 1.0), 3
        ),
        "current_battle_strafe_scale": round(
            _as_float(active_balance, "battle_strafe_scale", 1.0), 3
        ),
        "cooldown_seconds": round(_as_float(active_balance, "cooldown_seconds", 30.0), 1),
        "target_skill_level": clamp_int(
            _as_int(candidate_patch, "target_skill_level", 3),
            MIN_SKILL_LEVEL,
            MAX_SKILL_LEVEL,
        ),
        "bot_count_delta": clamp_int(_as_int(candidate_patch, "bot_count_delta", 0), -1, 1),
        "pause_frequency_scale": round(
            clamp_float(
                _as_float(candidate_patch, "pause_frequency_scale", 1.0), MIN_SCALE, MAX_SCALE
            ),
            3,
        ),
        "battle_strafe_scale": round(
            clamp_float(
                _as_float(candidate_patch, "battle_strafe_scale", 1.0), MIN_SCALE, MAX_SCALE
            ),
            3,
        ),
        "reason": str(candidate_patch.get("reason", "No reason provided.")),
        "emitted": emitted,
        "skip_reason": skip_reason,
    }
    return event


def _direction_from_change(
    previous_skill_level: int,
    effective_skill_level: int,
    applied_bot_count_delta: int,
    pause_frequency_scale: float,
    battle_strafe_scale: float,
) -> str:
    if (
        effective_skill_level < previous_skill_level
        or applied_bot_count_delta > 0
        or pause_frequency_scale < 1.0
        or battle_strafe_scale > 1.0
    ):
        return "strengthen"
    if (
        effective_skill_level > previous_skill_level
        or applied_bot_count_delta < 0
        or pause_frequency_scale > 1.0
        or battle_strafe_scale < 1.0
    ):
        return "relax"
    return "hold"


def _emitted_patch_records(patch_records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [record for record in patch_records if bool(record.get("emitted", True))]


def _patch_event_direction(record: dict[str, Any]) -> str:
    current_skill = _as_int(record, "current_default_bot_skill_level", 3)
    target_skill = _as_int(record, "target_skill_level", current_skill)
    current_pause = _as_float(record, "current_pause_frequency_scale", 1.0)
    target_pause = _as_float(record, "pause_frequency_scale", current_pause)
    current_battle = _as_float(record, "current_battle_strafe_scale", 1.0)
    target_battle = _as_float(record, "battle_strafe_scale", current_battle)
    bot_delta = _as_int(record, "bot_count_delta", 0)

    if (
        target_skill < current_skill
        or bot_delta > 0
        or target_pause < current_pause
        or target_battle > current_battle
    ):
        return "strengthen"
    if (
        target_skill > current_skill
        or bot_delta < 0
        or target_pause > current_pause
        or target_battle < current_battle
    ):
        return "relax"
    return "hold"

def _manifest_int(manifest: dict[str, Any] | None, key: str, default: int) -> int:
    return _as_int(manifest or {}, key, default)


def _manifest_float(manifest: dict[str, Any] | None, key: str, default: float) -> float:
    return _as_float(manifest or {}, key, default)


def _manifest_has_key(manifest: dict[str, Any] | None, key: str) -> bool:
    return isinstance(manifest, dict) and key in manifest


def _manifest_tuning_profile(manifest: dict[str, Any] | None) -> dict[str, Any]:
    if isinstance(manifest, dict):
        effective_profile = manifest.get("tuning_profile_effective")
        if isinstance(effective_profile, dict) and effective_profile:
            return resolve_tuning_profile(effective_profile)
        if str(manifest.get("mode", "Unknown")).upper() == "AI":
            return resolve_tuning_profile(manifest.get("tuning_profile", None))
    return resolve_tuning_profile(None)


def _summary_tuning_profile(
    manifest: dict[str, Any] | None,
) -> tuple[str | None, dict[str, Any] | None]:
    if str((manifest or {}).get("mode", "Unknown")).upper() != "AI":
        return (None, None)
    profile = _manifest_tuning_profile(manifest)
    return (str(profile.get("name", "default")), tuning_profile_summary(profile))


def _evaluation_setting(
    manifest: dict[str, Any] | None,
    key: str,
    default: float,
) -> float:
    profile = _manifest_tuning_profile(manifest)
    evaluation = profile.get("evaluation", {})
    return float(evaluation.get(key, default))


def _manifest_or_profile_int(
    manifest: dict[str, Any] | None,
    key: str,
    default: int,
    profile_key: str | None = None,
) -> int:
    if _manifest_has_key(manifest, key):
        return _manifest_int(manifest, key, default)
    resolved_key = profile_key or key
    return int(round(_evaluation_setting(manifest, resolved_key, float(default))))


def _manifest_or_profile_float(
    manifest: dict[str, Any] | None,
    key: str,
    default: float,
    profile_key: str | None = None,
) -> float:
    if _manifest_has_key(manifest, key):
        return _manifest_float(manifest, key, default)
    resolved_key = profile_key or key
    return _evaluation_setting(manifest, resolved_key, default)


def _lane_label(manifest: dict[str, Any] | None) -> str:
    value = str((manifest or {}).get("lane_label", "")).strip()
    return value or "default"


def _average_frag_gap(samples: list[int], *, absolute: bool = False) -> float | None:
    if not samples:
        return None

    values = [abs(int(sample)) if absolute else int(sample) for sample in samples]
    return round(sum(values) / len(values), 2)


def _is_plumbing_healthy(manifest: dict[str, Any] | None) -> bool:
    mode = str((manifest or {}).get("mode", "Unknown")).upper()
    smoke_status = str((manifest or {}).get("smoke_status", ""))

    if smoke_status == "simulated":
        return True

    if mode == "AI":
        return smoke_status == "ai-healthy"
    if mode == "NOAI":
        return smoke_status == "no-ai-healthy"
    return bool((manifest or {}).get("attach_observed", False))


def _record_span_seconds(telemetry_records: list[dict[str, Any]], index: int) -> float:
    record = telemetry_records[index]
    interval_seconds = max(
        1.0, _as_float(_active_balance(record), "interval_seconds", 20.0)
    )
    current_time = _as_float(record, "server_time_seconds", 0.0)
    if index + 1 >= len(telemetry_records):
        return interval_seconds

    next_time = _as_float(
        telemetry_records[index + 1], "server_time_seconds", current_time + interval_seconds
    )
    delta = next_time - current_time
    if delta <= 0.0:
        return interval_seconds
    return min(interval_seconds, delta)


def _latest_telemetry_at_or_before(
    telemetry_records: list[dict[str, Any]], server_time: float
) -> dict[str, Any] | None:
    latest_record: dict[str, Any] | None = None
    for record in telemetry_records:
        record_time = _as_float(record, "server_time_seconds", 0.0)
        if record_time <= server_time + EPSILON:
            latest_record = record
            continue
        break
    return latest_record


def _first_human_observation_after(
    telemetry_records: list[dict[str, Any]], server_time: float
) -> dict[str, Any] | None:
    for record in telemetry_records:
        record_time = _as_float(record, "server_time_seconds", 0.0)
        if record_time <= server_time + EPSILON:
            continue
        if (
            _as_int(record, "human_player_count", 0) > 0
            and _as_int(record, "bot_count", 0) > 0
        ):
            return record
    return None


def _collect_human_signal(
    manifest: dict[str, Any] | None,
    telemetry_records: list[dict[str, Any]],
    patch_records: list[dict[str, Any]],
    apply_records: list[dict[str, Any]],
) -> dict[str, Any]:
    min_human_snapshots = max(
        1,
        _manifest_or_profile_int(
            manifest,
            "min_human_snapshots",
            DEFAULT_MIN_HUMAN_SNAPSHOTS,
        ),
    )
    min_human_presence_seconds = max(
        1.0,
        _manifest_or_profile_float(
            manifest,
            "min_human_presence_seconds",
            DEFAULT_MIN_HUMAN_PRESENCE_SECONDS,
        ),
    )
    min_patch_events_for_usable_lane = max(
        0,
        _manifest_or_profile_int(
            manifest,
            "min_patch_events_for_usable_lane",
            DEFAULT_MIN_PATCH_EVENTS_FOR_USABLE_LANE,
        ),
    )
    meaningful_imbalance_momentum = _manifest_or_profile_float(
        manifest,
        "meaningful_imbalance_momentum",
        MEANINGFUL_IMBALANCE_MOMENTUM,
    )
    strong_imbalance_momentum = _manifest_or_profile_float(
        manifest,
        "strong_imbalance_momentum",
        STRONG_IMBALANCE_MOMENTUM,
    )
    rich_human_snapshot_multiplier = max(
        1,
        _manifest_or_profile_int(
            manifest,
            "rich_human_snapshot_multiplier",
            2,
        ),
    )
    rich_human_snapshot_extra = max(
        0,
        _manifest_or_profile_int(
            manifest,
            "rich_human_snapshot_extra",
            2,
        ),
    )
    rich_human_presence_multiplier = max(
        1.0,
        _manifest_or_profile_float(
            manifest,
            "rich_human_presence_multiplier",
            2.0,
        ),
    )
    rich_human_presence_extra_seconds = max(
        0.0,
        _manifest_or_profile_float(
            manifest,
            "rich_human_presence_extra_seconds",
            40.0,
        ),
    )
    rich_human_min_player_count = max(
        1,
        _manifest_or_profile_int(
            manifest,
            "rich_human_min_player_count",
            2,
        ),
    )

    lane_start_server_time = (
        _as_float(telemetry_records[0], "server_time_seconds", 0.0)
        if telemetry_records
        else 0.0
    )
    human_snapshots_count = 0
    seconds_with_human_presence = 0.0
    max_human_player_count = 0
    first_human_seen_timestamp_utc: str | None = None
    first_human_seen_server_time_seconds: float | None = None
    last_human_seen_timestamp_utc: str | None = None
    last_human_seen_server_time_seconds: float | None = None
    frag_gap_samples_while_humans_present: list[int] = []

    for index, record in enumerate(telemetry_records):
        human_count = max(0, _as_int(record, "human_player_count", 0))
        if human_count <= 0:
            continue

        if first_human_seen_timestamp_utc is None:
            first_human_seen_timestamp_utc = str(record.get("timestamp_utc", ""))
            first_human_seen_server_time_seconds = _as_float(
                record, "server_time_seconds", 0.0
            )

        last_human_seen_timestamp_utc = str(record.get("timestamp_utc", ""))
        last_human_seen_server_time_seconds = _as_float(
            record, "server_time_seconds", 0.0
        )
        human_snapshots_count += 1
        max_human_player_count = max(max_human_player_count, human_count)
        seconds_with_human_presence += _record_span_seconds(telemetry_records, index)

        if _as_int(record, "bot_count", 0) > 0:
            frag_gap_samples_while_humans_present.append(
                _as_int(record, "frag_gap_top_human_minus_top_bot", 0)
            )

    if human_snapshots_count == 0 or seconds_with_human_presence <= 0.0:
        human_signal_verdict = "no-humans"
    elif (
        human_snapshots_count < min_human_snapshots
        or seconds_with_human_presence + EPSILON < min_human_presence_seconds
    ):
        human_signal_verdict = "human-sparse"
    else:
        rich_min_human_snapshots = max(
            min_human_snapshots * rich_human_snapshot_multiplier,
            min_human_snapshots + rich_human_snapshot_extra,
        )
        rich_min_human_presence_seconds = max(
            min_human_presence_seconds * rich_human_presence_multiplier,
            min_human_presence_seconds + rich_human_presence_extra_seconds,
        )
        if (
            human_snapshots_count >= rich_min_human_snapshots
            and seconds_with_human_presence + EPSILON
            >= rich_min_human_presence_seconds
            and max_human_player_count >= rich_human_min_player_count
        ):
            human_signal_verdict = "human-rich"
        else:
            human_signal_verdict = "human-usable"

    meaningful_human_imbalance_records = [
        record
        for record in telemetry_records
        if _as_int(record, "human_player_count", 0) > 0
        and _as_int(record, "bot_count", 0) > 0
        and abs(momentum_from_telemetry(record)) >= meaningful_imbalance_momentum
    ]
    strong_human_imbalance_records = [
        record
        for record in telemetry_records
        if _as_int(record, "human_player_count", 0) > 0
        and _as_int(record, "bot_count", 0) > 0
        and abs(momentum_from_telemetry(record)) >= strong_imbalance_momentum
    ]

    emitted_patches = _emitted_patch_records(patch_records)
    patch_events_while_humans_present = [
        record
        for record in emitted_patches
        if _as_int(record, "current_human_player_count", 0) > 0
        and _as_int(record, "current_bot_count", 0) > 0
    ]
    human_reactive_patch_events = [
        record
        for record in emitted_patches
        if _as_int(record, "current_human_player_count", 0) > 0
        and _as_int(record, "current_bot_count", 0) > 0
        and abs(_as_float(record, "momentum", 0.0)) >= meaningful_imbalance_momentum
        and not str(record.get("reason", "")).lower().startswith(
            "waiting for both humans and bots"
        )
    ]
    human_reactive_patch_ids = {
        str(record.get("patch_id", ""))
        for record in human_reactive_patch_events
        if str(record.get("patch_id", ""))
    }
    human_reactive_apply_records = [
        record
        for record in apply_records
        if str(record.get("patch_id", "")) in human_reactive_patch_ids
    ]
    patch_apply_records_while_humans_present: list[dict[str, Any]] = []
    response_after_patch_observation_window_count = 0
    improved_post_patch_count = 0
    worsened_post_patch_count = 0

    for record in apply_records:
        apply_time = _as_float(record, "server_time_seconds", 0.0)
        current_human_state = _latest_telemetry_at_or_before(telemetry_records, apply_time)
        if current_human_state is None:
            continue
        if (
            _as_int(current_human_state, "human_player_count", 0) <= 0
            or _as_int(current_human_state, "bot_count", 0) <= 0
        ):
            continue

        patch_apply_records_while_humans_present.append(record)
        next_observation = _first_human_observation_after(telemetry_records, apply_time)
        if next_observation is None:
            continue

        response_after_patch_observation_window_count += 1
        before_gap = abs(
            _as_int(current_human_state, "frag_gap_top_human_minus_top_bot", 0)
        )
        after_gap = abs(
            _as_int(next_observation, "frag_gap_top_human_minus_top_bot", 0)
        )
        if after_gap + 1 < before_gap:
            improved_post_patch_count += 1
        elif after_gap > before_gap + 1:
            worsened_post_patch_count += 1

    if human_signal_verdict == "no-humans":
        tuning_signal_usable = False
        blocker_reason = "No human players were observed in telemetry, so the lane is plumbing-healthy at most."
    elif human_signal_verdict == "human-sparse":
        tuning_signal_usable = False
        blocker_reason = (
            "Human presence was too sparse for tuning: "
            f"{human_snapshots_count} human snapshots across "
            f"{round(seconds_with_human_presence, 1)} seconds, "
            f"below the configured minimums of {min_human_snapshots} snapshots and "
            f"{round(min_human_presence_seconds, 1)} seconds."
        )
    else:
        tuning_signal_usable = True
        blocker_reason = ""

    patch_event_requirement_met = (
        len(meaningful_human_imbalance_records) < min_human_snapshots
        or len(human_reactive_patch_events) >= min_patch_events_for_usable_lane
    )
    if improved_post_patch_count > worsened_post_patch_count and improved_post_patch_count > 0:
        post_patch_frag_gap_trend = "improved"
    elif worsened_post_patch_count > improved_post_patch_count and worsened_post_patch_count > 0:
        post_patch_frag_gap_trend = "worsened"
    else:
        post_patch_frag_gap_trend = "inconclusive"

    patching_happened_only_while_humans_absent = bool(emitted_patches) and not bool(
        patch_events_while_humans_present
    )
    lane_ever_became_tuning_usable = tuning_signal_usable
    lane_stayed_sparse_or_insufficient = not lane_ever_became_tuning_usable

    return {
        "min_human_snapshots": min_human_snapshots,
        "min_human_presence_seconds": round(min_human_presence_seconds, 1),
        "min_patch_events_for_usable_lane": min_patch_events_for_usable_lane,
        "meaningful_imbalance_momentum": round(meaningful_imbalance_momentum, 3),
        "strong_imbalance_momentum": round(strong_imbalance_momentum, 3),
        "human_snapshots_count": human_snapshots_count,
        "seconds_with_human_presence": round(seconds_with_human_presence, 1),
        "max_human_player_count": max_human_player_count,
        "first_human_seen_timestamp_utc": first_human_seen_timestamp_utc,
        "first_human_seen_server_time_seconds": first_human_seen_server_time_seconds,
        "first_human_seen_offset_seconds": (
            round(first_human_seen_server_time_seconds - lane_start_server_time, 1)
            if first_human_seen_server_time_seconds is not None
            else None
        ),
        "last_human_seen_timestamp_utc": last_human_seen_timestamp_utc,
        "last_human_seen_server_time_seconds": last_human_seen_server_time_seconds,
        "last_human_seen_offset_seconds": (
            round(last_human_seen_server_time_seconds - lane_start_server_time, 1)
            if last_human_seen_server_time_seconds is not None
            else None
        ),
        "frag_gap_samples_while_humans_present": frag_gap_samples_while_humans_present,
        "human_signal_verdict": human_signal_verdict,
        "tuning_signal_usable": tuning_signal_usable,
        "blocker_reason": blocker_reason,
        "lane_ever_became_tuning_usable": lane_ever_became_tuning_usable,
        "lane_stayed_sparse_or_insufficient": lane_stayed_sparse_or_insufficient,
        "meaningful_human_imbalance_snapshots_count": len(
            meaningful_human_imbalance_records
        ),
        "strong_human_imbalance_snapshots_count": len(strong_human_imbalance_records),
        "rebalance_opportunities_count": len(meaningful_human_imbalance_records),
        "patch_events_while_humans_present_count": len(patch_events_while_humans_present),
        "human_reactive_patch_events": human_reactive_patch_events,
        "human_reactive_patch_events_count": len(human_reactive_patch_events),
        "human_reactive_patch_ids": human_reactive_patch_ids,
        "human_reactive_patch_apply_count": len(human_reactive_apply_records),
        "patch_apply_count_while_humans_present": len(
            patch_apply_records_while_humans_present
        ),
        "response_after_patch_observation_window_count": (
            response_after_patch_observation_window_count
        ),
        "post_patch_frag_gap_trend": post_patch_frag_gap_trend,
        "patching_happened_only_while_humans_absent": (
            patching_happened_only_while_humans_absent
        ),
        "patch_response_to_human_imbalance_observed": bool(
            human_reactive_patch_events or human_reactive_apply_records
        ),
        "patch_event_requirement_met": patch_event_requirement_met,
    }


def _lane_quality_verdict(
    manifest: dict[str, Any] | None, human_signal: dict[str, Any]
) -> str:
    mode = str((manifest or {}).get("mode", "Unknown")).upper()
    smoke_status = str((manifest or {}).get("smoke_status", "")) or "plumbing-unhealthy"

    if not _is_plumbing_healthy(manifest):
        return smoke_status

    verdict_suffix = str(human_signal.get("human_signal_verdict", "no-humans"))
    if mode == "AI":
        return {
            "no-humans": "ai-healthy-no-humans",
            "human-sparse": "ai-healthy-human-sparse",
            "human-usable": "ai-healthy-human-usable",
            "human-rich": "ai-healthy-human-rich",
        }.get(verdict_suffix, "ai-healthy-human-sparse")
    if mode == "NOAI":
        return f"control-baseline-{verdict_suffix}"
    return f"{smoke_status}-{verdict_suffix}"


def _evidence_quality_from_signal(
    manifest: dict[str, Any] | None,
    human_signal: dict[str, Any],
) -> tuple[str, str]:
    mode = str((manifest or {}).get("mode", "Unknown")).upper()

    if not bool(human_signal.get("tuning_signal_usable", False)):
        return (
            "insufficient-data",
            "Human signal never cleared the tuning-usability gate.",
        )
    if mode == "NOAI":
        if human_signal["human_signal_verdict"] == "human-rich":
            return (
                "strong-signal",
                "The control lane captured rich human presence and a strong baseline sample.",
            )
        return (
            "usable-signal",
            "The control lane captured usable human presence and a baseline worth comparing against treatment.",
        )
    if human_signal["rebalance_opportunities_count"] <= 0:
        return (
            "weak-signal",
            "Humans were present, but no meaningful imbalance created a rebalance opportunity.",
        )
    if human_signal["patching_happened_only_while_humans_absent"]:
        return (
            "weak-signal",
            "All emitted patches happened while humans were absent, so treatment evidence stayed weak.",
        )
    if human_signal["response_after_patch_observation_window_count"] <= 0:
        return (
            "weak-signal",
            "No post-patch human observation window was captured after a treatment response.",
        )
    strong_signal_min_post_patch_windows = max(
        1,
        _manifest_or_profile_int(
            manifest,
            "strong_signal_min_post_patch_windows",
            2,
        ),
    )
    strong_signal_requires_human_rich = bool(
        _manifest_or_profile_int(
            manifest,
            "strong_signal_requires_human_rich",
            1,
        )
    )
    if (
        (
            not strong_signal_requires_human_rich
            or human_signal["human_signal_verdict"] == "human-rich"
        )
        and human_signal["response_after_patch_observation_window_count"]
        >= strong_signal_min_post_patch_windows
    ):
        return (
            "strong-signal",
            "Multiple post-patch human observation windows were captured with enough signal to trust the treatment response.",
        )
    return (
        "usable-signal",
        "Human presence and at least one post-patch observation window were captured.",
    )


def _derive_duration_seconds(
    manifest: dict[str, Any] | None, telemetry_records: list[dict[str, Any]]
) -> int:
    duration_seconds = _manifest_int(manifest, "duration_seconds", 0)
    if duration_seconds > 0:
        return duration_seconds
    if len(telemetry_records) >= 2:
        start_time = _as_float(telemetry_records[0], "server_time_seconds", 0.0)
        end_time = _as_float(telemetry_records[-1], "server_time_seconds", start_time)
        return int(round(max(0.0, end_time - start_time)))
    if telemetry_records:
        return int(round(_record_span_seconds(telemetry_records, len(telemetry_records) - 1)))
    return 0


def classify_behavior(
    manifest: dict[str, Any] | None,
    telemetry_records: list[dict[str, Any]],
    patch_records: list[dict[str, Any]],
    apply_records: list[dict[str, Any]],
    human_signal: dict[str, Any],
) -> tuple[str, str]:
    mode = str((manifest or {}).get("mode", "Unknown")).upper()
    if len(telemetry_records) < 2:
        return ("insufficient-data", "Not enough telemetry snapshots were captured.")

    if not _is_plumbing_healthy(manifest):
        return (
            "insufficient-data",
            str((manifest or {}).get("smoke_summary", "Lane plumbing was not healthy.")),
        )

    if not bool(human_signal.get("tuning_signal_usable", False)):
        return ("insufficient-data", str(human_signal.get("blocker_reason", "")))

    human_telemetry_records = [
        record
        for record in telemetry_records
        if _as_int(record, "human_player_count", 0) > 0
        and _as_int(record, "bot_count", 0) > 0
    ]
    momenta = [momentum_from_telemetry(record) for record in human_telemetry_records]
    if not momenta:
        return (
            "insufficient-data",
            "No telemetry snapshots contained both humans and bots at the same time.",
        )

    final_abs_momentum = max(abs(value) for value in momenta[-min(3, len(momenta)) :])
    human_reactive_patch_ids = human_signal["human_reactive_patch_ids"]
    human_reactive_apply_records = [
        record
        for record in apply_records
        if str(record.get("patch_id", "")) in human_reactive_patch_ids
    ]

    apply_directions = [
        str(record.get("direction", "hold"))
        for record in human_reactive_apply_records
        if str(record.get("direction", "hold")) != "hold"
    ]
    event_directions = [
        _patch_event_direction(record)
        for record in human_signal["human_reactive_patch_events"]
        if _patch_event_direction(record) != "hold"
    ]
    oscillation_apply_direction_flips = max(
        1,
        _manifest_or_profile_int(
            manifest,
            "oscillation_apply_direction_flips",
            2,
        ),
    )
    oscillation_event_direction_flips = max(
        1,
        _manifest_or_profile_int(
            manifest,
            "oscillation_event_direction_flips",
            3,
        ),
    )
    underactive_meaningful_imbalance_snapshots = max(
        1,
        _manifest_or_profile_int(
            manifest,
            "underactive_meaningful_imbalance_snapshots",
            2,
        ),
    )
    underactive_strong_imbalance_snapshots = max(
        1,
        _manifest_or_profile_int(
            manifest,
            "underactive_strong_imbalance_snapshots",
            2,
        ),
    )
    strong_imbalance_momentum = _manifest_or_profile_float(
        manifest,
        "strong_imbalance_momentum",
        STRONG_IMBALANCE_MOMENTUM,
    )
    direction_flips = sum(
        1
        for previous, current in zip(apply_directions, apply_directions[1:])
        if previous != current
    )
    event_direction_flips = sum(
        1
        for previous, current in zip(event_directions, event_directions[1:])
        if previous != current
    )

    if (
        direction_flips >= oscillation_apply_direction_flips
        or event_direction_flips >= oscillation_event_direction_flips
    ):
        return (
            "oscillatory",
            "Human-driven balance actions kept reversing direction instead of converging.",
        )

    if mode == "AI":
        if (
            human_signal["meaningful_human_imbalance_snapshots_count"]
            >= underactive_meaningful_imbalance_snapshots
            and human_signal["human_reactive_patch_events_count"]
            < human_signal["min_patch_events_for_usable_lane"]
        ):
            return (
                "underactive",
                "Sustained human-vs-bot imbalance was observed, but the AI lane emitted too few human-reactive patch events.",
        )

        if (
            human_signal["strong_human_imbalance_snapshots_count"]
            >= underactive_strong_imbalance_snapshots
            and human_signal["human_reactive_patch_apply_count"] <= 1
            and final_abs_momentum >= strong_imbalance_momentum
        ):
            return (
                "underactive",
                "Human pressure stayed clearly one-sided and the applied response remained too sparse.",
            )

        return (
            "stable",
            "Human-driven balance changes stayed bounded without oscillatory reversals.",
        )

    if (
        human_signal["strong_human_imbalance_snapshots_count"]
        >= underactive_strong_imbalance_snapshots
        and final_abs_momentum >= strong_imbalance_momentum
    ):
        return (
            "underactive",
            "The control lane stayed imbalanced for the human player across multiple snapshots.",
        )

    return ("stable", "The control lane captured usable human signal without treatment-side oscillation.")


def _build_lane_explanation(
    manifest: dict[str, Any] | None,
    human_signal: dict[str, Any],
    behavior_verdict: str,
    behavior_reason: str,
) -> str:
    mode = str((manifest or {}).get("mode", "Unknown")).upper()
    lane_quality_verdict = _lane_quality_verdict(manifest, human_signal)
    if not _is_plumbing_healthy(manifest):
        return str((manifest or {}).get("smoke_summary", "Lane plumbing was not healthy."))

    if not bool(human_signal.get("tuning_signal_usable", False)):
        timeout_suffix = ""
        if bool((manifest or {}).get("human_join_timed_out", False)):
            timeout_suffix = (
                " The mixed-session wait timed out before the lane became tuning-usable."
            )
        return (
            f"{lane_quality_verdict}: {human_signal.get('blocker_reason', '')}{timeout_suffix}"
        ).strip()

    human_signal_summary = (
        f"{human_signal['human_snapshots_count']} human snapshots over "
        f"{human_signal['seconds_with_human_presence']} seconds"
    )
    if behavior_verdict == "oscillatory":
        return (
            f"{lane_quality_verdict}: {human_signal_summary}, and emitted/applied changes flipped direction too often. "
            f"{behavior_reason}"
        )
    if behavior_verdict == "underactive":
        return (
            f"{lane_quality_verdict}: {human_signal_summary}, with "
            f"{human_signal['human_reactive_patch_events_count']} human-reactive patch events across "
            f"{human_signal['meaningful_human_imbalance_snapshots_count']} meaningful imbalance snapshots. "
            f"{behavior_reason}"
        )
    if mode == "AI" and human_signal["human_reactive_patch_events_count"] > 0:
        return (
            f"{lane_quality_verdict}: {human_signal_summary}, and the AI lane made "
            f"{human_signal['human_reactive_patch_events_count']} bounded human-reactive patch decisions. "
            f"{behavior_reason}"
        )
    return f"{lane_quality_verdict}: {human_signal_summary}. {behavior_reason}"


def analyze_lane(
    manifest: dict[str, Any] | None,
    telemetry_records: list[dict[str, Any]],
    patch_records: list[dict[str, Any]],
    apply_records: list[dict[str, Any]],
) -> dict[str, Any]:
    tuning_profile_name, tuning_profile_effective = _summary_tuning_profile(manifest)
    emitted_patches = _emitted_patch_records(patch_records)
    human_signal = _collect_human_signal(manifest, telemetry_records, patch_records, apply_records)

    unique_skill_targets = sorted(
        {
            clamp_int(_as_int(record, "target_skill_level", 3), MIN_SKILL_LEVEL, MAX_SKILL_LEVEL)
            for record in emitted_patches
        }
    )
    unique_bot_count_deltas = sorted(
        {clamp_int(_as_int(record, "bot_count_delta", 0), -1, 1) for record in emitted_patches}
    )

    patch_bounds_respected = all(
        MIN_SKILL_LEVEL <= _as_int(record, "target_skill_level", 3) <= MAX_SKILL_LEVEL
        and -1 <= _as_int(record, "bot_count_delta", 0) <= 1
        and MIN_SCALE <= round(_as_float(record, "pause_frequency_scale", 1.0), 3) <= MAX_SCALE
        and MIN_SCALE <= round(_as_float(record, "battle_strafe_scale", 1.0), 3) <= MAX_SCALE
        for record in emitted_patches
    )
    skill_step_budget_respected = all(
        abs(
            _as_int(record, "effective_default_bot_skill_level", 0)
            - _as_int(record, "previous_default_bot_skill_level", 0)
        )
        <= 1
        for record in apply_records
    )
    bot_delta_budget_respected = all(
        abs(_as_int(record, "applied_bot_count_delta", 0)) <= 1 for record in apply_records
    )
    cooldown_respected = True
    for previous, current in zip(apply_records, apply_records[1:]):
        delta = _as_float(current, "server_time_seconds", 0.0) - _as_float(
            previous, "server_time_seconds", 0.0
        )
        if delta + EPSILON < _as_float(current, "cooldown_seconds", 0.0):
            cooldown_respected = False
            break

    behavior_verdict, behavior_reason = classify_behavior(
        manifest,
        telemetry_records,
        patch_records,
        apply_records,
        human_signal,
    )
    lane_quality_verdict = _lane_quality_verdict(manifest, human_signal)
    evidence_quality, evidence_quality_reason = _evidence_quality_from_signal(
        manifest,
        human_signal,
    )
    explanation = _build_lane_explanation(
        manifest,
        human_signal,
        behavior_verdict,
        behavior_reason,
    )

    return {
        "schema_version": 2,
        "prompt_id": str((manifest or {}).get("prompt_id", "")),
        "mode": str((manifest or {}).get("mode", "Unknown")),
        "lane_label": _lane_label(manifest),
        "map": str((manifest or {}).get("map", "unknown")),
        "tuning_profile": tuning_profile_name,
        "tuning_profile_effective": tuning_profile_effective,
        "bot_count": _as_int(manifest or {}, "bot_count", 0),
        "bot_skill": _as_int(manifest or {}, "bot_skill", 0),
        "requested_duration_seconds": _as_int(manifest or {}, "requested_duration_seconds", 0),
        "duration_seconds": _derive_duration_seconds(manifest, telemetry_records),
        "wait_for_human_join": bool((manifest or {}).get("wait_for_human_join", False)),
        "human_join_grace_seconds": _as_int(manifest or {}, "human_join_grace_seconds", 0),
        "human_join_observed": bool(
            (manifest or {}).get("human_join_observed", False)
            or human_signal["human_snapshots_count"] > 0
        ),
        "human_join_timed_out": bool((manifest or {}).get("human_join_timed_out", False)),
        "bootstrap_log_present": bool((manifest or {}).get("bootstrap_log_present", False)),
        "attach_observed": bool((manifest or {}).get("attach_observed", False)),
        "ai_sidecar_observed": bool((manifest or {}).get("ai_sidecar_observed", False)),
        "smoke_status": str((manifest or {}).get("smoke_status", "")),
        "smoke_summary": str((manifest or {}).get("smoke_summary", "")),
        "match_id": str(
            (manifest or {}).get(
                "match_id",
                telemetry_records[-1].get("match_id", "") if telemetry_records else "",
            )
        ),
        "telemetry_snapshots_count": len(telemetry_records),
        "human_snapshots_count": human_signal["human_snapshots_count"],
        "seconds_with_human_presence": human_signal["seconds_with_human_presence"],
        "max_human_player_count": human_signal["max_human_player_count"],
        "first_human_seen_timestamp_utc": human_signal["first_human_seen_timestamp_utc"],
        "first_human_seen_server_time_seconds": human_signal[
            "first_human_seen_server_time_seconds"
        ],
        "first_human_seen_offset_seconds": human_signal["first_human_seen_offset_seconds"],
        "last_human_seen_timestamp_utc": human_signal["last_human_seen_timestamp_utc"],
        "last_human_seen_server_time_seconds": human_signal[
            "last_human_seen_server_time_seconds"
        ],
        "last_human_seen_offset_seconds": human_signal["last_human_seen_offset_seconds"],
        "frag_gap_samples_while_humans_present": human_signal[
            "frag_gap_samples_while_humans_present"
        ],
        "mean_frag_gap_while_humans_present": _average_frag_gap(
            human_signal["frag_gap_samples_while_humans_present"],
            absolute=False,
        ),
        "mean_abs_frag_gap_while_humans_present": _average_frag_gap(
            human_signal["frag_gap_samples_while_humans_present"],
            absolute=True,
        ),
        "meaningful_human_imbalance_snapshots_count": human_signal[
            "meaningful_human_imbalance_snapshots_count"
        ],
        "strong_human_imbalance_snapshots_count": human_signal[
            "strong_human_imbalance_snapshots_count"
        ],
        "rebalance_opportunities_count": human_signal["rebalance_opportunities_count"],
        "patch_events_count": len(emitted_patches),
        "patch_events_while_humans_present_count": human_signal[
            "patch_events_while_humans_present_count"
        ],
        "patch_apply_count": len(apply_records),
        "patch_apply_count_while_humans_present": human_signal[
            "patch_apply_count_while_humans_present"
        ],
        "human_reactive_patch_events_count": human_signal[
            "human_reactive_patch_events_count"
        ],
        "human_reactive_patch_apply_count": human_signal[
            "human_reactive_patch_apply_count"
        ],
        "response_after_patch_observation_window_count": human_signal[
            "response_after_patch_observation_window_count"
        ],
        "treatment_patched_while_humans_present": (
            human_signal["patch_events_while_humans_present_count"] > 0
        ),
        "meaningful_post_patch_observation_window_exists": (
            human_signal["response_after_patch_observation_window_count"] > 0
        ),
        "post_patch_frag_gap_trend": human_signal["post_patch_frag_gap_trend"],
        "patching_happened_only_while_humans_absent": human_signal[
            "patching_happened_only_while_humans_absent"
        ],
        "patch_response_to_human_imbalance_observed": human_signal[
            "patch_response_to_human_imbalance_observed"
        ],
        "unique_skill_targets_seen": unique_skill_targets,
        "unique_bot_count_deltas_seen": unique_bot_count_deltas,
        "cooldown_constraints_respected": cooldown_respected,
        "boundedness_constraints_respected": (
            patch_bounds_respected and skill_step_budget_respected and bot_delta_budget_respected
        ),
        "skill_step_budget_respected": skill_step_budget_respected,
        "bot_count_delta_budget_respected": bot_delta_budget_respected,
        "min_human_snapshots": human_signal["min_human_snapshots"],
        "min_human_presence_seconds": human_signal["min_human_presence_seconds"],
        "min_patch_events_for_usable_lane": human_signal[
            "min_patch_events_for_usable_lane"
        ],
        "meaningful_imbalance_momentum": human_signal["meaningful_imbalance_momentum"],
        "strong_imbalance_momentum": human_signal["strong_imbalance_momentum"],
        "human_signal_verdict": human_signal["human_signal_verdict"],
        "tuning_signal_usable": human_signal["tuning_signal_usable"],
        "lane_ever_became_tuning_usable": human_signal[
            "lane_ever_became_tuning_usable"
        ],
        "lane_stayed_sparse_or_insufficient": human_signal[
            "lane_stayed_sparse_or_insufficient"
        ],
        "lane_quality_verdict": lane_quality_verdict,
        "evidence_quality": evidence_quality,
        "evidence_quality_reason": evidence_quality_reason,
        "behavior_verdict": behavior_verdict,
        "behavior_reason": behavior_reason,
        "explanation": explanation,
    }


def _treatment_pre_post_trend_classification(treatment: dict[str, Any]) -> str:
    if not bool(treatment.get("tuning_signal_usable", False)):
        return "no-usable-human-signal"
    if bool(treatment.get("patching_happened_only_while_humans_absent", False)):
        return "patch-before-humans-only"
    if _as_int(treatment, "patch_events_while_humans_present_count", 0) <= 0:
        return "no-live-treatment-patch"
    if _as_int(treatment, "response_after_patch_observation_window_count", 0) <= 0:
        return "no-post-patch-window"

    trend = str(treatment.get("post_patch_frag_gap_trend", "inconclusive"))
    return {
        "improved": "pre-post-improved",
        "worsened": "pre-post-worsened",
        "inconclusive": "pre-post-inconclusive",
    }.get(trend, f"pre-post-{trend}")


def _treatment_relative_responsiveness(
    control: dict[str, Any],
    treatment: dict[str, Any],
    control_mean_abs_gap: float | None,
    treatment_mean_abs_gap: float | None,
) -> str:
    human_reactive_patch_events = _as_int(
        treatment, "human_reactive_patch_events_count", 0
    )
    post_patch_windows = _as_int(
        treatment, "response_after_patch_observation_window_count", 0
    )
    treatment_behavior = str(treatment.get("behavior_verdict", "insufficient-data"))

    if bool(treatment.get("patching_happened_only_while_humans_absent", False)):
        return "quieter"
    if human_reactive_patch_events <= 0:
        if _as_int(control, "meaningful_human_imbalance_snapshots_count", 0) > 0:
            return "quieter"
        return "inconclusive"
    if treatment_behavior == "oscillatory":
        return "more-responsive"

    if (
        control_mean_abs_gap is not None
        and treatment_mean_abs_gap is not None
        and abs(float(treatment_mean_abs_gap) - float(control_mean_abs_gap)) <= 1.0
    ):
        return "similar"
    if (
        post_patch_windows > 0
        and str(treatment.get("post_patch_frag_gap_trend", "inconclusive")) == "improved"
    ):
        return "more-responsive"
    if post_patch_windows > 0 and human_reactive_patch_events >= 2:
        return "more-responsive"
    return "inconclusive"


def compare_lane_summaries(
    first_summary: dict[str, Any], second_summary: dict[str, Any]
) -> dict[str, Any]:
    first_mode = str(first_summary.get("mode", "Unknown")).upper()
    second_mode = str(second_summary.get("mode", "Unknown")).upper()

    control = first_summary
    treatment = second_summary
    if first_mode != "NOAI" and second_mode == "NOAI":
        control, treatment = second_summary, first_summary

    control_sidecar_free = not bool(control.get("ai_sidecar_observed", False))
    treatment_sidecar_observed = bool(treatment.get("ai_sidecar_observed", False))
    control_tuning_signal_usable = bool(control.get("tuning_signal_usable", False))
    treatment_tuning_signal_usable = bool(treatment.get("tuning_signal_usable", False))
    control_evidence_quality = str(control.get("evidence_quality", "insufficient-data"))
    treatment_evidence_quality = str(treatment.get("evidence_quality", "insufficient-data"))
    treatment_patched_while_humans_present = bool(
        treatment.get("treatment_patched_while_humans_present", False)
        or _as_int(treatment, "patch_events_while_humans_present_count", 0) > 0
    )
    meaningful_post_patch_observation_window_exists = bool(
        treatment.get("meaningful_post_patch_observation_window_exists", False)
        or _as_int(treatment, "response_after_patch_observation_window_count", 0) > 0
    )
    control_frag_gap_samples = list(control.get("frag_gap_samples_while_humans_present", []))
    treatment_frag_gap_samples = list(
        treatment.get("frag_gap_samples_while_humans_present", [])
    )
    control_mean_abs_gap = _average_frag_gap(control_frag_gap_samples, absolute=True)
    treatment_mean_abs_gap = _average_frag_gap(treatment_frag_gap_samples, absolute=True)
    treatment_pre_post_trend_classification = _treatment_pre_post_trend_classification(
        treatment
    )
    treatment_relative_responsiveness = _treatment_relative_responsiveness(
        control,
        treatment,
        control_mean_abs_gap,
        treatment_mean_abs_gap,
    )

    comparison_verdict = "comparison-insufficient-data"
    comparison_usable = False
    comparison_reason = ""

    if str(control.get("mode", "Unknown")).upper() != "NOAI":
        comparison_reason = "The control lane is not the no-AI baseline."
    elif str(treatment.get("mode", "Unknown")).upper() != "AI":
        comparison_reason = "The treatment lane is not an AI lane."
    elif not control_sidecar_free:
        comparison_reason = "The control lane was not sidecar-free."
    elif not treatment_sidecar_observed:
        comparison_reason = "The treatment lane never observed the AI sidecar."
    elif str(control.get("smoke_status", "")) != "no-ai-healthy":
        comparison_reason = "The control lane was not plumbing-healthy."
    elif str(treatment.get("smoke_status", "")) not in {"ai-healthy", "simulated"}:
        comparison_reason = "The treatment lane was not plumbing-healthy."
    elif not control_tuning_signal_usable and not treatment_tuning_signal_usable:
        comparison_reason = (
            "Neither lane captured enough human signal for a live comparison. "
            f"Control: {control.get('lane_quality_verdict', 'unknown')}. "
            f"Treatment: {treatment.get('lane_quality_verdict', 'unknown')}."
        )
    elif not control_tuning_signal_usable:
        comparison_verdict = "comparison-weak-signal"
        comparison_reason = (
            "Only the treatment lane captured usable human signal. "
            f"The control lane stayed {control.get('lane_quality_verdict', 'unknown')}."
        )
    elif not treatment_tuning_signal_usable:
        comparison_verdict = "comparison-weak-signal"
        comparison_reason = (
            "Only the control lane captured usable human signal. "
            f"The treatment lane stayed {treatment.get('lane_quality_verdict', 'unknown')}."
        )
    elif bool(treatment.get("patching_happened_only_while_humans_absent", False)):
        comparison_verdict = "comparison-weak-signal"
        comparison_reason = (
            "Both lanes captured humans, but treatment patches only happened before humans joined. "
            "That is not grounded live evidence."
        )
    elif not treatment_patched_while_humans_present:
        comparison_verdict = "comparison-weak-signal"
        comparison_reason = (
            "Both lanes were human-usable, but the treatment lane never patched while humans were present."
        )
    elif not meaningful_post_patch_observation_window_exists:
        comparison_verdict = "comparison-weak-signal"
        comparison_reason = (
            "Treatment patched while humans were present, but no post-patch human observation window was captured."
        )
    elif treatment_evidence_quality == "weak-signal":
        comparison_verdict = "comparison-weak-signal"
        comparison_reason = (
            "The treatment lane captured humans, but treatment-response evidence stayed weak. "
            f"Reason: {treatment.get('evidence_quality_reason', '')}"
        )
    elif not bool(treatment.get("boundedness_constraints_respected", False)):
        comparison_reason = "The treatment lane violated boundedness constraints."
    elif not bool(treatment.get("cooldown_constraints_respected", False)):
        comparison_reason = "The treatment lane violated cooldown constraints."
    else:
        comparison_verdict = (
            "comparison-strong-signal"
            if treatment_evidence_quality == "strong-signal"
            and control_evidence_quality in {"usable-signal", "strong-signal"}
            else "comparison-usable"
        )
        comparison_usable = True
        comparison_reason = (
            f"Control lane {control.get('lane_label', 'control')} and treatment lane "
            f"{treatment.get('lane_label', 'treatment')} both captured usable human signal; "
            f"treatment quality was {treatment.get('lane_quality_verdict', 'unknown')} with "
            f"behavior {treatment.get('behavior_verdict', 'insufficient-data')} and "
            f"evidence quality {treatment_evidence_quality}. "
            f"Treatment looked {treatment_relative_responsiveness.replace('-', ' ')} relative to control."
        )

    relative_behavior_discussion_ready = comparison_verdict in {
        "comparison-usable",
        "comparison-strong-signal",
    }
    apparent_benefit_too_weak_to_trust = (
        treatment_relative_responsiveness == "more-responsive"
        and not relative_behavior_discussion_ready
    )

    return {
        "schema_version": 2,
        "control_mode": str(control.get("mode", "Unknown")),
        "control_lane_label": str(control.get("lane_label", "control")),
        "control_tuning_profile": control.get("tuning_profile", None),
        "treatment_mode": str(treatment.get("mode", "Unknown")),
        "treatment_lane_label": str(treatment.get("lane_label", "treatment")),
        "treatment_tuning_profile": treatment.get("tuning_profile", None),
        "control_sidecar_free": control_sidecar_free,
        "treatment_sidecar_observed": treatment_sidecar_observed,
        "control_behavior_verdict": str(control.get("behavior_verdict", "insufficient-data")),
        "treatment_behavior_verdict": str(
            treatment.get("behavior_verdict", "insufficient-data")
        ),
        "control_lane_quality_verdict": str(
            control.get("lane_quality_verdict", "insufficient-data")
        ),
        "treatment_lane_quality_verdict": str(
            treatment.get("lane_quality_verdict", "insufficient-data")
        ),
        "control_evidence_quality": control_evidence_quality,
        "treatment_evidence_quality": treatment_evidence_quality,
        "control_tuning_signal_usable": control_tuning_signal_usable,
        "treatment_tuning_signal_usable": treatment_tuning_signal_usable,
        "control_human_signal_verdict": str(
            control.get("human_signal_verdict", "no-humans")
        ),
        "treatment_human_signal_verdict": str(
            treatment.get("human_signal_verdict", "no-humans")
        ),
        "control_telemetry_snapshots_count": _as_int(
            control, "telemetry_snapshots_count", 0
        ),
        "treatment_telemetry_snapshots_count": _as_int(
            treatment, "telemetry_snapshots_count", 0
        ),
        "control_human_snapshots_count": _as_int(control, "human_snapshots_count", 0),
        "treatment_human_snapshots_count": _as_int(treatment, "human_snapshots_count", 0),
        "control_seconds_with_human_presence": _as_float(
            control, "seconds_with_human_presence", 0.0
        ),
        "treatment_seconds_with_human_presence": _as_float(
            treatment, "seconds_with_human_presence", 0.0
        ),
        "control_patch_apply_count": _as_int(control, "patch_apply_count", 0),
        "treatment_patch_apply_count": _as_int(treatment, "patch_apply_count", 0),
        "control_frag_gap_samples_while_humans_present": control_frag_gap_samples,
        "treatment_frag_gap_samples_while_humans_present": treatment_frag_gap_samples,
        "control_mean_abs_frag_gap_while_humans_present": control_mean_abs_gap,
        "treatment_mean_abs_frag_gap_while_humans_present": treatment_mean_abs_gap,
        "treatment_patched_while_humans_present": treatment_patched_while_humans_present,
        "meaningful_post_patch_observation_window_exists": (
            meaningful_post_patch_observation_window_exists
        ),
        "treatment_pre_post_trend_classification": (
            treatment_pre_post_trend_classification
        ),
        "treatment_relative_to_control": treatment_relative_responsiveness,
        "relative_behavior_discussion_ready": relative_behavior_discussion_ready,
        "apparent_benefit_too_weak_to_trust": apparent_benefit_too_weak_to_trust,
        "treatment_patch_response_to_human_imbalance_observed": bool(
            treatment.get("patch_response_to_human_imbalance_observed", False)
        ),
        "comparison_is_tuning_usable": comparison_usable,
        "comparison_verdict": comparison_verdict,
        "comparison_reason": comparison_reason,
        "comparison_explanation": comparison_reason,
    }


def _build_simulated_telemetry(
    scenario_name: str,
    index: int,
    state: dict[str, Any],
    frame: dict[str, Any],
    map_name: str,
    tuning_profile: dict[str, Any],
) -> dict[str, Any]:
    frag_gap = _as_int(frame, "frag_gap_top_human_minus_top_bot", 0)
    base_top_score = 15
    top_human_frags = base_top_score + max(frag_gap, 0)
    top_bot_frags = base_top_score + max(-frag_gap, 0)
    return {
        "schema_version": 1,
        "match_id": scenario_name,
        "telemetry_sequence": index,
        "timestamp_utc": str(frame.get("timestamp_utc", f"2026-04-17T00:00:{index:02d}Z")),
        "server_time_seconds": round(_as_float(frame, "server_time_seconds", index * 20.0), 2),
        "map_name": str(frame.get("map_name", map_name)),
        "human_player_count": max(0, _as_int(frame, "human_player_count", 2)),
        "bot_count": max(0, int(state["bot_count"])),
        "top_human_frags": top_human_frags,
        "top_human_deaths": max(0, _as_int(frame, "top_human_deaths", 8)),
        "top_bot_frags": top_bot_frags,
        "top_bot_deaths": max(0, _as_int(frame, "top_bot_deaths", 8)),
        "recent_human_kills_per_minute": max(
            0, _as_int(frame, "recent_human_kills_per_minute", 6)
        ),
        "recent_bot_kills_per_minute": max(
            0, _as_int(frame, "recent_bot_kills_per_minute", 6)
        ),
        "frag_gap_top_human_minus_top_bot": frag_gap,
        "current_default_bot_skill_level": int(state["current_default_bot_skill_level"]),
        "active_balance": {
            "pause_frequency_scale": round(float(state["pause_frequency_scale"]), 3),
            "battle_strafe_scale": round(float(state["battle_strafe_scale"]), 3),
            "interval_seconds": round(_as_float(frame, "interval_seconds", 20.0), 1),
            "cooldown_seconds": round(
                _as_float(
                    frame,
                    "cooldown_seconds",
                    float(tuning_profile.get("cooldown_seconds", 30.0)),
                ),
                1,
            ),
            "enabled": _as_int(frame, "enabled", 1),
        },
    }


def simulate_replay(
    scenario_name: str,
    frames: list[dict[str, Any]],
    *,
    tuning_profile: str | dict[str, Any] | None = None,
    initial_skill: int = 3,
    initial_bot_count: int = 4,
    map_name: str = "crossfire",
    lane_label: str = "replay-scenario",
    min_human_snapshots: int | None = None,
    min_human_presence_seconds: float | None = None,
    min_patch_events_for_usable_lane: int | None = None,
) -> dict[str, Any]:
    if not frames:
        raise ValueError("At least one telemetry frame is required.")

    resolved_profile = resolve_tuning_profile(tuning_profile)
    profile_summary = tuning_profile_summary(resolved_profile)
    evaluation_settings = dict(resolved_profile.get("evaluation", {}))
    min_human_snapshots = (
        max(
            1,
            int(
                evaluation_settings.get(
                    "min_human_snapshots", DEFAULT_MIN_HUMAN_SNAPSHOTS
                )
            ),
        )
        if min_human_snapshots is None
        else max(1, int(min_human_snapshots))
    )
    min_human_presence_seconds = (
        max(
            1.0,
            float(
                evaluation_settings.get(
                    "min_human_presence_seconds",
                    DEFAULT_MIN_HUMAN_PRESENCE_SECONDS,
                )
            ),
        )
        if min_human_presence_seconds is None
        else max(1.0, float(min_human_presence_seconds))
    )
    min_patch_events_for_usable_lane = (
        max(
            0,
            int(
                evaluation_settings.get(
                    "min_patch_events_for_usable_lane",
                    DEFAULT_MIN_PATCH_EVENTS_FOR_USABLE_LANE,
                )
            ),
        )
        if min_patch_events_for_usable_lane is None
        else max(0, int(min_patch_events_for_usable_lane))
    )

    state: dict[str, Any] = {
        "current_default_bot_skill_level": clamp_int(
            initial_skill, MIN_SKILL_LEVEL, MAX_SKILL_LEVEL
        ),
        "bot_count": max(1, initial_bot_count),
        "pause_frequency_scale": 1.0,
        "battle_strafe_scale": 1.0,
        "last_apply_time": -9999.0,
        "last_applied_patch_id": "",
    }
    telemetry_records: list[dict[str, Any]] = []
    patch_records: list[dict[str, Any]] = []
    apply_records: list[dict[str, Any]] = []
    pending_patch: dict[str, Any] | None = None

    for index, frame in enumerate(frames, start=1):
        telemetry = _build_simulated_telemetry(
            scenario_name,
            index,
            state,
            frame,
            map_name,
            resolved_profile,
        )
        telemetry_records.append(deepcopy(telemetry))

        cooldown_seconds = _as_float(_active_balance(telemetry), "cooldown_seconds", 30.0)
        server_time = _as_float(telemetry, "server_time_seconds", 0.0)
        if (
            pending_patch
            and pending_patch.get("patch_id", "") != state["last_applied_patch_id"]
            and (server_time - float(state["last_apply_time"])) + EPSILON >= cooldown_seconds
        ):
            previous_skill = int(state["current_default_bot_skill_level"])
            effective_skill = previous_skill
            target_skill = _as_int(pending_patch, "target_skill_level", previous_skill)
            if target_skill < previous_skill:
                effective_skill -= 1
            elif target_skill > previous_skill:
                effective_skill += 1
            effective_skill = clamp_int(
                effective_skill, MIN_SKILL_LEVEL, MAX_SKILL_LEVEL
            )

            applied_bot_delta = 0
            requested_bot_delta = clamp_int(_as_int(pending_patch, "bot_count_delta", 0), -1, 1)
            if requested_bot_delta > 0:
                state["bot_count"] = int(state["bot_count"]) + 1
                applied_bot_delta = 1
            elif requested_bot_delta < 0 and int(state["bot_count"]) > 1:
                state["bot_count"] = int(state["bot_count"]) - 1
                applied_bot_delta = -1

            state["current_default_bot_skill_level"] = effective_skill
            state["pause_frequency_scale"] = round(
                _as_float(pending_patch, "pause_frequency_scale", 1.0), 3
            )
            state["battle_strafe_scale"] = round(
                _as_float(pending_patch, "battle_strafe_scale", 1.0), 3
            )
            state["last_apply_time"] = server_time
            state["last_applied_patch_id"] = str(pending_patch.get("patch_id", ""))

            apply_records.append(
                {
                    "schema_version": 1,
                    "event_type": "patch_applied",
                    "match_id": scenario_name,
                    "patch_id": str(pending_patch.get("patch_id", "")),
                    "telemetry_sequence": _as_int(pending_patch, "telemetry_sequence", index),
                    "timestamp_utc": str(telemetry.get("timestamp_utc", "")),
                    "server_time_seconds": round(server_time, 2),
                    "map_name": str(telemetry.get("map_name", map_name)),
                    "previous_default_bot_skill_level": previous_skill,
                    "effective_default_bot_skill_level": effective_skill,
                    "target_skill_level": clamp_int(
                        _as_int(pending_patch, "target_skill_level", effective_skill),
                        MIN_SKILL_LEVEL,
                        MAX_SKILL_LEVEL,
                    ),
                    "requested_bot_count_delta": requested_bot_delta,
                    "applied_bot_count_delta": applied_bot_delta,
                    "pause_frequency_scale": round(_as_float(pending_patch, "pause_frequency_scale", 1.0), 3),
                    "battle_strafe_scale": round(_as_float(pending_patch, "battle_strafe_scale", 1.0), 3),
                    "cooldown_seconds": round(cooldown_seconds, 1),
                    "direction": _direction_from_change(
                        previous_skill,
                        effective_skill,
                        applied_bot_delta,
                        _as_float(pending_patch, "pause_frequency_scale", 1.0),
                        _as_float(pending_patch, "battle_strafe_scale", 1.0),
                    ),
                    "reason": str(pending_patch.get("reason", "No reason provided.")),
                }
            )

        recommendation = recommend_patch(telemetry, tuning_profile=resolved_profile)
        candidate_patch = materialize_patch(
            telemetry,
            recommendation,
            tuning_profile=resolved_profile,
        )
        patch_event = build_patch_event(telemetry, recommendation, candidate_patch, pending_patch)
        patch_records.append(patch_event)
        if patch_event["emitted"]:
            pending_patch = candidate_patch

    duration_seconds = 0
    if len(telemetry_records) >= 2:
        duration_seconds = int(
            round(
                _as_float(telemetry_records[-1], "server_time_seconds", 0.0)
                - _as_float(telemetry_records[0], "server_time_seconds", 0.0)
            )
        )

    manifest = {
        "prompt_id": "replay-simulated",
        "mode": "AI",
        "lane_label": lane_label,
        "map": map_name,
        "tuning_profile": str(resolved_profile.get("name", "default")),
        "tuning_profile_effective": profile_summary,
        "bot_count": initial_bot_count,
        "bot_skill": initial_skill,
        "requested_duration_seconds": duration_seconds,
        "duration_seconds": duration_seconds,
        "bootstrap_log_present": True,
        "attach_observed": True,
        "ai_sidecar_observed": True,
        "smoke_status": "simulated",
        "smoke_summary": "Deterministic replay scenario.",
        "match_id": scenario_name,
        "min_human_snapshots": min_human_snapshots,
        "min_human_presence_seconds": min_human_presence_seconds,
        "min_patch_events_for_usable_lane": min_patch_events_for_usable_lane,
        "meaningful_imbalance_momentum": float(
            evaluation_settings.get(
                "meaningful_imbalance_momentum", MEANINGFUL_IMBALANCE_MOMENTUM
            )
        ),
        "strong_imbalance_momentum": float(
            evaluation_settings.get(
                "strong_imbalance_momentum", STRONG_IMBALANCE_MOMENTUM
            )
        ),
        "rich_human_snapshot_multiplier": int(
            evaluation_settings.get("rich_human_snapshot_multiplier", 2)
        ),
        "rich_human_snapshot_extra": int(
            evaluation_settings.get("rich_human_snapshot_extra", 2)
        ),
        "rich_human_presence_multiplier": float(
            evaluation_settings.get("rich_human_presence_multiplier", 2.0)
        ),
        "rich_human_presence_extra_seconds": float(
            evaluation_settings.get("rich_human_presence_extra_seconds", 40.0)
        ),
        "rich_human_min_player_count": int(
            evaluation_settings.get("rich_human_min_player_count", 2)
        ),
        "oscillation_apply_direction_flips": int(
            evaluation_settings.get("oscillation_apply_direction_flips", 2)
        ),
        "oscillation_event_direction_flips": int(
            evaluation_settings.get("oscillation_event_direction_flips", 3)
        ),
        "underactive_meaningful_imbalance_snapshots": int(
            evaluation_settings.get("underactive_meaningful_imbalance_snapshots", 2)
        ),
        "underactive_strong_imbalance_snapshots": int(
            evaluation_settings.get("underactive_strong_imbalance_snapshots", 2)
        ),
        "strong_signal_min_post_patch_windows": int(
            evaluation_settings.get("strong_signal_min_post_patch_windows", 2)
        ),
        "strong_signal_requires_human_rich": bool(
            evaluation_settings.get("strong_signal_requires_human_rich", True)
        ),
    }
    return {
        "manifest": manifest,
        "telemetry_records": telemetry_records,
        "patch_records": patch_records,
        "apply_records": apply_records,
        "summary": analyze_lane(manifest, telemetry_records, patch_records, apply_records),
    }
