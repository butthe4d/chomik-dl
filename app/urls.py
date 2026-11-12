import re
from urllib.parse import unquote_plus, urlsplit, urlunsplit

from app.errors import ChomikError

_FILE_SEGMENT = re.compile(r",\d+\.[^/]+$")


def normalize_file_url(url: str, base_url: str) -> str:
    """Validate a chomikuj file-page URL and strip query/fragment and host aliases."""
    base = urlsplit(base_url)
    try:
        parts = urlsplit(url.strip())
        host = (parts.hostname or "").lower()
    except ValueError:
        raise ChomikError("invalid_url") from None
    base_host = (base.hostname or "").lower()
    if parts.scheme not in ("http", "https"):
        raise ChomikError("invalid_url")
    if host not in {base_host, f"www.{base_host}", f"m.{base_host}"}:
        raise ChomikError("invalid_url")
    if parts.port != base.port:
        raise ChomikError("invalid_url")
    last = parts.path.rstrip("/").rsplit("/", 1)[-1]
    if not _FILE_SEGMENT.search(unquote_plus(last)):
        raise ChomikError("invalid_url")
    return urlunsplit((base.scheme, base.netloc, parts.path, "", ""))
