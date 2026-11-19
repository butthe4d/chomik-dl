import os
from dataclasses import replace

import pytest

from app.browser.session import Resolved
from app.config import Settings
from app.errors import MESSAGES, ChomikError
from app.jobs import JobStore
from tests.conftest import make_job
from app import worker as worker_mod
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


async def _run_storage(env, tmp_path, monkeypatch=None, *, require_mount, prep=None):
    settings, store = env
    settings = replace(settings, download_require_mount=require_mount)
    if prep:
        prep(settings.download_dir)
    job = make_job(store, "https://chomikuj.pl/u/f,1.zip")
    session = FakeSession()
    w = Worker(settings, store, session, download=fake_download, retry_backoff=0)
    await w.run_once()
    return store.get(job.id), session


async def test_require_mount_plain_dir_fails_before_resolve(env, tmp_path):
    got, session = await _run_storage(env, tmp_path, require_mount=True, prep=lambda d: d.mkdir())
    assert got.status == "failed"
    assert got.error_code == "storage_unavailable"
    assert got.error_message == MESSAGES["storage_unavailable"]
    assert session.calls == 0


async def test_require_mount_false_plain_dir_ok(env, tmp_path):
    got, _ = await _run_storage(env, tmp_path, require_mount=False, prep=lambda d: d.mkdir())
    assert got.status == "done"


async def test_require_mount_false_missing_dir_created(env, tmp_path):
    got, _ = await _run_storage(env, tmp_path, require_mount=False)
    assert got.status == "done"


async def test_missing_dir_fails(env, tmp_path):
    got, session = await _run_storage(env, tmp_path, require_mount=True)
    assert got.error_code == "storage_unavailable"
    assert session.calls == 0


async def test_unwritable_dir_fails(env, tmp_path):
    if os.geteuid() == 0:
        pytest.skip("root ignores directory permissions")

    def prep(d):
        d.mkdir()
        d.chmod(0o500)

    try:
        got, session = await _run_storage(env, tmp_path, require_mount=False, prep=prep)
    finally:
        env[0].download_dir.chmod(0o700)
    assert got.error_code == "storage_unavailable"
    assert session.calls == 0


async def test_require_mount_with_mount_ok(env, tmp_path, monkeypatch):
    mi = tmp_path / "mountinfo"
    mi.write_text(_mi_line(env[0].download_dir.resolve()))
    monkeypatch.setattr(worker_mod, "MOUNTINFO", mi)
    got, _ = await _run_storage(env, tmp_path, require_mount=True, prep=lambda d: d.mkdir())
    assert got.status == "done"


def test_storage_unavailable_not_retryable():
    from app.worker import RETRYABLE
    assert "storage_unavailable" not in RETRYABLE


def _mi_line(mp) -> str:
    esc = str(mp).replace(" ", "\\040")
    return f"36 35 98:0 /mnt1 {esc} rw,noatime - ext3 /dev/root rw\n"


def test_is_mount_point_listed(tmp_path, monkeypatch):
    mi = tmp_path / "mi"
    mi.write_text("1 0 8:1 / / rw - ext4 /dev/sda1 rw\n" + _mi_line(tmp_path.resolve()))
    monkeypatch.setattr(worker_mod, "MOUNTINFO", mi)
    assert worker_mod.is_mount_point(tmp_path) is True


def test_is_mount_point_not_listed(tmp_path, monkeypatch):
    mi = tmp_path / "mi"
    mi.write_text("1 0 8:1 / / rw - ext4 /dev/sda1 rw\n")
    monkeypatch.setattr(worker_mod, "MOUNTINFO", mi)
    assert worker_mod.is_mount_point(tmp_path) is False


def test_is_mount_point_octal_space(tmp_path, monkeypatch):
    d = tmp_path / "my data"
    d.mkdir()
    mi = tmp_path / "mi"
    mi.write_text(_mi_line(d.resolve()))
    assert "\\040" in mi.read_text()
    monkeypatch.setattr(worker_mod, "MOUNTINFO", mi)
    assert worker_mod.is_mount_point(d) is True


def test_is_mount_point_fallback(tmp_path, monkeypatch):
    monkeypatch.setattr(worker_mod, "MOUNTINFO", tmp_path / "missing")
    monkeypatch.setattr(os.path, "ismount", lambda p: True)
    assert worker_mod.is_mount_point(tmp_path) is True
    monkeypatch.setattr(os.path, "ismount", lambda p: False)
    assert worker_mod.is_mount_point(tmp_path) is False
