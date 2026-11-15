import pytest
from fastapi.testclient import TestClient

from app.admin import load_or_create_token
from app.config import Settings
from app.errors import MESSAGES, ChomikError
from app.lookup import FileInfo
from app.main import create_app
from app.ratelimit import RateLimiter
from app.urls import file_id_from_url, suggested_name_from_url
from tests.conftest import make_job

URL = "https://chomikuj.pl/u/f,1.zip"


async def fake_lookup(url):
    return FileInfo(file_id=file_id_from_url(url), name=suggested_name_from_url(url), size_text="16 KB",
                    size_bytes=16384, description="opis\nlinia 2", folder=None)


def make_client(tmp_path, lookup=fake_lookup, limiter=None):
    settings = Settings(login="u", password="p", download_dir=tmp_path / "dl", data_dir=tmp_path / "data",
                        allowed_hosts=("testserver",))
    app = create_app(settings, start_worker=False, lookup=lookup, limiter=limiter)
    return TestClient(app, follow_redirects=False), settings, app


@pytest.fixture
def client(tmp_path):
    c, settings, _ = make_client(tmp_path)
    with c:
        c.settings = settings
        yield c


@pytest.fixture
def admin(client):
    token = load_or_create_token(client.settings.data_dir)
    r = client.get(f"/admin/{token}")
    assert r.status_code == 200
    return client


def test_page_has_single_url_input(client):
    r = client.get("/")
    assert r.status_code == 200
    assert '<input name="url"' in r.text


def test_submit_creates_waiting_request(client):
    r = client.post("/requests", data={"url": "https://www.chomikuj.pl/u/f,1.zip?x=1", "name": "Ania"})
    assert r.status_code == 201
    body = r.json()
    assert body["created"] is True
    assert body["request"]["status"] == "waiting"
    assert body["request"]["url"] == URL
    assert body["request"]["requested_by"] == "Ania"
    assert client.get("/requests").json()[0]["id"] == body["request"]["id"]


def test_submit_json_and_merge_names(client):
    client.post("/requests", json={"url": URL, "name": "Ania"})
    r = client.post("/requests", json={"url": URL, "name": "Tomek"})
    assert r.status_code == 201
    assert r.json()["created"] is False
    assert r.json()["request"]["requested_by"] == "Ania, Tomek"
    assert len(client.get("/requests").json()) == 1


def test_submit_invalid_url(client):
    r = client.post("/requests", data={"url": "https://evil.com/x,1.zip"})
    assert r.status_code == 400
    assert r.json()["detail"] == MESSAGES["invalid_url"]
    assert client.get("/requests").json() == []


@pytest.mark.parametrize("code,status", [("not_found", 400), ("password_protected", 400),
                                         ("adult_content", 400), ("unavailable", 503)])
def test_lookup_errors(tmp_path, code, status):
    async def failing(url):
        raise ChomikError(code)
    c, _, _ = make_client(tmp_path, lookup=failing)
    with c:
        r = c.post("/requests", data={"url": URL})
        assert r.status_code == status
        assert r.json()["detail"] == MESSAGES[code]
        assert c.get("/requests").json() == []


def test_healthz(client):
    assert client.get("/healthz").text == "ok"


def test_cross_site_post_rejected(client):
    r = client.post("/requests", data={"url": URL},
                    headers={"Origin": "https://evil.example", "Sec-Fetch-Site": "cross-site"})
    assert r.status_code == 403
    r = client.post("/requests", data={"url": URL}, headers={"Origin": "https://evil.example"})
    assert r.status_code == 403
    assert client.get("/requests").json() == []


def test_cross_site_admin_post_rejected(admin):
    job = make_job(admin.app.state.store, URL, status="waiting")
    r = admin.post(f"/admin/requests/{job.id}/accept", headers={"Sec-Fetch-Site": "cross-site"})
    assert r.status_code == 403
    assert admin.app.state.store.get(job.id).status == "waiting"


def test_same_origin_post_allowed(client):
    r = client.post("/requests", data={"url": URL},
                    headers={"Origin": "http://testserver", "Sec-Fetch-Site": "same-origin"})
    assert r.status_code == 201


def test_rate_limit(client):
    for _ in range(10):
        assert client.post("/requests", data={"url": URL}).status_code == 201
    r = client.post("/requests", data={"url": URL})
    assert r.status_code == 429
    assert r.json()["detail"] == "Too many requests, wait a minute"


def test_injected_limiter(tmp_path):
    c, _, _ = make_client(tmp_path, limiter=RateLimiter(limit=1))
    with c:
        assert c.post("/requests", data={"url": URL}).status_code == 201
        assert c.post("/requests", data={"url": URL}).status_code == 429


@pytest.mark.parametrize("host", ["192.168.1.10:8080", "127.0.0.1:8080", "localhost:8080", "[::1]:8080", "testserver"])
def test_ip_and_allowed_hosts_accepted(client, host):
    assert client.get("/requests", headers={"Host": host}).status_code == 200


def test_unknown_hostname_rejected_dns_rebinding(client):
    assert client.get("/requests", headers={"Host": "attacker.example:8080"}).status_code == 400
    r = client.post("/requests", data={"url": URL},
                    headers={"Host": "attacker.example:8080", "Origin": "http://attacker.example:8080",
                             "Sec-Fetch-Site": "same-origin"})
    assert r.status_code == 400


def test_old_jobs_routes_removed(client):
    assert client.post("/jobs", data={"url": URL}).status_code in (404, 405)
    assert client.get("/jobs").status_code in (404, 405)


def test_admin_access(client):
    assert client.get("/admin").status_code == 404
    assert client.get("/admin/wrong").status_code == 404
    token = load_or_create_token(client.settings.data_dir)
    r = client.get(f"/admin/{token}")
    assert r.status_code == 200
    assert "location.replace('/admin')" in r.text
    assert r.headers["referrer-policy"] == "no-referrer"
    assert r.headers["cache-control"] == "no-store"
    cookie = r.headers["set-cookie"]
    assert "chomikdl_admin" in cookie and "HttpOnly" in cookie and "SameSite=strict" in cookie
    assert "Max-Age=31536000" in cookie and "Path=/" in cookie
    assert client.get("/admin").status_code == 200


def test_admin_post_needs_cookie(client):
    job = make_job(client.app.state.store, URL, status="waiting")
    r = client.post(f"/admin/requests/{job.id}/accept")
    assert r.status_code == 403
    assert client.app.state.store.get(job.id).status == "waiting"
    assert client.post("/admin/requests", data={"url": URL}).status_code == 403


def test_accept_reject_retry(admin):
    store = admin.app.state.store
    a = make_job(store, "https://chomikuj.pl/u/a,10.zip", status="waiting")
    b = make_job(store, "https://chomikuj.pl/u/b,11.zip", status="waiting")
    c = make_job(store, "https://chomikuj.pl/u/c,12.zip", status="failed")
    r = admin.post(f"/admin/requests/{a.id}/accept")
    assert r.status_code == 200 and r.json()["status"] == "queued"
    r = admin.post(f"/admin/requests/{a.id}/accept")
    assert r.status_code == 409
    assert r.json()["detail"] == "Request is not in a state that allows this"
    assert admin.post(f"/admin/requests/{b.id}/reject").json()["status"] == "rejected"
    assert admin.post(f"/admin/requests/{c.id}/retry").json()["status"] == "queued"
    assert admin.post("/admin/requests/9999/accept").status_code == 409


def test_admin_direct_submit(admin):
    r = admin.post("/admin/requests", data={"url": URL, "name": "admin"})
    assert r.status_code == 201
    assert r.json()["request"]["status"] == "queued"
    assert r.json()["request"]["requested_by"] == ""


def test_admin_link_written(client):
    text = (client.settings.data_dir / "admin-link.txt").read_text()
    assert "/admin/" in text


def test_pages_use_textcontent_only():
    from pathlib import Path
    files = [*Path("app/templates").glob("*.html"), *Path("app/static").glob("*.js")]
    assert len(files) >= 3
    for f in files:
        assert "innerHTML" not in f.read_text(encoding="utf-8")


def test_static_assets_served(client):
    assert client.get("/static/requests.js").status_code == 200
    assert client.get("/static/style.css").status_code == 200


def test_startup_log_has_no_token(tmp_path, caplog):
    import logging
    c, settings, _ = make_client(tmp_path)
    with caplog.at_level(logging.DEBUG):
        with c:
            token = load_or_create_token(settings.data_dir)
    assert token not in caplog.text
    assert "admin-link.txt" in caplog.text and "PUBLIC_URL" in caplog.text


def test_regenerated_token_takes_effect(client):
    from app.admin import regenerate_token
    old = load_or_create_token(client.settings.data_dir)
    assert client.get(f"/admin/{old}").status_code == 200
    assert client.get("/admin").status_code == 200
    job = make_job(client.app.state.store, URL, status="waiting")
    new = regenerate_token(client.settings.data_dir)
    assert client.get("/admin").status_code == 404
    assert client.post(f"/admin/requests/{job.id}/accept").status_code == 403
    assert client.get(f"/admin/{old}").status_code == 404
    assert client.get(f"/admin/{new}").status_code == 200
    assert client.get("/admin").status_code == 200
