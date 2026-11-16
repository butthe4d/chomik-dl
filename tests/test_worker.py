from dataclasses import replace

import pytest

from app.browser.session import Resolved
from app.config import Settings
from app.errors import MESSAGES, ChomikError
from app.jobs import JobStore
from tests.conftest import make_job
from app.worker import Worker


@pytest.fixture
def env(tmp_path):
    settings = Settings(login="u", password="p", download_dir=tmp_path / "dl", data_dir=tmp_path / "data",
                        min_job_gap=0, pause_min=0, pause_max=0)
    return settings, JobStore(tmp_path / "data" / "jobs.db")


class FakeSession:
    def __init__(self, errors=()):
        self.errors = list(errors)
        self.calls = 0

    async def resolve(self, url):
        self.calls += 1
        if self.errors:
            raise ChomikError(self.errors.pop(0))
        return Resolved(url="https://dl/x", cookies={"s": "1"}, headers={"User-Agent": "UA"}, suggested_name="f.zip")


async def fake_download(url, *, cookies, headers, dest_dir, fallback_name, on_progress, client=None):
    dest_dir.mkdir(parents=True, exist_ok=True)
    on_progress(fallback_name, 5, 10)
    on_progress(fallback_name, 10, 10)
    (dest_dir / fallback_name).write_bytes(b"x" * 10)
    return dest_dir / fallback_name


async def test_success(env):
    settings, store = env
    job = make_job(store, "https://chomikuj.pl/u/f,1.zip")
    w = Worker(settings, store, FakeSession(), download=fake_download, retry_backoff=0)
    assert await w.run_once() is True
    got = store.get(job.id)
    assert (got.status, got.filename, got.bytes_done, got.bytes_total) == ("done", "f.zip", 10, 10)
    assert got.attempts == 1


async def test_empty_queue(env):
    settings, store = env
    assert await Worker(settings, store, FakeSession(), download=fake_download).run_once() is False


async def test_captcha_fails_without_retry(env):
    settings, store = env
    job = make_job(store, "u")
    session = FakeSession(errors=["captcha"])
    w = Worker(settings, store, session, download=fake_download, retry_backoff=0)
    await w.run_once()
    got = store.get(job.id)
    assert (got.status, got.error_code, got.error_message) == ("failed", "captcha", MESSAGES["captcha"])
    assert await w.run_once() is False
    assert session.calls == 1


async def test_timeout_retried_once_then_succeeds(env):
    settings, store = env
    job = make_job(store, "u")
    w = Worker(settings, store, FakeSession(errors=["timeout"]), download=fake_download, retry_backoff=0)
    await w.run_once()
    assert store.get(job.id).status == "queued"
    await w.run_once()
    got = store.get(job.id)
    assert got.status == "done" and got.attempts == 2


async def test_timeout_twice_fails(env):
    settings, store = env
    job = make_job(store, "u")
    w = Worker(settings, store, FakeSession(errors=["timeout", "timeout"]), download=fake_download, retry_backoff=0)
    await w.run_once()
    await w.run_once()
    got = store.get(job.id)
    assert got.status == "failed" and got.error_code == "timeout"


async def test_unexpected_exception_marks_failed(env):
    settings, store = env
    job = make_job(store, "u")

    async def boom(*a, **kw):
        raise RuntimeError("bug")

    w = Worker(settings, store, FakeSession(), download=boom, retry_backoff=0)
    await w.run_once()
    got = store.get(job.id)
    assert got.status == "failed" and got.error_code == "download_failed"
