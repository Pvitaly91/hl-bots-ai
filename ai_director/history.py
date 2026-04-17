from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any


def _sanitize_token(value: str) -> str:
    token = re.sub(r"[^A-Za-z0-9._-]", "_", value or "unknown-match").strip("._")
    return token or "unknown-match"


def history_file_path(runtime_dir: Path, kind: str, match_id: str) -> Path:
    return runtime_dir / "history" / f"{kind}-{_sanitize_token(match_id)}.ndjson"


def append_ndjson(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8", newline="\n") as handle:
        handle.write(json.dumps(payload, sort_keys=False, separators=(",", ":")))
        handle.write("\n")
