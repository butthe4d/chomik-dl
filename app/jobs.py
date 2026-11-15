import sqlite3
import threading
import time
from dataclasses import dataclass, fields
from pathlib import Path

from app.lookup import FileInfo
from app.urls import file_id_from_url, suggested_name_from_url


@dataclass
class Job:
    id: int
    url: str
    status: str  # waiting | rejected | queued | resolving | downloading | done | failed
    filename: str | None
    bytes_done: int
    bytes_total: int | None
    error_code: str | None
    error_message: str | None
    created_at: float
    attempts: int
    file_id: int | None
    name: str | None
    size_text: str | None
    size_bytes: int | None
    description: str | None
    folder: str | None
    requested_by: str


_ACTIVE = ("waiting", "queued", "resolving", "downloading")
_NEW_COLUMNS = {
    "file_id": "INTEGER",
    "name": "TEXT",
    "size_text": "TEXT",
    "size_bytes": "INTEGER",
    "description": "TEXT",
    "folder": "TEXT",
    "requested_by": "TEXT NOT NULL DEFAULT ''",
}


def normalize_name(raw: str | None) -> str | None:
    name = (raw or "").strip()[:40].strip()
    return name or None


_COLUMNS = [f.name for f in fields(Job)]
_UPDATABLE = set(_COLUMNS) - {"id", "url", "created_at"}


class JobStore:
    def __init__(self, db_path: Path):
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._db = sqlite3.connect(db_path, check_same_thread=False)
        self._db.execute(
            """CREATE TABLE IF NOT EXISTS jobs (
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
        )
        existing = {row[1] for row in self._db.execute("PRAGMA table_info(jobs)")}
        for column, decl in _NEW_COLUMNS.items():
            if column not in existing:
                self._db.execute(f"ALTER TABLE jobs ADD COLUMN {column} {decl}")
        for job_id, url in self._db.execute("SELECT id, url FROM jobs WHERE file_id IS NULL").fetchall():
            self._db.execute("UPDATE jobs SET file_id = ?, name = ? WHERE id = ?",
                             (file_id_from_url(url), suggested_name_from_url(url), job_id))
        self._db.commit()

    def _query(self, sql: str, args: tuple = ()) -> list[Job]:
        with self._lock:
            rows = self._db.execute(f"SELECT {', '.join(_COLUMNS)} FROM jobs {sql}", args).fetchall()
        return [Job(*r) for r in rows]

    def add_request(self, url: str, info: FileInfo, requested_by: str | None, *,
                    status: str = "waiting") -> tuple[Job, bool]:
        """Create a request, or merge into an active one for the same file. Returns (job, created)."""
        who = normalize_name(requested_by)
        with self._lock:
            row = None
            if info.file_id is not None:
                marks = ", ".join("?" for _ in _ACTIVE)
                row = self._db.execute(
                    f"SELECT id, status, requested_by FROM jobs WHERE file_id = ? AND status IN ({marks}) "
                    "ORDER BY id LIMIT 1", (info.file_id, *_ACTIVE)).fetchone()
            if row is None:
                cur = self._db.execute(
                    "INSERT INTO jobs (url, status, created_at, file_id, name, size_text, size_bytes, "
                    "description, folder, requested_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (url, status, time.time(), info.file_id, info.name, info.size_text, info.size_bytes,
                     info.description, info.folder, who or ""))
                job_id, created = cur.lastrowid, True
            else:
                job_id, current, names = row
                created = False
                merged = [n for n in names.split(", ") if n]
                if who and who not in merged:
                    merged.append(who)
                new_status = "queued" if current == "waiting" and status == "queued" else current
                self._db.execute("UPDATE jobs SET requested_by = ?, status = ? WHERE id = ?",
                                 (", ".join(merged), new_status, job_id))
            self._db.commit()
        return self.get(job_id), created

    def _transition(self, job_id: int, old: str, new: str, extra: str = "") -> bool:
        with self._lock:
            cur = self._db.execute(f"UPDATE jobs SET status = ?{extra} WHERE id = ? AND status = ?",
                                   (new, job_id, old))
            self._db.commit()
            return cur.rowcount == 1

    def accept(self, job_id: int) -> bool:
        return self._transition(job_id, "waiting", "queued")

    def reject(self, job_id: int) -> bool:
        return self._transition(job_id, "waiting", "rejected")

    def retry(self, job_id: int) -> bool:
        return self._transition(job_id, "failed", "queued",
                                ", attempts = 0, error_code = NULL, error_message = NULL")

    def get(self, job_id: int) -> Job | None:
        rows = self._query("WHERE id = ?", (job_id,))
        return rows[0] if rows else None

    def list(self, limit: int = 100) -> list[Job]:
        return self._query("ORDER BY id DESC LIMIT ?", (limit,))

    def next_queued(self) -> Job | None:
        rows = self._query("WHERE status = 'queued' ORDER BY id ASC LIMIT 1")
        return rows[0] if rows else None

    def update(self, job_id: int, **values) -> None:
        unknown = set(values) - _UPDATABLE
        if unknown:
            raise ValueError(f"cannot update {sorted(unknown)}")
        if not values:
            return
        assignments = ", ".join(f"{k} = ?" for k in values)
        with self._lock:
            self._db.execute(f"UPDATE jobs SET {assignments} WHERE id = ?", (*values.values(), job_id))
            self._db.commit()

    def recover(self, download_dir: Path) -> int:
        """Requeue jobs interrupted by a restart and remove their partial files."""
        stale = self._query("WHERE status IN ('resolving', 'downloading')")
        requeued = 0
        for job in stale:
            final = download_dir / job.filename if job.filename else None
            if (final and job.bytes_total is not None and final.exists()
                    and not final.with_name(final.name + ".part").exists()
                    and final.stat().st_size == job.bytes_total):
                # finished on disk, crashed before the status update — don't spend transfer again
                self.update(job.id, status="done", bytes_done=job.bytes_total)
                continue
            requeued += 1
            if job.filename:
                (download_dir / f"{job.filename}.part").unlink(missing_ok=True)
            self.update(job.id, status="queued", bytes_done=0, bytes_total=None, filename=None)
        return requeued
