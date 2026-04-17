from __future__ import annotations

import json
import unittest
from pathlib import Path

from ai_director.evaluation import simulate_replay


def load_scenarios() -> dict[str, list[dict[str, object]]]:
    fixture_path = (
        Path(__file__).resolve().parent.parent / "testdata" / "replay_scenarios.json"
    )
    return json.loads(fixture_path.read_text(encoding="utf-8"))


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


if __name__ == "__main__":
    unittest.main()
