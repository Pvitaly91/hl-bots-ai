from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

if __package__ in (None, ""):
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from ai_director.evaluation import analyze_lane, compare_lane_summaries, load_ndjson


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Summarize one or two HLDM balance evaluation lanes."
    )
    parser.add_argument("--lane-root", required=True, help="Primary lane artifact directory.")
    parser.add_argument(
        "--compare-lane-root",
        help="Optional second lane artifact directory for control-vs-treatment comparison.",
    )
    parser.add_argument(
        "--output-json",
        help="Optional output path for the machine-readable summary JSON.",
    )
    parser.add_argument(
        "--output-md",
        help="Optional output path for the human-readable Markdown summary.",
    )
    return parser.parse_args()


def read_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def summarize_lane(lane_root: Path) -> dict[str, Any]:
    manifest = read_json(lane_root / "lane.json")
    telemetry_records = load_ndjson(lane_root / "telemetry_history.ndjson")
    patch_records = load_ndjson(lane_root / "patch_history.ndjson")
    apply_records = load_ndjson(lane_root / "patch_apply_history.ndjson")
    return analyze_lane(manifest, telemetry_records, patch_records, apply_records)


def render_markdown(
    primary_summary: dict[str, Any],
    comparison_summary: dict[str, Any] | None = None,
    secondary_summary: dict[str, Any] | None = None,
) -> str:
    lines = [
        "# Balance Evaluation Summary",
        "",
        "## Primary Lane",
        f"- Mode: {primary_summary.get('mode', 'Unknown')}",
        f"- Map: {primary_summary.get('map', 'unknown')}",
        f"- Bot count / skill: {primary_summary.get('bot_count', 0)} / {primary_summary.get('bot_skill', 0)}",
        f"- Duration: {primary_summary.get('duration_seconds', 0)} seconds",
        f"- Bootstrap log present: {primary_summary.get('bootstrap_log_present', False)}",
        f"- Attach observed: {primary_summary.get('attach_observed', False)}",
        f"- Telemetry snapshots: {primary_summary.get('telemetry_snapshots_count', 0)}",
        f"- Patch events: {primary_summary.get('patch_events_count', 0)}",
        f"- Patch applies: {primary_summary.get('patch_apply_count', 0)}",
        f"- Unique skill targets: {primary_summary.get('unique_skill_targets_seen', [])}",
        f"- Unique bot-count deltas: {primary_summary.get('unique_bot_count_deltas_seen', [])}",
        f"- Cooldown respected: {primary_summary.get('cooldown_constraints_respected', False)}",
        f"- Boundedness respected: {primary_summary.get('boundedness_constraints_respected', False)}",
        f"- Verdict: {primary_summary.get('behavior_verdict', 'insufficient-data')}",
        f"- Notes: {primary_summary.get('behavior_reason', '')}",
    ]

    if secondary_summary:
        lines.extend(
            [
                "",
                "## Secondary Lane",
                f"- Mode: {secondary_summary.get('mode', 'Unknown')}",
                f"- Map: {secondary_summary.get('map', 'unknown')}",
                f"- Bot count / skill: {secondary_summary.get('bot_count', 0)} / {secondary_summary.get('bot_skill', 0)}",
                f"- Duration: {secondary_summary.get('duration_seconds', 0)} seconds",
                f"- Bootstrap log present: {secondary_summary.get('bootstrap_log_present', False)}",
                f"- Attach observed: {secondary_summary.get('attach_observed', False)}",
                f"- Telemetry snapshots: {secondary_summary.get('telemetry_snapshots_count', 0)}",
                f"- Patch events: {secondary_summary.get('patch_events_count', 0)}",
                f"- Patch applies: {secondary_summary.get('patch_apply_count', 0)}",
                f"- Unique skill targets: {secondary_summary.get('unique_skill_targets_seen', [])}",
                f"- Unique bot-count deltas: {secondary_summary.get('unique_bot_count_deltas_seen', [])}",
                f"- Cooldown respected: {secondary_summary.get('cooldown_constraints_respected', False)}",
                f"- Boundedness respected: {secondary_summary.get('boundedness_constraints_respected', False)}",
                f"- Verdict: {secondary_summary.get('behavior_verdict', 'insufficient-data')}",
                f"- Notes: {secondary_summary.get('behavior_reason', '')}",
            ]
        )

    if comparison_summary:
        lines.extend(
            [
                "",
                "## Comparison",
                f"- Control mode: {comparison_summary.get('control_mode', 'Unknown')}",
                f"- Treatment mode: {comparison_summary.get('treatment_mode', 'Unknown')}",
                f"- Control sidecar-free: {comparison_summary.get('control_sidecar_free', False)}",
                f"- Treatment sidecar observed: {comparison_summary.get('treatment_sidecar_observed', False)}",
                f"- Control verdict: {comparison_summary.get('control_behavior_verdict', 'insufficient-data')}",
                f"- Treatment verdict: {comparison_summary.get('treatment_behavior_verdict', 'insufficient-data')}",
                f"- Comparison verdict: {comparison_summary.get('comparison_verdict', 'comparison-incomplete')}",
            ]
        )

    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    lane_root = Path(args.lane_root).expanduser().resolve()
    output_json = (
        Path(args.output_json).expanduser().resolve()
        if args.output_json
        else lane_root / "summary.json"
    )
    output_md = (
        Path(args.output_md).expanduser().resolve()
        if args.output_md
        else lane_root / "summary.md"
    )

    primary_summary = summarize_lane(lane_root)
    result: dict[str, Any] = {"primary_lane": primary_summary}
    comparison_summary: dict[str, Any] | None = None
    secondary_summary: dict[str, Any] | None = None

    if args.compare_lane_root:
        compare_lane_root = Path(args.compare_lane_root).expanduser().resolve()
        secondary_summary = summarize_lane(compare_lane_root)
        comparison_summary = compare_lane_summaries(primary_summary, secondary_summary)
        result["secondary_lane"] = secondary_summary
        result["comparison"] = comparison_summary

    output_json.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    output_md.write_text(
        render_markdown(primary_summary, comparison_summary, secondary_summary),
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
