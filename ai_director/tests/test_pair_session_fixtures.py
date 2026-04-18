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


def mutate_pair_to_live_like(pair_root: Path, *, label: str) -> None:
    pair_summary_path = pair_root / "pair_summary.json"
    pair_summary = read_json(pair_summary_path)
    pair_summary["pair_id"] = f"{pair_summary['pair_id']}-{label}"
    pair_summary["prompt_id"] = f"HLDM-JKBOTTI-AI-STAND-TEST-{label.upper()}"
    pair_summary["synthetic_fixture"] = False
    pair_summary["rehearsal_mode"] = False
    pair_summary["validation_only"] = False
    pair_summary["evidence_origin"] = "live"
    pair_summary["source_commit_sha"] = f"test-live-like-{label}"
    pair_summary["operator_note"] = (
        "Test-only live-like certification branch derived from a deterministic fixture. "
        "This is not operator-facing lab evidence."
    )
    pair_summary_path.write_text(json.dumps(pair_summary, indent=2) + "\n", encoding="utf-8")


def certify_pair_session(pair_root: Path) -> dict[str, Any]:
    run_powershell(
        REPO_ROOT / "scripts" / "certify_latest_pair_session.ps1",
        "-PairRoot",
        str(pair_root),
    )
    return read_json(pair_root / "grounded_evidence_certificate.json")


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


def summarize_registry_with_gate(
    registry_path: Path,
    output_root: Path,
    *,
    include_synthetic_evidence_for_gate: bool = False,
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any], dict[str, Any]]:
    args = [
        "-RegistryPath",
        str(registry_path),
        "-OutputRoot",
        str(output_root),
        "-EvaluateResponsiveTrialGate",
    ]
    if include_synthetic_evidence_for_gate:
        args.append("-IncludeSyntheticEvidenceForResponsiveTrialGate")

    run_powershell(
        REPO_ROOT / "scripts" / "summarize_pair_session_registry.ps1",
        *args,
    )
    return (
        read_json(output_root / "registry_summary.json"),
        read_json(output_root / "profile_recommendation.json"),
        read_json(output_root / "responsive_trial_gate.json"),
        read_json(output_root / "responsive_trial_plan.json"),
    )


def summarize_registry_with_gate_and_plan(
    registry_path: Path,
    output_root: Path,
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any], dict[str, Any], dict[str, Any]]:
    run_powershell(
        REPO_ROOT / "scripts" / "summarize_pair_session_registry.ps1",
        "-RegistryPath",
        str(registry_path),
        "-OutputRoot",
        str(output_root),
        "-EvaluateResponsiveTrialGate",
        "-EvaluateNextLiveSessionPlan",
    )
    return (
        read_json(output_root / "registry_summary.json"),
        read_json(output_root / "profile_recommendation.json"),
        read_json(output_root / "responsive_trial_gate.json"),
        read_json(output_root / "responsive_trial_plan.json"),
        read_json(output_root / "next_live_plan.json"),
    )


def write_gate_config_override(
    destination_path: Path,
    *,
    min_grounded_conservative_sessions_for_responsive_trial: int | None = None,
    min_grounded_conservative_too_quiet_sessions_for_responsive_trial: int | None = None,
    min_distinct_grounded_conservative_too_quiet_pair_ids_for_responsive_trial: int | None = None,
) -> Path:
    payload = read_json(REPO_ROOT / "ai_director" / "testdata" / "responsive_trial_gate.json")
    thresholds = payload["gate_thresholds"]
    if min_grounded_conservative_sessions_for_responsive_trial is not None:
        thresholds["min_grounded_conservative_sessions_for_responsive_trial"] = (
            min_grounded_conservative_sessions_for_responsive_trial
        )
    if min_grounded_conservative_too_quiet_sessions_for_responsive_trial is not None:
        thresholds["min_grounded_conservative_too_quiet_sessions_for_responsive_trial"] = (
            min_grounded_conservative_too_quiet_sessions_for_responsive_trial
        )
    if min_distinct_grounded_conservative_too_quiet_pair_ids_for_responsive_trial is not None:
        thresholds["min_distinct_grounded_conservative_too_quiet_pair_ids_for_responsive_trial"] = (
            min_distinct_grounded_conservative_too_quiet_pair_ids_for_responsive_trial
        )
    destination_path.parent.mkdir(parents=True, exist_ok=True)
    destination_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return destination_path


def evaluate_responsive_gate(
    registry_path: Path,
    output_root: Path,
    *,
    include_synthetic_evidence_for_validation: bool = False,
    gate_config_path: Path | None = None,
) -> tuple[dict[str, Any], str, dict[str, Any], str]:
    args = [
        "-RegistryPath",
        str(registry_path),
        "-OutputRoot",
        str(output_root),
    ]
    if include_synthetic_evidence_for_validation:
        args.append("-IncludeSyntheticEvidenceForValidation")
    if gate_config_path is not None:
        args.extend(["-GateConfigPath", str(gate_config_path)])

    run_powershell(
        REPO_ROOT / "scripts" / "evaluate_responsive_trial_gate.ps1",
        *args,
    )
    gate_md_path = output_root / "responsive_trial_gate.md"
    plan_md_path = output_root / "responsive_trial_plan.md"
    return (
        read_json(output_root / "responsive_trial_gate.json"),
        gate_md_path.read_text(encoding="utf-8"),
        read_json(output_root / "responsive_trial_plan.json"),
        plan_md_path.read_text(encoding="utf-8"),
    )


def plan_next_live_session(
    registry_path: Path,
    output_root: Path,
    *,
    gate_config_path: Path | None = None,
) -> tuple[dict[str, Any], str]:
    args = [
        "-RegistryPath",
        str(registry_path),
        "-OutputRoot",
        str(output_root),
        "-RefreshRegistrySummary",
        "-RefreshResponsiveTrialGate",
    ]
    if gate_config_path is not None:
        args.extend(["-GateConfigPath", str(gate_config_path)])

    run_powershell(
        REPO_ROOT / "scripts" / "plan_next_live_session.ps1",
        *args,
    )
    plan_md_path = output_root / "next_live_plan.md"
    return (
        read_json(output_root / "next_live_plan.json"),
        plan_md_path.read_text(encoding="utf-8"),
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
class PairSessionCertificationTests(unittest.TestCase):
    def test_synthetic_fixture_is_not_certified_for_promotion(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir_name:
            tempdir = Path(tempdir_name)
            pair_root = copy_fixture("strong_signal_keep_conservative", tempdir / "pairs")
            run_fixture_pipeline(pair_root)
            certificate = certify_pair_session(pair_root)
            self.assertEqual(certificate["certification_verdict"], "excluded-not-grounded-evidence")
            self.assertFalse(certificate["counts_toward_promotion"])
            self.assertTrue(certificate["counts_only_as_workflow_validation"])
            self.assertIn("synthetic-evidence", certificate["exclusion_reasons"])

    def test_no_human_fixture_is_not_certified(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir_name:
            tempdir = Path(tempdir_name)
            pair_root = copy_fixture("no_humans_insufficient_data", tempdir / "pairs")
            run_fixture_pipeline(pair_root)
            certificate = certify_pair_session(pair_root)
            self.assertFalse(certificate["counts_toward_promotion"])
            self.assertIn("minimum-human-signal-thresholds-not-met", certificate["exclusion_reasons"])
            self.assertIn("treatment-never-patched-while-humans-present", certificate["exclusion_reasons"])

    def test_live_like_test_fixture_can_exercise_positive_certification_branch(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir_name:
            tempdir = Path(tempdir_name)
            pair_root = copy_fixture("strong_signal_keep_conservative", tempdir / "pairs")
            mutate_pair_to_live_like(pair_root, label="cert-positive")
            run_fixture_pipeline(pair_root)
            certificate = certify_pair_session(pair_root)
            self.assertEqual(certificate["certification_verdict"], "certified-grounded-evidence")
            self.assertTrue(certificate["counts_toward_promotion"])
            self.assertEqual(certificate["evidence_origin"], "live")


@unittest.skipUnless(POWERSHELL, "PowerShell is required for fixture-backed pair-session tests.")
class PairSessionRegistryTests(unittest.TestCase):
    fixture_definitions = load_fixture_definitions()["fixtures"]

    def _run_registry_combination(
        self,
        fixture_ids: list[str],
        *,
        duplicate_suffixes: dict[int, str] | None = None,
        live_like_indices: set[int] | None = None,
    ) -> tuple[list[dict[str, Any]], dict[str, Any], dict[str, Any]]:
        with tempfile.TemporaryDirectory() as tempdir_name:
            tempdir = Path(tempdir_name)
            registry_path = tempdir / "registry" / "pair_sessions.ndjson"
            output_root = tempdir / "registry" / "summary"
            registered_entries: list[dict[str, Any]] = []
            for index, fixture_id in enumerate(fixture_ids):
                suffix = None if duplicate_suffixes is None else duplicate_suffixes.get(index)
                pair_root = copy_fixture(fixture_id, tempdir / "pairs", pair_id_suffix=suffix)
                if live_like_indices and index in live_like_indices:
                    mutate_pair_to_live_like(pair_root, label=f"registry-{index}")
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
        self.assertEqual(summary["total_certified_grounded_sessions"], 0)
        self.assertGreaterEqual(summary["insufficient_data_count"], 1)

    def test_registry_can_keep_conservative_on_repeated_grounded_conservative_evidence(self) -> None:
        _, _, recommendation = self._run_registry_combination(
            ["conservative_acceptable_usable_signal", "strong_signal_keep_conservative"],
            live_like_indices={0, 1},
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
            live_like_indices={0, 1},
        )
        self.assertEqual(recommendation["decision"], "conservative-validated-try-responsive")
        self.assertEqual(recommendation["recommended_live_profile"], "responsive")
        self.assertTrue(recommendation["questions"]["responsive_justified_as_next_trial"])

    def test_registry_reverts_from_responsive_when_responsive_is_groundedly_too_reactive(self) -> None:
        _, _, recommendation = self._run_registry_combination(
            ["responsive_too_reactive_revert_candidate"],
            live_like_indices={0},
        )
        self.assertEqual(
            recommendation["decision"], "responsive-too-reactive-revert-to-conservative"
        )
        self.assertEqual(recommendation["recommended_live_profile"], "conservative")
        self.assertTrue(recommendation["questions"]["revert_from_responsive"])

    def test_registry_can_still_escalate_to_manual_review_on_mixed_ambiguous_evidence(self) -> None:
        _, _, recommendation = self._run_registry_combination(
            ["strong_signal_keep_conservative", "ambiguous_manual_review_needed"],
            live_like_indices={0, 1},
        )
        self.assertEqual(recommendation["decision"], "manual-review-needed")
        self.assertTrue(recommendation["questions"]["manual_review_needed"])

    def test_single_too_quiet_fixture_does_not_promote_responsive_by_itself(self) -> None:
        _, _, recommendation = self._run_registry_combination(
            ["conservative_too_quiet_responsive_candidate"],
            live_like_indices={0},
        )
        self.assertEqual(recommendation["recommended_live_profile"], "conservative")
        self.assertFalse(recommendation["questions"]["responsive_justified_as_next_trial"])


@unittest.skipUnless(POWERSHELL, "PowerShell is required for fixture-backed pair-session tests.")
class ResponsiveTrialGateTests(unittest.TestCase):
    def _run_gate_combination(
        self,
        fixture_ids: list[str],
        *,
        duplicate_suffixes: dict[int, str] | None = None,
        live_like_indices: set[int] | None = None,
        gate_config_path: Path | None = None,
    ) -> tuple[dict[str, Any], str, dict[str, Any], str]:
        with tempfile.TemporaryDirectory() as tempdir_name:
            tempdir = Path(tempdir_name)
            registry_path = tempdir / "registry" / "pair_sessions.ndjson"
            output_root = tempdir / "registry" / "summary"
            for index, fixture_id in enumerate(fixture_ids):
                suffix = None if duplicate_suffixes is None else duplicate_suffixes.get(index)
                pair_root = copy_fixture(fixture_id, tempdir / "pairs", pair_id_suffix=suffix)
                if live_like_indices and index in live_like_indices:
                    mutate_pair_to_live_like(pair_root, label=f"gate-{index}")
                run_fixture_pipeline(pair_root)
                register_fixture(pair_root, registry_path)
            summarize_registry(registry_path, output_root)
            return evaluate_responsive_gate(
                registry_path,
                output_root,
                gate_config_path=gate_config_path,
            )

    def test_gate_blocks_insufficient_and_weak_signal_registries(self) -> None:
        gate, gate_md, plan, plan_md = self._run_gate_combination(
            ["no_humans_insufficient_data", "sparse_humans_weak_signal"]
        )
        self.assertEqual(gate["gate_verdict"], "closed")
        self.assertEqual(gate["next_live_action"], "responsive-trial-not-allowed")
        self.assertTrue(gate["synthetic_only_evidence_excluded_from_promotion"])
        self.assertEqual(gate["certified_grounded_sessions"], 0)
        self.assertEqual(plan["plan_status"], "blocked")
        self.assertIn("responsive-trial-not-allowed", gate_md)
        self.assertIn("Not Yet", plan_md)

    def test_gate_keeps_single_certified_too_quiet_case_below_threshold(self) -> None:
        gate, _, plan, _ = self._run_gate_combination(
            ["conservative_too_quiet_responsive_candidate"],
            live_like_indices={0},
        )
        self.assertEqual(gate["gate_verdict"], "closed")
        self.assertEqual(gate["next_live_action"], "collect-more-conservative-evidence")
        self.assertEqual(plan["plan_status"], "blocked")

    def test_gate_excludes_synthetic_only_promotion_by_default(self) -> None:
        gate, _, plan, _ = self._run_gate_combination(
            [
                "conservative_too_quiet_responsive_candidate",
                "conservative_too_quiet_responsive_candidate",
            ],
            duplicate_suffixes={1: "repeat"},
        )
        self.assertEqual(gate["gate_verdict"], "closed")
        self.assertEqual(gate["next_live_action"], "responsive-trial-not-allowed")
        self.assertTrue(gate["synthetic_only_evidence_excluded_from_promotion"])
        self.assertEqual(gate["certified_grounded_sessions"], 0)
        self.assertEqual(plan["plan_status"], "blocked")

    def test_gate_can_open_for_repeated_certified_too_quiet_evidence(self) -> None:
        gate, gate_md, plan, plan_md = self._run_gate_combination(
            [
                "conservative_too_quiet_responsive_candidate",
                "conservative_too_quiet_responsive_candidate",
            ],
            duplicate_suffixes={1: "repeat"},
            live_like_indices={0, 1},
        )
        self.assertEqual(gate["gate_verdict"], "open")
        self.assertEqual(gate["next_live_action"], "responsive-trial-allowed")
        self.assertEqual(plan["plan_status"], "ready")
        self.assertEqual(plan["treatment_lane"]["treatment_profile"], "responsive")
        self.assertIn("responsive-trial-allowed", gate_md)
        self.assertIn("run_control_treatment_pair.ps1", plan_md)

    def test_gate_can_recommend_revert_for_certified_responsive_overreaction(self) -> None:
        gate, _, plan, _ = self._run_gate_combination(
            [
                "responsive_too_reactive_revert_candidate",
                "responsive_too_reactive_revert_candidate",
            ],
            duplicate_suffixes={1: "repeat"},
            live_like_indices={0, 1},
        )
        self.assertEqual(gate["gate_verdict"], "revert-recommended")
        self.assertEqual(gate["next_live_action"], "responsive-revert-recommended")
        self.assertEqual(plan["plan_status"], "blocked")

    def test_gate_can_escalate_ambiguous_grounded_evidence_to_manual_review(self) -> None:
        gate, _, plan, _ = self._run_gate_combination(
            ["strong_signal_keep_conservative", "ambiguous_manual_review_needed"],
            live_like_indices={0, 1},
        )
        self.assertEqual(gate["gate_verdict"], "manual-review-needed")
        self.assertEqual(gate["next_live_action"], "manual-review-needed")
        self.assertEqual(plan["plan_status"], "blocked")

    def test_registry_summary_can_reference_gate_output(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir_name:
            tempdir = Path(tempdir_name)
            registry_path = tempdir / "registry" / "pair_sessions.ndjson"
            output_root = tempdir / "registry" / "summary"
            pair_root = copy_fixture("no_humans_insufficient_data", tempdir / "pairs")
            run_fixture_pipeline(pair_root)
            register_fixture(pair_root, registry_path)
            summary, _, gate, plan = summarize_registry_with_gate(registry_path, output_root)
            self.assertTrue(summary["responsive_trial_gate_present"])
            self.assertEqual(summary["responsive_trial_gate_verdict"], gate["gate_verdict"])
            self.assertEqual(summary["responsive_trial_gate_next_live_action"], gate["next_live_action"])
            self.assertEqual(plan["plan_status"], "blocked")

    def test_registry_summary_can_optionally_emit_next_live_plan(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir_name:
            tempdir = Path(tempdir_name)
            registry_path = tempdir / "registry" / "pair_sessions.ndjson"
            output_root = tempdir / "registry" / "summary"
            pair_root = copy_fixture("no_humans_insufficient_data", tempdir / "pairs")
            run_fixture_pipeline(pair_root)
            register_fixture(pair_root, registry_path)
            summary, _, gate, _, next_live_plan = summarize_registry_with_gate_and_plan(
                registry_path,
                output_root,
            )
            self.assertTrue(summary["next_live_plan_present"])
            self.assertEqual(summary["responsive_trial_gate_verdict"], gate["gate_verdict"])
            self.assertEqual(
                summary["next_live_session_objective"],
                next_live_plan["recommended_next_session_objective"],
            )
            self.assertEqual(
                summary["next_live_recommended_live_profile"],
                next_live_plan["recommended_next_live_profile"],
            )


@unittest.skipUnless(POWERSHELL, "PowerShell is required for fixture-backed pair-session tests.")
class NextLiveSessionPlannerTests(unittest.TestCase):
    def _run_planner_combination(
        self,
        fixture_ids: list[str],
        *,
        duplicate_suffixes: dict[int, str] | None = None,
        live_like_indices: set[int] | None = None,
        gate_config_path: Path | None = None,
    ) -> tuple[dict[str, Any], str]:
        with tempfile.TemporaryDirectory() as tempdir_name:
            tempdir = Path(tempdir_name)
            registry_path = tempdir / "registry" / "pair_sessions.ndjson"
            output_root = tempdir / "registry" / "summary"
            for index, fixture_id in enumerate(fixture_ids):
                suffix = None if duplicate_suffixes is None else duplicate_suffixes.get(index)
                pair_root = copy_fixture(fixture_id, tempdir / "pairs", pair_id_suffix=suffix)
                if live_like_indices and index in live_like_indices:
                    mutate_pair_to_live_like(pair_root, label=f"plan-{index}")
                run_fixture_pipeline(pair_root)
                register_fixture(pair_root, registry_path)
            return plan_next_live_session(
                registry_path,
                output_root,
                gate_config_path=gate_config_path,
            )

    def test_planner_keeps_synthetic_and_no_human_evidence_out_of_promotion_gap(self) -> None:
        plan, plan_md = self._run_planner_combination(["no_humans_insufficient_data"])
        self.assertEqual(
            plan["recommended_next_session_objective"],
            "collect-first-grounded-conservative-session",
        )
        self.assertEqual(plan["recommended_next_live_profile"], "conservative")
        self.assertEqual(plan["current_responsive_gate_verdict"], "closed")
        self.assertEqual(plan["current_certified_grounded_session_counts"]["total"], 0)
        self.assertEqual(plan["exclusions"]["workflow_validation_only_sessions_count"], 1)
        self.assertEqual(plan["evidence_gap"]["grounded_sessions_current"], 0)
        self.assertIn("Synthetic or rehearsal sessions excluded from promotion: True", plan_md)

    def test_planner_requests_more_grounded_conservative_evidence_after_one_usable_session(self) -> None:
        plan, _ = self._run_planner_combination(
            ["conservative_acceptable_usable_signal"],
            live_like_indices={0},
        )
        self.assertEqual(
            plan["recommended_next_session_objective"],
            "collect-more-grounded-conservative-sessions",
        )
        self.assertEqual(plan["recommended_next_live_profile"], "conservative")
        self.assertEqual(plan["evidence_gap"]["grounded_sessions_current"], 1)
        self.assertEqual(plan["evidence_gap"]["grounded_too_quiet_current"], 0)
        self.assertFalse(
            plan["session_target"]["could_theoretically_open_responsive_gate_if_successful"]
        )

    def test_planner_keeps_repeated_too_quiet_evidence_conservative_when_thresholds_are_still_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir_name:
            tempdir = Path(tempdir_name)
            gate_config_path = write_gate_config_override(
                tempdir / "responsive_trial_gate.override.json",
                min_grounded_conservative_sessions_for_responsive_trial=3,
                min_grounded_conservative_too_quiet_sessions_for_responsive_trial=3,
                min_distinct_grounded_conservative_too_quiet_pair_ids_for_responsive_trial=3,
            )
            plan, _ = self._run_planner_combination(
                [
                    "conservative_too_quiet_responsive_candidate",
                    "conservative_too_quiet_responsive_candidate",
                ],
                duplicate_suffixes={1: "repeat"},
                live_like_indices={0, 1},
                gate_config_path=gate_config_path,
            )
        self.assertEqual(
            plan["recommended_next_session_objective"],
            "collect-grounded-conservative-too-quiet-evidence",
        )
        self.assertEqual(plan["recommended_next_live_profile"], "conservative")
        self.assertEqual(plan["evidence_gap"]["grounded_too_quiet_current"], 2)
        self.assertEqual(plan["evidence_gap"]["grounded_too_quiet_missing"], 1)
        self.assertTrue(plan["session_target"]["can_reduce_promotion_gap"])
        self.assertTrue(
            plan["session_target"]["could_theoretically_open_responsive_gate_if_successful"]
        )

    def test_planner_marks_responsive_trial_ready_when_grounded_too_quiet_threshold_is_met(self) -> None:
        plan, plan_md = self._run_planner_combination(
            [
                "conservative_too_quiet_responsive_candidate",
                "conservative_too_quiet_responsive_candidate",
            ],
            duplicate_suffixes={1: "repeat"},
            live_like_indices={0, 1},
        )
        self.assertEqual(plan["recommended_next_session_objective"], "responsive-trial-ready")
        self.assertEqual(plan["recommended_next_live_profile"], "responsive")
        self.assertEqual(plan["current_responsive_gate_verdict"], "open")
        self.assertEqual(plan["session_target"]["next_session_profile"], "responsive")
        self.assertIn("Recommended next-session objective: responsive-trial-ready", plan_md)

    def test_planner_blocks_responsive_when_grounded_overreaction_history_exists(self) -> None:
        plan, _ = self._run_planner_combination(
            ["responsive_too_reactive_revert_candidate"],
            live_like_indices={0},
        )
        self.assertEqual(
            plan["recommended_next_session_objective"],
            "responsive-blocked-by-overreaction-history",
        )
        self.assertEqual(plan["recommended_next_live_profile"], "conservative")
        self.assertGreater(
            plan["evidence_gap"]["responsive_overreaction_blockers_current"],
            0,
        )
        self.assertEqual(plan["session_target"]["priorities"], ["manual-review"])

    def test_planner_escalates_ambiguous_grounded_registry_to_manual_review(self) -> None:
        plan, _ = self._run_planner_combination(
            ["strong_signal_keep_conservative", "ambiguous_manual_review_needed"],
            live_like_indices={0, 1},
        )
        self.assertEqual(
            plan["recommended_next_session_objective"],
            "manual-review-before-next-session",
        )
        self.assertEqual(plan["recommended_next_live_profile"], "conservative")
        self.assertEqual(plan["session_target"]["priorities"], ["manual-review"])


if __name__ == "__main__":
    unittest.main()
