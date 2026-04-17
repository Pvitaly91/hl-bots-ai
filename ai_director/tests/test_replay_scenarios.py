from __future__ import annotations

import json
import unittest
from pathlib import Path

from ai_director.evaluation import analyze_lane, compare_lane_summaries, simulate_replay


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

    manifest = {
        "prompt_id": "test-pair",
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


class ReplayScenarioTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.scenarios = load_scenarios()

    def test_one_human_outperforming_bots_stays_bounded_and_usable(self) -> None:
        result = simulate_replay(
            "one-human-ahead",
            self.scenarios["one_human_steadily_outperforming_bots"],
        )
        summary = result["summary"]
        apply_records = result["apply_records"]
        self.assertTrue(summary["boundedness_constraints_respected"])
        self.assertTrue(summary["cooldown_constraints_respected"])
        self.assertEqual(summary["lane_quality_verdict"], "ai-healthy-human-usable")
        self.assertTrue(summary["tuning_signal_usable"])
        self.assertGreaterEqual(summary["human_reactive_patch_events_count"], 2)
        self.assertEqual(summary["behavior_verdict"], "stable")
        self.assertTrue(
            all(record["direction"] == "strengthen" for record in apply_records),
            "steady human pressure should not trigger relax actions",
        )

    def test_one_human_stomped_by_bots_relaxes_boundedly(self) -> None:
        result = simulate_replay(
            "one-human-stomped",
            self.scenarios["one_human_repeatedly_stomped_by_bots"],
        )
        summary = result["summary"]
        apply_records = result["apply_records"]
        self.assertTrue(summary["boundedness_constraints_respected"])
        self.assertTrue(summary["cooldown_constraints_respected"])
        self.assertEqual(summary["lane_quality_verdict"], "ai-healthy-human-usable")
        self.assertTrue(summary["tuning_signal_usable"])
        self.assertGreaterEqual(summary["human_reactive_patch_events_count"], 2)
        self.assertEqual(summary["behavior_verdict"], "stable")
        self.assertTrue(
            all(record["direction"] == "relax" for record in apply_records),
            "steady bot pressure should not trigger strengthen actions",
        )

    def test_close_game_with_mild_imbalance_stays_conservative(self) -> None:
        result = simulate_replay(
            "close-mild-imbalance",
            self.scenarios["close_game_mild_imbalance"],
        )
        summary = result["summary"]
        patch_records = result["patch_records"]
        self.assertEqual(summary["lane_quality_verdict"], "ai-healthy-human-rich")
        self.assertTrue(summary["tuning_signal_usable"])
        self.assertEqual(summary["patch_events_count"], 0)
        self.assertEqual(summary["patch_apply_count"], 0)
        self.assertEqual(summary["behavior_verdict"], "stable")
        self.assertTrue(
            all(record["skip_reason"] == "state_already_matches" for record in patch_records)
        )

    def test_alternating_advantage_is_bounded_not_explosive(self) -> None:
        result = simulate_replay(
            "alternating-advantage",
            self.scenarios["alternating_advantage"],
        )
        summary = result["summary"]
        self.assertTrue(summary["boundedness_constraints_respected"])
        self.assertTrue(summary["cooldown_constraints_respected"])
        self.assertEqual(summary["behavior_verdict"], "oscillatory")
        self.assertLessEqual(
            summary["patch_apply_count"],
            len(self.scenarios["alternating_advantage"]),
        )

    def test_humans_absent_after_initial_join_is_not_human_rich(self) -> None:
        result = simulate_replay(
            "humans-absent-after-join",
            self.scenarios["humans_absent_after_initial_join"],
        )
        summary = result["summary"]
        self.assertEqual(summary["human_snapshots_count"], 2)
        self.assertEqual(summary["seconds_with_human_presence"], 40.0)
        self.assertEqual(summary["lane_quality_verdict"], "ai-healthy-human-usable")
        self.assertTrue(summary["tuning_signal_usable"])
        self.assertEqual(summary["evidence_quality"], "weak-signal")
        self.assertLessEqual(summary["human_reactive_patch_events_count"], 2)

    def test_brief_human_join_is_insufficient_data(self) -> None:
        result = simulate_replay(
            "brief-human-join",
            self.scenarios["brief_human_join_not_sufficient"],
        )
        summary = result["summary"]
        self.assertEqual(summary["lane_quality_verdict"], "ai-healthy-human-sparse")
        self.assertFalse(summary["tuning_signal_usable"])
        self.assertEqual(summary["behavior_verdict"], "insufficient-data")
        self.assertLessEqual(summary["patch_apply_count"], 1)
        self.assertEqual(summary["evidence_quality"], "insufficient-data")

    def test_spike_then_stabilization_stays_bounded(self) -> None:
        result = simulate_replay(
            "spike-then-stabilization",
            self.scenarios["spike_then_stabilization"],
        )
        summary = result["summary"]
        self.assertTrue(summary["boundedness_constraints_respected"])
        self.assertTrue(summary["cooldown_constraints_respected"])
        self.assertTrue(summary["tuning_signal_usable"])
        self.assertEqual(summary["behavior_verdict"], "stable")
        self.assertGreaterEqual(summary["human_reactive_patch_events_count"], 1)
        self.assertGreaterEqual(summary["response_after_patch_observation_window_count"], 1)
        self.assertIn(summary["post_patch_frag_gap_trend"], {"improved", "inconclusive"})

    def test_human_joins_late_can_still_become_usable(self) -> None:
        result = simulate_replay(
            "human-joins-late",
            self.scenarios["human_joins_late"],
        )
        summary = result["summary"]
        self.assertTrue(summary["tuning_signal_usable"])
        self.assertEqual(summary["lane_quality_verdict"], "ai-healthy-human-usable")
        self.assertEqual(summary["first_human_seen_offset_seconds"], 40.0)
        self.assertTrue(summary["lane_ever_became_tuning_usable"])
        self.assertGreaterEqual(summary["patch_events_while_humans_present_count"], 1)

    def test_human_join_after_waiting_patch_keeps_evidence_grounded(self) -> None:
        result = simulate_replay(
            "human-joins-after-waiting-patch",
            self.scenarios["human_joins_after_ai_waiting_patch"],
        )
        summary = result["summary"]
        self.assertTrue(summary["tuning_signal_usable"])
        self.assertGreaterEqual(summary["patch_events_count"], 2)
        self.assertGreaterEqual(summary["patch_events_while_humans_present_count"], 1)
        self.assertFalse(summary["patching_happened_only_while_humans_absent"])
        self.assertIn(summary["evidence_quality"], {"usable-signal", "strong-signal"})

    def test_sustained_moderate_imbalance_is_bounded_under_default_profile(self) -> None:
        result = simulate_replay(
            "sustained-moderate-default",
            self.scenarios["sustained_moderate_imbalance"],
            tuning_profile="default",
        )
        summary = result["summary"]
        self.assertTrue(summary["boundedness_constraints_respected"])
        self.assertTrue(summary["cooldown_constraints_respected"])
        self.assertEqual(summary["tuning_profile"], "default")
        self.assertIn(summary["behavior_verdict"], {"stable", "underactive"})

    def test_post_patch_overcorrection_risk_stays_bounded(self) -> None:
        result = simulate_replay(
            "post-patch-overcorrection",
            self.scenarios["post_patch_overcorrection_risk"],
            tuning_profile="default",
        )
        summary = result["summary"]
        self.assertTrue(summary["boundedness_constraints_respected"])
        self.assertTrue(summary["cooldown_constraints_respected"])
        self.assertIn(summary["behavior_verdict"], {"stable", "oscillatory"})
        self.assertGreaterEqual(summary["patch_events_count"], 1)

    def test_pair_sparse_human_signal_stays_insufficient(self) -> None:
        control_summary = simulate_control_replay(
            "pair-sparse-control",
            self.scenarios["brief_human_join_not_sufficient"],
        )
        treatment_summary = simulate_replay(
            "pair-sparse-treatment",
            self.scenarios["brief_human_join_not_sufficient"],
        )["summary"]

        comparison = compare_lane_summaries(control_summary, treatment_summary)
        self.assertEqual(comparison["comparison_verdict"], "comparison-insufficient-data")
        self.assertFalse(comparison["comparison_is_tuning_usable"])
        self.assertIn("Neither lane captured enough human signal", comparison["comparison_reason"])

    def test_pair_with_only_one_usable_lane_stays_weak_signal(self) -> None:
        control_summary = simulate_control_replay(
            "pair-control-sparse",
            self.scenarios["brief_human_join_not_sufficient"],
        )
        treatment_summary = simulate_replay(
            "pair-treatment-usable",
            self.scenarios["human_joins_after_ai_waiting_patch"],
            tuning_profile="conservative",
        )["summary"]

        comparison = compare_lane_summaries(control_summary, treatment_summary)
        self.assertEqual(comparison["comparison_verdict"], "comparison-weak-signal")
        self.assertFalse(comparison["comparison_is_tuning_usable"])
        self.assertIn("Only the treatment lane captured usable human signal", comparison["comparison_reason"])

    def test_pair_waiting_patch_before_humans_is_not_live_evidence(self) -> None:
        control_summary = simulate_control_replay(
            "pair-control-before-humans-only",
            self.scenarios["patches_before_humans_only_not_live_evidence"],
        )
        treatment_summary = simulate_replay(
            "pair-treatment-before-humans-only",
            self.scenarios["patches_before_humans_only_not_live_evidence"],
            tuning_profile="default",
        )["summary"]

        comparison = compare_lane_summaries(control_summary, treatment_summary)
        self.assertEqual(comparison["comparison_verdict"], "comparison-weak-signal")
        self.assertFalse(comparison["treatment_patched_while_humans_present"])
        self.assertFalse(comparison["meaningful_post_patch_observation_window_exists"])
        self.assertEqual(
            comparison["treatment_pre_post_trend_classification"],
            "patch-before-humans-only",
        )

    def test_pair_bounded_treatment_window_can_be_usable(self) -> None:
        control_summary = simulate_control_replay(
            "pair-control-usable",
            self.scenarios["spike_then_stabilization"],
        )
        treatment_summary = simulate_replay(
            "pair-treatment-usable",
            self.scenarios["spike_then_stabilization"],
            tuning_profile="default",
        )["summary"]

        comparison = compare_lane_summaries(control_summary, treatment_summary)
        self.assertIn(
            comparison["comparison_verdict"],
            {"comparison-usable", "comparison-strong-signal"},
        )
        self.assertTrue(comparison["comparison_is_tuning_usable"])
        self.assertTrue(comparison["relative_behavior_discussion_ready"])
        self.assertTrue(comparison["treatment_patched_while_humans_present"])
        self.assertTrue(comparison["meaningful_post_patch_observation_window_exists"])

    def test_responsive_pair_can_surface_overreaction_risk(self) -> None:
        control_summary = simulate_control_replay(
            "pair-control-noisy",
            self.scenarios["noisy_threshold_alternation"],
        )
        treatment_summary = simulate_replay(
            "pair-treatment-responsive",
            self.scenarios["noisy_threshold_alternation"],
            tuning_profile="responsive",
        )["summary"]

        comparison = compare_lane_summaries(control_summary, treatment_summary)
        self.assertEqual(treatment_summary["behavior_verdict"], "oscillatory")
        self.assertEqual(comparison["treatment_relative_to_control"], "more-responsive")


if __name__ == "__main__":
    unittest.main()
