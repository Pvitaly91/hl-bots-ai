from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

if __package__ in (None, ""):
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from ai_director.evaluation import simulate_replay
from ai_director.tuning import (
    available_tuning_profiles,
    default_tuning_profile_name,
    tuning_profile_summary,
)

SCENARIO_RULES: dict[str, dict[str, str]] = {
    "one_human_steadily_outperforming_bots": {
        "family": "response",
        "purpose": "Humans lead steadily; AI should strengthen bots in bounded steps.",
    },
    "one_human_repeatedly_stomped_by_bots": {
        "family": "response",
        "purpose": "Bots lead steadily; AI should relax bots in bounded steps.",
    },
    "close_game_mild_imbalance": {
        "family": "hold",
        "purpose": "Close game; profiles should stay conservative.",
    },
    "alternating_advantage": {
        "family": "oscillation-risk",
        "purpose": "Large alternating swings; profiles should avoid flip-flop behavior.",
    },
    "humans_absent_after_initial_join": {
        "family": "sparse",
        "purpose": "Humans vanish; evidence should remain weak and conservative.",
    },
    "brief_human_join_not_sufficient": {
        "family": "sparse",
        "purpose": "Brief human join; the lane should stay insufficient-data.",
    },
    "spike_then_stabilization": {
        "family": "stabilize",
        "purpose": "One spike followed by recovery; hysteresis should stay bounded.",
    },
    "human_joins_late": {
        "family": "late-join",
        "purpose": "Human joins late; the lane should only become usable after enough signal.",
    },
    "human_joins_after_ai_waiting_patch": {
        "family": "grounded",
        "purpose": "Initial waiting patch should not overclaim evidence after humans appear.",
    },
    "mild_imbalance_conservative_hold": {
        "family": "hold-threshold",
        "purpose": "Near-threshold lane; conservative should hold while more responsive profiles may react.",
    },
    "sustained_moderate_imbalance": {
        "family": "response-threshold",
        "purpose": "Moderate sustained imbalance; responsive profiles should react sooner than conservative ones.",
    },
    "noisy_threshold_alternation": {
        "family": "oscillation-risk",
        "purpose": "Noisy near-threshold alternation; profiles should not thrash.",
    },
    "post_patch_overcorrection_risk": {
        "family": "overcorrection-risk",
        "purpose": "Early strong reaction followed by reversal risk; bounded hysteresis matters.",
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run replay scenarios across named tuning profiles."
    )
    parser.add_argument(
        "--scenarios-file",
        default=str(
            Path(__file__).resolve().parent.parent / "testdata" / "replay_scenarios.json"
        ),
        help="Path to the replay scenario fixture JSON.",
    )
    parser.add_argument(
        "--output-root",
        help="Directory where summary/comparison artifacts will be written.",
    )
    parser.add_argument(
        "--profiles",
        nargs="+",
        help="Optional subset of tuning profiles to compare.",
    )
    return parser.parse_args()


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def _scenario_rule(name: str) -> dict[str, str]:
    return SCENARIO_RULES.get(
        name,
        {"family": "response", "purpose": "General bounded-response scenario."},
    )


def _scenario_outcome(
    scenario_name: str,
    summary: dict[str, Any],
) -> dict[str, Any]:
    rule = _scenario_rule(scenario_name)
    family = rule["family"]
    bounded = bool(summary.get("boundedness_constraints_respected", False))
    cooldown = bool(summary.get("cooldown_constraints_respected", False))
    tuning_usable = bool(summary.get("tuning_signal_usable", False))
    behavior = str(summary.get("behavior_verdict", "insufficient-data"))
    evidence = str(summary.get("evidence_quality", "insufficient-data"))
    patch_events = int(summary.get("patch_events_count", 0))
    patch_applies = int(summary.get("patch_apply_count", 0))
    human_reactive = int(summary.get("human_reactive_patch_events_count", 0))
    post_patch_windows = int(
        summary.get("response_after_patch_observation_window_count", 0)
    )
    rebalance_opportunities = int(summary.get("rebalance_opportunities_count", 0))
    churn_flag = False
    response_score = 0.0
    acceptable = False
    note = ""

    if not bounded:
        note = "Boundedness constraints were violated."
    elif not cooldown:
        note = "Cooldown constraints were violated."
    elif family == "response":
        acceptable = (
            tuning_usable
            and behavior != "oscillatory"
            and behavior != "underactive"
            and human_reactive >= 1
        )
        response_score = float((human_reactive * 2) + patch_applies)
        note = (
            "Expected a bounded treatment response to sustained imbalance."
            if acceptable
            else "Expected a bounded treatment response, but the lane stayed weak or underactive."
        )
    elif family == "response-threshold":
        acceptable = (
            tuning_usable
            and behavior != "oscillatory"
            and human_reactive >= 1
            and patch_applies >= 1
        )
        response_score = float((human_reactive * 2) + (patch_applies * 1.5))
        note = (
            "Expected a moderate but visible response to sustained imbalance."
            if acceptable
            else "Expected a visible response to moderate imbalance, but the profile stayed too quiet."
        )
    elif family == "hold":
        acceptable = patch_events == 0 and patch_applies == 0 and behavior == "stable"
        churn_flag = patch_events > 0 or patch_applies > 0
        note = (
            "Expected profiles to hold on a close match."
            if acceptable
            else "Expected the profile to hold, but it emitted unnecessary churn."
        )
    elif family == "hold-threshold":
        acceptable = behavior == "stable" and patch_applies <= 1
        churn_flag = patch_applies > 1
        note = (
            "Near-threshold lane stayed conservative enough."
            if acceptable
            else "Near-threshold lane triggered too much adjustment churn."
        )
    elif family == "sparse":
        acceptable = (not tuning_usable) and behavior == "insufficient-data"
        churn_flag = patch_events > 1 or int(
            summary.get("patch_events_while_humans_present_count", 0)
        ) > 0
        note = (
            "Sparse or absent humans were handled conservatively."
            if acceptable
            else "Sparse-signal lane looked more confident than it should."
        )
    elif family == "oscillation-risk":
        acceptable = behavior != "oscillatory" and patch_applies <= 2
        churn_flag = patch_applies > 2
        note = (
            "Oscillation risk stayed bounded."
            if acceptable
            else "Profile flipped direction too often under noisy or alternating pressure."
        )
    elif family == "stabilize":
        acceptable = (
            behavior == "stable"
            and post_patch_windows >= 1
            and str(summary.get("post_patch_frag_gap_trend", "inconclusive"))
            != "worsened"
        )
        note = (
            "Spike was handled without obvious overcorrection."
            if acceptable
            else "Spike handling stayed weak or worsened after treatment."
        )
    elif family == "late-join":
        acceptable = (
            tuning_usable
            and summary.get("first_human_seen_offset_seconds", None) is not None
            and int(summary.get("patch_events_while_humans_present_count", 0)) >= 1
        )
        note = (
            "Late human join still produced usable evidence."
            if acceptable
            else "Late join did not generate enough grounded signal."
        )
    elif family == "grounded":
        acceptable = (
            tuning_usable
            and not bool(summary.get("patching_happened_only_while_humans_absent", False))
            and evidence in {"usable-signal", "strong-signal"}
        )
        note = (
            "Treatment evidence stayed grounded after humans appeared."
            if acceptable
            else "Evidence stayed weak because treatment mostly happened before humans were present."
        )
    elif family == "overcorrection-risk":
        acceptable = (
            behavior != "oscillatory"
            and str(summary.get("post_patch_frag_gap_trend", "inconclusive"))
            != "worsened"
        )
        note = (
            "Profile avoided obvious post-patch overcorrection."
            if acceptable
            else "Profile looked too eager to reverse after its first response."
        )
    else:
        acceptable = (
            bounded
            and cooldown
            and (
                rebalance_opportunities <= 0
                or behavior != "underactive"
            )
        )
        note = "General bounded-response check."

    return {
        "scenario_name": scenario_name,
        "family": family,
        "purpose": rule["purpose"],
        "acceptable": acceptable and bounded and cooldown,
        "boundedness_ok": bounded,
        "cooldown_ok": cooldown,
        "behavior_verdict": behavior,
        "evidence_quality": evidence,
        "lane_quality_verdict": str(summary.get("lane_quality_verdict", "")),
        "patch_events_count": patch_events,
        "patch_apply_count": patch_applies,
        "human_reactive_patch_events_count": human_reactive,
        "rebalance_opportunities_count": rebalance_opportunities,
        "pointless_churn": churn_flag,
        "response_score": round(response_score, 2),
        "note": note,
    }


def _profile_rollup(
    profile_name: str,
    profile_summary: dict[str, Any],
    scenario_results: list[dict[str, Any]],
) -> dict[str, Any]:
    boundedness_violation_count = sum(
        1 for result in scenario_results if not result["boundedness_ok"]
    )
    cooldown_violation_count = sum(
        1 for result in scenario_results if not result["cooldown_ok"]
    )
    pointless_churn_count = sum(
        1 for result in scenario_results if result["pointless_churn"]
    )
    oscillation_count = sum(
        1 for result in scenario_results if result["behavior_verdict"] == "oscillatory"
    )
    underactive_count = sum(
        1 for result in scenario_results if result["behavior_verdict"] == "underactive"
    )
    insufficient_data_total = sum(
        1 for result in scenario_results if result["family"] == "sparse"
    )
    insufficient_data_handled = sum(
        1
        for result in scenario_results
        if result["family"] == "sparse" and result["acceptable"]
    )
    acceptable_scenarios_count = sum(
        1 for result in scenario_results if result["acceptable"]
    )
    total_patch_apply_count = sum(
        int(result["patch_apply_count"]) for result in scenario_results
    )
    response_score = round(
        sum(float(result["response_score"]) for result in scenario_results), 2
    )
    hold_success_count = sum(
        1
        for result in scenario_results
        if result["family"] in {"hold", "hold-threshold"} and result["acceptable"]
    )
    sparse_conservative_success_count = sum(
        1 for result in scenario_results if result["family"] == "sparse" and result["acceptable"]
    )
    aggregate_score = round(
        (acceptable_scenarios_count * 10.0)
        + response_score
        + (hold_success_count * 1.5)
        + (sparse_conservative_success_count * 1.5)
        - (boundedness_violation_count * 60.0)
        - (cooldown_violation_count * 40.0)
        - (oscillation_count * 10.0)
        - (underactive_count * 8.0)
        - (pointless_churn_count * 5.0),
        2,
    )

    strengths: list[str] = []
    weaknesses: list[str] = []
    if boundedness_violation_count == 0 and cooldown_violation_count == 0:
        strengths.append("Stayed inside boundedness and cooldown guardrails.")
    if oscillation_count == 0:
        strengths.append("Avoided oscillatory reversals across the sweep.")
    if response_score >= 10.0:
        strengths.append("Produced visible responses on the sustained-imbalance scenarios.")
    if sparse_conservative_success_count >= 2:
        strengths.append("Handled sparse or absent human signal conservatively.")

    if underactive_count > 0:
        weaknesses.append(
            f"Marked underactive in {underactive_count} scenario(s) that wanted a clearer response."
        )
    if oscillation_count > 0:
        weaknesses.append(
            f"Showed oscillation risk in {oscillation_count} scenario(s)."
        )
    if pointless_churn_count > 0:
        weaknesses.append(
            f"Created pointless churn in {pointless_churn_count} conservative scenario(s)."
        )
    if insufficient_data_total > insufficient_data_handled:
        weaknesses.append("Sparse-signal handling was more confident than desired.")

    return {
        "profile": profile_name,
        "description": str(profile_summary.get("description", "")),
        "effective_knobs": profile_summary,
        "scenario_results": scenario_results,
        "boundedness_compliance": boundedness_violation_count == 0,
        "boundedness_violation_count": boundedness_violation_count,
        "cooldown_compliance": cooldown_violation_count == 0,
        "cooldown_violation_count": cooldown_violation_count,
        "pointless_churn_count": pointless_churn_count,
        "oscillation_count": oscillation_count,
        "underactive_count": underactive_count,
        "insufficient_data_scenarios_total": insufficient_data_total,
        "insufficient_data_scenarios_handled": insufficient_data_handled,
        "insufficient_data_handling_quality": (
            f"{insufficient_data_handled}/{insufficient_data_total}"
            if insufficient_data_total > 0
            else "n/a"
        ),
        "acceptable_scenarios_count": acceptable_scenarios_count,
        "scenario_count": len(scenario_results),
        "response_score": response_score,
        "total_patch_apply_count": total_patch_apply_count,
        "hold_success_count": hold_success_count,
        "sparse_conservative_success_count": sparse_conservative_success_count,
        "aggregate_score": aggregate_score,
        "strengths": strengths,
        "weaknesses": weaknesses,
        "explanation": _profile_explanation(
            acceptable_scenarios_count,
            len(scenario_results),
            strengths,
            weaknesses,
        ),
    }


def _profile_explanation(
    acceptable_count: int,
    scenario_count: int,
    strengths: list[str],
    weaknesses: list[str],
) -> str:
    parts = [f"Accepted {acceptable_count} of {scenario_count} scenarios."]
    if strengths:
        parts.append(f"Strengths: {' '.join(strengths[:2])}")
    if weaknesses:
        parts.append(f"Weaknesses: {' '.join(weaknesses[:2])}")
    return " ".join(parts)


def _comparison_summary(profile_rollups: list[dict[str, Any]]) -> dict[str, Any]:
    ordered = sorted(
        profile_rollups,
        key=lambda item: (float(item["aggregate_score"]), -float(item["response_score"])),
        reverse=True,
    )
    safest = min(
        profile_rollups,
        key=lambda item: (
            item["boundedness_violation_count"],
            item["cooldown_violation_count"],
            item["oscillation_count"],
            item["pointless_churn_count"],
            item["total_patch_apply_count"],
            -item["acceptable_scenarios_count"],
        ),
    )
    most_conservative = min(
        profile_rollups,
        key=lambda item: (
            item["total_patch_apply_count"],
            item["pointless_churn_count"],
            item["oscillation_count"],
            -item["hold_success_count"],
        ),
    )
    most_responsive = max(
        profile_rollups,
        key=lambda item: (
            item["response_score"],
            item["total_patch_apply_count"],
            -item["underactive_count"],
        ),
    )
    best_oscillation_avoidance = min(
        profile_rollups,
        key=lambda item: (
            item["oscillation_count"],
            item["pointless_churn_count"],
            item["total_patch_apply_count"],
        ),
    )
    best_underreaction_avoidance = min(
        profile_rollups,
        key=lambda item: (
            item["underactive_count"],
            -item["response_score"],
            item["oscillation_count"],
        ),
    )

    best_next_live_candidate = ordered[0]
    recommendation_confidence = "clear"
    recommendation_reason = (
        f"{best_next_live_candidate['profile']} ranked highest on the replay sweep "
        f"with {best_next_live_candidate['acceptable_scenarios_count']} accepted scenarios "
        f"and aggregate score {best_next_live_candidate['aggregate_score']}."
    )
    if len(ordered) > 1:
        margin = round(
            float(best_next_live_candidate["aggregate_score"])
            - float(ordered[1]["aggregate_score"]),
            2,
        )
        if margin <= 3.0:
            recommendation_confidence = "close-call"
            recommendation_reason += (
                f" The margin to {ordered[1]['profile']} was only {margin}, so this is a cautious recommendation."
            )

    return {
        "schema_version": 1,
        "profile_order": [item["profile"] for item in ordered],
        "safest_profile": safest["profile"],
        "most_conservative_profile": most_conservative["profile"],
        "most_responsive_profile": most_responsive["profile"],
        "best_oscillation_avoidance_profile": best_oscillation_avoidance["profile"],
        "best_underreaction_avoidance_profile": best_underreaction_avoidance["profile"],
        "best_next_live_candidate": best_next_live_candidate["profile"],
        "recommendation_confidence": recommendation_confidence,
        "recommendation_reason": recommendation_reason,
    }


def _render_summary_markdown(summary: dict[str, Any]) -> str:
    lines = [
        "# Replay Sweep Summary",
        "",
        f"- Generated at: {summary.get('generated_at_utc', '')}",
        f"- Default profile: {summary.get('default_profile', '')}",
        f"- Compared profiles: {', '.join(summary.get('profiles', {}).keys())}",
        "",
    ]

    for profile_name, rollup in summary.get("profiles", {}).items():
        lines.extend(
            [
                f"## {profile_name}",
                f"- Description: {rollup.get('description', '')}",
                (
                    f"- Acceptable scenarios: {rollup.get('acceptable_scenarios_count', 0)} / "
                    f"{rollup.get('scenario_count', 0)}"
                ),
                f"- Aggregate score: {rollup.get('aggregate_score', 0)}",
                f"- Response score: {rollup.get('response_score', 0)}",
                f"- Boundedness compliant: {rollup.get('boundedness_compliance', False)}",
                f"- Cooldown compliant: {rollup.get('cooldown_compliance', False)}",
                f"- Pointless churn count: {rollup.get('pointless_churn_count', 0)}",
                f"- Oscillation count: {rollup.get('oscillation_count', 0)}",
                f"- Underactive count: {rollup.get('underactive_count', 0)}",
                (
                    f"- Insufficient-data handling: "
                    f"{rollup.get('insufficient_data_handling_quality', 'n/a')}"
                ),
                f"- Explanation: {rollup.get('explanation', '')}",
                "",
            ]
        )

    return "\n".join(lines).rstrip() + "\n"


def _render_comparison_markdown(comparison: dict[str, Any], summary: dict[str, Any]) -> str:
    lines = [
        "# Replay Sweep Comparison",
        "",
        f"- Safest profile: {comparison.get('safest_profile', '')}",
        f"- Most conservative profile: {comparison.get('most_conservative_profile', '')}",
        f"- Most responsive profile: {comparison.get('most_responsive_profile', '')}",
        (
            f"- Best oscillation avoidance: "
            f"{comparison.get('best_oscillation_avoidance_profile', '')}"
        ),
        (
            f"- Best underreaction avoidance: "
            f"{comparison.get('best_underreaction_avoidance_profile', '')}"
        ),
        (
            f"- Recommended next live profile: "
            f"{comparison.get('best_next_live_candidate', '')}"
        ),
        (
            f"- Recommendation confidence: "
            f"{comparison.get('recommendation_confidence', '')}"
        ),
        f"- Reason: {comparison.get('recommendation_reason', '')}",
        "",
    ]

    ordered_names = comparison.get("profile_order", [])
    profiles = summary.get("profiles", {})
    for name in ordered_names:
        rollup = profiles.get(name, {})
        lines.extend(
            [
                f"## {name}",
                f"- Aggregate score: {rollup.get('aggregate_score', 0)}",
                f"- Acceptable scenarios: {rollup.get('acceptable_scenarios_count', 0)}",
                f"- Response score: {rollup.get('response_score', 0)}",
                f"- Oscillation count: {rollup.get('oscillation_count', 0)}",
                f"- Underactive count: {rollup.get('underactive_count', 0)}",
                f"- Pointless churn count: {rollup.get('pointless_churn_count', 0)}",
                "",
            ]
        )

    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parent.parent.parent
    scenarios_file = Path(args.scenarios_file).expanduser().resolve()
    output_root = (
        Path(args.output_root).expanduser().resolve()
        if args.output_root
        else repo_root
        / "lab"
        / "logs"
        / "eval"
        / "replay_sweeps"
        / datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    )
    output_root.mkdir(parents=True, exist_ok=True)

    scenarios = load_json(scenarios_file)
    selected_profiles = (
        list(dict.fromkeys(args.profiles))
        if args.profiles
        else available_tuning_profiles()
    )

    profiles_summary: dict[str, Any] = {}
    for profile_name in selected_profiles:
        scenario_results: list[dict[str, Any]] = []
        for scenario_name, frames in scenarios.items():
            result = simulate_replay(
                scenario_name,
                frames,
                tuning_profile=profile_name,
                lane_label=f"replay-sweep-{profile_name}",
            )
            scenario_results.append(
                _scenario_outcome(scenario_name, result["summary"])
            )

        profiles_summary[profile_name] = _profile_rollup(
            profile_name,
            tuning_profile_summary(profile_name),
            scenario_results,
        )

    summary = {
        "schema_version": 1,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "default_profile": default_tuning_profile_name(),
        "profiles": profiles_summary,
    }
    comparison = _comparison_summary(list(profiles_summary.values()))

    summary_json_path = output_root / "summary.json"
    summary_md_path = output_root / "summary.md"
    comparison_json_path = output_root / "comparison.json"
    comparison_md_path = output_root / "comparison.md"

    summary_json_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    summary_md_path.write_text(_render_summary_markdown(summary), encoding="utf-8")
    comparison_json_path.write_text(
        json.dumps(comparison, indent=2) + "\n",
        encoding="utf-8",
    )
    comparison_md_path.write_text(
        _render_comparison_markdown(comparison, summary),
        encoding="utf-8",
    )

    print(f"Replay sweep summary written to {summary_json_path}")
    print(f"Replay sweep comparison written to {comparison_json_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
