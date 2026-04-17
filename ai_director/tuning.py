from __future__ import annotations

import json
from copy import deepcopy
from functools import lru_cache
from pathlib import Path
from typing import Any

DEFAULT_PROFILE_NAME = "default"


def _profiles_path() -> Path:
    return Path(__file__).resolve().parent / "testdata" / "tuning_profiles.json"


@lru_cache(maxsize=1)
def load_tuning_profile_catalog() -> dict[str, Any]:
    payload = json.loads(_profiles_path().read_text(encoding="utf-8"))
    profiles = payload.get("profiles")
    if not isinstance(profiles, dict) or not profiles:
        raise ValueError("Tuning profile catalog is missing profiles.")
    default_profile = str(payload.get("default_profile", DEFAULT_PROFILE_NAME)).strip()
    if default_profile not in profiles:
        raise ValueError(
            f"Default tuning profile '{default_profile}' was not found in the catalog."
        )
    return payload


def available_tuning_profiles() -> list[str]:
    catalog = load_tuning_profile_catalog()
    return sorted(str(name) for name in catalog["profiles"].keys())


def default_tuning_profile_name() -> str:
    catalog = load_tuning_profile_catalog()
    return str(catalog.get("default_profile", DEFAULT_PROFILE_NAME))


def _deep_merge(base: dict[str, Any], overrides: dict[str, Any]) -> dict[str, Any]:
    merged = deepcopy(base)
    for key, value in overrides.items():
        if (
            isinstance(value, dict)
            and isinstance(merged.get(key), dict)
        ):
            merged[key] = _deep_merge(merged[key], value)
        else:
            merged[key] = deepcopy(value)
    return merged


def resolve_tuning_profile(profile: str | dict[str, Any] | None) -> dict[str, Any]:
    catalog = load_tuning_profile_catalog()
    profiles = catalog["profiles"]
    default_name = default_tuning_profile_name()
    default_profile = deepcopy(profiles[default_name])

    if profile is None:
        resolved = default_profile
        resolved["name"] = default_name
        return resolved

    if isinstance(profile, dict):
        requested_name = str(profile.get("name", default_name)).strip() or default_name
        if requested_name in profiles:
            resolved = _deep_merge(profiles[requested_name], profile)
        else:
            resolved = _deep_merge(default_profile, profile)
        resolved["name"] = requested_name
        return resolved

    requested_name = str(profile).strip() or default_name
    if requested_name not in profiles:
        available = ", ".join(available_tuning_profiles())
        raise ValueError(
            f"Unknown tuning profile '{requested_name}'. Available profiles: {available}."
        )

    resolved = deepcopy(profiles[requested_name])
    resolved["name"] = requested_name
    return resolved


def tuning_profile_summary(profile: str | dict[str, Any] | None) -> dict[str, Any]:
    resolved = resolve_tuning_profile(profile)
    return {
        "name": resolved["name"],
        "description": str(resolved.get("description", "")),
        "cooldown_seconds": float(resolved.get("cooldown_seconds", 30.0)),
        "decision": deepcopy(resolved.get("decision", {})),
        "evaluation": deepcopy(resolved.get("evaluation", {})),
    }
