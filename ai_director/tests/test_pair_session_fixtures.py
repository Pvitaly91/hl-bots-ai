from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any
import os

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_ROOT = REPO_ROOT / "ai_director" / "testdata" / "pair_sessions"
FIXTURE_DEFINITIONS_PATH = FIXTURE_ROOT / "fixture_definitions.json"
POWERSHELL = shutil.which("powershell")


def resolve_python_path() -> str:
    candidates: list[Path] = []
    raw_candidates = [
        os.environ.get("PYTHON", ""),
        sys.executable,
        getattr(sys, "_base_executable", ""),
        shutil.which("python") or "",
        shutil.which("py") or "",
    ]

    for raw_candidate in raw_candidates:
        if not raw_candidate:
            continue
        candidate = Path(raw_candidate)
        candidates.append(candidate)
        if candidate.is_dir():
            candidates.append(candidate / "python.exe")
            candidates.append(candidate / "bin" / "python.exe")

    for candidate in candidates:
        if candidate.is_file():
            return str(candidate.resolve())

    raise RuntimeError("Could not resolve a usable Python executable for fixture-backed tests.")


PYTHON_PATH = resolve_python_path()


def load_fixture_definitions() -> dict[str, Any]:
    payload = json.loads(FIXTURE_DEFINITIONS_PATH.read_text(encoding="utf-8"))
    fixtures = {fixture["id"]: fixture for fixture in payload["fixtures"]}
    return {"synthetic_note": payload["synthetic_note"], "fixtures": fixtures}


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def read_ndjson(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if line:
            records.append(json.loads(line))
    return records


def run_powershell(script_path: Path, *script_args: str) -> subprocess.CompletedProcess[str]:
    assert POWERSHELL is not None
    command = [
        POWERSHELL,
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script_path),
        *script_args,
    ]
    completed = subprocess.run(
        command,
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise AssertionError(
            f"Command failed: {' '.join(command)}\n"
            f"stdout:\n{completed.stdout}\n"
            f"stderr:\n{completed.stderr}"
        )
    return completed


def copy_fixture(
    fixture_id: str,
    destination_root: Path,
    *,
    pair_id_suffix: str | None = None,
) -> Path:
    source_root = FIXTURE_ROOT / fixture_id
    destination = destination_root / (
        fixture_id if not pair_id_suffix else f"{fixture_id}-{pair_id_suffix}"
    )
    shutil.copytree(source_root, destination)
    if pair_id_suffix:
        pair_summary_path = destination / "pair_summary.json"
        pair_summary = read_json(pair_summary_path)
        pair_summary["pair_id"] = f"{pair_summary['pair_id']}-{pair_id_suffix}"
        pair_summary["fixture_id"] = f"{pair_summary['fixture_id']}-{pair_id_suffix}"
        pair_summary["fixture_description"] = (
            f"{pair_summary['fixture_description']} Duplicate {pair_id_suffix}."
        )
        pair_summary_path.write_text(
            json.dumps(pair_summary, indent=2) + "\n",
            encoding="utf-8",
        )

        metadata_path = destination / "fixture_metadata.json"
        metadata = read_json(metadata_path)
        metadata["fixture_id"] = f"{metadata['fixture_id']}-{pair_id_suffix}"
        metadata["description"] = f"{metadata['description']} Duplicate {pair_id_suffix}."
        metadata_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    return destination


def run_fixture_pipeline(pair_root: Path) -> dict[str, Any]:
    metadata = read_json(pair_root / "fixture_metadata.json")
    min_human_snapshots = str(metadata["min_human_snapshots"])
    min_human_presence_seconds = str(metadata["min_human_presence_seconds"])

    run_powershell(
        REPO_ROOT / "scripts" / "run_shadow_profile_review.ps1",
        "-PairRoot",
        str(pair_root),
        "-Profiles",
        "conservative",
        "default",
        "responsive",
        "-RequireHumanSignal",
        "-MinHumanSnapshots",
        min_human_snapshots,
        "-MinHumanPresenceSeconds",
        min_human_presence_seconds,
        "-PythonPath",
        PYTHON_PATH,
    )
    run_powershell(
        REPO_ROOT / "scripts" / "score_latest_pair_session.ps1",
        "-PairRoot",
        str(pair_root),
    )
    return {
        "metadata": metadata,
        "pair_summary": read_json(pair_root / "pair_summary.json"),
        "comparison": read_json(pair_root / "comparison.json")["comparison"],
        "scorecard": read_json(pair_root / "scorecard.json"),
        "shadow_recommendation": read_json(
            pair_root / "shadow_review" / "shadow_recommendation.json"
        ),
    }


def register_fixture(pair_root: Path, registry_path: Path) -> dict[str, Any]:
    run_powershell(
        REPO_ROOT / "scripts" / "register_pair_session_result.ps1",
        "-PairRoot",
        str(pair_root),
        "-RegistryPath",
        str(registry_path),
    )
    return read_ndjson(registry_path)[-1]


def summarize_registry(registry_path: Path, output_root: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    run_powershell(
        REPO_ROOT / "scripts" / "summarize_pair_session_registry.ps1",
        "-RegistryPath",
        str(registry_path),
        "-OutputRoot",
        str(output_root),
    )
    return (
        read_json(output_root / "registry_summary.json"),
        read_json(output_root / "profile_recommendation.json"),
    )


@unittest.skipUnless(POWERSHELL, "PowerShell is required for fixture-backed pair-session tests.")
class PairSessionFixtureDecisionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixture_definitions = load_fixture_definitions()["fixtures"]
        cls.tempdir = tempfile.TemporaryDirectory()
        cls.runtime_root = Path(cls.tempdir.name)
        cls.fixture_results: dict[str, dict[str, Any]] = {}
        for fixture_id in cls.fixture_definitions:
            pair_root = copy_fixture(fixture_id, cls.runtime_root)
            cls.fixture_results[fixture_id] = run_fixture_pipeline(pair_root)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.tempdir.cleanup()

    def test_scorecard_branches_match_expected_fixtures(self) -> None:
        for fixture_id, definition in self.fixture_definitions.items():
            with self.subTest(fixture=fixture_id):
                result = self.fixture_results[fixture_id]
                expected = definition["expected"]
                scorecard = result["scorecard"]
                shadow = result["shadow_recommendation"]
                self.assertEqual(scorecard["pair_classification"], expected["pair_classification"])
                self.assertEqual(scorecard["comparison_verdict"], expected["comparison_verdict"])
                self.assertEqual(
                    scorecard["treatment_behavior_assessment"],
                    expected["scorecard_treatment_behavior_assessment"],
                )
                self.assertEqual(scorecard["recommendation"], expected["scorecard_recommendation"])
                self.assertEqual(shadow["decision"], expected["shadow_decision"])

    def test_cross_tool_consistency_guards_hold(self) -> None:
        insufficient = self.fixture_results["no_humans_insufficient_data"]
        weak = self.fixture_results["sparse_humans_weak_signal"]
        quiet = self.fixture_results["conservative_too_quiet_responsive_candidate"]
        reactive = self.fixture_results["responsive_too_reactive_revert_candidate"]

        self.assertFalse(insufficient["scorecard"]["good_enough_for"]["try_responsive_next"])
        self.assertFalse(
            insufficient["shadow_recommendation"]["responsive_justified_as_next_trial"]
        )
        self.assertNotIn("responsive", insufficient["scorecard"]["recommendation"])

        self.assertFalse(weak["scorecard"]["good_enough_for"]["try_responsive_next"])
        self.assertFalse(weak["shadow_recommendation"]["responsive_justified_as_next_trial"])
        self.assertEqual(weak["scorecard"]["recommendation"], "weak-signal-repeat-session")

        self.assertEqual(reactive["scorecard"]["treatment_behavior_assessment"], "too reactive")
        self.assertEqual(
            reactive["scorecard"]["recommendation"],
            "responsive-too-reactive-revert-to-conservative",
        )
        self.assertFalse(reactive["scorecard"]["good_enough_for"]["try_responsive_next"])

        self.assertEqual(quiet["scorecard"]["recommendation"], "conservative-looks-too-quiet-try-responsive-next")
        self.assertIn(
            quiet["scorecard"]["comparison_verdict"],
            {"comparison-usable", "comparison-strong-signal"},
        )
        self.assertIn(
            quiet["scorecard"]["treatment_evidence_quality"],
            {"usable-signal", "strong-signal"},
        )
        self.assertTrue(
            quiet["shadow_recommendation"]["responsive_justified_as_next_trial"]
        )

    def test_shadow_review_branch_examples_are_exercised(self) -> None:
        branch_expectations = {
            "no_humans_insufficient_data": "insufficient-data-no-promotion",
            "strong_signal_keep_conservative": "conservative-and-default-similar",
            "conservative_too_quiet_responsive_candidate": "conservative-looks-too-quiet-responsive-candidate",
            "responsive_too_reactive_revert_candidate": "responsive-would-have-overreacted",
        }
        for fixture_id, expected_decision in branch_expectations.items():
            with self.subTest(fixture=fixture_id):
                self.assertEqual(
                    self.fixture_results[fixture_id]["shadow_recommendation"]["decision"],
                    expected_decision,
                )


@unittest.skipUnless(POWERSHELL, "PowerShell is required for fixture-backed pair-session tests.")
class PairSessionRegistryTests(unittest.TestCase):
    fixture_definitions = load_fixture_definitions()["fixtures"]

    def _run_registry_combination(
        self,
        fixture_ids: list[str],
        *,
        duplicate_suffixes: dict[int, str] | None = None,
    ) -> tuple[list[dict[str, Any]], dict[str, Any], dict[str, Any]]:
        with tempfile.TemporaryDirectory() as tempdir_name:
            tempdir = Path(tempdir_name)
            registry_path = tempdir / "registry" / "pair_sessions.ndjson"
            output_root = tempdir / "registry" / "summary"
            registered_entries: list[dict[str, Any]] = []
            for index, fixture_id in enumerate(fixture_ids):
                suffix = None if duplicate_suffixes is None else duplicate_suffixes.get(index)
                pair_root = copy_fixture(fixture_id, tempdir / "pairs", pair_id_suffix=suffix)
                run_fixture_pipeline(pair_root)
                registered_entries.append(register_fixture(pair_root, registry_path))
            registry_summary, profile_recommendation = summarize_registry(registry_path, output_root)
            return registered_entries, registry_summary, profile_recommendation

    def test_registry_keeps_conservative_when_evidence_is_still_too_weak(self) -> None:
        _, summary, recommendation = self._run_registry_combination(
            ["no_humans_insufficient_data", "sparse_humans_weak_signal"]
        )
        self.assertEqual(recommendation["recommended_live_profile"], "conservative")
        self.assertFalse(recommendation["questions"]["responsive_justified_as_next_trial"])
        self.assertTrue(recommendation["questions"]["evidence_too_weak_for_profile_change"])
        self.assertGreaterEqual(summary["insufficient_data_count"], 1)

    def test_registry_can_keep_conservative_on_repeated_grounded_conservative_evidence(self) -> None:
        _, _, recommendation = self._run_registry_combination(
            ["conservative_acceptable_usable_signal", "strong_signal_keep_conservative"]
        )
        self.assertEqual(recommendation["decision"], "keep-conservative")
        self.assertEqual(recommendation["recommended_live_profile"], "conservative")
        self.assertFalse(recommendation["questions"]["responsive_justified_as_next_trial"])

    def test_registry_can_recommend_responsive_after_repeated_grounded_too_quiet_sessions(self) -> None:
        _, _, recommendation = self._run_registry_combination(
            [
                "conservative_too_quiet_responsive_candidate",
                "conservative_too_quiet_responsive_candidate",
            ],
            duplicate_suffixes={1: "repeat"},
        )
        self.assertEqual(recommendation["decision"], "conservative-validated-try-responsive")
        self.assertEqual(recommendation["recommended_live_profile"], "responsive")
        self.assertTrue(recommendation["questions"]["responsive_justified_as_next_trial"])

    def test_registry_reverts_from_responsive_when_responsive_is_groundedly_too_reactive(self) -> None:
        _, _, recommendation = self._run_registry_combination(
            ["responsive_too_reactive_revert_candidate"]
        )
        self.assertEqual(
            recommendation["decision"], "responsive-too-reactive-revert-to-conservative"
        )
        self.assertEqual(recommendation["recommended_live_profile"], "conservative")
        self.assertTrue(recommendation["questions"]["revert_from_responsive"])

    def test_registry_can_still_escalate_to_manual_review_on_mixed_ambiguous_evidence(self) -> None:
        _, _, recommendation = self._run_registry_combination(
            ["strong_signal_keep_conservative", "ambiguous_manual_review_needed"]
        )
        self.assertEqual(recommendation["decision"], "manual-review-needed")
        self.assertTrue(recommendation["questions"]["manual_review_needed"])

    def test_single_too_quiet_fixture_does_not_promote_responsive_by_itself(self) -> None:
        _, _, recommendation = self._run_registry_combination(
            ["conservative_too_quiet_responsive_candidate"]
        )
        self.assertEqual(recommendation["recommended_live_profile"], "conservative")
        self.assertFalse(recommendation["questions"]["responsive_justified_as_next_trial"])


if __name__ == "__main__":
    unittest.main()
