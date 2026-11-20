"""Browser tests for the request list tabs, requester filter and name suggestions."""
import threading
import time

import pytest
import uvicorn
from playwright.sync_api import sync_playwright

from app.config import Settings
from app.main import create_app
from tests.conftest import _free_port, make_job

TAB_LABELS = ["Czeka na akceptację", "Zaakceptowane", "Pobrane", "Błędy", "Odrzucone"]


async def _no_lookup(url):  # never called: tests seed rows directly
    raise AssertionError("lookup should not run")


@pytest.fixture(scope="module")
def site(tmp_path_factory):
    tmp = tmp_path_factory.mktemp("pages")
    settings = Settings(login="u", password="p", download_dir=tmp / "dl", data_dir=tmp / "data")
    app = create_app(settings, start_worker=False, lookup=_no_lookup)
    store = app.state.store
    rows = [
        ("https://chomikuj.pl/u/w1,1.zip", "waiting", "Ania"),
        ("https://chomikuj.pl/u/w2,2.zip", "waiting", None),
        ("https://chomikuj.pl/u/q,3.zip", "queued", "Tomek"),
        ("https://chomikuj.pl/u/d,4.zip", "downloading", "Ania, Ola"),
        ("https://chomikuj.pl/u/ok,5.zip", "done", "Basia"),
        ("https://chomikuj.pl/u/f,6.zip", "failed", "Celina"),
        ("https://chomikuj.pl/u/r,7.zip", "rejected", "Darek"),
    ]
    for url, status, who in rows:
        make_job(store, url, status=status, requested_by=who)
    port = _free_port()
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning"))
    t = threading.Thread(target=server.run, daemon=True)
    t.start()
    while not server.started:
        time.sleep(0.05)
    token = (settings.data_dir / "admin-token").read_text().strip()
    yield {"url": f"http://127.0.0.1:{port}", "token": token}
    server.should_exit = True
    t.join(5)


@pytest.fixture(scope="module")
def browser():
    with sync_playwright() as pw:
        b = pw.chromium.launch()
        yield b
        b.close()


@pytest.fixture
def page(browser):
    ctx = browser.new_context()
    p = ctx.new_page()
    yield p
    ctx.close()


def tab(page, label):
    return page.locator('#tabs [role="tab"]', has_text=label)


def visible_names(page):
    return page.locator("#jobs li .name").all_inner_texts()


def open_public(page, site):
    page.goto(site["url"] + "/")
    page.wait_for_selector('#tabs [role="tab"]')
    page.wait_for_selector("#jobs li")


def test_tabs_counts_and_default(page, site):
    open_public(page, site)
    tabs = page.locator('#tabs [role="tab"]').all_inner_texts()
    assert tabs == ["Czeka na akceptację (2)", "Zaakceptowane (2)", "Pobrane (1)", "Błędy (1)", "Odrzucone (1)"]
    assert tab(page, "Czeka na akceptację").get_attribute("aria-selected") == "true"
    assert sorted(visible_names(page)) == ["w1.zip", "w2.zip"]


def test_switching_tab_survives_poll(page, site):
    open_public(page, site)
    tab(page, "Pobrane").click()
    assert visible_names(page) == ["ok.zip"]
    page.wait_for_timeout(2500)
    assert tab(page, "Pobrane").get_attribute("aria-selected") == "true"
    assert visible_names(page) == ["ok.zip"]


def test_filter_by_requester(page, site):
    open_public(page, site)
    options = page.locator("#who option").all_inner_texts()
    assert options == ["wszyscy", "Ania", "Basia", "Celina", "Darek", "Ola", "Tomek"]
    page.select_option("#who", "Ola")
    tabs = page.locator('#tabs [role="tab"]').all_inner_texts()
    assert tabs == ["Czeka na akceptację (0)", "Zaakceptowane (1)", "Pobrane (0)", "Błędy (0)", "Odrzucone (0)"]
    page.reload()
    page.wait_for_selector('#tabs [role="tab"]')
    page.wait_for_function("document.querySelector('#who').options.length > 1")
    assert page.input_value("#who") == "Ola"


def test_missing_requester_falls_back(page, site):
    page.add_init_script("try { localStorage.setItem('chomikdl_who_public', 'Zenek'); } catch (e) {}")
    open_public(page, site)
    page.wait_for_function("document.querySelector('#who').options.length > 1")
    assert page.input_value("#who") == ""
    assert sorted(visible_names(page)) == ["w1.zip", "w2.zip"]


def test_name_suggestions(page, site):
    open_public(page, site)
    page.wait_for_function("document.querySelectorAll('#names option').length > 0")
    values = page.eval_on_selector_all("#names option", "os => os.map(o => o.value)")
    assert values == ["Darek", "Celina", "Basia", "Ania", "Ola"]
    assert page.get_attribute("input[name=name]", "list") == "names"


def test_empty_tab_and_storage_errors(page, site):
    page.add_init_script(
        "Object.defineProperty(window, 'localStorage', {get() { throw new Error('denied'); }});")
    open_public(page, site)
    assert tab(page, "Czeka na akceptację").get_attribute("aria-selected") == "true"
    page.select_option("#who", "Basia")
    tab(page, "Czeka na akceptację").click()
    assert page.locator("#jobs li.empty").inner_text() == "Brak próśb."


def test_admin_buttons_in_tabs(page, site):
    page.goto(f"{site['url']}/admin/{site['token']}")
    page.wait_for_url("**/admin")
    page.wait_for_selector('#tabs [role="tab"]')
    page.wait_for_selector("#jobs li")
    assert page.locator("#names").count() == 0
    assert page.locator("#jobs li .actions button").all_inner_texts()[:2] == ["Akceptuj", "Odrzuć"]
    tab(page, "Błędy").click()
    assert page.locator("#jobs li .actions button").all_inner_texts() == ["Ponów"]
