import asyncio
import ipaddress
import contextlib
import logging
from contextlib import asynccontextmanager
from dataclasses import asdict
from pathlib import Path
from urllib.parse import urlsplit

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse, RedirectResponse

from app.browser.session import BrowserSession
from app.config import Settings, load_settings
from app.errors import ChomikError
from app.jobs import JobStore
from app.admin import admin_link, load_or_create_token, token_matches, write_link_file
from app.lookup import lookup_file
from app.ratelimit import RateLimiter
from app.urls import normalize_file_url
from app.worker import Worker

INDEX_HTML = (Path(__file__).parent / "templates" / "index.html").read_text(encoding="utf-8")
ADMIN_HTML = (Path(__file__).parent / "templates" / "admin.html").read_text(encoding="utf-8")
COOKIE = "chomikdl_admin"


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


def create_app(settings: Settings, *, start_worker: bool = True, lookup=lookup_file,
               limiter: RateLimiter | None = None) -> FastAPI:
    store = JobStore(settings.data_dir / "jobs.db")
    limiter = limiter or RateLimiter()
    state: dict = {}

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        settings.download_dir.mkdir(parents=True, exist_ok=True)
        state["token"] = load_or_create_token(settings.data_dir)
        link = admin_link(state["token"], settings.public_url)
        write_link_file(settings.data_dir, link)
        logging.getLogger(__name__).info("Admin link: %s", link)
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
    app.state.store = store

    @app.middleware("http")
    async def check_host(request: Request, call_next):
        if not _host_allowed(request.headers.get("host"), settings.allowed_hosts):
            return PlainTextResponse("Invalid host — add it to ALLOWED_HOSTS", status_code=400)
        return await call_next(request)

    def wake() -> None:
        if "worker" in state:
            state["worker"].wake()

    async def read_body(request: Request) -> dict:
        if request.headers.get("content-type", "").startswith("application/json"):
            data = await request.json()
            return data if isinstance(data, dict) else {}
        return dict(await request.form())

    def is_admin(request: Request) -> bool:
        return token_matches(state["token"], request.cookies.get(COOKIE))

    def require_same_origin(request: Request) -> None:
        if not _same_origin(request):
            raise HTTPException(status_code=403, detail="Cross-site request rejected")

    def require_admin(request: Request) -> None:
        require_same_origin(request)
        if not is_admin(request):
            raise HTTPException(status_code=403, detail="Admin link required")

    async def submit(body: dict, status: str, requested_by: str | None) -> JSONResponse:
        try:
            normalized = normalize_file_url(str(body.get("url", "")), settings.base_url)
            info = await lookup(normalized)
        except ChomikError as err:
            code = 503 if err.code == "unavailable" else 400
            raise HTTPException(status_code=code, detail=err.message)
        job, created = store.add_request(normalized, info, requested_by, status=status)
        if job.status == "queued":
            wake()
        return JSONResponse({"request": asdict(job), "created": created}, status_code=201)

    @app.get("/", response_class=HTMLResponse)
    async def index():
        return INDEX_HTML

    @app.get("/requests")
    async def requests_list():
        return JSONResponse([asdict(j) for j in store.list()])

    @app.post("/requests")
    async def create_request(request: Request):
        require_same_origin(request)
        if not limiter.allow(request.client.host if request.client else "unknown"):
            raise HTTPException(status_code=429, detail="Too many requests, wait a minute")
        body = await read_body(request)
        return await submit(body, "waiting", str(body.get("name") or ""))

    @app.get("/admin/{token}")
    async def admin_login(token: str):
        if not token_matches(state["token"], token):
            raise HTTPException(status_code=404)
        resp = RedirectResponse("/admin", status_code=303)
        resp.set_cookie(COOKIE, state["token"], max_age=31536000, httponly=True, samesite="strict", path="/")
        return resp

    @app.get("/admin", response_class=HTMLResponse)
    async def admin_page(request: Request):
        if not is_admin(request):
            raise HTTPException(status_code=404)
        return ADMIN_HTML

    @app.post("/admin/requests")
    async def admin_create(request: Request):
        require_admin(request)
        return await submit(await read_body(request), "queued", None)

    def transition(action: str):
        async def handler(job_id: int, request: Request):
            require_admin(request)
            if not getattr(store, action)(job_id):
                raise HTTPException(status_code=409, detail="Request is not in a state that allows this")
            if action in ("accept", "retry"):
                wake()
            return JSONResponse(asdict(store.get(job_id)))
        return handler

    for _action in ("accept", "reject", "retry"):
        app.post(f"/admin/requests/{{job_id}}/{_action}")(transition(_action))

    @app.get("/healthz", response_class=PlainTextResponse)
    async def healthz():
        return "ok"

    return app


def build() -> FastAPI:
    """uvicorn --factory entry point."""
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    logging.getLogger("httpx").setLevel(logging.WARNING)  # its INFO lines contain signed download URLs
    return create_app(load_settings())
