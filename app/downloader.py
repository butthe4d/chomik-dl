import time
from collections.abc import Callable
from pathlib import Path

import httpx

from app.errors import ChomikError
from app.files import filename_from_content_disposition, sanitize_filename, unique_path

Progress = Callable[[str, int, int | None], None]
CHUNK = 1024 * 1024
PROGRESS_INTERVAL = 0.5


async def stream_download(
    url: str,
    *,
    cookies: dict[str, str],
    headers: dict[str, str],
    dest_dir: Path,
    fallback_name: str,
    on_progress: Progress,
    client: httpx.AsyncClient | None = None,
) -> Path:
    """Stream `url` into dest_dir via a .part file; return the final path."""
    own_client = client is None
    if own_client:
        client = httpx.AsyncClient(follow_redirects=True, timeout=httpx.Timeout(60.0, connect=20.0))
    part: Path | None = None
    try:
        # identity: Content-Length must match the bytes we write (no transparent gzip)
        req_headers = {**headers, "Accept-Encoding": "identity"}
        async with client.stream("GET", url, cookies=cookies, headers=req_headers) as resp:
            if resp.status_code == 404:
                raise ChomikError("not_found")
            if resp.status_code >= 400:
                raise ChomikError("download_failed")
            if resp.headers.get("content-type", "").startswith("text/html"):
                raise ChomikError("download_failed")
            raw = filename_from_content_disposition(resp.headers.get("content-disposition")) or fallback_name
            dest_dir.mkdir(parents=True, exist_ok=True)
            final = unique_path(dest_dir, sanitize_filename(raw))
            part = final.with_name(final.name + ".part")
            total = int(resp.headers["content-length"]) if "content-length" in resp.headers else None
            done, last = 0, 0.0
            on_progress(final.name, 0, total)
            with part.open("wb") as fh:
                async for chunk in resp.aiter_bytes(CHUNK):
                    fh.write(chunk)
                    done += len(chunk)
                    now = time.monotonic()
                    if now - last >= PROGRESS_INTERVAL:
                        on_progress(final.name, done, total)
                        last = now
        if total is not None and done != total:
            raise ChomikError("download_failed")
        part.rename(final)
        on_progress(final.name, done, total)
        return final
    except ChomikError:
        if part:
            part.unlink(missing_ok=True)
        raise
    except (httpx.HTTPError, OSError) as exc:
        if part:
            part.unlink(missing_ok=True)
        raise ChomikError("download_failed") from exc
    finally:
        if own_client:
            await client.aclose()
