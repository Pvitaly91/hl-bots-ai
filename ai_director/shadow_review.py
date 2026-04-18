from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Sequence

from ai_director.decision import (
    MAX_SCALE,
    MAX_SKILL_LEVEL,
    MIN_SCALE,
    MIN_SKILL_LEVEL,
    clamp_float,
    clamp_int,
    materialize_patch,
    recommend_patch,
)
from ai_director.evaluation import (
    analyze_lane,
    build_patch_event,
    compare_lane_summaries,
    load_ndjson,
)
from ai_director.tuning import resolve_tuning_profile, tuning_profile_summary


def _repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def repo_prompt_id() -> str:
    prompt_id_path = _repo_root() / "PROMPT_ID.txt"
    raw_lines = [line.strip() for line in prompt_id_path.read_text(encoding="utf-8").splitlines()]
    begin_index = raw_lines.index("PROMPT_ID_BEGIN")
    end_index = raw_lines.index("PROMPT_ID_END")
    prompt_lines = [
        line
        for line in raw_lines[(begin_index + 1) : end_index]
        if line and line != "PROMPT_ID_BEGIN" and line != "PROMPT_ID_END"
    ]
    if len(prompt_lines) != 1:
        raise ValueError(f"Malformed prompt ID file: {prompt_id_path}")
    return prompt_lines[0]


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content.rstrip() + "\n", encoding="utf-8")


def _as_int(payload: dict[str, Any] | None, key: str, default: int = 0) -> int:
    try:
        return int((payload or {}).get(key, default))
    except (TypeError, ValueError):
        return default


def _as_float(payload: dict[str, Any] | None, key: str, default: float = 0.0) -> float:
    try:
        return float((payload or {}).get(key, default))
    except (TypeError, ValueError):
        return default


def _as_bool(payload: dict[str, Any] | None, key: str, default: bool = False) -> bool:
    value = (payload or {}).get(key, default)
    return bool(value)


def _as_str(payload: dict[str, Any] | None, key: str, default: str = "") -> str:
    value = (payload or {}).get(key, default)
    return str(value) if value is not None else default


def _active_balance(payload: dict[str, Any]) -> dict[str, Any]:
    value = payload.get("active_balance")
    return value if isinstance(value, dict) else {}


def _resolve_optional_threshold(
    explicit_value: int | float | None,
    manifest: dict[str, Any],
    manifest_key: str,
    profile_default: int | float,
) -> int | float:
    if explicit_value is not None:
        return explicit_value
    if manifest_key in manifest and manifest[manifest_key] is not None:
        return manifest[manifest_key]
    return profile_default


def locate_pair_root_from_lane(lane_root: Path) -> Path | None:
    for parent in [lane_root] + list(lane_root.parents):
        candidate = parent / "pair_summary.json"
        if candidate.exists():
            return parent
    return None


def load_lane_bundle(lane_root: Path) -> dict[str, Any]:
    resolved_lane_root = lane_root.resolve()
    lane_json_path = resolved_lane_root / "lane.json"
    summary_json_path = resolved_lane_root / "summary.json"
    session_pack_json_path = resolved_lane_root / "session_pack.json"
    if not lane_json_path.exists():
        raise FileNotFoundError(f"Lane metadata was not found: {lane_json_path}")
    if not summary_json_path.exists():
        raise FileNotFoundError(f"Lane summary was not found: {summary_json_path}")
    if not session_pack_json_path.exists():
        raise FileNotFoundError(f"Lane session pack was not found: {session_pack_json_path}")

    lane_json = read_json(lane_json_path)
    summary_payload = read_json(summary_json_path)
    session_pack = read_json(session_pack_json_path)
    summary = summary_payload.get("primary_lane", summary_payload)

    copied = session_pack.get("copied_artifacts", {})
    telemetry_path = Path(_as_str(copied, "telemetry_history", str(resolved_lane_root / "telemetry_history.ndjson")))
    patch_path = Path(_as_str(copied, "patch_history", str(resolved_lane_root / "patch_history.ndjson")))
    patch_apply_path = Path(
        _as_str(copied, "patch_apply_history", str(resolved_lane_root / "patch_apply_history.ndjson"))
    )

    return {
        "lane_root": resolved_lane_root,
        "lane_json_path": lane_json_path,
        "summary_json_path": summary_json_path,
        "session_pack_json_path": session_pack_json_path,
        "lane_json": lane_json,
        "summary": summary,
        "session_pack": session_pack,
        "telemetry_records": load_ndjson(telemetry_path),
        "patch_records": load_ndjson(patch_path),
        "apply_records": load_ndjson(patch_apply_path),
    }


def load_pair_context(pair_root: Path) -> dict[str, Any]:
    resolved_pair_root = pair_root.resolve()
    pair_summary_path = resolved_pair_root / "pair_summary.json"
    comparison_path = resolved_pair_root / "comparison.json"
    if not pair_summary_path.exists():
        raise FileNotFoundError(f"Pair summary was not found: {pair_summary_path}")

    pair_summary = read_json(pair_summary_path)
    comparison_payload = read_json(comparison_path) if comparison_path.exists() else {}
    treatment_lane_root = Path(_as_str(pair_summary.get("treatment_lane", {}), "lane_root"))
    control_lane_root = Path(_as_str(pair_summary.get("control_lane", {}), "lane_root"))
    treatment_lane = load_lane_bundle(treatment_lane_root)
    control_lane = load_lane_bundle(control_lane_root)
    comparison = comparison_payload.get("comparison", pair_summary.get("comparison"))

    return {
        "pair_root": resolved_pair_root,
        "pair_summary_path": pair_summary_path,
        "comparison_path": comparison_path,
        "pair_summary": pair_summary,
        "comparison": comparison,
        "control_lane": control_lane,
        "treatment_lane": treatment_lane,
    }


def _counterfactual_manifest(
    live_manifest: dict[str, Any],
    profile_name: str,
    *,
    min_human_snapshots: int | None,
    min_human_presence_seconds: float | None,
    min_patch_events_for_usable_lane: int | None,
) -> dict[str, Any]:
    resolved_profile = resolve_tuning_profile(profile_name)
    evaluation = resolved_profile.get("evaluation", {})
    manifest = dict(live_manifest)
    manifest["mode"] = "AI"
    manifest["lane_label"] = f"shadow-{_as_str(live_manifest, 'lane_label', 'treatment')}-{profile_name}"
    manifest["tuning_profile"] = profile_name
    manifest["tuning_profile_effective"] = tuning_profile_summary(profile_name)
    manifest["smoke_status"] = "simulated"
    manifest["smoke_summary"] = (
        "Counterfactual replay against captured telemetry. "
        "This is evidence support only and does not outrank real live human sessions."
    )
    manifest["bootstrap_log_present"] = True
    manifest["attach_observed"] = True
    manifest["ai_sidecar_observed"] = True
    manifest["min_human_snapshots"] = int(
        _resolve_optional_threshold(
            min_human_snapshots,
            live_manifest,
            "min_human_snapshots",
            int(evaluation.get("min_human_snapshots", 2)),
        )
    )
    manifest["min_human_presence_seconds"] = float(
        _resolve_optional_threshold(
            min_human_presence_seconds,
            live_manifest,
            "min_human_presence_seconds",
            float(evaluation.get("min_human_presence_seconds", 40.0)),
        )
    )
    manifest["min_patch_events_for_usable_lane"] = int(
        _resolve_optional_threshold(
            min_patch_events_for_usable_lane,
            live_manifest,
            "min_patch_events_for_usable_lane",
            int(evaluation.get("min_patch_events_for_usable_lane", 1)),
        )
    )
    return manifest


def replay_captured_lane(
    live_manifest: dict[str, Any],
    telemetry_records: list[dict[str, Any]],
    profile_name: str,
    *,
    min_human_snapshots: int | None = None,
    min_human_presence_seconds: float | None = None,
    min_patch_events_for_usable_lane: int | None = None,
) -> dict[str, Any]:
    if not telemetry_records:
        raise ValueError("Captured telemetry history is empty.")

    resolved_profile = resolve_tuning_profile(profile_name)
    manifest = _counterfactual_manifest(
        live_manifest,
        profile_name,
        min_human_snapshots=min_human_snapshots,
        min_human_presence_seconds=min_human_presence_seconds,
        min_patch_events_for_usable_lane=min_patch_events_for_usable_lane,
    )

    state = {
        "current_default_bot_skill_level": clamp_int(
            _as_int(live_manifest, "bot_skill", 3),
            MIN_SKILL_LEVEL,
            MAX_SKILL_LEVEL,
        ),
        "bot_count": max(1, _as_int(live_manifest, "bot_count", 4)),
        "pause_frequency_scale": 1.0,
        "battle_strafe_scale": 1.0,
        "last_apply_time": -9999.0,
        "last_applied_patch_id": "",
    }
    replayed_telemetry_records: list[dict[str, Any]] = []
    patch_records: list[dict[str, Any]] = []
    apply_records: list[dict[str, Any]] = []
    pending_patch: dict[str, Any] | None = None

    for source_record in telemetry_records:
        server_time = _as_float(source_record, "server_time_seconds", 0.0)
        cooldown_seconds = float(resolved_profile.get("cooldown_seconds", 30.0))
        if (
            pending_patch
            and pending_patch.get("patch_id", "") != state["last_applied_patch_id"]
            and (server_time - float(state["last_apply_time"])) >= cooldown_seconds
        ):
            previous_skill = int(state["current_default_bot_skill_level"])
            target_skill = clamp_int(
                _as_int(pending_patch, "target_skill_level", previous_skill),
                MIN_SKILL_LEVEL,
                MAX_SKILL_LEVEL,
            )
            effective_skill = previous_skill
            if target_skill < previous_skill:
                effective_skill -= 1
            elif target_skill > previous_skill:
                effective_skill += 1
            effective_skill = clamp_int(effective_skill, MIN_SKILL_LEVEL, MAX_SKILL_LEVEL)

            requested_bot_delta = clamp_int(_as_int(pending_patch, "bot_count_delta", 0), -1, 1)
            applied_bot_delta = 0
            if requested_bot_delta > 0:
                state["bot_count"] = int(state["bot_count"]) + 1
                applied_bot_delta = 1
            elif requested_bot_delta < 0 and int(state["bot_count"]) > 1:
                state["bot_count"] = int(state["bot_count"]) - 1
                applied_bot_delta = -1

            state["current_default_bot_skill_level"] = effective_skill
            state["pause_frequency_scale"] = round(
                clamp_float(_as_float(pending_patch, "pause_frequency_scale", 1.0), MIN_SCALE, MAX_SCALE),
                3,
            )
            state["battle_strafe_scale"] = round(
                clamp_float(_as_float(pending_patch, "battle_strafe_scale", 1.0), MIN_SCALE, MAX_SCALE),
                3,
            )
            state["last_apply_time"] = server_time
            state["last_applied_patch_id"] = str(pending_patch.get("patch_id", ""))

            apply_records.append(
                {
                    "schema_version": 1,
                    "event_type": "patch_applied",
                    "match_id": _as_str(source_record, "match_id", _as_str(live_manifest, "match_id", "unknown-match")),
                    "patch_id": state["last_applied_patch_id"],
                    "telemetry_sequence": _as_int(pending_patch, "telemetry_sequence", _as_int(source_record, "telemetry_sequence", 0)),
                    "timestamp_utc": _as_str(source_record, "timestamp_utc"),
                    "server_time_seconds": round(server_time, 2),
                    "map_name": _as_str(source_record, "map_name", _as_str(live_manifest, "map", "unknown")),
                    "previous_default_bot_skill_level": previous_skill,
                    "effective_default_bot_skill_level": effective_skill,
                    "target_skill_level": target_skill,
                    "requested_bot_count_delta": requested_bot_delta,
                    "applied_bot_count_delta": applied_bot_delta,
                    "pause_frequency_scale": state["pause_frequency_scale"],
                    "battle_strafe_scale": state["battle_strafe_scale"],
                    "cooldown_seconds": round(cooldown_seconds, 1),
                    "direction": (
                        "strengthen"
                        if (
                            effective_skill < previous_skill
                            or applied_bot_delta > 0
                            or state["pause_frequency_scale"] < 1.0
                            or state["battle_strafe_scale"] > 1.0
                        )
                        else (
                            "relax"
                            if (
                                effective_skill > previous_skill
                                or applied_bot_delta < 0
                                or state["pause_frequency_scale"] > 1.0
                                or state["battle_strafe_scale"] < 1.0
                            )
                            else "hold"
                        )
                    ),
                    "reason": _as_str(pending_patch, "reason", "No reason provided."),
                }
            )

        active_source = _active_balance(source_record)
        replayed_telemetry = {
            **source_record,
            "bot_count": int(state["bot_count"]),
            "current_default_bot_skill_level": int(state["current_default_bot_skill_level"]),
            "active_balance": {
                "pause_frequency_scale": round(float(state["pause_frequency_scale"]), 3),
                "battle_strafe_scale": round(float(state["battle_strafe_scale"]), 3),
                "interval_seconds": round(_as_float(active_source, "interval_seconds", 20.0), 1),
                "cooldown_seconds": round(float(resolved_profile.get("cooldown_seconds", 30.0)), 1),
                "enabled": _as_int(active_source, "enabled", 1),
            },
        }
        replayed_telemetry_records.append(replayed_telemetry)

        recommendation = recommend_patch(replayed_telemetry, tuning_profile=resolved_profile)
        candidate_patch = materialize_patch(
            replayed_telemetry,
            recommendation,
            tuning_profile=resolved_profile,
        )
        patch_event = build_patch_event(
            replayed_telemetry,
            recommendation,
            candidate_patch,
            pending_patch,
        )
        patch_records.append(patch_event)
        if patch_event["emitted"]:
            pending_patch = candidate_patch

    summary = analyze_lane(manifest, replayed_telemetry_records, patch_records, apply_records)
    return {
        "manifest": manifest,
        "telemetry_records": replayed_telemetry_records,
        "patch_records": patch_records,
        "apply_records": apply_records,
        "summary": summary,
    }


def _profile_assessment(
    profile_name: str,
    summary: dict[str, Any],
    comparison: dict[str, Any] | None,
) -> tuple[str, str]:
    if (
        str(summary.get("behavior_verdict", "")) == "oscillatory"
        or not bool(summary.get("cooldown_constraints_respected", False))
        or not bool(summary.get("boundedness_constraints_respected", False))
    ):
        return (
            "too reactive",
            f"{profile_name} looked oscillatory or failed a guardrail in replay.",
        )

    if comparison is None:
        if not bool(summary.get("tuning_signal_usable", False)):
            return (
                "inconclusive",
                "No paired control lane was available and the replayed lane did not clear the human-signal gate.",
            )
        if str(summary.get("behavior_verdict", "")) == "underactive":
            return (
                "too quiet",
                f"{profile_name} replay stayed underactive without a paired control comparison.",
            )
        return (
            "appropriately conservative",
            f"{profile_name} stayed bounded on the captured lane, but this should still be read as counterfactual support only.",
        )

    comparison_verdict = str(comparison.get("comparison_verdict", "comparison-insufficient-data"))
    comparison_reason = str(comparison.get("comparison_reason", ""))
    if comparison_verdict == "comparison-insufficient-data":
        return ("inconclusive", comparison_reason)

    if (
        comparison.get("treatment_relative_to_control") == "quieter"
        and not bool(comparison.get("treatment_patched_while_humans_present", False))
        and not bool(comparison.get("meaningful_post_patch_observation_window_exists", False))
    ):
        return (
            "too quiet",
            f"{profile_name} stayed quieter than control without grounded human-present patch evidence.",
        )

    if str(summary.get("behavior_verdict", "")) == "underactive":
        return (
            "too quiet",
            f"{profile_name} cleared the human gate but still looked underactive on the captured lane.",
        )

    if comparison_verdict == "comparison-weak-signal":
        return ("inconclusive", comparison_reason)

    return (
        "appropriately conservative",
        f"{profile_name} stayed bounded and produced the strongest grounded response this captured lane can support.",
    )


def _patch_apply_times(apply_records: list[dict[str, Any]]) -> list[float]:
    return [round(_as_float(record, "server_time_seconds", 0.0), 2) for record in apply_records]


def _emitted_patch_times(patch_records: list[dict[str, Any]]) -> list[float]:
    return [
        round(_as_float(record, "server_time_seconds", 0.0), 2)
        for record in patch_records
        if _as_bool(record, "emitted", False)
    ]


def _profile_entry(
    profile_name: str,
    source_kind: str,
    summary: dict[str, Any],
    comparison: dict[str, Any] | None,
    patch_records: list[dict[str, Any]],
    apply_records: list[dict[str, Any]],
) -> dict[str, Any]:
    assessment, assessment_reason = _profile_assessment(profile_name, summary, comparison)
    return {
        "profile": profile_name,
        "source": source_kind,
        "would_have_patched": int(summary.get("patch_apply_count", 0)) > 0,
        "would_have_patched_while_humans_present": bool(
            summary.get("treatment_patched_while_humans_present", False)
        ),
        "patch_events_count": int(summary.get("patch_events_count", 0)),
        "patch_apply_count": int(summary.get("patch_apply_count", 0)),
        "patch_apply_count_while_humans_present": int(
            summary.get("patch_apply_count_while_humans_present", 0)
        ),
        "patch_event_times_seconds": _emitted_patch_times(patch_records),
        "patch_apply_times_seconds": _patch_apply_times(apply_records),
        "target_skill_changes": [
            int(record.get("effective_default_bot_skill_level", 0)) for record in apply_records
        ],
        "requested_skill_targets": [
            int(record.get("target_skill_level", 0))
            for record in patch_records
            if bool(record.get("emitted", False))
        ],
        "bot_count_delta_changes": [
            int(record.get("applied_bot_count_delta", 0)) for record in apply_records
        ],
        "requested_bot_count_deltas": [
            int(record.get("bot_count_delta", 0))
            for record in patch_records
            if bool(record.get("emitted", False))
        ],
        "patch_events_while_humans_present_count": int(
            summary.get("patch_events_while_humans_present_count", 0)
        ),
        "human_snapshots_count": int(summary.get("human_snapshots_count", 0)),
        "seconds_with_human_presence": float(summary.get("seconds_with_human_presence", 0.0)),
        "human_signal_verdict": str(summary.get("human_signal_verdict", "no-humans")),
        "tuning_signal_usable": bool(summary.get("tuning_signal_usable", False)),
        "evidence_quality": str(summary.get("evidence_quality", "insufficient-data")),
        "behavior_verdict": str(summary.get("behavior_verdict", "insufficient-data")),
        "meaningful_post_patch_observation_window_exists": bool(
            summary.get("meaningful_post_patch_observation_window_exists", False)
        ),
        "response_after_patch_observation_window_count": int(
            summary.get("response_after_patch_observation_window_count", 0)
        ),
        "boundedness_constraints_respected": bool(
            summary.get("boundedness_constraints_respected", False)
        ),
        "cooldown_constraints_respected": bool(
            summary.get("cooldown_constraints_respected", False)
        ),
        "oscillation_flag": str(summary.get("behavior_verdict", "")) == "oscillatory",
        "underactivity_flag": str(summary.get("behavior_verdict", "")) == "underactive",
        "insufficient_data_flag": not bool(summary.get("tuning_signal_usable", False)),
        "patching_happened_only_while_humans_absent": bool(
            summary.get("patching_happened_only_while_humans_absent", False)
        ),
        "assessment": assessment,
        "assessment_reason": assessment_reason,
        "comparison_verdict": str(comparison.get("comparison_verdict", "")) if comparison else "",
        "comparison_reason": str(comparison.get("comparison_reason", "")) if comparison else "",
        "treatment_relative_to_control": (
            str(comparison.get("treatment_relative_to_control", "")) if comparison else ""
        ),
        "summary": summary,
        "comparison": comparison,
    }


def _profiles_similar(left: dict[str, Any] | None, right: dict[str, Any] | None) -> bool:
    if not left or not right:
        return False
    return (
        left["assessment"] == right["assessment"]
        and abs(int(left["patch_apply_count"]) - int(right["patch_apply_count"])) <= 1
        and abs(
            int(left["patch_events_while_humans_present_count"])
            - int(right["patch_events_while_humans_present_count"])
        )
        <= 1
        and abs(
            int(left["response_after_patch_observation_window_count"])
            - int(right["response_after_patch_observation_window_count"])
        )
        <= 1
        and left["treatment_relative_to_control"] == right["treatment_relative_to_control"]
    )


def _gate_reason(
    control_summary: dict[str, Any] | None,
    live_summary: dict[str, Any],
    actual_comparison: dict[str, Any] | None,
    *,
    require_human_signal: bool,
    min_human_snapshots: int | None,
    min_human_presence_seconds: float | None,
) -> str | None:
    if actual_comparison is None:
        return "A paired control-vs-treatment comparison is missing, so shadow replay cannot justify a live profile change on its own."

    if str(actual_comparison.get("comparison_verdict", "")) == "comparison-insufficient-data":
        return str(actual_comparison.get("comparison_reason", "The captured pair stayed insufficient-data."))

    required_snapshots = min_human_snapshots
    required_presence = min_human_presence_seconds
    if require_human_signal and required_snapshots is not None:
        if int(live_summary.get("human_snapshots_count", 0)) < required_snapshots:
            return (
                "The captured treatment lane did not reach the requested human-snapshot gate "
                f"({live_summary.get('human_snapshots_count', 0)} < {required_snapshots})."
            )
        if control_summary and int(control_summary.get("human_snapshots_count", 0)) < required_snapshots:
            return (
                "The captured control lane did not reach the requested human-snapshot gate "
                f"({control_summary.get('human_snapshots_count', 0)} < {required_snapshots})."
            )
    if require_human_signal and required_presence is not None:
        if float(live_summary.get("seconds_with_human_presence", 0.0)) < required_presence:
            return (
                "The captured treatment lane did not reach the requested human-presence window "
                f"({live_summary.get('seconds_with_human_presence', 0.0)}s < {required_presence}s)."
            )
        if control_summary and float(control_summary.get("seconds_with_human_presence", 0.0)) < required_presence:
            return (
                "The captured control lane did not reach the requested human-presence window "
                f"({control_summary.get('seconds_with_human_presence', 0.0)}s < {required_presence}s)."
            )

    if not bool(live_summary.get("tuning_signal_usable", False)):
        return str(
            actual_comparison.get(
                "comparison_reason",
                "The captured treatment lane never cleared the tuning-usability gate.",
            )
        )
    if control_summary and not bool(control_summary.get("tuning_signal_usable", False)):
        return str(
            actual_comparison.get(
                "comparison_reason",
                "The captured control lane never cleared the tuning-usability gate.",
            )
        )
    return None


def build_shadow_recommendation(
    actual_live_entry: dict[str, Any],
    shadow_entries: dict[str, dict[str, Any]],
    control_summary: dict[str, Any] | None,
    actual_comparison: dict[str, Any] | None,
    *,
    require_human_signal: bool,
    min_human_snapshots: int | None,
    min_human_presence_seconds: float | None,
) -> dict[str, Any]:
    live_summary = actual_live_entry["summary"]
    signal_gate_reason = _gate_reason(
        control_summary,
        live_summary,
        actual_comparison,
        require_human_signal=require_human_signal,
        min_human_snapshots=min_human_snapshots,
        min_human_presence_seconds=min_human_presence_seconds,
    )

    conservative_reference = (
        actual_live_entry if actual_live_entry["profile"] == "conservative" else shadow_entries.get("conservative")
    )
    default_shadow = shadow_entries.get("default")
    responsive_shadow = shadow_entries.get("responsive")

    decision = "manual-review-needed"
    explanation = "The captured evidence needs manual review before changing the live profile."
    responsive_justified = False
    conservative_should_remain = False
    evidence_too_weak = False
    manual_review_needed = True

    if signal_gate_reason:
        decision = "insufficient-data-no-promotion"
        explanation = (
            f"{signal_gate_reason} The captured treatment lane had "
            f"{live_summary.get('human_snapshots_count', 0)} human snapshots across "
            f"{live_summary.get('seconds_with_human_presence', 0.0)} seconds, so shadow replay "
            "remains counterfactual support only."
        )
        responsive_justified = False
        conservative_should_remain = True
        evidence_too_weak = True
        manual_review_needed = False
    elif responsive_shadow and responsive_shadow["assessment"] == "too reactive":
        decision = "responsive-would-have-overreacted"
        explanation = (
            "Responsive would have looked too reactive on this captured lane, "
            f"so the safer next live profile remains conservative. {responsive_shadow['assessment_reason']}"
        )
        responsive_justified = False
        conservative_should_remain = True
        evidence_too_weak = False
        manual_review_needed = False
    elif conservative_reference and conservative_reference["assessment"] == "too quiet":
        responsive_support_points = 0
        if responsive_shadow and responsive_shadow["assessment"] == "appropriately conservative":
            if responsive_shadow["comparison_verdict"] in {"comparison-usable", "comparison-strong-signal"}:
                responsive_support_points += 1
            if (
                int(responsive_shadow["patch_events_while_humans_present_count"])
                > int(conservative_reference["patch_events_while_humans_present_count"])
            ):
                responsive_support_points += 1
            if (
                int(responsive_shadow["response_after_patch_observation_window_count"])
                > int(conservative_reference["response_after_patch_observation_window_count"])
            ):
                responsive_support_points += 1
            if int(responsive_shadow["patch_apply_count"]) > int(conservative_reference["patch_apply_count"]):
                responsive_support_points += 1

        if responsive_support_points >= 3:
            decision = "conservative-looks-too-quiet-responsive-candidate"
            explanation = (
                "Conservative looks too quiet on the captured treatment lane, while responsive "
                "would have added more grounded human-present treatment activity without tripping the guardrails. "
                "This is still a candidate only, not stronger evidence than another real live session."
            )
            responsive_justified = True
            conservative_should_remain = False
            evidence_too_weak = False
            manual_review_needed = False
        else:
            decision = "keep-conservative"
            explanation = (
                "Conservative may have been quiet, but the shadow delta is still too small or too noisy "
                "to justify a live promotion to responsive from this one captured lane."
            )
            responsive_justified = False
            conservative_should_remain = True
            evidence_too_weak = True
            manual_review_needed = False
    elif conservative_reference and conservative_reference["assessment"] == "appropriately conservative":
        if _profiles_similar(conservative_reference, default_shadow):
            decision = "conservative-and-default-similar"
            explanation = (
                "Default shadow replay stayed materially similar to the captured conservative lane, "
                "so there is no grounded reason to spend the next live session on a profile change."
            )
        else:
            decision = "keep-conservative"
            explanation = (
                "The captured conservative lane stayed bounded without looking overreactive, "
                "so conservative remains the safest next live profile."
            )
        responsive_justified = False
        conservative_should_remain = True
        evidence_too_weak = False
        manual_review_needed = False
    elif conservative_reference and conservative_reference["assessment"] == "too reactive":
        decision = "manual-review-needed"
        explanation = "The conservative reference itself looked too reactive, so the captured artifacts need manual inspection before any live change."
        responsive_justified = False
        conservative_should_remain = False
        evidence_too_weak = False
        manual_review_needed = True
    else:
        decision = "keep-conservative"
        explanation = (
            "The captured lane does not provide a clean, grounded case for moving off conservative yet."
        )
        responsive_justified = False
        conservative_should_remain = True
        evidence_too_weak = True
        manual_review_needed = False

    return {
        "schema_version": 1,
        "prompt_id": repo_prompt_id(),
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "decision": decision,
        "explanation": explanation,
        "responsive_justified_as_next_trial": responsive_justified,
        "conservative_should_remain_next_live_profile": conservative_should_remain,
        "evidence_too_weak_for_profile_change": evidence_too_weak,
        "manual_review_needed": manual_review_needed,
        "actual_live_profile": actual_live_entry["profile"],
        "actual_live_assessment": actual_live_entry["assessment"],
        "actual_live_comparison_verdict": (
            str(actual_comparison.get("comparison_verdict", "")) if actual_comparison else ""
        ),
        "actual_live_human_signal_verdict": str(live_summary.get("human_signal_verdict", "no-humans")),
        "signal_quality": {
            "require_human_signal": require_human_signal,
            "required_min_human_snapshots": min_human_snapshots,
            "required_min_human_presence_seconds": min_human_presence_seconds,
            "control_human_snapshots_count": (
                int(control_summary.get("human_snapshots_count", 0)) if control_summary else None
            ),
            "control_seconds_with_human_presence": (
                float(control_summary.get("seconds_with_human_presence", 0.0))
                if control_summary
                else None
            ),
            "treatment_human_snapshots_count": int(live_summary.get("human_snapshots_count", 0)),
            "treatment_seconds_with_human_presence": float(
                live_summary.get("seconds_with_human_presence", 0.0)
            ),
            "gate_reason": signal_gate_reason or "",
        },
        "profile_snapshot": {
            "actual_live": {
                "profile": actual_live_entry["profile"],
                "assessment": actual_live_entry["assessment"],
                "patch_apply_count": actual_live_entry["patch_apply_count"],
                "patch_apply_count_while_humans_present": actual_live_entry[
                    "patch_apply_count_while_humans_present"
                ],
                "response_after_patch_observation_window_count": actual_live_entry[
                    "response_after_patch_observation_window_count"
                ],
            },
            "default": (
                {
                    "assessment": default_shadow["assessment"],
                    "patch_apply_count": default_shadow["patch_apply_count"],
                    "patch_apply_count_while_humans_present": default_shadow[
                        "patch_apply_count_while_humans_present"
                    ],
                    "response_after_patch_observation_window_count": default_shadow[
                        "response_after_patch_observation_window_count"
                    ],
                }
                if default_shadow
                else None
            ),
            "responsive": (
                {
                    "assessment": responsive_shadow["assessment"],
                    "patch_apply_count": responsive_shadow["patch_apply_count"],
                    "patch_apply_count_while_humans_present": responsive_shadow[
                        "patch_apply_count_while_humans_present"
                    ],
                    "response_after_patch_observation_window_count": responsive_shadow[
                        "response_after_patch_observation_window_count"
                    ],
                }
                if responsive_shadow
                else None
            ),
        },
    }


def render_shadow_profiles_markdown(payload: dict[str, Any]) -> str:
    lines = [
        "# Shadow Profile Review",
        "",
        f"- Pair root: {payload.get('pair_root', '')}",
        f"- Lane root: {payload.get('lane_root', '')}",
        f"- Actual live treatment profile: {payload.get('actual_live_profile', '')}",
        f"- Compared shadow profiles: {', '.join(payload.get('compared_profiles', []))}",
        "",
        "## Actual Live Treatment",
        "",
    ]

    actual_live = payload.get("actual_live_treatment", {})
    lines.extend(
        [
            f"- Profile: {actual_live.get('profile', '')}",
            f"- Assessment: {actual_live.get('assessment', '')}",
            f"- Would have patched: {actual_live.get('would_have_patched', False)}",
            f"- Patched while humans were present: {actual_live.get('would_have_patched_while_humans_present', False)}",
            f"- Patch apply count: {actual_live.get('patch_apply_count', 0)}",
            f"- Patch apply times (s): {actual_live.get('patch_apply_times_seconds', [])}",
            f"- Meaningful post-patch observation window: {actual_live.get('meaningful_post_patch_observation_window_exists', False)}",
            f"- Comparison verdict: {actual_live.get('comparison_verdict', '')}",
            f"- Reason: {actual_live.get('assessment_reason', '')}",
            "",
            "## Shadow Profiles",
            "",
        ]
    )

    for entry in payload.get("shadow_profiles", []):
        lines.extend(
            [
                f"### {entry.get('profile', '')}",
                f"- Assessment: {entry.get('assessment', '')}",
                f"- Would have patched: {entry.get('would_have_patched', False)}",
                f"- Patched while humans were present: {entry.get('would_have_patched_while_humans_present', False)}",
                f"- Patch apply count: {entry.get('patch_apply_count', 0)}",
                f"- Patch apply times (s): {entry.get('patch_apply_times_seconds', [])}",
                f"- Target skill changes: {entry.get('target_skill_changes', [])}",
                f"- Bot-count delta changes: {entry.get('bot_count_delta_changes', [])}",
                f"- Meaningful post-patch observation window: {entry.get('meaningful_post_patch_observation_window_exists', False)}",
                f"- Boundedness respected: {entry.get('boundedness_constraints_respected', False)}",
                f"- Cooldown respected: {entry.get('cooldown_constraints_respected', False)}",
                f"- Oscillation flag: {entry.get('oscillation_flag', False)}",
                f"- Underactivity flag: {entry.get('underactivity_flag', False)}",
                f"- Insufficient-data flag: {entry.get('insufficient_data_flag', False)}",
                f"- Comparison verdict: {entry.get('comparison_verdict', '')}",
                f"- Reason: {entry.get('assessment_reason', '')}",
                "",
            ]
        )

    return "\n".join(lines).rstrip() + "\n"


def render_shadow_recommendation_markdown(payload: dict[str, Any]) -> str:
    signal_quality = payload.get("signal_quality", {})
    lines = [
        "# Shadow Recommendation",
        "",
        f"- Decision: {payload.get('decision', '')}",
        f"- Actual live profile: {payload.get('actual_live_profile', '')}",
        f"- Actual live assessment: {payload.get('actual_live_assessment', '')}",
        f"- Responsive justified as next trial: {payload.get('responsive_justified_as_next_trial', False)}",
        f"- Conservative should remain next live profile: {payload.get('conservative_should_remain_next_live_profile', False)}",
        f"- Evidence too weak for profile change: {payload.get('evidence_too_weak_for_profile_change', False)}",
        f"- Manual review needed: {payload.get('manual_review_needed', False)}",
        f"- Explanation: {payload.get('explanation', '')}",
        "",
        "## Signal Quality",
        "",
        f"- Control human snapshots: {signal_quality.get('control_human_snapshots_count', '')}",
        f"- Control seconds with human presence: {signal_quality.get('control_seconds_with_human_presence', '')}",
        f"- Treatment human snapshots: {signal_quality.get('treatment_human_snapshots_count', '')}",
        f"- Treatment seconds with human presence: {signal_quality.get('treatment_seconds_with_human_presence', '')}",
        f"- Required minimum human snapshots: {signal_quality.get('required_min_human_snapshots', '')}",
        f"- Required minimum human presence seconds: {signal_quality.get('required_min_human_presence_seconds', '')}",
        f"- Gate reason: {signal_quality.get('gate_reason', '')}",
        "",
    ]
    return "\n".join(lines).rstrip() + "\n"


def build_shadow_review(
    *,
    pair_root: Path | None,
    lane_root: Path | None,
    profiles: Sequence[str],
    require_human_signal: bool = False,
    min_human_snapshots: int | None = None,
    min_human_presence_seconds: float | None = None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    if pair_root is None and lane_root is None:
        raise ValueError("Either pair_root or lane_root is required.")

    pair_context: dict[str, Any] | None = None
    lane_bundle: dict[str, Any]
    control_summary: dict[str, Any] | None = None
    actual_comparison: dict[str, Any] | None = None

    if pair_root is not None:
        pair_context = load_pair_context(pair_root)
        lane_bundle = pair_context["treatment_lane"]
        control_summary = pair_context["control_lane"]["summary"]
        actual_comparison = pair_context["comparison"]
    else:
        resolved_lane_root = lane_root.resolve()
        resolved_pair_root = locate_pair_root_from_lane(resolved_lane_root)
        if resolved_pair_root is not None:
            pair_context = load_pair_context(resolved_pair_root)
            lane_bundle = pair_context["treatment_lane"]
            control_summary = pair_context["control_lane"]["summary"]
            actual_comparison = pair_context["comparison"]
        else:
            lane_bundle = load_lane_bundle(resolved_lane_root)

    live_manifest = lane_bundle["session_pack"]
    live_summary = lane_bundle["summary"]
    actual_profile = _as_str(live_summary, "tuning_profile", _as_str(live_manifest, "tuning_profile", "default"))
    actual_live_entry = _profile_entry(
        actual_profile,
        "actual-live-treatment",
        live_summary,
        actual_comparison,
        lane_bundle["patch_records"],
        lane_bundle["apply_records"],
    )

    shadow_entries: dict[str, dict[str, Any]] = {}
    for profile_name in list(dict.fromkeys(str(profile).strip() for profile in profiles if str(profile).strip())):
        replay = replay_captured_lane(
            live_manifest,
            lane_bundle["telemetry_records"],
            profile_name,
            min_human_snapshots=min_human_snapshots,
            min_human_presence_seconds=min_human_presence_seconds,
            min_patch_events_for_usable_lane=None,
        )
        shadow_comparison = (
            compare_lane_summaries(control_summary, replay["summary"])
            if control_summary is not None
            else None
        )
        shadow_entries[profile_name] = _profile_entry(
            profile_name,
            "shadow-replay",
            replay["summary"],
            shadow_comparison,
            replay["patch_records"],
            replay["apply_records"],
        )

    shadow_profiles_payload = {
        "schema_version": 1,
        "prompt_id": repo_prompt_id(),
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "pair_root": str(pair_context["pair_root"]) if pair_context else "",
        "lane_root": str(lane_bundle["lane_root"]),
        "actual_live_profile": actual_profile,
        "actual_live_treatment": actual_live_entry,
        "compared_profiles": list(shadow_entries.keys()),
        "shadow_profiles": [shadow_entries[name] for name in shadow_entries.keys()],
    }

    shadow_recommendation_payload = build_shadow_recommendation(
        actual_live_entry,
        shadow_entries,
        control_summary,
        actual_comparison,
        require_human_signal=require_human_signal,
        min_human_snapshots=min_human_snapshots,
        min_human_presence_seconds=min_human_presence_seconds,
    )
    shadow_recommendation_payload["pair_root"] = shadow_profiles_payload["pair_root"]
    shadow_recommendation_payload["lane_root"] = shadow_profiles_payload["lane_root"]
    shadow_recommendation_payload["compared_profiles"] = list(shadow_entries.keys())

    return shadow_profiles_payload, shadow_recommendation_payload
