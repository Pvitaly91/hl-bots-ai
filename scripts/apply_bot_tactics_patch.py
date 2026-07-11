from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    file_path = Path(path)
    text = file_path.read_text(encoding="utf-8")
    if old not in text:
        raise RuntimeError(f"Expected source block not found in {path}")
    if text.count(old) != 1:
        raise RuntimeError(f"Expected exactly one source block in {path}, found {text.count(old)}")
    file_path.write_text(text.replace(old, new, 1), encoding="