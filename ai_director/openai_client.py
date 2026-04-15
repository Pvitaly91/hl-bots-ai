from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from ai_director.decision import PatchRecommendation, recommendation_from_payload

PATCH_SCHEMA = {
    "type": "object",
    "properties": {
        "target_skill_level": {"type": "integer", "minimum": 1, "maximum": 5},
        "bot_count_delta": {"type": "integer", "minimum": -1, "maximum": 1},
        "pause_frequency_scale": {
            "type": "number",
            "minimum": 0.85,
            "maximum": 1.15,
        },
        "battle_strafe_scale": {
            "type": "number",
            "minimum": 0.85,
            "maximum": 1.15,
        },
        "reason": {"type": "string"},
    },
    "required": [
        "target_skill_level",
        "bot_count_delta",
        "pause_frequency_scale",
        "battle_strafe_scale",
        "reason",
    ],
    "additionalProperties": False,
}


def generate_recommendation_with_openai(
    telemetry: dict[str, Any],
    *,
    prompt_path: Path,
    api_key: str,
    model: str,
) -> PatchRecommendation:
    try:
        from openai import OpenAI
    except ImportError as exc:  # pragma: no cover - depends on local env
        raise RuntimeError(
            "The OpenAI Python SDK is not installed. Install ai_director/requirements.txt."
        ) from exc

    prompt = prompt_path.read_text(encoding="utf-8")
    client = OpenAI(api_key=api_key)
    response = client.responses.create(
        model=model,
        input=[
            {"role": "system", "content": prompt},
            {
                "role": "user",
                "content": "Telemetry JSON:\n"
                + json.dumps(telemetry, indent=2, sort_keys=True),
            },
        ],
        text={
            "format": {
                "type": "json_schema",
                "name": "balance_patch",
                "schema": PATCH_SCHEMA,
                "strict": True,
            }
        },
    )

    return recommendation_from_payload(json.loads(response.output_text))
