import httpx
import pytest

from app.browser.session import BrowserSession, suggested_name_from_url
from app.errors import ChomikError


async def _resolve(settings, path):
    s = BrowserSession(settings)
    await s.start()
    try:
        return await s.resolve(settings.base_url + path)
    finally:
        await s.close()


async def _expect_error(settings, path, code):
    with pytest.raises(ChomikError) as e:
        await _resolve(settings, path)
    assert e.value.code == code


def test_suggested_name_from_url():
    assert suggested_name_from_url("https://chomikuj.pl/u/Moje+pliki/Za%C5%BC%C3%B3%C5%82%C4%87+to,555.mp3(audio)") == "Zażółć to.mp3"
    assert suggested_name_from_url("https://chomikuj.pl/u/f,1.zip") == "f.zip"


async def test_resolve_logs_in_and_returns_file_url(site_settings, fake_state):
    r = await _resolve(site_settings, "/u/f,1.zip")
    assert r.url.endswith("/files/1")
    assert r.cookies["sess"]
    assert r.suggested_name == "f.zip"
    assert "Headless" not in r.headers["User-Agent"]
    assert r.headers["Accept-Language"].startswith("pl-PL")
    assert r.headers["Referer"] == site_settings.base_url + "/u/f,1.zip"
    assert fake_state["logins"] == 1
    # cookies + headers really work for a plain HTTP client
    resp = httpx.get(r.url, cookies=r.cookies, headers=r.headers)
    assert resp.status_code == 200 and resp.content.startswith(b"PK")


async def test_resolve_direct_redirect_without_popup(site_settings):
    r = await _resolve(site_settings, "/u/direct,5.zip")
    assert r.url.endswith("/files/1")


async def test_browser_requests_look_like_regular_chrome(site_settings, fake_state):
    await _resolve(site_settings, "/u/f,1.zip")
    for req in fake_state["requests"]:
        h = req["headers"]
        assert "headless" not in h.get("user-agent", "").lower()
        assert "headless" not in h.get("sec-ch-ua", "").lower()
    page_req = next(r for r in fake_state["requests"] if r["path"] == "/u/f,1.zip")
    assert page_req["headers"]["accept-language"].startswith("pl-PL")


async def test_navigator_webdriver_false(site_settings):
    s = BrowserSession(site_settings)
    await s.start()
    try:
        page = await s.new_page()
        await page.goto(site_settings.base_url)
        assert not await page.evaluate("navigator.webdriver")
        assert await page.evaluate("Intl.DateTimeFormat().resolvedOptions().timeZone") == "Europe/Warsaw"
    finally:
        await s.close()


async def test_wrong_password_login_failed(make_settings):
    await _expect_error(make_settings(password="bad"), "/u/f,1.zip", "login_failed")


async def test_captcha(make_settings):
    await _expect_error(make_settings(login="captcha"), "/u/f,1.zip", "captcha")


async def test_out_of_transfer(site_settings):
    await _expect_error(site_settings, "/u/big,2.zip", "out_of_transfer")


async def test_password_protected(site_settings):
    await _expect_error(site_settings, "/u/pw,3.zip", "password_protected")


async def test_not_found_saves_screenshot(site_settings):
    await _expect_error(site_settings, "/u/gone,4.zip", "not_found")
    assert (site_settings.data_dir / "last_error.png").exists()


async def test_session_persists(site_settings, fake_state):
    await _resolve(site_settings, "/u/f,1.zip")
    await _resolve(site_settings, "/u/f,1.zip")
    assert fake_state["logins"] == 1


async def test_expired_session_relogs_once(site_settings, fake_state):
    await _resolve(site_settings, "/u/f,1.zip")
    httpx.post(site_settings.base_url + "/test/expire")
    r = await _resolve(site_settings, "/u/f,1.zip")
    assert r.url.endswith("/files/1")
    assert fake_state["logins"] == 2
