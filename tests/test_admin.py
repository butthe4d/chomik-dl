import stat

from app.admin import admin_link, load_or_create_token, regenerate_token, token_matches, write_link_file


def _mode(p):
    return stat.S_IMODE(p.stat().st_mode)


def test_token_created_once_and_private(tmp_path):
    t1 = load_or_create_token(tmp_path)
    assert t1 and load_or_create_token(tmp_path) == t1
    assert _mode(tmp_path / "admin-token") == 0o600


def test_regenerate(tmp_path):
    old = load_or_create_token(tmp_path)
    new = regenerate_token(tmp_path)
    assert new != old
    assert load_or_create_token(tmp_path) == new
    assert not token_matches(old, new)
    assert _mode(tmp_path / "admin-token") == 0o600


def test_token_matches():
    assert token_matches("abc", "abc")
    assert token_matches("abc", None) is False
    assert token_matches("abc", "abd") is False


def test_admin_link():
    assert admin_link("tok", "http://h:8080") == "http://h:8080/admin/tok"
    assert admin_link("tok", None) == "<PUBLIC_URL>/admin/tok"


def test_link_file_private_even_if_preexisting(tmp_path):
    (tmp_path / "admin-link.txt").write_text("x")
    (tmp_path / "admin-link.txt").chmod(0o644)
    p = write_link_file(tmp_path, "http://h/admin/t")
    assert p == tmp_path / "admin-link.txt"
    assert p.read_text().strip() == "http://h/admin/t"
    assert _mode(p) == 0o600
