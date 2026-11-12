import re
from pathlib import Path
from urllib.parse import unquote

_ILLEGAL = re.compile(r'[<>:"/\\|?*\x00-\x1f]')
_MAX_BYTES = 200


def sanitize_filename(name: str) -> str:
    """Make a server-provided name safe to use as a single file inside the download dir."""
    name = name.replace("\\", "/").rsplit("/", 1)[-1]
    name = _ILLEGAL.sub("_", name).strip(" .")
    if not name:
        return "download"
    if len(name.encode()) > _MAX_BYTES:
        stem, dot, ext = name.rpartition(".")
        if not dot or len(ext.encode()) > 20:
            stem, ext = name, ""
        suffix = f".{ext}" if ext else ""
        budget = _MAX_BYTES - len(suffix.encode())
        stem = stem.encode()[:budget].decode(errors="ignore")
        name = stem + suffix
    return name


def filename_from_content_disposition(header: str | None) -> str | None:
    if not header:
        return None
    m = re.search(r"filename\*\s*=\s*([^']*)'[^']*'([^;]+)", header, re.I)
    if m:
        return unquote(m.group(2).strip().strip('"'), encoding=m.group(1) or "utf-8")
    m = re.search(r'filename\s*=\s*"([^"]*)"', header, re.I) or re.search(r"filename\s*=\s*([^;]+)", header, re.I)
    if m:
        return m.group(1).strip() or None
    return None


def unique_path(directory: Path, name: str) -> Path:
    stem, dot, ext = name.rpartition(".")
    if not dot or not stem:
        stem, ext = name, ""
    suffix = f".{ext}" if ext else ""
    candidate, n = directory / name, 0
    while candidate.exists() or candidate.with_name(candidate.name + ".part").exists():
        n += 1
        candidate = directory / f"{stem} ({n}){suffix}"
    return candidate
