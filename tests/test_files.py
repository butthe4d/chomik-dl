from app.files import filename_from_content_disposition, sanitize_filename, unique_path


def test_sanitize_strips_path():
    assert sanitize_filename("../../etc/passwd") == "passwd"
    assert sanitize_filename("a\\b\\c.txt") == "c.txt"


def test_sanitize_replaces_illegal_chars():
    assert sanitize_filename('a<b>:c?.txt') == "a_b__c_.txt"
    assert sanitize_filename("x\x00y.bin") == "x_y.bin"


def test_sanitize_never_empty():
    assert sanitize_filename("..") == "download"
    assert sanitize_filename("   ") == "download"


def test_sanitize_limits_length_keeping_extension():
    name = sanitize_filename("ż" * 300 + ".zip")
    assert name.endswith(".zip")
    assert len(name.encode()) <= 200


def test_content_disposition():
    assert filename_from_content_disposition(
        "attachment; filename*=UTF-8''za%C5%BC%C3%B3%C5%82%C4%87.zip") == "zażółć.zip"
    assert filename_from_content_disposition('attachment; filename="x.rar"') == "x.rar"
    assert filename_from_content_disposition('attachment; filename=plain.7z') == "plain.7z"
    assert filename_from_content_disposition(None) is None
    assert filename_from_content_disposition("inline") is None


def test_unique_path(tmp_path):
    assert unique_path(tmp_path, "a.zip") == tmp_path / "a.zip"
    (tmp_path / "a.zip").write_text("x")
    (tmp_path / "a (1).zip.part").write_text("x")
    assert unique_path(tmp_path, "a.zip") == tmp_path / "a (2).zip"
