from pathlib import Path

import pytest

from app.config import load_settings
from app.errors import MESSAGES, ChomikError


def test_defaults():
    s = load_settings({"CHOMIKUJ_LOGIN": "u", "CHOMIKUJ_PASSWORD": "p"})
    assert s.login == "u" and s.password == "p"
    assert s.base_url == "https://chomikuj.pl"
    assert s.download_dir == Path("/downloads")
    assert s.data_dir == Path("/data")
    assert s.min_job_gap == 20.0
    assert (s.pause_min, s.pause_max) == (1.0, 4.0)
    assert s.headless is True
    assert s.allowed_hosts == ()


def test_overrides():
    s = load_settings({
        "CHOMIKUJ_LOGIN": "u", "CHOMIKUJ_PASSWORD": "p",
        "CHOMIKUJ_BASE_URL": "http://127.0.0.1:8765/", "HEADLESS": "false",
        "MIN_JOB_GAP_SECONDS": "0", "DOWNLOAD_DIR": "/tmp/d", "ALLOWED_HOSTS": "homelab.lan, nas.local",
    })
    assert s.allowed_hosts == ("homelab.lan", "nas.local")
    assert s.base_url == "http://127.0.0.1:8765"
    assert s.headless is False
    assert s.min_job_gap == 0.0
    assert s.download_dir == Path("/tmp/d")


def test_missing_credentials_raises():
    with pytest.raises(ValueError, match="CHOMIKUJ_LOGIN"):
        load_settings({})


def test_error_message():
    assert ChomikError("captcha").message == MESSAGES["captcha"]
    assert ChomikError("captcha").code == "captcha"
    with pytest.raises(KeyError):
        ChomikError("nope")


def test_public_url():
    base = {"CHOMIKUJ_LOGIN": "u", "CHOMIKUJ_PASSWORD": "p"}
    assert load_settings(base).public_url is None
    assert load_settings({**base, "PUBLIC_URL": "http://h:8080/"}).public_url == "http://h:8080"
    assert load_settings({**base, "PUBLIC_URL": ""}).public_url is None
