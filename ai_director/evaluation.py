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

EPSILON = 1e-3


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
        "momentum": round(momentum_from_telemetry(telemetry), 3),
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


def classify_behavior(
    mode: str,
    telemetry_records: list[dict[str, Any]],
    patch_records: list[dict[str, Any]],
    apply_records: list[dict[str, Any]],
) -> tuple[str, str]:
    if len(telemetry_records) < 2:
        return ("insufficient-data", "Not enough telemetry snapshots were captured.")

    emitted_patches = _emitted_patch_records(patch_records)
    momenta = [momentum_from_telemetry(record) for record in telemetry_records]
    strong_imbalance_count = sum(1 for value in momenta if abs(value) >= 8.0)
    final_abs_momentum = max(abs(value) for value in momenta[-min(3, len(momenta)) :])

    apply_directions = [
        str(record.get("direction", "hold"))
        for record in apply_records
        if str(record.get("direction", "hold")) != "hold"
    ]
    event_directions = [
        _patch_event_direction(record)
        for record in emitted_patches
        if _patch_event_direction(record) != "hold"
    ]
    direction_flips = sum(
        1 for previous, current in zip(apply_directions, apply_directions[1:]) if previous != current
    )
    event_direction_flips = sum(
        1 for previous, current in zip(event_directions, event_directions[1:]) if previous != current
    )

    if direction_flips >= 3 or event_direction_flips >= 3:
        return (
            "oscillatory",
            "Patch applications reversed direction repeatedly instead of converging.",
        )

    if mode.upper() == "AI":
        if strong_imbalance_count >= 2 and not emitted_patches and not apply_records:
            return (
                "underactive",
                "Strong momentum persisted without any emitted or applied balance action.",
            )
        if strong_imbalance_count >= 2 and final_abs_momentum >= 8.0 and direction_flips == 0 and len(apply_records) <= 1:
            return (
                "underactive",
                "Balance changes were too sparse to counter the sustained frag-gap momentum.",
            )
        if final_abs_momentum <= 4.0 and direction_flips <= 1:
            return (
                "stable",
                "Recent telemetry stayed near equilibrium without excessive reversals.",
            )
        if direction_flips >= 2 and len(apply_records) >= 4:
            return (
                "oscillatory",
                "The lane kept alternating between stronger and weaker bot adjustments.",
            )
        return (
            "stable",
            "Balance actions stayed bounded and did not show runaway oscillation.",
        )

    if final_abs_momentum <= 4.0:
        return ("stable", "Control telemetry stayed near equilibrium.")
    if strong_imbalance_count >= 2:
        return (
            "underactive",
            "Control telemetry showed a sustained imbalance with no treatment lane activity.",
        )
    return ("stable", "Control telemetry stayed within a moderate range.")


def analyze_lane(
    manifest: dict[str, Any] | None,
    telemetry_records: list[dict[str, Any]],
    patch_records: list[dict[str, Any]],
    apply_records: list[dict[str, Any]],
) -> dict[str, Any]:
    emitted_patches = _emitted_patch_records(patch_records)

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
        str((manifest or {}).get("mode", "Unknown")),
        telemetry_records,
        patch_records,
        apply_records,
    )

    summary = {
        "schema_version": 1,
        "mode": str((manifest or {}).get("mode", "Unknown")),
        "map": str((manifest or {}).get("map", "unknown")),
        "bot_count": _as_int(manifest or {}, "bot_count", 0),
        "bot_skill": _as_int(manifest or {}, "bot_skill", 0),
        "duration_seconds": _as_int(manifest or {}, "duration_seconds", 0),
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
        "patch_events_count": len(emitted_patches),
        "patch_apply_count": len(apply_records),
        "unique_skill_targets_seen": unique_skill_targets,
        "unique_bot_count_deltas_seen": unique_bot_count_deltas,
        "cooldown_constraints_respected": cooldown_respected,
        "boundedness_constraints_respected": (
            patch_bounds_respected and skill_step_budget_respected and bot_delta_budget_respected
        ),
        "skill_step_budget_respected": skill_step_budget_respected,
        "bot_count_delta_budget_respected": bot_delta_budget_respected,
        "behavior_verdict": behavior_verdict,
        "behavior_reason": behavior_reason,
    }
    return summary


def compare_lane_summaries(
    first_summary: dict[str, Any], second_summary: dict[str, Any]
) -> dict[str, Any]:
    first_mode = str(first_summary.get("mode", "Unknown")).upper()
    second_mode = str(second_summary.get("mode", "Unknown")).upper()

    control = first_summary
    treatment = second_summary
    if first_mode != "NOAI" and second_mode == "NOAI":
        control, treatment = second_summary, first_summary

    control_mode = str(control.get("mode", "Unknown"))
    treatment_mode = str(treatment.get("mode", "Unknown"))
    return {
        "schema_version": 1,
        "control_mode": control_mode,
        "treatment_mode": treatment_mode,
        "control_sidecar_free": not bool(control.get("ai_sidecar_observed", False)),
        "treatment_sidecar_observed": bool(treatment.get("ai_sidecar_observed", False)),
        "control_behavior_verdict": str(control.get("behavior_verdict", "insufficient-data")),
        "treatment_behavior_verdict": str(
            treatment.get("behavior_verdict", "insufficient-data")
        ),
        "control_telemetry_snapshots_count": _as_int(
            control, "telemetry_snapshots_count", 0
        ),
        "treatment_telemetry_snapshots_count": _as_int(
            treatment, "telemetry_snapshots_count", 0
        ),
        "control_patch_apply_count": _as_int(control, "patch_apply_count", 0),
        "treatment_patch_apply_count": _as_int(treatment, "patch_apply_count", 0),
        "treatment_generated_patch_history": _as_int(treatment, "patch_events_count", 0) > 0,
        "comparison_verdict": (
            "control-vs-treatment-usable"
            if not bool(control.get("ai_sidecar_observed", False))
            and _as_int(treatment, "patch_events_count", 0) > 0
            and bool(treatment.get("boundedness_constraints_respected", False))
            else "comparison-incomplete"
        ),
    }


def _build_simulated_telemetry(
    scenario_name: str,
    index: int,
    state: dict[str, Any],
    frame: dict[str, Any],
    map_name: str,
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
            "cooldown_seconds": round(_as_float(frame, "cooldown_seconds", 30.0), 1),
            "enabled": _as_int(frame, "enabled", 1),
        },
    }


def simulate_replay(
    scenario_name: str,
    frames: list[dict[str, Any]],
    *,
    initial_skill: int = 3,
    initial_bot_count: int = 4,
    map_name: str = "crossfire",
) -> dict[str, Any]:
    if not frames:
        raise ValueError("At least one telemetry frame is required.")

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
        telemetry = _build_simulated_telemetry(scenario_name, index, state, frame, map_name)
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

        recommendation = recommend_patch(telemetry)
        candidate_patch = materialize_patch(telemetry, recommendation)
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
        "mode": "AI",
        "map": map_name,
        "bot_count": initial_bot_count,
        "bot_skill": initial_skill,
        "duration_seconds": duration_seconds,
        "bootstrap_log_present": True,
        "attach_observed": True,
        "ai_sidecar_observed": True,
        "smoke_status": "simulated",
        "smoke_summary": "Deterministic replay scenario.",
        "match_id": scenario_name,
    }
    return {
        "manifest": manifest,
        "telemetry_records": telemetry_records,
        "patch_records": patch_records,
        "apply_records": apply_records,
        "summary": analyze_lane(manifest, telemetry_records, patch_records, apply_records),
    }
