import pytest

from app.errors import ChomikError
from app.urls import normalize_file_url

BASE = "https://chomikuj.pl"


@pytest.mark.parametrize("url,expected", [
    ("https://chomikuj.pl/user/Folder/plik,123.rar(archive)?a=1#x",
     "https://chomikuj.pl/user/Folder/plik,123.rar(archive)"),
    ("http://www.chomikuj.pl/u/f,9.pdf", "https://chomikuj.pl/u/f,9.pdf"),
    ("https://m.chomikuj.pl/u/f,9.pdf", "https://chomikuj.pl/u/f,9.pdf"),
    ("  https://chomikuj.pl/u/Moje+pliki/Za%C5%BC%C3%B3%C5%82%C4%87,555.mp3(audio)  ",
     "https://chomikuj.pl/u/Moje+pliki/Za%C5%BC%C3%B3%C5%82%C4%87,555.mp3(audio)"),
])
def test_accepts_and_normalises(url, expected):
    assert normalize_file_url(url, BASE) == expected


@pytest.mark.parametrize("url", [
    "https://evil.com/u/f,9.pdf",
    "https://chomikuj.pl.evil.com/u/f,9.pdf",
    "https://chomikuj.pl/",
    "https://chomikuj.pl/user",
    "ftp://chomikuj.pl/u/f,9.pdf",
    "not a url",
    "",
])
def test_rejects(url):
    with pytest.raises(ChomikError) as e:
        normalize_file_url(url, BASE)
    assert e.value.code == "invalid_url"


def test_local_base_keeps_scheme_and_port():
    base = "http://127.0.0.1:8765"
    assert normalize_file_url("http://127.0.0.1:8765/u/f,9.pdf", base) == "http://127.0.0.1:8765/u/f,9.pdf"


def test_file_id_from_url():
    from app.urls import file_id_from_url
    assert file_id_from_url("https://chomikuj.pl/u/Folder/f,9.pdf") == 9
    assert file_id_from_url("https://chomikuj.pl/user") is None
