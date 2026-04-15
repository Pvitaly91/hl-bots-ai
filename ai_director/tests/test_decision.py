from __future__ import annotations

import unittest

from ai_director.decision import materialize_patch, recommend_patch


def sample_telemetry(**overrides):
    telemetry = {
        "match_id": "stalkyard-123",
        "telemetry_sequence": 7,
        "map_name": "stalkyard",
        "human_player_count": 2,
        "bot_count": 3,
        "top_human_frags": 12,
        "top_bot_frags": 9,
        "recent_human_kills_per_minute": 8,
        "recent_bot_kills_per_minute": 5,
        "frag_gap_top_human_minus_top_bot": 3,
        "current_default_bot_skill_level": 3,
    }
    telemetry.update(overrides)
    return telemetry


class DecisionTests(unittest.TestCase):
    def test_humans_ahead_strengthens_bots(self) -> None:
        recommendation = recommend_patch(
            sample_telemetry(
                frag_gap_top_human_minus_top_bot=8,
                recent_human_kills_per_minute=10,
                recent_bot_kills_per_minute=3,
            )
        )
        self.assertEqual(recommendation.target_skill_level, 2)
        self.assertGreater(recommendation.battle_strafe_scale, 1.0)
        self.assertLess(recommendation.pause_frequency_scale, 1.0)

    def test_bots_ahead_weakens_bots(self) -> None:
        recommendation = recommend_patch(
            sample_telemetry(
                frag_gap_top_human_minus_top_bot=-9,
                recent_human_kills_per_minute=2,
                recent_bot_kills_per_minute=9,
            )
        )
        self.assertEqual(recommendation.target_skill_level, 4)
        self.assertLess(recommendation.battle_strafe_scale, 1.0)
        self.assertGreater(recommendation.pause_frequency_scale, 1.0)

    def test_materialized_patch_is_stable_and_bounded(self) -> None:
        recommendation = recommend_patch(sample_telemetry())
        patch = materialize_patch(sample_telemetry(), recommendation)
        self.assertEqual(patch["schema_version"], 1)
        self.assertTrue(patch["patch_id"].startswith("stalkyard-123:7:"))
        self.assertIn("reason", patch)
        self.assertGreaterEqual(patch["pause_frequency_scale"], 0.85)
        self.assertLessEqual(patch["battle_strafe_scale"], 1.15)


if __name__ == "__main__":
    unittest.main()
