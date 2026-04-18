from __future__ import annotations

import json
import re
import shutil
import tempfile
import unittest
from pathlib import Path
from typing import Any

from ai_director.live_pair_monitor import MonitorThresholds, compute_status


REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_ROOT = REPO_ROOT / "ai_director" / "testdata" / "pair_sessions"


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def read_ndjson(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    if not path.exists():
        return records
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if line:
            records.append(json.loads(line))
    return records


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def write_ndjson(path: Path, records: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        for record in records:
            handle.write(json.dumps(record, separators=(",", ":")) + "\n")


def safe_match_id(match_id: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "_", match_id)


def stage_runtime_from_fixture(
    runtime_root: Path,
    fixture_id: str,
    lane_name: str,
    *,
    telemetry_count: int | None = None,
    patch_count: int | None = None,
    apply_count: int | None = None,
) -> Path:
    source_lane = FIXTURE_ROOT / fixture_id / "lanes" / lane_name
    telemetry_records = read_ndjson(source_lane / "telemetry_history.ndjson")
    patch_records = read_ndjson(source_lane / "patch_history.ndjson")
    apply_records = read_ndjson(source_lane / "patch_apply_history.ndjson")

    telemetry_records = telemetry_records[:telemetry_count] if telemetry_count is not None else telemetry_records
    patch_records = patch_records[:patch_count] if patch_count is not None else patch_records
    apply_records = apply_records[:apply_count] if apply_count is not None else apply_records

    if not telemetry_records:
        raise AssertionError("Telemetry records are required for live monitor staging.")

    runtime_root.mkdir(parents=True, exist_ok=True)
    history_dir = runtime_root / "history"
    history_dir.mkdir(parents=True, exist_ok=True)

    match_id = str(telemetry_records[-1]["match_id"])
    write_json(runtime_root / "telemetry.json", telemetry_records[-1])
    write_ndjson(history_dir / f"telemetry-{safe_match_id(match_id)}.ndjson", telemetry_records)

    if patch_records:
        write_json(runtime_root / "patch.json", patch_records[-1])
        write_ndjson(history_dir / f"patch-{safe_match_id(match_id)}.ndjson", patch_records)
    else:
        patch_json = runtime_root / "patch.json"
        if patch_json.exists():
            patch_json.unlink()

    write_ndjson(history_dir / f"patch_apply-{safe_match_id(match_id)}.ndjson", apply_records)
    return runtime_root


def copy_control_lane(pair_root: Path, fixture_id: str) -> None:
    source_lane_root = FIXTURE_ROOT / fixture_id / "lanes" / "control"
    destination_lane_root = pair_root / "lanes" / "control"
    shutil.copytree(source_lane_root, destination_lane_root)


class LivePairMonitorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.thresholds = MonitorThresholds(
            min_control_human_snapshots=3,
            min_control_human_presence_seconds=60.0,
            min_treatment_human_snapshots=3,
            min_treatment_human_presence_seconds=60.0,
            min_treatment_patch_events_while_humans_present=2,
            min_post_patch_observation_seconds=40.0,
        )

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def test_missing_pair_root_is_blocked(self) -> None:
        status = compute_status(
            pair_root=self.root / "missing-pair",
            runtime_dir=None,
            thresholds=self.thresholds,
        )

        self.assertEqual(status["current_verdict"], "blocked-no-active-pair-run")

    def test_waits_for_control_human_signal_while_control_lane_is_live(self) -> None:
        pair_root = self.root / "active-control"
        pair_root.mkdir(parents=True, exist_ok=True)
        runtime_dir = stage_runtime_from_fixture(
            self.root / "runtime-control",
            "no_humans_insufficient_data",
            "control",
        )

        status = compute_status(
            pair_root=pair_root,
            runtime_dir=runtime_dir,
            thresholds=self.thresholds,
        )

        self.assertEqual(status["current_verdict"], "waiting-for-control-human-signal")

    def test_completed_no_humans_pair_times_out_insufficiently(self) -> None:
        pair_root = self.root / "no-humans"
        shutil.copytree(FIXTURE_ROOT / "no_humans_insufficient_data", pair_root)

        status = compute_status(
            pair_root=pair_root,
            runtime_dir=None,
            thresholds=self.thresholds,
        )

        self.assertEqual(status["current_verdict"], "insufficient-data-timeout")
        self.assertTrue(status["likely_remains_insufficient_if_stopped_immediately"])

    def test_waits_for_treatment_human_signal_when_control_is_ready_but_treatment_is_sparse(self) -> None:
        pair_root = self.root / "active-treatment-sparse"
        pair_root.mkdir(parents=True, exist_ok=True)
        copy_control_lane(pair_root, "conservative_acceptable_usable_signal")
        runtime_dir = stage_runtime_from_fixture(
            self.root / "runtime-treatment-sparse",
            "sparse_humans_weak_signal",
            "treatment",
        )

        status = compute_status(
            pair_root=pair_root,
            runtime_dir=runtime_dir,
            thresholds=self.thresholds,
            treatment_profile="conservative",
        )

        self.assertEqual(status["current_verdict"], "waiting-for-treatment-human-signal")

    def test_waits_for_patch_while_humans_are_present(self) -> None:
        pair_root = self.root / "active-no-live-patch"
        pair_root.mkdir(parents=True, exist_ok=True)
        copy_control_lane(pair_root, "conservative_acceptable_usable_signal")
        runtime_dir = stage_runtime_from_fixture(
            self.root / "runtime-no-live-patch",
            "conservative_acceptable_usable_signal",
            "treatment",
            telemetry_count=6,
            patch_count=2,
            apply_count=1,
        )

        status = compute_status(
            pair_root=pair_root,
            runtime_dir=runtime_dir,
            thresholds=self.thresholds,
            treatment_profile="conservative",
        )

        self.assertEqual(status["current_verdict"], "waiting-for-treatment-patch-while-humans-present")

    def test_waits_for_post_patch_observation_window(self) -> None:
        pair_root = self.root / "active-post-patch-short"
        pair_root.mkdir(parents=True, exist_ok=True)
        copy_control_lane(pair_root, "conservative_acceptable_usable_signal")
        runtime_dir = stage_runtime_from_fixture(
            self.root / "runtime-post-patch-short",
            "conservative_acceptable_usable_signal",
            "treatment",
            telemetry_count=5,
            patch_count=5,
            apply_count=2,
        )

        status = compute_status(
            pair_root=pair_root,
            runtime_dir=runtime_dir,
            thresholds=self.thresholds,
            treatment_profile="conservative",
        )

        self.assertEqual(status["current_verdict"], "waiting-for-post-patch-observation-window")
        self.assertEqual(status["meaningful_post_patch_observation_seconds"], 20.0)

    def test_active_pair_becomes_tuning_usable_only_after_observation_window(self) -> None:
        pair_root = self.root / "active-sufficient"
        pair_root.mkdir(parents=True, exist_ok=True)
        copy_control_lane(pair_root, "conservative_acceptable_usable_signal")
        runtime_dir = stage_runtime_from_fixture(
            self.root / "runtime-sufficient",
            "conservative_acceptable_usable_signal",
            "treatment",
            telemetry_count=6,
            patch_count=6,
            apply_count=3,
        )

        status = compute_status(
            pair_root=pair_root,
            runtime_dir=runtime_dir,
            thresholds=self.thresholds,
            treatment_profile="conservative",
        )

        self.assertEqual(status["current_verdict"], "sufficient-for-tuning-usable-review")
        self.assertTrue(status["operator_can_stop_now"])

    def test_completed_pair_with_grounded_evidence_is_scorecard_ready(self) -> None:
        pair_root = self.root / "completed-sufficient"
        shutil.copytree(FIXTURE_ROOT / "conservative_acceptable_usable_signal", pair_root)

        status = compute_status(
            pair_root=pair_root,
            runtime_dir=None,
            thresholds=self.thresholds,
        )

        self.assertEqual(status["current_verdict"], "sufficient-for-scorecard")
        self.assertFalse(status["likely_remains_insufficient_if_stopped_immediately"])


if __name__ == "__main__":
    unittest.main()
