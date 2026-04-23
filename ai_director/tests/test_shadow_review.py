from __future__ import annotations

import json
import unittest
from pathlib import Path

from ai_director.evaluation import compare_lane_summaries, simulate_replay
from ai_director.shadow_review import (
    _profile_entry,
    build_shadow_recommendation,
    replay_captured_lane,
)


def load_scenarios() -> dict[str, list[dict[str, object]]]:
    fixture_path = (
        Path(__file__).resolve().parent.parent / "testdata" / "replay_scenarios.json"
    )
    return json.loads(fixture_path.read_text(encoding="utf-8"))


def simulate_control_replay(
    scenario_name: str,
    frames: list[dict[str, object]],
    *,
    lane_label: str = "control-baseline",
    bot_count: int = 4,
    bot_skill: int = 3,
) -> dict[str, object]:
    telemetry_records: list[dict[str, object]] = []
    for index, frame in enumerate(frames, start=1):
        frag_gap = int(frame.get("frag_gap_top_human_minus_top_bot", 0))
        base_top_score = 15
        telemetry_records.append(
            {
                "schema_version": 1,
                "match_id": scenario_name,
                "telemetry_sequence": index,
                "timestamp_utc": str(
                    frame.get("timestamp_utc", f"2026-04-17T00:00:{index:02d}Z")
                ),
                "server_time_seconds": float(
                    frame.get("server_time_seconds", index * 20.0)
                ),
                "map_name": str(frame.get("map_name", "crossfire")),
                "human_player_count": max(0, int(frame.get("human_player_count", 1))),
                "bot_count": max(0, int(frame.get("bot_count", bot_count))),
                "top_human_frags": base_top_score + max(frag_gap, 0),
                "top_human_deaths": max(0, int(frame.get("top_human_deaths", 8))),
                "top_bot_frags": base_top_score + max(-frag_gap, 0),
                "top_bot_deaths": max(0, int(frame.get("top_bot_deaths", 8))),
                "recent_human_kills_per_minute": max(
                    0, int(frame.get("recent_human_kills_per_minute", 6))
                ),
                "recent_bot_kills_per_minute": max(
                    0, int(frame.get("recent_bot_kills_per_minute", 6))
                ),
                "frag_gap_top_human_minus_top_bot": frag_gap,
                "current_default_bot_skill_level": bot_skill,
                "active_balance": {
                    "pause_frequency_scale": 1.0,
                    "battle_strafe_scale": 1.0,
                    "interval_seconds": float(frame.get("interval_seconds", 20.0)),
                    "cooldown_seconds": 30.0,
                    "enabled": 0,
                },
            }
        )

    from ai_director.evaluation import analyze_lane

    manifest = {
        "prompt_id": "test-shadow-review",
        "mode": "NoAI",
        "lane_label": lane_label,
        "map": "crossfire",
        "bot_count": bot_count,
        "bot_skill": bot_skill,
        "duration_seconds": int(
            float(frames[-1].get("server_time_seconds", len(frames) * 20.0))
        ),
        "wait_for_human_join": True,
        "human_join_grace_seconds": 120,
        "bootstrap_log_present": True,
        "attach_observed": True,
        "ai_sidecar_observed": False,
        "smoke_status": "no-ai-healthy",
        "smoke_summary": "Simulated no-AI control lane healthy.",
        "min_human_snapshots": 2,
        "min_human_presence_seconds": 40.0,
        "min_patch_events_for_usable_lane": 1,
    }
    return analyze_lane(manifest, telemetry_records, [], [])


class ShadowReviewTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.scenarios = load_scenarios()

    def test_replay_captured_lane_stays_bounded(self) -> None:
        live_result = simulate_replay(
            "captured-moderate-imbalance",
            self.scenarios["sustained_moderate_imbalance"],
            tuning_profile="conservative",
        )

        responsive_replay = replay_captured_lane(
            live_result["manifest"],
            live_result["telemetry_records"],
            "responsive",
        )
        summary = responsive_replay["summary"]

        self.assertTrue(summary["boundedness_constraints_respected"])
        self.assertTrue(summary["cooldown_constraints_respected"])
        self.assertEqual(summary["tuning_profile"], "responsive")
        self.assertGreaterEqual(
            summary["patch_apply_count"],
            live_result["summary"]["patch_apply_count"],
        )

    def test_shadow_recommendation_stays_insufficient_without_grounded_signal(self) -> None:
        frames = self.scenarios["brief_human_join_not_sufficient"]
        control_summary = simulate_control_replay("sparse-control", frames)
        actual_live = simulate_replay(
            "sparse-treatment",
            frames,
            tuning_profile="conservative",
        )
        comparison = compare_lane_summaries(control_summary, actual_live["summary"])

        actual_entry = _profile_entry(
            "conservative",
            "actual-live-treatment",
            actual_live["summary"],
            comparison,
            actual_live["patch_records"],
            actual_live["apply_records"],
        )
        default_replay = replay_captured_lane(
            actual_live["manifest"],
            actual_live["telemetry_records"],
            "default",
        )
        responsive_replay = replay_captured_lane(
            actual_live["manifest"],
            actual_live["telemetry_records"],
            "responsive",
        )
        shadow_entries = {
            "default": _profile_entry(
                "default",
                "shadow-replay",
                default_replay["summary"],
                compare_lane_summaries(control_summary, default_replay["summary"]),
                default_replay["patch_records"],
                default_replay["apply_records"],
            ),
            "responsive": _profile_entry(
                "responsive",
                "shadow-replay",
                responsive_replay["summary"],
                compare_lane_summaries(control_summary, responsive_replay["summary"]),
                responsive_replay["patch_records"],
                responsive_replay["apply_records"],
            ),
        }

        recommendation = build_shadow_recommendation(
            actual_entry,
            shadow_entries,
            control_summary,
            comparison,
            require_human_signal=True,
            min_human_snapshots=2,
            min_human_presence_seconds=40.0,
        )

        self.assertEqual(recommendation["decision"], "insufficient-data-no-promotion")
        self.assertFalse(recommendation["responsive_justified_as_next_trial"])
        self.assertTrue(recommendation["conservative_should_remain_next_live_profile"])


if __name__ == "__main__":
    unittest.main()
