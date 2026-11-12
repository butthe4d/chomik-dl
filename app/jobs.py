import sqlite3
import threading
import time
from dataclasses import dataclass, fields
from pathlib import Path


@dataclass
class Job:
    id: int
    url: str
    status: str  # queued | resolving | downloading | done | failed
    filename: str | None
    bytes_done: int
    bytes_total: int | None
    error_code: str | None
    error_message: str | None
    created_at: float
    attempts: int


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
        self._db.commit()

    def _query(self, sql: str, args: tuple = ()) -> list[Job]:
        with self._lock:
            rows = self._db.execute(f"SELECT {', '.join(_COLUMNS)} FROM jobs {sql}", args).fetchall()
        return [Job(*r) for r in rows]

    def add(self, url: str) -> Job:
        with self._lock:
            cur = self._db.execute("INSERT INTO jobs (url, created_at) VALUES (?, ?)", (url, time.time()))
            self._db.commit()
            job_id = cur.lastrowid
        return self.get(job_id)

    def get(self, job_id: int) -> Job | None:
        rows = self._query("WHERE id = ?", (job_id,))
        return rows[0] if rows else None

    def list(self, limit: int = 50) -> list[Job]:
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
        for job in stale:
            if job.filename:
                (download_dir / f"{job.filename}.part").unlink(missing_ok=True)
            self.update(job.id, status="queued", bytes_done=0, bytes_total=None, filename=None)
        return len(stale)
