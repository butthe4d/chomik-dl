from pathlib import Path

import httpx
import pytest

from app.errors import ChomikError
from app.lookup import LOOKUP_HEADERS, lookup_file, parse_file_page, parse_size

FIX = Path(__file__).parent / "fixtures"
HARRY = "https://chomikuj.pl/kazik_78/Ksi*c4*85*c5*bcki/Harry+Harrison/Harrison+Harry/Harry+Harrison,2279812126.zip(archive)"
PIRAT = "https://chomikuj.pl/Sylwiasiegmuller/Przedszkole/pirat/pirat+kolorowanka,5999643804.jpg"


def fx(name):
    return (FIX / name).read_text(encoding="utf-8")


def test_parse_with_description():
    info = parse_file_page(fx("with_description.html"), HARRY)
    assert info.file_id == 2279812126
    assert info.name == "Harry Harrison.zip"
    assert info.size_text == "16,38 MB"
    assert info.size_bytes == 17175674
    lines = info.description.splitlines()
    assert lines[0] == "Harrison Harry - 24 Opowiadania"
    assert "Harrison Harry - Stalowy Szczur 04 - Stalowy Szczur" in lines
    assert "<" not in info.description
    assert info.folder == "kazik_78 / Książki / Harry Harrison / Harrison Harry"


def test_parse_without_description():
    info = parse_file_page(fx("no_description.html"), PIRAT)
    assert info.name == "pirat kolorowanka.jpg"
    assert info.size_text == "35 KB"
    assert info.size_bytes == 35840
    assert info.description is None


def test_parse_not_found():
    with pytest.raises(ChomikError) as e:
        parse_file_page(fx("not_found.html"), HARRY)
    assert e.value.code == "not_found"


def test_parse_markup_is_text():
    html = ('<div id="fileDetails"><h1><a>a&amp;b.zip</a></h1>'
            '<div class="filedescription">x <script>alert(1)</script><br>y &lt;b&gt;</div></div>')
    info = parse_file_page(html, "https://chomikuj.pl/u/a%26b,7.zip")
    assert info.name == "a&b.zip"
    assert info.description == "x alert(1)\ny <b>"


@pytest.mark.parametrize("text,code", [
    ("Podaj hasło do folderu", "password_protected"),
    ("Musisz być pełnoletni", "adult_content"),
])
def test_parse_password_and_adult_gates(text, code):
    with pytest.raises(ChomikError) as e:
        parse_file_page(f"<html><body><p>{text}</p></body></html>", HARRY)
    assert e.value.code == code


@pytest.mark.parametrize("text,expected", [
    ("16,38 MB", 17175674), ("35 KB", 35840), ("1 GB", 1073741824), ("700 B", 700), ("?", None),
    ("1.5 KB", 1536),
])
def test_parse_size(text, expected):
    assert parse_size(text) == expected


def client_for(handler):
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


async def test_lookup_ok_and_headers():
    seen = {}

    def handler(request):
        seen["headers"] = request.headers
        return httpx.Response(200, text=fx("no_description.html"))

    async with client_for(handler) as c:
        info = await lookup_file(PIRAT, client=c)
    assert info.file_id == 5999643804
    assert seen["headers"]["accept-language"].startswith("pl-PL")
    assert "cookie" not in seen["headers"]
    assert "Accept-Language" in LOOKUP_HEADERS


async def test_lookup_404():
    async with client_for(lambda r: httpx.Response(404)) as c:
        with pytest.raises(ChomikError) as e:
            await lookup_file(PIRAT, client=c)
    assert e.value.code == "not_found"


@pytest.mark.parametrize("status", [503, 429])
async def test_lookup_unavailable_status(status):
    async with client_for(lambda r: httpx.Response(status)) as c:
        with pytest.raises(ChomikError) as e:
            await lookup_file(PIRAT, client=c)
    assert e.value.code == "unavailable"


async def test_lookup_timeout():
    def handler(request):
        raise httpx.ConnectTimeout("boom")

    async with client_for(handler) as c:
        with pytest.raises(ChomikError) as e:
            await lookup_file(PIRAT, client=c)
    assert e.value.code == "unavailable"


def test_gate_error_messages():
    assert ChomikError("unavailable").message == "chomikuj is not responding, try again later"
    assert ChomikError("adult_content").message == "File is behind an adult-content check"
