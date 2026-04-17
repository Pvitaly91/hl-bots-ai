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
    parser.add_argument("--output-json", help="Optional output path for the summary JSON.")
    parser.add_argument("--output-md", help="Optional output path for the summary Markdown.")
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


def _lane_markdown(summary: dict[str, Any], heading: str) -> list[str]:
    return [
        heading,
        f"- Mode: {summary.get('mode', 'Unknown')}",
        f"- Lane label: {summary.get('lane_label', 'default')}",
        f"- Map: {summary.get('map', 'unknown')}",
        (
            f"- Bot count / skill: {summary.get('bot_count', 0)} / "
            f"{summary.get('bot_skill', 0)}"
        ),
        f"- Duration: {summary.get('duration_seconds', 0)} seconds",
        f"- Bootstrap log present: {summary.get('bootstrap_log_present', False)}",
        f"- Attach observed: {summary.get('attach_observed', False)}",
        f"- Smoke status: {summary.get('smoke_status', '')}",
        f"- Human snapshots: {summary.get('human_snapshots_count', 0)}",
        (
            f"- Seconds with human presence: "
            f"{summary.get('seconds_with_human_presence', 0)}"
        ),
        (
            f"- First human seen offset: "
            f"{summary.get('first_human_seen_offset_seconds', None)}"
        ),
        (
            f"- Last human seen offset: "
            f"{summary.get('last_human_seen_offset_seconds', None)}"
        ),
        f"- Telemetry snapshots: {summary.get('telemetry_snapshots_count', 0)}",
        f"- Patch events: {summary.get('patch_events_count', 0)}",
        (
            f"- Patch events while humans present: "
            f"{summary.get('patch_events_while_humans_present_count', 0)}"
        ),
        f"- Patch applies: {summary.get('patch_apply_count', 0)}",
        (
            f"- Patch applies while humans present: "
            f"{summary.get('patch_apply_count_while_humans_present', 0)}"
        ),
        (
            f"- Human-reactive patch events: "
            f"{summary.get('human_reactive_patch_events_count', 0)}"
        ),
        (
            f"- Rebalance opportunities: "
            f"{summary.get('rebalance_opportunities_count', 0)}"
        ),
        (
            f"- Post-patch observation windows: "
            f"{summary.get('response_after_patch_observation_window_count', 0)}"
        ),
        (
            f"- Post-patch frag-gap trend: "
            f"{summary.get('post_patch_frag_gap_trend', 'inconclusive')}"
        ),
        (
            f"- Evidence quality: "
            f"{summary.get('evidence_quality', 'insufficient-data')}"
        ),
        (
            f"- Unique skill targets: {summary.get('unique_skill_targets_seen', [])}"
        ),
        (
            f"- Unique bot-count deltas: "
            f"{summary.get('unique_bot_count_deltas_seen', [])}"
        ),
        (
            f"- Cooldown respected: "
            f"{summary.get('cooldown_constraints_respected', False)}"
        ),
        (
            f"- Boundedness respected: "
            f"{summary.get('boundedness_constraints_respected', False)}"
        ),
        (
            f"- Lane quality verdict: "
            f"{summary.get('lane_quality_verdict', 'insufficient-data')}"
        ),
        f"- Tuning usable: {summary.get('tuning_signal_usable', False)}",
        (
            f"- Ever became tuning-usable: "
            f"{summary.get('lane_ever_became_tuning_usable', False)}"
        ),
        f"- Stability verdict: {summary.get('behavior_verdict', 'insufficient-data')}",
        f"- Evidence notes: {summary.get('evidence_quality_reason', '')}",
        f"- Explanation: {summary.get('explanation', '')}",
    ]


def render_markdown(
    primary_summary: dict[str, Any],
    comparison_summary: dict[str, Any] | None = None,
    secondary_summary: dict[str, Any] | None = None,
) -> str:
    lines = ["# Balance Evaluation Summary", ""]
    lines.extend(_lane_markdown(primary_summary, "## Primary Lane"))

    if secondary_summary:
        lines.extend([""])
        lines.extend(_lane_markdown(secondary_summary, "## Secondary Lane"))

    if comparison_summary:
        lines.extend(
            [
                "",
                "## Comparison",
                f"- Control mode: {comparison_summary.get('control_mode', 'Unknown')}",
                (
                    f"- Control lane label: "
                    f"{comparison_summary.get('control_lane_label', 'control')}"
                ),
                (
                    f"- Treatment mode: "
                    f"{comparison_summary.get('treatment_mode', 'Unknown')}"
                ),
                (
                    f"- Treatment lane label: "
                    f"{comparison_summary.get('treatment_lane_label', 'treatment')}"
                ),
                (
                    f"- Control verdict: "
                    f"{comparison_summary.get('control_behavior_verdict', 'insufficient-data')}"
                ),
                (
                    f"- Treatment verdict: "
                    f"{comparison_summary.get('treatment_behavior_verdict', 'insufficient-data')}"
                ),
                (
                    f"- Treatment lane quality: "
                    f"{comparison_summary.get('treatment_lane_quality_verdict', 'insufficient-data')}"
                ),
                (
                    f"- Treatment evidence quality: "
                    f"{comparison_summary.get('treatment_evidence_quality', 'insufficient-data')}"
                ),
                (
                    f"- Comparison usable for tuning: "
                    f"{comparison_summary.get('comparison_is_tuning_usable', False)}"
                ),
                (
                    f"- Comparison verdict: "
                    f"{comparison_summary.get('comparison_verdict', 'comparison-insufficient-data')}"
                ),
                (
                    f"- Comparison reason: "
                    f"{comparison_summary.get('comparison_reason', '')}"
                ),
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
