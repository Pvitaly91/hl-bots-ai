from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from ai_director.live_pair_monitor import (
    DEFAULT_POST_PATCH_OBSERVATION_SECONDS,
    MonitorThresholds,
    compute_status,
)


def main() -> int:
    parser = argparse.ArgumentParser(description="Compute a one-shot live pair monitor status.")
    parser.add_argument("--pair-root", required=True)
    parser.add_argument("--runtime-dir", default="")
    parser.add_argument("--prompt-id", default="")
    parser.add_argument("--treatment-profile", default="conservative")
    parser.add_argument("--min-control-human-snapshots", type=int, required=True)
    parser.add_argument("--min-control-human-presence-seconds", type=float, required=True)
    parser.add_argument("--min-treatment-human-snapshots", type=int, required=True)
    parser.add_argument("--min-treatment-human-presence-seconds", type=float, required=True)
    parser.add_argument("--min-treatment-patch-events-while-humans-present", type=int, required=True)
    parser.add_argument(
        "--min-post-patch-observation-seconds",
        type=float,
        default=DEFAULT_POST_PATCH_OBSERVATION_SECONDS,
    )
    args = parser.parse_args()

    status = compute_status(
        pair_root=Path(args.pair_root),
        runtime_dir=Path(args.runtime_dir) if args.runtime_dir else None,
        thresholds=MonitorThresholds(
            min_control_human_snapshots=args.min_control_human_snapshots,
            min_control_human_presence_seconds=args.min_control_human_presence_seconds,
            min_treatment_human_snapshots=args.min_treatment_human_snapshots,
            min_treatment_human_presence_seconds=args.min_treatment_human_presence_seconds,
            min_treatment_patch_events_while_humans_present=args.min_treatment_patch_events_while_humans_present,
            min_post_patch_observation_seconds=args.min_post_patch_observation_seconds,
        ),
        treatment_profile=args.treatment_profile,
        prompt_id=args.prompt_id,
    )
    print(json.dumps(status, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
