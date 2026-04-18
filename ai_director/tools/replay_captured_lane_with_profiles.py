from __future__ import annotations

import argparse
from pathlib import Path

if __package__ in (None, ""):
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from ai_director.shadow_review import (
    build_shadow_review,
    render_shadow_profiles_markdown,
    render_shadow_recommendation_markdown,
    write_json,
    write_text,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Replay a captured treatment lane through multiple tuning profiles."
    )
    parser.add_argument("--pair-root", help="Pair pack root containing pair_summary.json.")
    parser.add_argument("--lane-root", help="Treatment lane root containing lane.json.")
    parser.add_argument(
        "--profiles",
        nargs="+",
        default=["conservative", "default", "responsive"],
        help="Named tuning profiles to replay.",
    )
    parser.add_argument(
        "--output-root",
        required=True,
        help="Directory where shadow review artifacts will be written.",
    )
    parser.add_argument(
        "--require-human-signal",
        action="store_true",
        help="Require the captured lane to clear the requested human-signal gate before any promotion can be justified.",
    )
    parser.add_argument(
        "--min-human-snapshots",
        type=int,
        help="Optional override for the minimum human snapshots gate.",
    )
    parser.add_argument(
        "--min-human-presence-seconds",
        type=float,
        help="Optional override for the minimum human-presence gate.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    output_root = Path(args.output_root).expanduser().resolve()
    output_root.mkdir(parents=True, exist_ok=True)

    pair_root = Path(args.pair_root).expanduser().resolve() if args.pair_root else None
    lane_root = Path(args.lane_root).expanduser().resolve() if args.lane_root else None

    shadow_profiles, shadow_recommendation = build_shadow_review(
        pair_root=pair_root,
        lane_root=lane_root,
        profiles=args.profiles,
        require_human_signal=bool(args.require_human_signal),
        min_human_snapshots=args.min_human_snapshots,
        min_human_presence_seconds=args.min_human_presence_seconds,
    )

    shadow_profiles_json_path = output_root / "shadow_profiles.json"
    shadow_profiles_md_path = output_root / "shadow_profiles.md"
    shadow_recommendation_json_path = output_root / "shadow_recommendation.json"
    shadow_recommendation_md_path = output_root / "shadow_recommendation.md"

    write_json(shadow_profiles_json_path, shadow_profiles)
    write_text(
        shadow_profiles_md_path,
        render_shadow_profiles_markdown(shadow_profiles),
    )
    write_json(shadow_recommendation_json_path, shadow_recommendation)
    write_text(
        shadow_recommendation_md_path,
        render_shadow_recommendation_markdown(shadow_recommendation),
    )

    print(f"Shadow profile review JSON: {shadow_profiles_json_path}")
    print(f"Shadow profile review Markdown: {shadow_profiles_md_path}")
    print(f"Shadow recommendation JSON: {shadow_recommendation_json_path}")
    print(f"Shadow recommendation Markdown: {shadow_recommendation_md_path}")
    print(f"Decision: {shadow_recommendation.get('decision', '')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
