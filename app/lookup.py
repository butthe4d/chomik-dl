"""Logged-out lookup of a chomikuj file page (name, size, description).

Deliberately free of playwright: plain httpx + BeautifulSoup.
"""
import re
from dataclasses import dataclass

import httpx
from bs4 import BeautifulSoup, Comment, NavigableString, Tag

from app.browser import selectors as sel
from app.errors import ChomikError
from app.urls import file_id_from_url, suggested_name_from_url

# Same UA shape as app.browser.session.chrome_user_agent (not imported: that module pulls in playwright).
DEFAULT_CHROME_MAJOR = "158"
LOOKUP_HEADERS: dict[str, str] = {
    "User-Agent": (
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
        f"Chrome/{DEFAULT_CHROME_MAJOR}.0.0.0 Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "pl-PL,pl;q=0.9,en;q=0.8",
}
LOOKUP_TIMEOUT_S = 15.0

_UNITS = {"B": 1, "KB": 1024, "MB": 1024**2, "GB": 1024**3}
_SIZE = re.compile(r"^\s*(\d+(?:[.,]\d+)?)\s*(B|KB|MB|GB)\s*$", re.I)


@dataclass
class FileInfo:
    file_id: int
    name: str
    size_text: str | None
    size_bytes: int | None
    description: str | None
    folder: str | None


def parse_size(text: str) -> int | None:
    m = _SIZE.match(text or "")
    if not m:
        return None
    return int(float(m.group(1).replace(",", ".")) * _UNITS[m.group(2).upper()])


def _element_text(el: Tag) -> str:
    """Text of an element with <br> as newlines; tags dropped, entities decoded."""
    parts: list[str] = []
    for node in el.descendants:
        if isinstance(node, Comment):
            continue
        if isinstance(node, NavigableString):
            parts.append(str(node))
        elif node.name == "br":
            parts.append("\n")
    return "".join(parts)


def _description(soup: BeautifulSoup) -> str | None:
    el = soup.select_one(sel.LOOKUP_DESCRIPTION)
    if el is None:
        return None
    lines = [line.strip() for line in _element_text(el).splitlines()]
    while lines and not lines[0]:
        lines.pop(0)
    while lines and not lines[-1]:
        lines.pop()
    return "\n".join(lines) or None


def _name(soup: BeautifulSoup, url: str) -> str:
    h1 = soup.select_one(sel.LOOKUP_NAME)
    if h1 and h1.get_text(strip=True):
        return h1.get_text(strip=True)
    og = soup.find("meta", property="og:title")
    if og and og.get("content", "").strip():
        return og["content"].strip()
    return suggested_name_from_url(url)


def _folder(soup: BeautifulSoup) -> str | None:
    el = soup.select_one(sel.LOOKUP_FOLDER)
    if el is None:
        return None
    parts = [a.get_text(strip=True) for a in el.find_all("a")]
    return " / ".join(p for p in parts if p) or None


def parse_file_page(html: str, url: str) -> FileInfo:
    soup = BeautifulSoup(html, "html.parser")
    if soup.select_one("#fileDetails") is None:
        text = soup.get_text(" ", strip=True)
        if sel.TEXT_PASSWORD.search(text):
            raise ChomikError("password_protected")
        if sel.TEXT_ADULT.search(text):
            raise ChomikError("adult_content")
        raise ChomikError("not_found")
    size_el = soup.select_one(sel.LOOKUP_SIZE)
    size_text = size_el.get_text(strip=True) if size_el else None
    size_text = size_text or None
    return FileInfo(
        file_id=file_id_from_url(url) or 0,
        name=_name(soup, url),
        size_text=size_text,
        size_bytes=parse_size(size_text) if size_text else None,
        description=_description(soup),
        folder=_folder(soup),
    )


async def lookup_file(url: str, *, client: httpx.AsyncClient | None = None) -> FileInfo:
    own = client is None
    if own:
        client = httpx.AsyncClient(headers=LOOKUP_HEADERS, timeout=LOOKUP_TIMEOUT_S, follow_redirects=True)
    try:
        try:
            resp = await client.get(url, headers=LOOKUP_HEADERS)
        except httpx.HTTPError:
            raise ChomikError("unavailable") from None
    finally:
        if own:
            await client.aclose()
    if resp.status_code == 404:
        raise ChomikError("not_found")
    if resp.status_code == 429 or resp.status_code >= 500:
        raise ChomikError("unavailable")
    return parse_file_page(resp.text, url)
