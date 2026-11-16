"""Drive a real (headless) Chromium through chomikuj's login and download flow.

The browser only *resolves* the final file URL; the bytes are fetched by
app.downloader with the cookies/headers returned here.
"""
import asyncio
import logging
import random
from dataclasses import dataclass

from playwright.async_api import BrowserContext, Download, Page, Playwright, async_playwright
from playwright.async_api import Error as PlaywrightError
from playwright.async_api import TimeoutError as PlaywrightTimeout

from app.browser import selectors as sel
from app.config import Settings
from app.errors import ChomikError
from app.humanize import human_pause
from app.urls import suggested_name_from_url  # noqa: F401  (re-exported)

log = logging.getLogger(__name__)

ACCEPT_LANGUAGE = "pl-PL,pl;q=0.9,en;q=0.8"
LOCALE = "pl-PL"
TIMEZONE = "Europe/Warsaw"
VIEWPORT = {"width": 1920, "height": 1080}
NAV_TIMEOUT_MS = 45_000
DOWNLOAD_WAIT_S = 45.0
LAUNCH_ARGS = ["--disable-blink-features=AutomationControlled"]


@dataclass
class Resolved:
    url: str
    cookies: dict[str, str]
    headers: dict[str, str]
    suggested_name: str


def chrome_user_agent(browser_version: str) -> str:
    major = browser_version.split(".", 1)[0]
    return f"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/{major}.0.0.0 Safari/537.36"


class BrowserSession:
    def __init__(self, settings: Settings):
        self.settings = settings
        self._pw: Playwright | None = None
        self._ctx: BrowserContext | None = None
        self.user_agent = ""

    async def start(self) -> None:
        self._pw = await async_playwright().start()
        # Probe the real browser version so the UA matches the engine (no "HeadlessChrome").
        probe = await self._pw.chromium.launch(channel="chromium", headless=True)
        self.user_agent = chrome_user_agent(probe.version)
        await probe.close()
        profile = self.settings.data_dir / "browser"
        profile.mkdir(parents=True, exist_ok=True)
        self._ctx = await self._pw.chromium.launch_persistent_context(
            user_data_dir=str(profile),
            channel="chromium",
            headless=self.settings.headless,
            args=LAUNCH_ARGS,
            user_agent=self.user_agent,
            locale=LOCALE,
            timezone_id=TIMEZONE,
            viewport=VIEWPORT,
            extra_http_headers={"Accept-Language": ACCEPT_LANGUAGE},
            accept_downloads=True,
        )
        self._ctx.set_default_timeout(NAV_TIMEOUT_MS)

    async def close(self) -> None:
        if self._ctx:
            await self._ctx.close()
        if self._pw:
            await self._pw.stop()
        self._ctx = self._pw = None

    async def new_page(self) -> Page:
        assert self._ctx, "start() first"
        return await self._ctx.new_page()

    @property
    def headers(self) -> dict[str, str]:
        return {"User-Agent": self.user_agent, "Accept-Language": ACCEPT_LANGUAGE}

    async def resolve(self, file_url: str) -> Resolved:
        page = await self.new_page()
        try:
            return await self._resolve(page, file_url)
        except ChomikError:
            await self._screenshot(page)
            raise
        except PlaywrightTimeout as exc:
            await self._screenshot(page)
            raise ChomikError("timeout") from exc
        finally:
            await page.close()

    async def _resolve(self, page: Page, file_url: str) -> Resolved:
        resp = await self._goto(page, file_url)
        if not await self._logged_in(page):
            await self._login_in_own_tab(file_url)
            resp = await self._goto(page, file_url)
            if not await self._logged_in(page):
                raise ChomikError("login_failed")
        await human_pause(self.settings)
        if resp is not None and resp.status == 404:
            raise ChomikError("not_found")
        if await page.locator(sel.DOWNLOAD_BUTTON).count() == 0:
            text = await page.locator("body").inner_text()
            if sel.TEXT_PASSWORD.search(text):
                raise ChomikError("password_protected")
            raise ChomikError("not_found")
        download = await self._trigger_download(page)
        url = download.url
        try:
            await download.cancel()
        except PlaywrightError:
            pass
        cookies = {c["name"]: c["value"] for c in await self._ctx.cookies(url)}
        return Resolved(
            url=url,
            cookies=cookies,
            headers={**self.headers, "Referer": file_url},
            suggested_name=suggested_name_from_url(file_url),
        )

    async def _goto(self, page: Page, url: str):
        resp = await page.goto(url, wait_until="domcontentloaded")
        consent = page.locator(f"{sel.TERMS_ACCEPT} >> visible=true")
        if await consent.count():
            log.info("accepting cookie consent")
            await human_pause(self.settings)
            await consent.first.click()
            # the site may reload or just hide the overlay; either way it must go away
            await page.locator(sel.TERMS_ACCEPT).first.wait_for(state="hidden")
            resp = await page.goto(url, wait_until="domcontentloaded")
        return resp

    async def _logged_in(self, page: Page) -> bool:
        return await page.locator(sel.LOGIN_INPUT).count() == 0

    def _typing_delay(self) -> float:
        return random.uniform(50, 150) if self.settings.pause_max > 0 else 0

    async def _login_in_own_tab(self, return_url: str) -> None:
        # Chromium's "save password?" prompt leaves the login tab unclickable, so use a throwaway tab.
        page = await self.new_page()
        try:
            await self._goto(page, return_url)
            if not await self._logged_in(page):
                await self._login(page)
        except ChomikError:
            await self._screenshot(page)
            raise
        finally:
            await page.close()

    async def _login(self, page: Page) -> None:
        log.info("logging in to chomikuj")
        await page.locator(sel.LOGIN_INPUT).first.click()
        await page.locator(sel.LOGIN_INPUT).first.press_sequentially(self.settings.login, delay=self._typing_delay())
        await human_pause(self.settings)
        await page.locator(sel.PASSWORD_INPUT).first.click()
        await page.locator(sel.PASSWORD_INPUT).first.press_sequentially(self.settings.password, delay=self._typing_delay())
        await human_pause(self.settings)
        await page.locator(sel.LOGIN_SUBMIT).first.click()
        loop = asyncio.get_running_loop()
        deadline = loop.time() + 20
        while loop.time() < deadline:
            await asyncio.sleep(0.3)
            try:
                if await page.locator(sel.CAPTCHA_MARKER).count():
                    raise ChomikError("captcha")
                if await page.locator(f"{sel.LOGIN_ERROR}:visible").count():
                    raise ChomikError("login_failed")
                if await self._logged_in(page):
                    return
            except PlaywrightError:
                continue  # page navigating; look again
        raise ChomikError("login_failed")

    async def _trigger_download(self, page: Page) -> Download:
        loop = asyncio.get_running_loop()
        got: asyncio.Future[Download] = loop.create_future()

        def on_download(d: Download) -> None:
            if not got.done():
                got.set_result(d)

        def on_page(p: Page) -> None:
            p.on("download", on_download)

        page.on("download", on_download)
        self._ctx.on("page", on_page)
        try:
            await page.locator(sel.DOWNLOAD_BUTTON).first.click()
            confirmed = False
            deadline = loop.time() + DOWNLOAD_WAIT_S
            while not got.done():
                if loop.time() > deadline:
                    raise ChomikError("timeout")
                for p in list(self._ctx.pages):
                    try:
                        text = " ".join(await p.locator(sel.DIALOG).all_inner_texts())
                        if sel.TEXT_OUT_OF_TRANSFER.search(text):
                            raise ChomikError("out_of_transfer")
                        if sel.TEXT_PASSWORD.search(text):
                            raise ChomikError("password_protected")
                        confirm = p.locator(f"{sel.POPUP_CONFIRM_BUTTON} >> visible=true")
                        if not confirmed and await confirm.count():
                            await human_pause(self.settings)
                            await confirm.first.click()
                            confirmed = True
                    except PlaywrightError:
                        continue
                await asyncio.wait({got}, timeout=0.3)
            return got.result()
        finally:
            self._ctx.remove_listener("page", on_page)

    async def _screenshot(self, page: Page) -> None:
        try:
            self.settings.data_dir.mkdir(parents=True, exist_ok=True)
            await page.screenshot(path=str(self.settings.data_dir / "last_error.png"), full_page=True)
        except Exception:  # never mask the real error
            log.warning("could not save error screenshot", exc_info=True)
