from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from ai_director.evaluation import analyze_lane, compare_lane_summaries, simulate_replay

FIXTURE_ROOT = REPO_ROOT / "ai_director" / "testdata" / "pair_sessions"
DEFINITIONS_PATH = FIXTURE_ROOT / "fixture_definitions.json"
REPLAY_SCENARIOS_PATH = REPO_ROOT / "ai_director" / "testdata" / "replay_scenarios.json"
SYNTHETIC_PROMPT_ID = "HLDM-JKBOTTI-AI-STAND-20260415-23-SYNTHETIC"
SYNTHETIC_NOTE = (
    "Synthetic decision-validation fixture generated from deterministic replay frames. "
    "This is not a real live pair run."
)
BOT_COUNT = 4
BOT_SKILL = 3
CONTROL_PORT = 27016
TREATMENT_PORT = 27017


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def write_ndjson(path: Path, records: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        for record in records:
            handle.write(json.dumps(record, separators=(",", ":")) + "\n")


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content.rstrip() + "\n", encoding="utf-8")


def windows_rel(path: Path) -> str:
    return str(path).replace("/", "\\")


def resolve_frames(
    fixture: dict[str, Any],
    key: str,
    replay_scenarios: dict[str, list[dict[str, Any]]],
) -> list[dict[str, Any]]:
    value = fixture[key]
    if isinstance(value, str):
        return list(replay_scenarios[value])
    return list(value)


def control_manifest(
    fixture_id: str,
    *,
    lane_label: str,
    duration_seconds: int,
    min_human_snapshots: int,
    min_human_presence_seconds: float,
    min_patch_events_for_usable_lane: int,
) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "prompt_id": SYNTHETIC_PROMPT_ID,
        "synthetic_fixture": True,
        "fixture_id": fixture_id,
        "fixture_note": SYNTHETIC_NOTE,
        "mode": "NoAI",
        "lane_label": lane_label,
        "map": "crossfire",
        "bot_count": BOT_COUNT,
        "bot_skill": BOT_SKILL,
        "requested_duration_seconds": duration_seconds,
        "duration_seconds": duration_seconds,
        "wait_for_human_join": True,
        "human_join_grace_seconds": 120,
        "bootstrap_log_present": True,
        "attach_observed": True,
        "ai_sidecar_observed": False,
        "smoke_status": "no-ai-healthy",
        "smoke_summary": (
            "Synthetic control-lane fixture: no AI sidecar, no hidden information, "
            "and no patch path."
        ),
        "min_human_snapshots": min_human_snapshots,
        "min_human_presence_seconds": float(min_human_presence_seconds),
        "min_patch_events_for_usable_lane": min_patch_events_for_usable_lane,
        "source_commit_sha": "synthetic-fixture",
    }


def build_control_lane(
    fixture_id: str,
    frames: list[dict[str, Any]],
    *,
    lane_label: str,
    min_human_snapshots: int,
    min_human_presence_seconds: float,
    min_patch_events_for_usable_lane: int,
) -> dict[str, Any]:
    telemetry_records: list[dict[str, Any]] = []
    for index, frame in enumerate(frames, start=1):
        frag_gap = int(frame.get("frag_gap_top_human_minus_top_bot", 0))
        base_top_score = 15
        telemetry_records.append(
            {
                "schema_version": 1,
                "match_id": f"synthetic-{fixture_id}-control",
                "telemetry_sequence": index,
                "timestamp_utc": str(
                    frame.get("timestamp_utc", f"2026-04-18T00:00:{index:02d}Z")
                ),
                "server_time_seconds": float(
                    frame.get("server_time_seconds", index * 20.0)
                ),
                "map_name": str(frame.get("map_name", "crossfire")),
                "human_player_count": max(0, int(frame.get("human_player_count", 0))),
                "bot_count": max(0, int(frame.get("bot_count", BOT_COUNT))),
                "top_human_frags": base_top_score + max(frag_gap, 0),
                "top_human_deaths": max(0, int(frame.get("top_human_deaths", 8))),
                "top_bot_frags": base_top_score + max(-frag_gap, 0),
                "top_bot_deaths": max(0, int(frame.get("top_bot_deaths", 8))),
                "recent_human_kills_per_minute": max(
                    0, int(frame.get("recent_human_kills_per_minute", 0))
                ),
                "recent_bot_kills_per_minute": max(
                    0, int(frame.get("recent_bot_kills_per_minute", 0))
                ),
                "frag_gap_top_human_minus_top_bot": frag_gap,
                "current_default_bot_skill_level": BOT_SKILL,
                "active_balance": {
                    "pause_frequency_scale": 1.0,
                    "battle_strafe_scale": 1.0,
                    "interval_seconds": float(frame.get("interval_seconds", 20.0)),
                    "cooldown_seconds": 30.0,
                    "enabled": 0,
                },
            }
        )

    duration_seconds = int(
        float(frames[-1].get("server_time_seconds", len(frames) * 20.0))
    )
    manifest = control_manifest(
        fixture_id,
        lane_label=lane_label,
        duration_seconds=duration_seconds,
        min_human_snapshots=min_human_snapshots,
        min_human_presence_seconds=min_human_presence_seconds,
        min_patch_events_for_usable_lane=min_patch_events_for_usable_lane,
    )
    summary = analyze_lane(manifest, telemetry_records, [], [])
    return {
        "manifest": manifest,
        "telemetry_records": telemetry_records,
        "patch_records": [],
        "apply_records": [],
        "summary": summary,
    }


def operator_note_classification(
    control_summary: dict[str, Any],
    treatment_summary: dict[str, Any],
    comparison: dict[str, Any],
) -> str:
    comparison_verdict = str(comparison.get("comparison_verdict", ""))
    if comparison_verdict == "comparison-strong-signal":
        return "strong-signal"
    if comparison_verdict == "comparison-usable":
        return "tuning-usable"

    control_plumbing_healthy = str(control_summary.get("smoke_status", "")) == "no-ai-healthy"
    treatment_plumbing_healthy = str(treatment_summary.get("smoke_status", "")) in {
        "ai-healthy",
        "simulated",
    }
    control_usable = bool(control_summary.get("tuning_signal_usable", False))
    treatment_usable = bool(treatment_summary.get("tuning_signal_usable", False))
    if (
        control_plumbing_healthy
        and treatment_plumbing_healthy
        and not control_usable
        and not treatment_usable
    ):
        return "plumbing-valid only"
    return "partially usable"


def operator_note_text(
    classification: str,
    description: str,
    comparison: dict[str, Any],
) -> str:
    base_reason = str(comparison.get("comparison_explanation", ""))
    if classification == "strong-signal":
        detail = (
            "Both lanes were human-usable and the treatment lane captured multiple grounded "
            "post-patch windows."
        )
    elif classification == "tuning-usable":
        detail = (
            "Both lanes were human-usable and the treatment lane produced grounded live "
            "treatment evidence."
        )
    elif classification == "plumbing-valid only":
        detail = (
            "Both launch paths stayed healthy, but neither lane captured enough human signal "
            "to support tuning claims."
        )
    else:
        detail = (
            "At least one lane captured some useful signal, but the pair is still too weak for "
            "an honest control-vs-treatment conclusion."
        )
    return f"Synthetic fixture: {description} {detail} {base_reason}".strip()


def render_lane_summary_markdown(summary: dict[str, Any]) -> str:
    lines = [
        "# Synthetic Lane Summary",
        "",
        f"- Synthetic fixture: True",
        f"- Lane label: {summary.get('lane_label', '')}",
        f"- Mode: {summary.get('mode', '')}",
        f"- Lane verdict: {summary.get('lane_quality_verdict', '')}",
        f"- Evidence quality: {summary.get('evidence_quality', '')}",
        f"- Behavior verdict: {summary.get('behavior_verdict', '')}",
        f"- Human signal verdict: {summary.get('human_signal_verdict', '')}",
        f"- Human snapshots: {summary.get('human_snapshots_count', 0)}",
        f"- Seconds with human presence: {summary.get('seconds_with_human_presence', 0.0)}",
        f"- Patch apply count: {summary.get('patch_apply_count', 0)}",
        f"- Response-after-patch windows: {summary.get('response_after_patch_observation_window_count', 0)}",
        "",
        f"- Explanation: {summary.get('explanation', '')}",
    ]
    return "\n".join(lines) + "\n"


def render_session_pack_markdown(manifest: dict[str, Any], summary: dict[str, Any]) -> str:
    lines = [
        "# Synthetic Session Pack",
        "",
        f"- Synthetic fixture: True",
        f"- Fixture ID: {manifest.get('fixture_id', '')}",
        f"- Lane label: {manifest.get('lane_label', '')}",
        f"- Mode: {manifest.get('mode', '')}",
        f"- Map: {manifest.get('map', '')}",
        f"- Bot count: {manifest.get('bot_count', 0)}",
        f"- Bot skill: {manifest.get('bot_skill', 0)}",
        f"- Tuning profile: {summary.get('tuning_profile', '')}",
        f"- Note: {manifest.get('fixture_note', '')}",
    ]
    return "\n".join(lines) + "\n"


def render_comparison_markdown(
    comparison: dict[str, Any],
    control_summary: dict[str, Any],
    treatment_summary: dict[str, Any],
) -> str:
    lines = [
        "# Synthetic Pair Comparison",
        "",
        f"- Synthetic fixture: True",
        f"- Comparison verdict: {comparison.get('comparison_verdict', '')}",
        f"- Comparison usable: {comparison.get('comparison_is_tuning_usable', False)}",
        f"- Control evidence quality: {control_summary.get('evidence_quality', '')}",
        f"- Treatment evidence quality: {treatment_summary.get('evidence_quality', '')}",
        f"- Treatment relative to control: {comparison.get('treatment_relative_to_control', '')}",
        f"- Treatment patched while humans present: {comparison.get('treatment_patched_while_humans_present', False)}",
        f"- Meaningful post-patch observation window: {comparison.get('meaningful_post_patch_observation_window_exists', False)}",
        "",
        f"- Reason: {comparison.get('comparison_reason', '')}",
    ]
    return "\n".join(lines) + "\n"


def render_pair_summary_markdown(pair_summary: dict[str, Any]) -> str:
    lines = [
        "# Synthetic Pair Summary",
        "",
        f"- Synthetic fixture: True",
        f"- Fixture ID: {pair_summary.get('fixture_id', '')}",
        f"- Pair classification: {pair_summary.get('operator_note_classification', '')}",
        f"- Comparison verdict: {pair_summary.get('comparison', {}).get('comparison_verdict', '')}",
        f"- Operator note: {pair_summary.get('operator_note', '')}",
        "",
        "## Control Lane",
        "",
        f"- Lane verdict: {pair_summary.get('control_lane', {}).get('lane_verdict', '')}",
        f"- Evidence quality: {pair_summary.get('control_lane', {}).get('evidence_quality', '')}",
        f"- Human snapshots: {pair_summary.get('control_lane', {}).get('human_snapshots_count', 0)}",
        "",
        "## Treatment Lane",
        "",
        f"- Lane verdict: {pair_summary.get('treatment_lane', {}).get('lane_verdict', '')}",
        f"- Treatment profile: {pair_summary.get('treatment_lane', {}).get('treatment_profile', '')}",
        f"- Evidence quality: {pair_summary.get('treatment_lane', {}).get('evidence_quality', '')}",
        f"- Human snapshots: {pair_summary.get('treatment_lane', {}).get('human_snapshots_count', 0)}",
    ]
    return "\n".join(lines) + "\n"


def lane_join_instructions(role_name: str, mode: str, lane_label: str, port: int) -> str:
    lines = [
        "Synthetic HLDM paired lane instructions",
        f"Role: {role_name}",
        f"Mode: {mode}",
        f"Lane label: {lane_label}",
        f"Loopback join target: 127.0.0.1:{port}",
        "Synthetic fixture only. Do not treat this as a real operator runbook.",
    ]
    return "\n".join(lines) + "\n"


def pair_join_instructions(treatment_profile: str) -> str:
    lines = [
        "Synthetic HLDM paired instructions",
        "Control lane comes first, treatment lane second.",
        f"Treatment profile: {treatment_profile}",
        "Synthetic fixture only. This pair pack exists to validate the post-run decision stack.",
    ]
    return "\n".join(lines) + "\n"


def build_fixture(fixture: dict[str, Any], replay_scenarios: dict[str, list[dict[str, Any]]], output_root: Path) -> None:
    fixture_id = str(fixture["id"])
    description = str(fixture["description"])
    treatment_profile = str(fixture["treatment_profile"])
    min_human_snapshots = int(fixture["min_human_snapshots"])
    min_human_presence_seconds = float(fixture["min_human_presence_seconds"])
    min_patch_events_for_usable_lane = int(fixture["min_patch_events_for_usable_lane"])

    control_frames = resolve_frames(fixture, "control_frames", replay_scenarios)
    treatment_frames = resolve_frames(fixture, "treatment_frames", replay_scenarios)

    control_lane = build_control_lane(
        fixture_id,
        control_frames,
        lane_label="control-baseline",
        min_human_snapshots=min_human_snapshots,
        min_human_presence_seconds=min_human_presence_seconds,
        min_patch_events_for_usable_lane=min_patch_events_for_usable_lane,
    )
    treatment_lane = simulate_replay(
        f"synthetic-{fixture_id}-treatment",
        treatment_frames,
        tuning_profile=treatment_profile,
        lane_label=f"treatment-{treatment_profile}",
        min_human_snapshots=min_human_snapshots,
        min_human_presence_seconds=min_human_presence_seconds,
        min_patch_events_for_usable_lane=min_patch_events_for_usable_lane,
    )
    comparison = compare_lane_summaries(control_lane["summary"], treatment_lane["summary"])
    pair_classification = operator_note_classification(
        control_lane["summary"], treatment_lane["summary"], comparison
    )
    pair_root = output_root / fixture_id
    if pair_root.exists():
        shutil.rmtree(pair_root)
    pair_root.mkdir(parents=True, exist_ok=True)

    control_root = pair_root / "lanes" / "control"
    treatment_root = pair_root / "lanes" / "treatment"

    control_summary_path = control_root / "summary.json"
    control_summary_md_path = control_root / "summary.md"
    control_session_pack_path = control_root / "session_pack.json"
    control_session_pack_md_path = control_root / "session_pack.md"
    control_lane_json_path = control_root / "lane.json"
    treatment_summary_path = treatment_root / "summary.json"
    treatment_summary_md_path = treatment_root / "summary.md"
    treatment_session_pack_path = treatment_root / "session_pack.json"
    treatment_session_pack_md_path = treatment_root / "session_pack.md"
    treatment_lane_json_path = treatment_root / "lane.json"

    control_manifest = {
        **control_lane["manifest"],
        "summary_json": "summary.json",
        "summary_markdown": "summary.md",
        "session_pack_markdown": "session_pack.md",
        "lane_json": "lane.json",
        "join_instructions": "..\\..\\control_join_instructions.txt",
        "copied_artifacts": {
            "telemetry_history": "telemetry_history.ndjson",
            "patch_history": "patch_history.ndjson",
            "patch_apply_history": "patch_apply_history.ndjson",
        },
    }
    treatment_manifest = {
        **treatment_lane["manifest"],
        "prompt_id": SYNTHETIC_PROMPT_ID,
        "synthetic_fixture": True,
        "fixture_id": fixture_id,
        "fixture_note": SYNTHETIC_NOTE,
        "summary_json": "summary.json",
        "summary_markdown": "summary.md",
        "session_pack_markdown": "session_pack.md",
        "lane_json": "lane.json",
        "join_instructions": "..\\..\\treatment_join_instructions.txt",
        "copied_artifacts": {
            "telemetry_history": "telemetry_history.ndjson",
            "patch_history": "patch_history.ndjson",
            "patch_apply_history": "patch_apply_history.ndjson",
        },
        "source_commit_sha": "synthetic-fixture",
    }

    write_json(control_summary_path, {"primary_lane": control_lane["summary"]})
    write_json(treatment_summary_path, {"primary_lane": treatment_lane["summary"]})
    write_text(control_summary_md_path, render_lane_summary_markdown(control_lane["summary"]))
    write_text(
        treatment_summary_md_path,
        render_lane_summary_markdown(treatment_lane["summary"]),
    )
    write_json(control_session_pack_path, control_manifest)
    write_json(treatment_session_pack_path, treatment_manifest)
    write_text(
        control_session_pack_md_path,
        render_session_pack_markdown(control_manifest, control_lane["summary"]),
    )
    write_text(
        treatment_session_pack_md_path,
        render_session_pack_markdown(treatment_manifest, treatment_lane["summary"]),
    )
    write_json(
        control_lane_json_path,
        {
            "schema_version": 1,
            "synthetic_fixture": True,
            "fixture_id": fixture_id,
            "fixture_note": SYNTHETIC_NOTE,
            "lane_label": "control-baseline",
            "mode": "NoAI",
            "summary_json": "summary.json",
            "session_pack_json": "session_pack.json",
        },
    )
    write_json(
        treatment_lane_json_path,
        {
            "schema_version": 1,
            "synthetic_fixture": True,
            "fixture_id": fixture_id,
            "fixture_note": SYNTHETIC_NOTE,
            "lane_label": f"treatment-{treatment_profile}",
            "mode": "AI",
            "summary_json": "summary.json",
            "session_pack_json": "session_pack.json",
        },
    )
    write_ndjson(control_root / "telemetry_history.ndjson", control_lane["telemetry_records"])
    write_ndjson(control_root / "patch_history.ndjson", control_lane["patch_records"])
    write_ndjson(control_root / "patch_apply_history.ndjson", control_lane["apply_records"])
    write_ndjson(treatment_root / "telemetry_history.ndjson", treatment_lane["telemetry_records"])
    write_ndjson(treatment_root / "patch_history.ndjson", treatment_lane["patch_records"])
    write_ndjson(treatment_root / "patch_apply_history.ndjson", treatment_lane["apply_records"])

    comparison_payload = {
        "synthetic_fixture": True,
        "fixture_id": fixture_id,
        "primary_lane": control_lane["summary"],
        "secondary_lane": treatment_lane["summary"],
        "comparison": comparison,
    }
    write_json(pair_root / "comparison.json", comparison_payload)
    write_text(
        pair_root / "comparison.md",
        render_comparison_markdown(
            comparison, control_lane["summary"], treatment_lane["summary"]
        ),
    )

    control_lane_rel = Path("lanes") / "control"
    treatment_lane_rel = Path("lanes") / "treatment"
    pair_summary = {
        "schema_version": 1,
        "prompt_id": SYNTHETIC_PROMPT_ID,
        "synthetic_fixture": True,
        "fixture_id": fixture_id,
        "fixture_description": description,
        "fixture_note": SYNTHETIC_NOTE,
        "source_commit_sha": "synthetic-fixture",
        "pair_id": f"synthetic-{fixture_id}",
        "pair_root": ".",
        "map": "crossfire",
        "bot_count": BOT_COUNT,
        "bot_skill": BOT_SKILL,
        "duration_seconds": max(
            int(control_lane["summary"].get("duration_seconds", 0)),
            int(treatment_lane["summary"].get("duration_seconds", 0)),
        ),
        "wait_for_human_join": True,
        "human_join_grace_seconds": 120,
        "min_human_snapshots": min_human_snapshots,
        "min_human_presence_seconds": min_human_presence_seconds,
        "min_patch_events_for_usable_lane": min_patch_events_for_usable_lane,
        "treatment_profile": treatment_profile,
        "control_lane": {
            "lane_root": windows_rel(control_lane_rel),
            "lane_label": "control-baseline",
            "mode": "NoAI",
            "port": CONTROL_PORT,
            "join_target": f"127.0.0.1:{CONTROL_PORT}",
            "join_instructions": "control_join_instructions.txt",
            "session_pack_json": windows_rel(control_lane_rel / "session_pack.json"),
            "session_pack_markdown": windows_rel(control_lane_rel / "session_pack.md"),
            "summary_json": windows_rel(control_lane_rel / "summary.json"),
            "summary_markdown": windows_rel(control_lane_rel / "summary.md"),
            "lane_verdict": control_lane["summary"]["lane_quality_verdict"],
            "evidence_quality": control_lane["summary"]["evidence_quality"],
            "behavior_verdict": control_lane["summary"]["behavior_verdict"],
            "human_snapshots_count": control_lane["summary"]["human_snapshots_count"],
            "seconds_with_human_presence": control_lane["summary"]["seconds_with_human_presence"],
        },
        "treatment_lane": {
            "lane_root": windows_rel(treatment_lane_rel),
            "lane_label": f"treatment-{treatment_profile}",
            "mode": "AI",
            "port": TREATMENT_PORT,
            "treatment_profile": treatment_profile,
            "join_target": f"127.0.0.1:{TREATMENT_PORT}",
            "join_instructions": "treatment_join_instructions.txt",
            "session_pack_json": windows_rel(treatment_lane_rel / "session_pack.json"),
            "session_pack_markdown": windows_rel(treatment_lane_rel / "session_pack.md"),
            "summary_json": windows_rel(treatment_lane_rel / "summary.json"),
            "summary_markdown": windows_rel(treatment_lane_rel / "summary.md"),
            "lane_verdict": treatment_lane["summary"]["lane_quality_verdict"],
            "evidence_quality": treatment_lane["summary"]["evidence_quality"],
            "behavior_verdict": treatment_lane["summary"]["behavior_verdict"],
            "human_snapshots_count": treatment_lane["summary"]["human_snapshots_count"],
            "seconds_with_human_presence": treatment_lane["summary"]["seconds_with_human_presence"],
        },
        "comparison": comparison,
        "operator_note_classification": pair_classification,
        "operator_note": operator_note_text(pair_classification, description, comparison),
        "artifacts": {
            "comparison_json": "comparison.json",
            "comparison_markdown": "comparison.md",
            "pair_summary_json": "pair_summary.json",
            "pair_summary_markdown": "pair_summary.md",
            "pair_join_instructions": "pair_join_instructions.txt",
            "control_join_instructions": "control_join_instructions.txt",
            "treatment_join_instructions": "treatment_join_instructions.txt",
        },
    }
    write_json(pair_root / "pair_summary.json", pair_summary)
    write_text(pair_root / "pair_summary.md", render_pair_summary_markdown(pair_summary))
    write_text(
        pair_root / "control_join_instructions.txt",
        lane_join_instructions(
            "Control baseline", "NoAI", "control-baseline", CONTROL_PORT
        ),
    )
    write_text(
        pair_root / "treatment_join_instructions.txt",
        lane_join_instructions(
            "Treatment", "AI", f"treatment-{treatment_profile}", TREATMENT_PORT
        ),
    )
    write_text(pair_root / "pair_join_instructions.txt", pair_join_instructions(treatment_profile))
    write_json(
        pair_root / "fixture_metadata.json",
        {
            "schema_version": 1,
            "synthetic_fixture": True,
            "fixture_id": fixture_id,
            "description": description,
            "fixture_note": SYNTHETIC_NOTE,
            "treatment_profile": treatment_profile,
            "min_human_snapshots": min_human_snapshots,
            "min_human_presence_seconds": min_human_presence_seconds,
            "min_patch_events_for_usable_lane": min_patch_events_for_usable_lane,
            "expected": fixture.get("expected", {}),
        },
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate deterministic synthetic pair/session fixtures."
    )
    parser.add_argument(
        "--output-root",
        type=Path,
        default=FIXTURE_ROOT,
        help="Directory that will receive fixture pair-pack folders.",
    )
    args = parser.parse_args()

    definitions = read_json(DEFINITIONS_PATH)
    replay_scenarios = read_json(REPLAY_SCENARIOS_PATH)
    output_root = args.output_root.resolve()
    output_root.mkdir(parents=True, exist_ok=True)

    for fixture in definitions.get("fixtures", []):
        build_fixture(fixture, replay_scenarios, output_root)


if __name__ == "__main__":
    main()
