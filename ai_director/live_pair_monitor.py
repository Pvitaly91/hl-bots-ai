from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ai_director.evaluation import EPSILON, analyze_lane, compare_lane_summaries, load_ndjson


DEFAULT_POST_PATCH_OBSERVATION_SECONDS = 20.0


def read_json(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def _unwrap_lane_summary(payload: dict[str, Any] | None) -> dict[str, Any] | None:
    if not isinstance(payload, dict):
        return None
    primary_lane = payload.get("primary_lane")
    if isinstance(primary_lane, dict):
        return primary_lane
    return payload


def _unwrap_comparison(payload: dict[str, Any] | None) -> dict[str, Any] | None:
    if not isinstance(payload, dict):
        return None
    comparison = payload.get("comparison")
    if isinstance(comparison, dict):
        return comparison
    return payload


def _safe_match_id(match_id: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "_", match_id)


def _runtime_history_path(runtime_dir: Path, kind: str, match_id: str) -> Path:
    return runtime_dir / "history" / f"{kind}-{_safe_match_id(match_id)}.ndjson"


def _record_span_seconds(telemetry_records: list[dict[str, Any]], index: int) -> float:
    record = telemetry_records[index]
    active_balance = record.get("active_balance", {})
    interval_seconds = max(1.0, float(active_balance.get("interval_seconds", 20.0)))
    current_time = float(record.get("server_time_seconds", 0.0))
    if index + 1 >= len(telemetry_records):
        return interval_seconds

    next_time = float(telemetry_records[index + 1].get("server_time_seconds", current_time + interval_seconds))
    delta = next_time - current_time
    if delta <= 0.0:
        return interval_seconds
    return min(interval_seconds, delta)


def _latest_telemetry_at_or_before(
    telemetry_records: list[dict[str, Any]], server_time: float
) -> dict[str, Any] | None:
    latest_record: dict[str, Any] | None = None
    for record in telemetry_records:
        record_time = float(record.get("server_time_seconds", 0.0))
        if record_time <= server_time + EPSILON:
            latest_record = record
            continue
        break
    return latest_record


def _human_present(record: dict[str, Any] | None) -> bool:
    if not isinstance(record, dict):
        return False
    return int(record.get("human_player_count", 0)) > 0 and int(record.get("bot_count", 0)) > 0


def _lane_records_from_runtime(runtime_dir: Path) -> tuple[str, list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]], dict[str, Any] | None, dict[str, Any] | None]:
    latest_telemetry = read_json(runtime_dir / "telemetry.json")
    latest_patch = read_json(runtime_dir / "patch.json")
    match_id = ""
    if isinstance(latest_telemetry, dict):
        match_id = str(latest_telemetry.get("match_id", "")).strip()
    if not match_id and isinstance(latest_patch, dict):
        match_id = str(latest_patch.get("match_id", "")).strip()

    telemetry_records: list[dict[str, Any]] = []
    patch_records: list[dict[str, Any]] = []
    apply_records: list[dict[str, Any]] = []

    if match_id:
        telemetry_records = load_ndjson(_runtime_history_path(runtime_dir, "telemetry", match_id))
        patch_records = load_ndjson(_runtime_history_path(runtime_dir, "patch", match_id))
        apply_records = load_ndjson(_runtime_history_path(runtime_dir, "patch_apply", match_id))

    if not telemetry_records and isinstance(latest_telemetry, dict):
        telemetry_records = [latest_telemetry]
    if not patch_records and isinstance(latest_patch, dict):
        patch_records = [latest_patch]

    return (match_id, telemetry_records, patch_records, apply_records, latest_telemetry, latest_patch)


def _lane_records_from_lane_root(
    lane_root: Path,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    return (
        load_ndjson(lane_root / "telemetry_history.ndjson"),
        load_ndjson(lane_root / "patch_history.ndjson"),
        load_ndjson(lane_root / "patch_apply_history.ndjson"),
    )


@dataclass(frozen=True)
class MonitorThresholds:
    min_control_human_snapshots: int
    min_control_human_presence_seconds: float
    min_treatment_human_snapshots: int
    min_treatment_human_presence_seconds: float
    min_treatment_patch_events_while_humans_present: int
    min_post_patch_observation_seconds: float

    def normalized(self) -> "MonitorThresholds":
        return MonitorThresholds(
            min_control_human_snapshots=max(1, int(self.min_control_human_snapshots)),
            min_control_human_presence_seconds=max(1.0, float(self.min_control_human_presence_seconds)),
            min_treatment_human_snapshots=max(1, int(self.min_treatment_human_snapshots)),
            min_treatment_human_presence_seconds=max(1.0, float(self.min_treatment_human_presence_seconds)),
            min_treatment_patch_events_while_humans_present=max(
                1, int(self.min_treatment_patch_events_while_humans_present)
            ),
            min_post_patch_observation_seconds=max(1.0, float(self.min_post_patch_observation_seconds)),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "min_control_human_snapshots": self.min_control_human_snapshots,
            "min_control_human_presence_seconds": round(self.min_control_human_presence_seconds, 1),
            "min_treatment_human_snapshots": self.min_treatment_human_snapshots,
            "min_treatment_human_presence_seconds": round(self.min_treatment_human_presence_seconds, 1),
            "min_treatment_patch_events_while_humans_present": self.min_treatment_patch_events_while_humans_present,
            "min_post_patch_observation_seconds": round(self.min_post_patch_observation_seconds, 1),
        }


def _now_utc() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _build_live_manifest(
    *,
    mode: str,
    lane_label: str,
    treatment_profile: str,
    telemetry_records: list[dict[str, Any]],
    match_id: str,
    thresholds: MonitorThresholds,
    prompt_id: str,
) -> dict[str, Any]:
    latest = telemetry_records[-1] if telemetry_records else {}
    smoke_status = "ai-healthy" if mode.upper() == "AI" else "no-ai-healthy"
    summary = {
        "prompt_id": prompt_id,
        "mode": mode,
        "lane_label": lane_label,
        "map": str(latest.get("map_name", "crossfire")),
        "tuning_profile": treatment_profile if mode.upper() == "AI" else None,
        "bot_count": int(latest.get("bot_count", 4)) if latest else 4,
        "bot_skill": int(latest.get("current_default_bot_skill_level", 3)) if latest else 3,
        "requested_duration_seconds": int(float(latest.get("server_time_seconds", 0.0))) if latest else 0,
        "duration_seconds": int(float(latest.get("server_time_seconds", 0.0))) if latest else 0,
        "wait_for_human_join": True,
        "human_join_grace_seconds": 0,
        "human_join_observed": any(int(record.get("human_player_count", 0)) > 0 for record in telemetry_records),
        "human_join_timed_out": False,
        "bootstrap_log_present": True,
        "attach_observed": bool(telemetry_records),
        "ai_sidecar_observed": mode.upper() == "AI",
        "smoke_status": smoke_status,
        "smoke_summary": "Live monitor inference from the active runtime artifacts.",
        "match_id": match_id,
        "min_human_snapshots": (
            thresholds.min_treatment_human_snapshots if mode.upper() == "AI" else thresholds.min_control_human_snapshots
        ),
        "min_human_presence_seconds": (
            thresholds.min_treatment_human_presence_seconds
            if mode.upper() == "AI"
            else thresholds.min_control_human_presence_seconds
        ),
        "min_patch_events_for_usable_lane": (
            thresholds.min_treatment_patch_events_while_humans_present if mode.upper() == "AI" else 0
        ),
    }
    return summary


def _live_summary_from_runtime(
    *,
    mode: str,
    lane_label: str,
    treatment_profile: str,
    runtime_dir: Path,
    thresholds: MonitorThresholds,
    prompt_id: str,
) -> tuple[dict[str, Any] | None, list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]], dict[str, Any] | None]:
    match_id, telemetry_records, patch_records, apply_records, latest_telemetry, latest_patch = _lane_records_from_runtime(runtime_dir)
    if not telemetry_records:
        return (None, [], [], [], latest_telemetry)

    manifest = _build_live_manifest(
        mode=mode,
        lane_label=lane_label,
        treatment_profile=treatment_profile,
        telemetry_records=telemetry_records,
        match_id=match_id,
        thresholds=thresholds,
        prompt_id=prompt_id,
    )
    summary = analyze_lane(manifest, telemetry_records, patch_records, apply_records)
    return (summary, telemetry_records, patch_records, apply_records, latest_patch)


def _post_patch_observation_seconds(
    telemetry_records: list[dict[str, Any]], apply_records: list[dict[str, Any]]
) -> float:
    if not telemetry_records or not apply_records:
        return 0.0

    first_human_present_apply_time: float | None = None
    for record in apply_records:
        apply_time = float(record.get("server_time_seconds", 0.0))
        current_state = _latest_telemetry_at_or_before(telemetry_records, apply_time)
        if not _human_present(current_state):
            continue
        first_human_present_apply_time = apply_time
        break

    if first_human_present_apply_time is None:
        return 0.0

    total_seconds = 0.0
    for index, record in enumerate(telemetry_records):
        record_time = float(record.get("server_time_seconds", 0.0))
        if record_time <= first_human_present_apply_time + EPSILON:
            continue
        if not _human_present(record):
            continue
        total_seconds += _record_span_seconds(telemetry_records, index)

    return round(total_seconds, 1)


def _artifact_path(path: Path) -> str:
    return str(path) if path.exists() else ""


def compute_status(
    *,
    pair_root: Path,
    runtime_dir: Path | None,
    thresholds: MonitorThresholds,
    treatment_profile: str = "conservative",
    prompt_id: str = "",
) -> dict[str, Any]:
    thresholds = thresholds.normalized()
    pair_root = pair_root.resolve()
    control_lane_root = pair_root / "lanes" / "control"
    treatment_lane_root = pair_root / "lanes" / "treatment"
    control_summary_path = control_lane_root / "summary.json"
    treatment_summary_path = treatment_lane_root / "summary.json"
    comparison_path = pair_root / "comparison.json"
    pair_summary_path = pair_root / "pair_summary.json"

    pair_summary = read_json(pair_summary_path)
    comparison = _unwrap_comparison(read_json(comparison_path))
    control_summary = _unwrap_lane_summary(read_json(control_summary_path))
    treatment_summary = _unwrap_lane_summary(read_json(treatment_summary_path))

    if isinstance(pair_summary, dict):
        prompt_id = prompt_id or str(pair_summary.get("prompt_id", ""))
        treatment_profile = str(pair_summary.get("treatment_profile", treatment_profile) or treatment_profile)
    if isinstance(treatment_summary, dict):
        treatment_profile = str(treatment_summary.get("tuning_profile", treatment_profile) or treatment_profile)

    phase = "unknown"
    treatment_telemetry_records: list[dict[str, Any]] = []
    treatment_apply_records: list[dict[str, Any]] = []
    latest_runtime_patch: dict[str, Any] | None = None

    if not isinstance(control_summary, dict):
        phase = "control-live"
        if runtime_dir is not None and runtime_dir.exists():
            control_summary, _, _, _, _ = _live_summary_from_runtime(
                mode="NoAI",
                lane_label="control-baseline",
                treatment_profile=treatment_profile,
                runtime_dir=runtime_dir,
                thresholds=thresholds,
                prompt_id=prompt_id,
            )
    elif not isinstance(treatment_summary, dict):
        phase = "treatment-pending"
        if runtime_dir is not None and runtime_dir.exists():
            live_treatment_summary, treatment_telemetry_records, _, treatment_apply_records, latest_runtime_patch = _live_summary_from_runtime(
                mode="AI",
                lane_label=f"treatment-{treatment_profile}",
                treatment_profile=treatment_profile,
                runtime_dir=runtime_dir,
                thresholds=thresholds,
                prompt_id=prompt_id,
            )
            active_balance_enabled = bool(
                int(((treatment_telemetry_records[-1] if treatment_telemetry_records else {}).get("active_balance", {}) or {}).get("enabled", 0))
            )
            if isinstance(live_treatment_summary, dict) and (
                active_balance_enabled or treatment_apply_records or latest_runtime_patch is not None
            ):
                treatment_summary = live_treatment_summary
                phase = "treatment-live"
    elif isinstance(pair_summary, dict) and isinstance(comparison, dict):
        phase = "completed"
    else:
        phase = "pair-packaging"

    if phase == "completed" and not treatment_telemetry_records and treatment_lane_root.exists():
        treatment_telemetry_records, _, treatment_apply_records = _lane_records_from_lane_root(treatment_lane_root)
    if phase != "completed" and not treatment_telemetry_records and treatment_lane_root.exists() and treatment_summary_path.exists():
        treatment_telemetry_records, _, treatment_apply_records = _lane_records_from_lane_root(treatment_lane_root)

    if not isinstance(control_summary, dict) and not isinstance(pair_summary, dict) and phase == "control-live":
        control_summary = None

    if isinstance(control_summary, dict) and isinstance(treatment_summary, dict) and not isinstance(comparison, dict):
        comparison = compare_lane_summaries(control_summary, treatment_summary)

    control_human_snapshots = int((control_summary or {}).get("human_snapshots_count", 0))
    control_human_presence_seconds = float((control_summary or {}).get("seconds_with_human_presence", 0.0))
    treatment_human_snapshots = int((treatment_summary or {}).get("human_snapshots_count", 0))
    treatment_human_presence_seconds = float((treatment_summary or {}).get("seconds_with_human_presence", 0.0))
    treatment_patch_events_while_humans_present = int(
        (treatment_summary or {}).get("patch_events_while_humans_present_count", 0)
    )
    treatment_response_windows = int(
        (treatment_summary or {}).get("response_after_patch_observation_window_count", 0)
    )
    meaningful_post_patch_observation_seconds = _post_patch_observation_seconds(
        treatment_telemetry_records, treatment_apply_records
    )

    control_ready = (
        control_human_snapshots >= thresholds.min_control_human_snapshots
        and control_human_presence_seconds + EPSILON >= thresholds.min_control_human_presence_seconds
    )
    treatment_ready = (
        treatment_human_snapshots >= thresholds.min_treatment_human_snapshots
        and treatment_human_presence_seconds + EPSILON >= thresholds.min_treatment_human_presence_seconds
    )
    patch_ready = (
        treatment_patch_events_while_humans_present
        >= thresholds.min_treatment_patch_events_while_humans_present
    )
    post_patch_ready = (
        treatment_response_windows > 0
        and meaningful_post_patch_observation_seconds + EPSILON
        >= thresholds.min_post_patch_observation_seconds
    )
    pair_complete = isinstance(pair_summary, dict) and isinstance(comparison, dict)

    if not pair_root.exists():
        verdict = "blocked-no-active-pair-run"
        explanation = "The requested pair root does not exist."
    elif pair_complete and control_ready and treatment_ready and patch_ready and post_patch_ready:
        verdict = "sufficient-for-scorecard"
        explanation = (
            "Both lanes cleared the human gate, treatment patched while humans were present, "
            "the post-patch observation window is long enough, and the pair artifacts are finalized."
        )
    elif pair_complete:
        verdict = "insufficient-data-timeout"
        explanation = (
            "The pair pack is already finalized, but it stopped before the grounded evidence gate was cleared."
        )
    elif not control_ready:
        verdict = "waiting-for-control-human-signal"
        explanation = (
            f"Control has {control_human_snapshots}/{thresholds.min_control_human_snapshots} human snapshots and "
            f"{round(control_human_presence_seconds, 1)}/{round(thresholds.min_control_human_presence_seconds, 1)} seconds "
            "of human presence. Keep the control lane running longer."
        )
    elif not treatment_ready:
        verdict = "waiting-for-treatment-human-signal"
        explanation = (
            f"Treatment has {treatment_human_snapshots}/{thresholds.min_treatment_human_snapshots} human snapshots and "
            f"{round(treatment_human_presence_seconds, 1)}/{round(thresholds.min_treatment_human_presence_seconds, 1)} seconds "
            "of human presence. Keep the treatment lane running longer."
        )
    elif not patch_ready:
        verdict = "waiting-for-treatment-patch-while-humans-present"
        explanation = (
            f"Treatment human presence is usable, but only {treatment_patch_events_while_humans_present}/"
            f"{thresholds.min_treatment_patch_events_while_humans_present} patch events happened while humans were present."
        )
    elif not post_patch_ready:
        verdict = "waiting-for-post-patch-observation-window"
        explanation = (
            f"Treatment already patched while humans were present, but only "
            f"{round(meaningful_post_patch_observation_seconds, 1)}/"
            f"{round(thresholds.min_post_patch_observation_seconds, 1)} seconds of human-present observation "
            "have been captured after the first live patch apply."
        )
    else:
        verdict = "sufficient-for-tuning-usable-review"
        explanation = (
            "Both lanes cleared the human gate, treatment patched while humans were present, "
            "and the post-patch observation window is already long enough. The operator can stop the session now."
        )

    operator_can_stop_now = verdict in {
        "sufficient-for-scorecard",
        "sufficient-for-tuning-usable-review",
        "insufficient-data-timeout",
    }
    likely_insufficient_if_stopped_immediately = verdict not in {
        "sufficient-for-scorecard",
        "sufficient-for-tuning-usable-review",
    }

    return {
        "schema_version": 1,
        "generated_at_utc": _now_utc(),
        "pair_root": str(pair_root),
        "phase": phase,
        "pair_complete": pair_complete,
        "comparison_available": isinstance(comparison, dict),
        "treatment_profile": treatment_profile,
        "thresholds": thresholds.to_dict(),
        "control_human_snapshots_count": control_human_snapshots,
        "control_human_presence_seconds": round(control_human_presence_seconds, 1),
        "treatment_human_snapshots_count": treatment_human_snapshots,
        "treatment_human_presence_seconds": round(treatment_human_presence_seconds, 1),
        "treatment_patch_events_while_humans_present": treatment_patch_events_while_humans_present,
        "meaningful_post_patch_observation_seconds": round(meaningful_post_patch_observation_seconds, 1),
        "treatment_response_after_patch_window_count": treatment_response_windows,
        "current_verdict": verdict,
        "explanation": explanation,
        "operator_can_stop_now": operator_can_stop_now,
        "likely_remains_insufficient_if_stopped_immediately": likely_insufficient_if_stopped_immediately,
        "control_lane_quality_verdict": str((control_summary or {}).get("lane_quality_verdict", "")),
        "treatment_lane_quality_verdict": str((treatment_summary or {}).get("lane_quality_verdict", "")),
        "comparison_verdict": str((comparison or {}).get("comparison_verdict", "")),
        "comparison_explanation": str((comparison or {}).get("comparison_explanation", "")),
        "artifacts": {
            "control_summary_json": _artifact_path(control_summary_path),
            "treatment_summary_json": _artifact_path(treatment_summary_path),
            "comparison_json": _artifact_path(comparison_path),
            "pair_summary_json": _artifact_path(pair_summary_path),
        },
    }
