import asyncio
import logging
import os
import tempfile
from pathlib import Path

from app.config import Settings
from app.downloader import stream_download
from app.errors import MESSAGES, ChomikError
from app.jobs import Job, JobStore

log = logging.getLogger(__name__)

RETRYABLE = {"timeout", "download_failed"}
MAX_ATTEMPTS = 2


def check_download_dir(path: Path, require_mount: bool) -> None:
    """Raise storage_unavailable unless `path` is a writable directory (and a mount, if required)."""
    if not path.exists():
        if require_mount:
            raise ChomikError("storage_unavailable")
        try:
            path.mkdir(parents=True, exist_ok=True)
        except OSError:
            raise ChomikError("storage_unavailable") from None
    if not path.is_dir():
        raise ChomikError("storage_unavailable")
    if require_mount and not os.path.ismount(path):
        raise ChomikError("storage_unavailable")
    try:
        with tempfile.TemporaryFile(dir=path):
            pass
    except OSError:
        raise ChomikError("storage_unavailable") from None


class Worker:
    """Processes queued jobs strictly one at a time."""

    def __init__(self, settings: Settings, store: JobStore, session, download=stream_download,
                 retry_backoff: float = 30.0):
        self.settings = settings
        self.store = store
        self.session = session
        self.download = download
        self.retry_backoff = retry_backoff
        self._wake = asyncio.Event()

    def wake(self) -> None:
        self._wake.set()

    async def run_forever(self) -> None:
        while True:
            try:
                worked = await self.run_once()
            except Exception:
                log.exception("worker loop error")
                worked = False
            if worked:
                await asyncio.sleep(self.settings.min_job_gap)
            else:
                self._wake.clear()
                try:
                    await asyncio.wait_for(self._wake.wait(), timeout=5)
                except TimeoutError:
                    pass

    async def run_once(self) -> bool:
        job = self.store.next_queued()
        if job is None:
            return False
        attempts = job.attempts + 1
        self.store.update(job.id, status="resolving", attempts=attempts, error_code=None, error_message=None)
        try:
            await self._process(job)
        except ChomikError as err:
            if err.code in RETRYABLE and attempts < MAX_ATTEMPTS:
                log.warning("job %s: %s, retrying", job.id, err.code)
                await asyncio.sleep(self.retry_backoff)
                self.store.update(job.id, status="queued", bytes_done=0, bytes_total=None)
            else:
                self._fail(job, err.code)
        except Exception:
            log.exception("job %s crashed", job.id)
            self._fail(job, "download_failed")
        return True

    async def _process(self, job: Job) -> None:
        check_download_dir(self.settings.download_dir, self.settings.download_require_mount)
        log.info("job %s: resolving %s", job.id, job.url)
        resolved = await self.session.resolve(job.url)
        self.store.update(job.id, status="downloading")

        def progress(name: str, done: int, total: int | None) -> None:
            self.store.update(job.id, filename=name, bytes_done=done, bytes_total=total)

        path = await self.download(
            resolved.url, cookies=resolved.cookies, headers=resolved.headers,
            dest_dir=self.settings.download_dir, fallback_name=resolved.suggested_name, on_progress=progress,
        )
        self.store.update(job.id, status="done", filename=path.name)
        log.info("job %s: saved %s", job.id, path)

    def _fail(self, job: Job, code: str) -> None:
        self.store.update(job.id, status="failed", error_code=code, error_message=MESSAGES[code])
