from __future__ import annotations

import json
import unittest
from pathlib import Path

from ai_director.decision import recommend_patch
from ai_director.evaluation import simulate_replay


def load_scenarios() -> dict[str, list[dict[str, object]]]:
    fixture_path = (
        Path(__file__).resolve().parent.parent / "testdata" / "replay_scenarios.json"
    )
    return json.loads(fixture_path.read_text(encoding="utf-8"))


def sample_telemetry(**overrides: object) -> dict[str, object]:
    telemetry: dict[str, object] = {
        "match_id": "profile-test",
        "telemetry_sequence": 3,
        "map_name": "crossfire",
        "human_player_count": 1,
        "bot_count": 4,
        "frag_gap_top_human_minus_top_bot": 8,
        "recent_human_kills_per_minute": 10,
        "recent_bot_kills_per_minute": 4,
        "current_default_bot_skill_level": 3,
    }
    telemetry.update(overrides)
    return telemetry


class TuningProfileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.scenarios = load_scenarios()

    def test_default_profile_preserves_existing_strong_human_response(self) -> None:
        recommendation = recommend_patch(sample_telemetry(), tuning_profile="default")
        self.assertEqual(recommendation.target_skill_level, 2)
        self.assertGreater(recommendation.battle_strafe_scale, 1.0)
        self.assertLess(recommendation.pause_frequency_scale, 1.0)

    def test_conservative_profile_holds_where_responsive_reacts(self) -> None:
        conservative = simulate_replay(
            "mild-imbalance-conservative",
            self.scenarios["mild_imbalance_conservative_hold"],
            tuning_profile="conservative",
        )["summary"]
        responsive = simulate_replay(
            "mild-imbalance-responsive",
            self.scenarios["mild_imbalance_conservative_hold"],
            tuning_profile="responsive",
        )["summary"]

        self.assertEqual(conservative["patch_events_count"], 0)
        self.assertGreaterEqual(responsive["patch_events_count"], 1)
        self.assertEqual(conservative["behavior_verdict"], "stable")
        self.assertEqual(responsive["behavior_verdict"], "stable")

    def test_responsive_profile_reacts_faster_than_conservative(self) -> None:
        conservative = simulate_replay(
            "sustained-moderate-conservative",
            self.scenarios["sustained_moderate_imbalance"],
            tuning_profile="conservative",
        )["summary"]
        responsive = simulate_replay(
            "sustained-moderate-responsive",
            self.scenarios["sustained_moderate_imbalance"],
            tuning_profile="responsive",
        )["summary"]

        self.assertLessEqual(
            conservative["patch_apply_count"],
            responsive["patch_apply_count"],
        )
        self.assertGreaterEqual(
            responsive["human_reactive_patch_events_count"],
            conservative["human_reactive_patch_events_count"],
        )

    def test_responsive_profile_is_more_exposed_on_noisy_thresholds(self) -> None:
        conservative = simulate_replay(
            "noisy-threshold-conservative",
            self.scenarios["noisy_threshold_alternation"],
            tuning_profile="conservative",
        )["summary"]
        responsive = simulate_replay(
            "noisy-threshold-responsive",
            self.scenarios["noisy_threshold_alternation"],
            tuning_profile="responsive",
        )["summary"]

        self.assertLessEqual(
            conservative["patch_events_count"],
            responsive["patch_events_count"],
        )
        self.assertIn(conservative["behavior_verdict"], {"stable", "insufficient-data"})
        self.assertIn(responsive["behavior_verdict"], {"stable", "oscillatory"})


if __name__ == "__main__":
    unittest.main()
