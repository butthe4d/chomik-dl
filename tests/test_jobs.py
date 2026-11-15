import sqlite3

from app.jobs import JobStore, normalize_name
from app.lookup import FileInfo
from tests.conftest import make_job


def test_add_and_get(tmp_path):
    s = JobStore(tmp_path / "j.db")
    j = make_job(s, "https://chomikuj.pl/u/f,1.zip")
    got = s.get(j.id)
    assert got.url == "https://chomikuj.pl/u/f,1.zip"
    assert got.status == "queued" and got.bytes_done == 0 and got.attempts == 0
    assert s.get(9999) is None


def test_list_newest_first_and_next_queued_oldest_first(tmp_path):
    s = JobStore(tmp_path / "j.db")
    a, b, c = (make_job(s, f"u{i}") for i in range(3))
    assert [j.id for j in s.list()] == [c.id, b.id, a.id]
    s.update(a.id, status="done")
    assert s.next_queued().id == b.id


def test_update_fields(tmp_path):
    s = JobStore(tmp_path / "j.db")
    j = make_job(s, "u")
    s.update(j.id, status="failed", error_code="captcha", error_message="m", bytes_total=None)
    got = s.get(j.id)
    assert (got.status, got.error_code, got.error_message) == ("failed", "captcha", "m")


def test_recover_requeues_and_removes_part(tmp_path):
    dl = tmp_path / "dl"
    dl.mkdir()
    s = JobStore(tmp_path / "j.db")
    a = make_job(s, "a")
    s.update(a.id, status="downloading", filename="a.zip", bytes_done=5)
    b = make_job(s, "b")
    s.update(b.id, status="resolving")
    c = make_job(s, "c")
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
    make_job(JobStore(tmp_path / "j.db"), "u")
    assert len(JobStore(tmp_path / "j.db").list()) == 1


def test_recover_marks_finished_file_done_instead_of_redownloading(tmp_path):
    # crash between rename and status update: file is complete on disk
    dl = tmp_path / "dl"
    dl.mkdir()
    s = JobStore(tmp_path / "j.db")
    a = make_job(s, "a")
    s.update(a.id, status="downloading", filename="a.zip", bytes_done=4, bytes_total=4)
    (dl / "a.zip").write_bytes(b"abcd")
    assert s.recover(dl) == 0
    assert s.get(a.id).status == "done"
    assert (dl / "a.zip").exists()


def _info(file_id=11, name="Plik a.zip"):
    return FileInfo(file_id=file_id, name=name, size_text="1,5 MB", size_bytes=1572864,
                    description="opis", folder="Folder")


URL = "https://chomikuj.pl/u/Plik+a,11.zip"


def test_add_request_waiting(tmp_path):
    s = JobStore(tmp_path / "j.db")
    job, created = s.add_request(URL, _info(), "Ania")
    assert created is True
    assert job.status == "waiting"
    assert (job.file_id, job.name, job.size_text, job.size_bytes, job.description, job.folder) == (
        11, "Plik a.zip", "1,5 MB", 1572864, "opis", "Folder")
    assert job.requested_by == "Ania"


def test_duplicate_merges_names(tmp_path):
    s = JobStore(tmp_path / "j.db")
    first, created = s.add_request(URL, _info(), "Ania")
    for who in ("Tomek", "Ania", None):
        job, created = s.add_request(URL, _info(), who)
        assert created is False
        assert job.id == first.id
    assert job.requested_by == "Ania, Tomek"
    assert len(s.list()) == 1


def test_rejected_file_can_be_requested_again(tmp_path):
    s = JobStore(tmp_path / "j.db")
    first, _ = s.add_request(URL, _info(), "Ania")
    assert s.reject(first.id) is True
    again, created = s.add_request(URL, _info(), "Ania")
    assert created is True and again.id != first.id and again.status == "waiting"


def test_admin_add_promotes_waiting(tmp_path):
    s = JobStore(tmp_path / "j.db")
    first, _ = s.add_request(URL, _info(), "Ania")
    job, created = s.add_request(URL, _info(), None, status="queued")
    assert created is False and job.id == first.id and job.status == "queued"


def test_transitions(tmp_path):
    s = JobStore(tmp_path / "j.db")
    a, _ = s.add_request(URL, _info(), "Ania")
    assert s.accept(a.id) is True and s.get(a.id).status == "queued"
    assert s.accept(a.id) is False
    assert s.reject(a.id) is False
    assert s.retry(a.id) is False
    b, _ = s.add_request("u2", _info(12), "Ania")
    assert s.reject(b.id) is True and s.get(b.id).status == "rejected"
    assert s.reject(b.id) is False and s.accept(b.id) is False
    s.update(a.id, status="failed", attempts=2, error_code="timeout", error_message="m")
    assert s.retry(a.id) is True
    got = s.get(a.id)
    assert (got.status, got.attempts, got.error_code, got.error_message) == ("queued", 0, None, None)
    assert s.accept(9999) is False and s.reject(9999) is False and s.retry(9999) is False


def test_normalize_name():
    assert normalize_name("  ") is None
    assert normalize_name(None) is None
    assert normalize_name("x" * 200) == "x" * 40
    assert normalize_name(" Ania ") == "Ania"


V1_SCHEMA = """CREATE TABLE IF NOT EXISTS jobs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                url TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'queued',
                filename TEXT,
                bytes_done INTEGER NOT NULL DEFAULT 0,
                bytes_total INTEGER,
                error_code TEXT,
                error_message TEXT,
                created_at REAL NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0
            )"""


def test_v1_database_migrates(tmp_path):
    path = tmp_path / "j.db"
    db = sqlite3.connect(path)
    db.execute(V1_SCHEMA)
    db.execute("INSERT INTO jobs (url, status, created_at) VALUES (?, 'done', 1)", (URL,))
    db.execute("INSERT INTO jobs (url, status, created_at) VALUES (?, 'queued', 2)",
               ("https://chomikuj.pl/u/Inny,12.zip",))
    db.commit()
    db.close()
    s = JobStore(path)
    jobs = {j.file_id: j for j in s.list()}
    assert jobs[11].name == "Plik a.zip" and jobs[11].requested_by == "" and jobs[11].status == "done"
    assert s.next_queued().file_id == 12
    JobStore(path)  # reopening an already migrated db is a no-op


def test_request_for_done_file_merges(tmp_path):
    s = JobStore(tmp_path / "j.db")
    first, _ = s.add_request(URL, _info(), "Ania")
    s.update(first.id, status="done")
    job, created = s.add_request(URL, _info(), "Tomek")
    assert created is False and job.id == first.id
    assert job.status == "done" and job.requested_by == "Ania, Tomek"
    job, created = s.add_request(URL, _info(), None, status="queued")
    assert created is False and job.status == "done"
    assert len(s.list()) == 1
