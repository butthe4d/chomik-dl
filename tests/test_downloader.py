import httpx
import pytest

from app.downloader import stream_download
from app.errors import ChomikError

DATA = b"0123456789" * 300_000  # 3 MB


def _client(handler):
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


async def _run(tmp_path, handler, fallback="fallback.bin"):
    calls = []
    path = await stream_download(
        "https://dl.example/file", cookies={"s": "1"}, headers={"User-Agent": "UA"},
        dest_dir=tmp_path, fallback_name=fallback,
        on_progress=lambda name, done, total: calls.append((name, done, total)),
        client=_client(handler),
    )
    return path, calls


async def test_full_download(tmp_path):
    seen = {}

    def handler(request):
        seen["ua"] = request.headers["user-agent"]
        seen["cookie"] = request.headers.get("cookie")
        return httpx.Response(200, content=DATA, headers={
            "Content-Disposition": 'attachment; filename="real.zip"',
            "Content-Length": str(len(DATA))})

    path, calls = await _run(tmp_path, handler)
    assert path == tmp_path / "real.zip"
    assert path.read_bytes() == DATA
    assert list(tmp_path.glob("*.part")) == []
    assert calls[0][0] == "real.zip"
    assert calls[-1] == ("real.zip", len(DATA), len(DATA))
    assert seen == {"ua": "UA", "cookie": "s=1"}


async def test_no_headers_uses_fallback_and_unknown_total(tmp_path):
    def handler(request):
        async def body():
            yield DATA
        return httpx.Response(200, content=body())  # streamed, no length

    path, calls = await _run(tmp_path, handler, fallback="from page.rar")
    assert path.name == "from page.rar"
    assert calls[-1] == ("from page.rar", len(DATA), None)


async def test_error_mid_stream_cleans_up(tmp_path):
    async def gen():
        yield DATA[:1000]
        raise httpx.ReadError("boom")

    def handler(request):
        return httpx.Response(200, content=gen())

    with pytest.raises(ChomikError) as e:
        await _run(tmp_path, handler)
    assert e.value.code == "download_failed"
    assert list(tmp_path.iterdir()) == []


async def test_404_is_not_found(tmp_path):
    with pytest.raises(ChomikError) as e:
        await _run(tmp_path, lambda r: httpx.Response(404))
    assert e.value.code == "not_found"
    assert list(tmp_path.iterdir()) == []


async def test_html_response_is_failure(tmp_path):
    # chomikuj answering with a web page instead of the file means the link expired / session lost
    def handler(request):
        return httpx.Response(200, content=b"<html>login</html>", headers={"Content-Type": "text/html; charset=utf-8"})

    with pytest.raises(ChomikError) as e:
        await _run(tmp_path, handler)
    assert e.value.code == "download_failed"


async def test_malicious_disposition_stays_inside(tmp_path):
    def handler(request):
        return httpx.Response(200, content=b"x", headers={"Content-Disposition": 'attachment; filename="../../x"'})

    path, _ = await _run(tmp_path, handler)
    assert path == tmp_path / "x"


async def test_gzip_encoded_response_is_not_a_failure(tmp_path):
    import gzip

    body = b"subtitle line\n" * 2000
    packed = gzip.compress(body)

    def handler(request):
        if request.headers.get("accept-encoding", "identity") != "identity":
            return httpx.Response(200, content=packed, headers={
                "Content-Encoding": "gzip", "Content-Length": str(len(packed)),
                "Content-Disposition": 'attachment; filename="a.srt"'})
        return httpx.Response(200, content=body, headers={
            "Content-Length": str(len(body)), "Content-Disposition": 'attachment; filename="a.srt"'})

    path, calls = await _run(tmp_path, handler)
    assert path.read_bytes() == body
    assert calls[-1][1] == calls[-1][2] == len(body)
