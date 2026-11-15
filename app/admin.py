"""Secret admin link: a random token stored in DATA_DIR, shown only via the CLI."""
import argparse
import hmac
import os
import secrets
from pathlib import Path

TOKEN_FILE = "admin-token"
LINK_FILE = "admin-link.txt"


def _write_private(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.fchmod(fd, 0o600)  # also tightens a pre-existing file before any data is written
        with os.fdopen(fd, "w") as f:
            fd = -1
            f.write(text)
    finally:
        if fd != -1:
            os.close(fd)


def load_or_create_token(data_dir: Path) -> str:
    path = data_dir / TOKEN_FILE
    if path.exists():
        token = path.read_text().strip()
        if token:
            path.chmod(0o600)
            return token
    return regenerate_token(data_dir)


def regenerate_token(data_dir: Path) -> str:
    token = secrets.token_urlsafe(32)
    _write_private(data_dir / TOKEN_FILE, token + "\n")
    return token


def admin_link(token: str, public_url: str | None) -> str:
    return f"{public_url or '<PUBLIC_URL>'}/admin/{token}"


def write_link_file(data_dir: Path, link: str) -> Path:
    path = data_dir / LINK_FILE
    _write_private(path, link + "\n")
    return path


def token_matches(expected: str, given: str | None) -> bool:
    if not given:
        return False
    return hmac.compare_digest(expected.encode(), given.encode())


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="python -m app.admin", description="Print the secret admin link")
    parser.add_argument("--regenerate", action="store_true", help="invalidate the old link and create a new one")
    args = parser.parse_args(argv)
    data_dir = Path(os.environ.get("DATA_DIR", "/data"))
    public_url = os.environ.get("PUBLIC_URL", "").strip().rstrip("/") or None
    token = regenerate_token(data_dir) if args.regenerate else load_or_create_token(data_dir)
    link = admin_link(token, public_url)
    path = write_link_file(data_dir, link)
    print(link)
    if public_url is None:
        print("Hint: set PUBLIC_URL (e.g. http://192.168.1.10:8080) to print a full link.")
    print(f"Link also saved to {path}")


if __name__ == "__main__":
    main()
