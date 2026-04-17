from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from typing import Any

from ai_director.tuning import resolve_tuning_profile

MIN_SKILL_LEVEL = 1
MAX_SKILL_LEVEL = 5
MIN_SCALE = 0.85
MAX_SCALE = 1.15


def clamp_int(value: int, low: int, high: int) -> int:
    return max(low, min(high, int(value)))


def clamp_float(value: float, low: float, high: float) -> float:
    return max(low, min(high, float(value)))


def _as_int(payload: dict[str, Any], key: str, default: int = 0) -> int:
    try:
        return int(payload.get(key, default))
    except (TypeError, ValueError):
        return default


@dataclass(frozen=True)
class PatchRecommendation:
    target_skill_level: int
    bot_count_delta: int
    pause_frequency_scale: float
    battle_strafe_scale: float
    reason: str

    def clamped(self) -> "PatchRecommendation":
        return PatchRecommendation(
            target_skill_level=clamp_int(
                self.target_skill_level, MIN_SKILL_LEVEL, MAX_SKILL_LEVEL
            ),
            bot_count_delta=clamp_int(self.bot_count_delta, -1, 1),
            pause_frequency_scale=round(
                clamp_float(self.pause_frequency_scale, MIN_SCALE, MAX_SCALE), 3
            ),
            battle_strafe_scale=round(
                clamp_float(self.battle_strafe_scale, MIN_SCALE, MAX_SCALE), 3
            ),
            reason=(self.reason or "No reason provided.")[:140],
        )

    def as_model_payload(self) -> dict[str, Any]:
        return {
            "target_skill_level": self.target_skill_level,
            "bot_count_delta": self.bot_count_delta,
            "pause_frequency_scale": self.pause_frequency_scale,
            "battle_strafe_scale": self.battle_strafe_scale,
            "reason": self.reason,
        }


def recommendation_from_payload(payload: dict[str, Any]) -> PatchRecommendation:
    return PatchRecommendation(
        target_skill_level=_as_int(payload, "target_skill_level", 3),
        bot_count_delta=_as_int(payload, "bot_count_delta", 0),
        pause_frequency_scale=float(payload.get("pause_frequency_scale", 1.0)),
        battle_strafe_scale=float(payload.get("battle_strafe_scale", 1.0)),
        reason=str(payload.get("reason", "No reason provided.")),
    ).clamped()


def _decision_settings(
    tuning_profile: str | dict[str, Any] | None,
) -> tuple[str, dict[str, Any], float]:
    profile = resolve_tuning_profile(tuning_profile)
    return (
        str(profile.get("name", "default")),
        dict(profile.get("decision", {})),
        float(profile.get("cooldown_seconds", 30.0)),
    )


def recommend_patch(
    telemetry: dict[str, Any], tuning_profile: str | dict[str, Any] | None = None
) -> PatchRecommendation:
    profile_name, settings, _ = _decision_settings(tuning_profile)
    current_skill = clamp_int(
        _as_int(telemetry, "current_default_bot_skill_level", 3),
        MIN_SKILL_LEVEL,
        MAX_SKILL_LEVEL,
    )
    human_count = max(0, _as_int(telemetry, "human_player_count", 0))
    bot_count = max(0, _as_int(telemetry, "bot_count", 0))
    frag_gap = _as_int(telemetry, "frag_gap_top_human_minus_top_bot", 0)
    human_kpm = _as_int(telemetry, "recent_human_kills_per_minute", 0)
    bot_kpm = _as_int(telemetry, "recent_bot_kills_per_minute", 0)

    if human_count == 0 or bot_count == 0:
        return PatchRecommendation(
            target_skill_level=current_skill,
            bot_count_delta=0,
            pause_frequency_scale=1.0,
            battle_strafe_scale=1.0,
            reason=f"Waiting for both humans and bots to become active ({profile_name} profile).",
        )

    momentum = frag_gap + ((human_kpm - bot_kpm) * 0.75)
    mild_momentum_threshold = float(settings.get("mild_momentum_threshold", 4.0))
    strong_momentum_threshold = float(settings.get("strong_momentum_threshold", 8.0))
    max_extra_bots_above_humans = max(
        0, _as_int(settings, "max_extra_bots_above_humans", 2)
    )
    max_bot_count = max(1, _as_int(settings, "max_bot_count", 6))

    if momentum >= strong_momentum_threshold:
        return PatchRecommendation(
            target_skill_level=current_skill - 1,
            bot_count_delta=(
                1
                if bot_count < min(human_count + max_extra_bots_above_humans, max_bot_count)
                else 0
            ),
            pause_frequency_scale=float(
                settings.get("strong_strengthen_pause_frequency_scale", 0.92)
            ),
            battle_strafe_scale=float(
                settings.get("strong_strengthen_battle_strafe_scale", 1.08)
            ),
            reason=f"Humans are pulling ahead on frags and recent kill pace ({profile_name} profile).",
        ).clamped()

    if momentum >= mild_momentum_threshold:
        return PatchRecommendation(
            target_skill_level=current_skill - 1,
            bot_count_delta=0,
            pause_frequency_scale=float(
                settings.get("mild_strengthen_pause_frequency_scale", 0.96)
            ),
            battle_strafe_scale=float(
                settings.get("mild_strengthen_battle_strafe_scale", 1.04)
            ),
            reason=f"Humans are slightly ahead; strengthen bots cautiously ({profile_name} profile).",
        ).clamped()

    if momentum <= -strong_momentum_threshold:
        return PatchRecommendation(
            target_skill_level=current_skill + 1,
            bot_count_delta=-1 if bot_count > 1 else 0,
            pause_frequency_scale=float(
                settings.get("strong_relax_pause_frequency_scale", 1.08)
            ),
            battle_strafe_scale=float(
                settings.get("strong_relax_battle_strafe_scale", 0.92)
            ),
            reason=f"Bots are leading too hard on frags and recent kill pace ({profile_name} profile).",
        ).clamped()

    if momentum <= -mild_momentum_threshold:
        return PatchRecommendation(
            target_skill_level=current_skill + 1,
            bot_count_delta=0,
            pause_frequency_scale=float(
                settings.get("mild_relax_pause_frequency_scale", 1.04)
            ),
            battle_strafe_scale=float(
                settings.get("mild_relax_battle_strafe_scale", 0.96)
            ),
            reason=f"Bots are slightly ahead; relax them cautiously ({profile_name} profile).",
        ).clamped()

    return PatchRecommendation(
        target_skill_level=current_skill,
        bot_count_delta=0,
        pause_frequency_scale=1.0,
        battle_strafe_scale=1.0,
        reason=f"Match looks close enough; hold current balance ({profile_name} profile).",
    ).clamped()


def materialize_patch(
    telemetry: dict[str, Any],
    recommendation: PatchRecommendation,
    tuning_profile: str | dict[str, Any] | None = None,
) -> dict[str, Any]:
    recommendation = recommendation.clamped()
    profile_name, _, cooldown_seconds = _decision_settings(tuning_profile)
    match_id = str(telemetry.get("match_id", "unknown-match"))
    telemetry_sequence = _as_int(telemetry, "telemetry_sequence", 0)
    map_name = str(telemetry.get("map_name", "unknown"))

    patch_core = recommendation.as_model_payload()
    patch_hash = hashlib.sha1(
        json.dumps(
            {
                "match_id": match_id,
                "telemetry_sequence": telemetry_sequence,
                "patch": patch_core,
            },
            sort_keys=True,
        ).encode("utf-8")
    ).hexdigest()[:12]

    return {
        "schema_version": 1,
        "match_id": match_id,
        "telemetry_sequence": telemetry_sequence,
        "map_name": map_name,
        "patch_id": f"{match_id}:{telemetry_sequence}:{patch_hash}",
        "tuning_profile": profile_name,
        "profile_cooldown_seconds": round(cooldown_seconds, 1),
        **patch_core,
    }
