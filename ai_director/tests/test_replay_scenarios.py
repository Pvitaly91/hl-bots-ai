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

    def test_humans_dominate_steadily_stays_bounded(self) -> None:
        result = simulate_replay(
            "humans-dominate",
            self.scenarios["humans_dominate_steadily"],
        )
        summary = result["summary"]
        apply_records = result["apply_records"]
        self.assertTrue(summary["boundedness_constraints_respected"])
        self.assertTrue(summary["cooldown_constraints_respected"])
        self.assertGreaterEqual(summary["patch_events_count"], 2)
        self.assertTrue(
            all(record["direction"] == "strengthen" for record in apply_records),
            "steady human pressure should not trigger relax actions",
        )

    def test_bots_dominate_steadily_stays_bounded(self) -> None:
        result = simulate_replay(
            "bots-dominate",
            self.scenarios["bots_dominate_steadily"],
        )
        summary = result["summary"]
        apply_records = result["apply_records"]
        self.assertTrue(summary["boundedness_constraints_respected"])
        self.assertTrue(summary["cooldown_constraints_respected"])
        self.assertGreaterEqual(summary["patch_events_count"], 2)
        self.assertTrue(
            all(record["direction"] == "relax" for record in apply_records),
            "steady bot pressure should not trigger strengthen actions",
        )

    def test_close_match_suppresses_pointless_churn(self) -> None:
        result = simulate_replay(
            "close-match",
            self.scenarios["close_hold_steady"],
        )
        summary = result["summary"]
        patch_records = result["patch_records"]
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
        self.assertLessEqual(summary["patch_apply_count"], len(self.scenarios["alternating_advantage"]))

    def test_spike_and_recovery_end_without_runaway_growth(self) -> None:
        spike = simulate_replay(
            "frag-gap-spike",
            self.scenarios["sudden_frag_gap_spike"],
        )
        recovery = simulate_replay(
            "recovery-to-equilibrium",
            self.scenarios["recovery_to_equilibrium"],
        )
        self.assertTrue(spike["summary"]["boundedness_constraints_respected"])
        self.assertTrue(recovery["summary"]["boundedness_constraints_respected"])
        self.assertEqual(recovery["summary"]["behavior_verdict"], "stable")
        self.assertLessEqual(
            recovery["summary"]["patch_apply_count"],
            len(self.scenarios["recovery_to_equilibrium"]),
        )


if __name__ == "__main__":
    unittest.main()
