import os
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    login: str
    password: str
    base_url: str = "https://chomikuj.pl"
    download_dir: Path = Path("/downloads")
    data_dir: Path = Path("/data")
    min_job_gap: float = 20.0
    pause_min: float = 1.0
    pause_max: float = 4.0
    headless: bool = True


def _bool(value: str) -> bool:
    return value.strip().lower() not in {"0", "false", "no", "off", ""}


def load_settings(env: Mapping[str, str] = os.environ) -> Settings:
    login = env.get("CHOMIKUJ_LOGIN", "")
    password = env.get("CHOMIKUJ_PASSWORD", "")
    if not login or not password:
        raise ValueError("CHOMIKUJ_LOGIN and CHOMIKUJ_PASSWORD must be set")
    d = Settings(login=login, password=password)
    return Settings(
        login=login,
        password=password,
        base_url=env.get("CHOMIKUJ_BASE_URL", d.base_url).rstrip("/"),
        download_dir=Path(env.get("DOWNLOAD_DIR", str(d.download_dir))),
        data_dir=Path(env.get("DATA_DIR", str(d.data_dir))),
        min_job_gap=float(env.get("MIN_JOB_GAP_SECONDS", d.min_job_gap)),
        pause_min=float(env.get("HUMAN_PAUSE_MIN", d.pause_min)),
        pause_max=float(env.get("HUMAN_PAUSE_MAX", d.pause_max)),
        headless=_bool(env.get("HEADLESS", "true")),
    )
