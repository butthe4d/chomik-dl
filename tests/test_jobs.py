from app.jobs import JobStore


def test_add_and_get(tmp_path):
    s = JobStore(tmp_path / "j.db")
    j = s.add("https://chomikuj.pl/u/f,1.zip")
    got = s.get(j.id)
    assert got.url == "https://chomikuj.pl/u/f,1.zip"
    assert got.status == "queued" and got.bytes_done == 0 and got.attempts == 0
    assert s.get(9999) is None


def test_list_newest_first_and_next_queued_oldest_first(tmp_path):
    s = JobStore(tmp_path / "j.db")
    a, b, c = (s.add(f"u{i}") for i in range(3))
    assert [j.id for j in s.list()] == [c.id, b.id, a.id]
    s.update(a.id, status="done")
    assert s.next_queued().id == b.id


def test_update_fields(tmp_path):
    s = JobStore(tmp_path / "j.db")
    j = s.add("u")
    s.update(j.id, status="failed", error_code="captcha", error_message="m", bytes_total=None)
    got = s.get(j.id)
    assert (got.status, got.error_code, got.error_message) == ("failed", "captcha", "m")


def test_recover_requeues_and_removes_part(tmp_path):
    dl = tmp_path / "dl"
    dl.mkdir()
    s = JobStore(tmp_path / "j.db")
    a = s.add("a")
    s.update(a.id, status="downloading", filename="a.zip", bytes_done=5)
    b = s.add("b")
    s.update(b.id, status="resolving")
    c = s.add("c")
    s.update(c.id, status="done", filename="c.zip")
    (dl / "a.zip.part").write_bytes(b"xx")
    (dl / "c.zip").write_bytes(b"ok")
    assert s.recover(dl) == 2
    assert s.get(a.id).status == "queued" and s.get(a.id).bytes_done == 0
    assert s.get(b.id).status == "queued"
    assert s.get(c.id).status == "done"
    assert not (dl / "a.zip.part").exists()
    assert (dl / "c.zip").exists()


def test_persists_across_instances(tmp_path):
    JobStore(tmp_path / "j.db").add("u")
    assert len(JobStore(tmp_path / "j.db").list()) == 1


def test_recover_marks_finished_file_done_instead_of_redownloading(tmp_path):
    # crash between rename and status update: file is complete on disk
    dl = tmp_path / "dl"
    dl.mkdir()
    s = JobStore(tmp_path / "j.db")
    a = s.add("a")
    s.update(a.id, status="downloading", filename="a.zip", bytes_done=4, bytes_total=4)
    (dl / "a.zip").write_bytes(b"abcd")
    assert s.recover(dl) == 0
    assert s.get(a.id).status == "done"
    assert (dl / "a.zip").exists()
