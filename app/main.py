import asyncio
import ipaddress
import contextlib
import logging
from contextlib import asynccontextmanager
from dataclasses import asdict
from pathlib import Path
from urllib.parse import urlsplit

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse

from app.browser.session import BrowserSession
from app.config import Settings, load_settings
from app.errors import ChomikError
from app.jobs import JobStore
from app.lookup import FileInfo
from app.urls import file_id_from_url, normalize_file_url, suggested_name_from_url
from app.worker import Worker

INDEX_HTML = (Path(__file__).parent / "templates" / "index.html").read_text(encoding="utf-8")


def _host_allowed(host_header: str | None, allowed: tuple[str, ...]) -> bool:
    """Accept IP literals, localhost and configured names only (blocks DNS rebinding)."""
    if not host_header:
        return False
    host = (urlsplit(f"//{host_header}").hostname or "").lower()
    if host == "localhost" or host in allowed:
        return True
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        return False


def _same_origin(request: Request) -> bool:
    """Block other websites from queuing downloads through the user's browser (CSRF)."""
    site = request.headers.get("sec-fetch-site")
    if site is not None and site not in ("same-origin", "none"):
        return False
    origin = request.headers.get("origin")
    if origin is not None and urlsplit(origin).netloc != request.headers.get("host"):
        return False
    return True


def create_app(settings: Settings, *, start_worker: bool = True) -> FastAPI:
    store = JobStore(settings.data_dir / "jobs.db")
    state: dict = {}

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        settings.download_dir.mkdir(parents=True, exist_ok=True)
        recovered = store.recover(settings.download_dir)
        if recovered:
            logging.getLogger(__name__).info("requeued %d interrupted job(s)", recovered)
        if start_worker:
            session = BrowserSession(settings)
            await session.start()
            worker = Worker(settings, store, session)
            state["worker"] = worker
            task = asyncio.create_task(worker.run_forever())
        try:
            yield
        finally:
            if start_worker:
                task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await task
                await session.close()

    app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None)

    @app.middleware("http")
    async def check_host(request: Request, call_next):
        if not _host_allowed(request.headers.get("host"), settings.allowed_hosts):
            return PlainTextResponse("Invalid host — add it to ALLOWED_HOSTS", status_code=400)
        return await call_next(request)

    @app.get("/", response_class=HTMLResponse)
    async def index():
        return INDEX_HTML

    @app.post("/jobs", status_code=201)
    async def submit(request: Request):
        if not _same_origin(request):
            raise HTTPException(status_code=403, detail="Cross-site request rejected")
        if request.headers.get("content-type", "").startswith("application/json"):
            url = (await request.json()).get("url", "")
        else:
            url = (await request.form()).get("url", "")
        try:
            normalized = normalize_file_url(str(url), settings.base_url)
        except ChomikError as err:
            raise HTTPException(status_code=400, detail=err.message)
        # temporary bridge until the approval routes replace this handler
        info = FileInfo(file_id=file_id_from_url(normalized), name=suggested_name_from_url(normalized),
                        size_text=None, size_bytes=None, description=None, folder=None)
        job, _ = store.add_request(normalized, info, None, status="queued")
        if "worker" in state:
            state["worker"].wake()
        return asdict(job)

    @app.get("/jobs")
    async def jobs():
        return JSONResponse([asdict(j) for j in store.list()])

    @app.get("/healthz", response_class=PlainTextResponse)
    async def healthz():
        return "ok"

    return app


def build() -> FastAPI:
    """uvicorn --factory entry point."""
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    logging.getLogger("httpx").setLevel(logging.WARNING)  # its INFO lines contain signed download URLs
    return create_app(load_settings())
