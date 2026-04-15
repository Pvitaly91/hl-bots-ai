from __future__ import annotations

import argparse
import logging
import os
import time
from pathlib import Path

if __package__ in (None, ""):
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ai_director.bridge import load_dotenv, read_json, write_json_atomic
from ai_director.decision import materialize_patch, recommend_patch
from ai_director.openai_client import generate_recommendation_with_openai

DEFAULT_MODEL = "gpt-4o-mini"


def configure_logging(level: str) -> None:
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(message)s",
    )


def process_telemetry(
    telemetry: dict,
    *,
    prompt_path: Path,
    api_key: str | None,
    model: str,
) -> dict:
    if api_key:
        try:
            recommendation = generate_recommendation_with_openai(
                telemetry, prompt_path=prompt_path, api_key=api_key, model=model
            )
            logging.info("Generated patch with OpenAI model %s", model)
        except Exception as exc:  # pragma: no cover - depends on local env
            logging.warning("OpenAI path failed, falling back to rules: %s", exc)
            recommendation = recommend_patch(telemetry)
    else:
        recommendation = recommend_patch(telemetry)

    patch = materialize_patch(telemetry, recommendation)
    logging.info(
        "Patch %s target_skill=%s bot_delta=%s reason=%s",
        patch["patch_id"],
        patch["target_skill_level"],
        patch["bot_count_delta"],
        patch["reason"],
    )
    return patch


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="HLDM AI balance director sidecar for jk_botti."
    )
    parser.add_argument(
        "--runtime-dir",
        required=True,
        help="Runtime directory that contains telemetry.json and patch.json.",
    )
    parser.add_argument(
        "--poll-interval",
        type=float,
        default=float(os.getenv("AI_DIRECTOR_POLL_INTERVAL", "5")),
        help="Polling interval in seconds.",
    )
    parser.add_argument(
        "--prompt-path",
        default=str(Path(__file__).with_name("prompt.md")),
        help="Prompt template for the optional OpenAI call path.",
    )
    parser.add_argument(
        "--log-level",
        default=os.getenv("AI_DIRECTOR_LOG_LEVEL", "INFO"),
        help="Python logging level.",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Process the latest telemetry file once and exit.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parent.parent
    load_dotenv(repo_root / ".env")
    load_dotenv(repo_root / "ai_director" / ".env")
    configure_logging(args.log_level)

    runtime_dir = Path(args.runtime_dir).expanduser().resolve()
    telemetry_path = runtime_dir / "telemetry.json"
    patch_path = runtime_dir / "patch.json"
    prompt_path = Path(args.prompt_path).expanduser().resolve()

    api_key = os.getenv("OPENAI_API_KEY")
    model = os.getenv("OPENAI_MODEL", DEFAULT_MODEL)
    last_processed = ""

    logging.info("Watching runtime directory %s", runtime_dir)

    while True:
        if telemetry_path.exists():
            telemetry = read_json(telemetry_path)
            telemetry_key = f"{telemetry.get('match_id', '')}:{telemetry.get('telemetry_sequence', '')}"

            if telemetry_key and telemetry_key != last_processed:
                patch = process_telemetry(
                    telemetry,
                    prompt_path=prompt_path,
                    api_key=api_key,
                    model=model,
                )
                write_json_atomic(patch_path, patch)
                last_processed = telemetry_key

                if args.once:
                    return 0
        elif args.once:
            raise FileNotFoundError(f"Telemetry file not found: {telemetry_path}")

        time.sleep(max(0.5, float(args.poll_interval)))


if __name__ == "__main__":
    raise SystemExit(main())
