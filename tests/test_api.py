import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.errors import MESSAGES
from app.main import create_app


@pytest.fixture
def client(tmp_path):
    settings = Settings(login="u", password="p", download_dir=tmp_path / "dl", data_dir=tmp_path / "data")
    with TestClient(create_app(settings, start_worker=False)) as c:
        yield c


def test_page_has_single_url_input(client):
    r = client.get("/")
    assert r.status_code == 200
    assert '<input name="url"' in r.text


def test_submit_valid_url_form(client):
    r = client.post("/jobs", data={"url": "https://www.chomikuj.pl/u/f,1.zip?x=1"})
    assert r.status_code == 201
    job = r.json()
    assert job["status"] == "queued"
    assert job["url"] == "https://chomikuj.pl/u/f,1.zip"
    assert client.get("/jobs").json()[0]["id"] == job["id"]


def test_submit_json(client):
    r = client.post("/jobs", json={"url": "https://chomikuj.pl/u/f,1.zip"})
    assert r.status_code == 201


def test_submit_invalid_url(client):
    r = client.post("/jobs", data={"url": "https://evil.com/x,1.zip"})
    assert r.status_code == 400
    assert r.json()["detail"] == MESSAGES["invalid_url"]
    assert client.get("/jobs").json() == []


def test_healthz(client):
    assert client.get("/healthz").text == "ok"


def test_cross_site_post_rejected(client):
    # a random website the user visits must not be able to queue downloads (spends their transfer)
    r = client.post("/jobs", data={"url": "https://chomikuj.pl/u/f,1.zip"},
                    headers={"Origin": "https://evil.example", "Sec-Fetch-Site": "cross-site"})
    assert r.status_code == 403
    r = client.post("/jobs", data={"url": "https://chomikuj.pl/u/f,1.zip"}, headers={"Origin": "https://evil.example"})
    assert r.status_code == 403
    assert client.get("/jobs").json() == []


def test_same_origin_post_allowed(client):
    r = client.post("/jobs", data={"url": "https://chomikuj.pl/u/f,1.zip"},
                    headers={"Origin": "http://testserver", "Sec-Fetch-Site": "same-origin"})
    assert r.status_code == 201
