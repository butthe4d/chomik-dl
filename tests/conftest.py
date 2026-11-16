import socket
import threading
import time
from dataclasses import replace

import pytest
import uvicorn

from app.config import Settings
from app.lookup import FileInfo
from app.urls import file_id_from_url, suggested_name_from_url
from tests.fake_site import app as fake


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture(scope="session")
def fake_site_url():
    port = _free_port()
    server = uvicorn.Server(uvicorn.Config(fake.app, host="127.0.0.1", port=port, log_level="warning"))
    t = threading.Thread(target=server.run, daemon=True)
    t.start()
    while not server.started:
        time.sleep(0.05)
    yield f"http://127.0.0.1:{port}"
    server.should_exit = True
    t.join(5)


@pytest.fixture
def fake_state(fake_site_url):
    fake.reset()
    return fake.state


@pytest.fixture
def site_settings(tmp_path, fake_site_url, fake_state):
    return Settings(
        login=fake.USER, password=fake.PASSWORD, base_url=fake_site_url,
        download_dir=tmp_path / "downloads", data_dir=tmp_path / "data",
        min_job_gap=0, pause_min=0, pause_max=0, headless=True,
    )


@pytest.fixture
def make_settings(site_settings):
    return lambda **kw: replace(site_settings, **kw)


def make_job(store, url, status="queued", requested_by=None):
    """Create a job row without any network lookup."""
    info = FileInfo(file_id=file_id_from_url(url), name=suggested_name_from_url(url),
                    size_text=None, size_bytes=None, description=None, folder=None)
    job, _ = store.add_request(url, info, requested_by, status=status)
    return job
