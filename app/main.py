import asyncio
import contextlib
import logging
from contextlib import asynccontextmanager
from dataclasses import asdict
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse

from app.browser.session import BrowserSession
from app.config import Settings, load_settings
from app.errors import ChomikError
from app.jobs import JobStore
from app.urls import normalize_file_url
from app.worker import Worker

INDEX_HTML = (Path(__file__).parent / "templates" / "index.html").read_text(encoding="utf-8")


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

    @app.get("/", response_class=HTMLResponse)
    async def index():
        return INDEX_HTML

    @app.post("/jobs", status_code=201)
    async def submit(request: Request):
        if request.headers.get("content-type", "").startswith("application/json"):
            url = (await request.json()).get("url", "")
        else:
            url = (await request.form()).get("url", "")
        try:
            normalized = normalize_file_url(str(url), settings.base_url)
        except ChomikError as err:
            raise HTTPException(status_code=400, detail=err.message)
        job = store.add(normalized)
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
    return create_app(load_settings())
