"""A tiny stand-in for chomikuj.pl that mirrors app/browser/selectors.py."""
import secrets
from html import escape

from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response

USER, PASSWORD = "tester", "secret"
FILE_BYTES = b"PK\x03\x04fake-zip-content" * 1000

state = {"tokens": set(), "logins": 0, "requests": []}

app = FastAPI()


def reset():
    state["tokens"].clear()
    state["logins"] = 0
    state["requests"].clear()


def logged_in(request: Request) -> bool:
    return request.cookies.get("sess") in state["tokens"]


def topbar(request: Request, error: str = "", captcha: bool = False) -> str:
    if logged_in(request):
        return '<div id="topbar"><span id="topbarAvatar">tester</span> <a href="/logout">Wyloguj</a></div>'
    err_style = "" if error else "display: none"
    cap = '<iframe src="/recaptcha/api2/anchor" width="300" height="80"></iframe>' if captcha else ""
    return f"""<div id="topbar"><div id="topbarLoginForm">
      <form action="/action/Login/TopBarLogin" method="post">
        <input name="__RequestVerificationToken" type="hidden" value="tok" />
        <input id="ReturnUrl" name="ReturnUrl" type="hidden" value="{escape(request.url.path)}" />
        <input id="topBarLogin" name="Login" type="text" />
        <input id="topBarPassword" name="Password" type="password" />
        {cap}
        <input class="greenButtonCSS" id="topBar_LoginBtn" type="submit" value="Zaloguj" />
      </form></div>
      <div id="topBarLoginError" style="{err_style}"><span id="loginErrorContent">{escape(error)}</span></div>
    </div>"""


def page(request: Request, body: str, status: int = 200, **kw) -> HTMLResponse:
    return HTMLResponse(f"<html><body>{topbar(request, **kw)}{body}</body></html>", status_code=status)


@app.middleware("http")
async def record(request: Request, call_next):
    state["requests"].append({"path": request.url.path, "headers": dict(request.headers)})
    return await call_next(request)


@app.get("/")
async def home(request: Request):
    return page(request, "<p>Przyjazny dysk internetowy</p>")


@app.post("/action/Login/TopBarLogin")
async def login(request: Request, Login: str = Form(""), Password: str = Form(""), ReturnUrl: str = Form("/")):
    state["logins"] += 1
    if Login == "captcha":
        return page(request, "", error="Przepisz kod z obrazka", captcha=True)
    if (Login, Password) != (USER, PASSWORD):
        return page(request, "", error="Nieprawidłowy login lub hasło")
    token = secrets.token_hex(8)
    state["tokens"].add(token)
    resp = RedirectResponse(ReturnUrl or "/", status_code=303)
    resp.set_cookie("sess", token, max_age=3600)
    return resp


FILES = {
    "f,1.zip": "confirm",
    "big,2.zip": "transfer",
    "pw,3.zip": "password",
    "direct,5.zip": "direct",
}

DOWNLOAD_JS = """
<script>
document.querySelector('a.downloadAction').addEventListener('click', async (e) => {
  e.preventDefault();
  const r = await fetch('/action/License/Download?file=' + encodeURIComponent(location.pathname), {method: 'POST'});
  const j = await r.json();
  if (j.redirectUrl) { location.href = j.redirectUrl; return; }
  const w = document.createElement('div');
  w.className = 'window'; w.setAttribute('role', 'dialog');
  w.innerHTML = j.Content;
  document.body.appendChild(w);
  const btn = w.querySelector('#confirmDownload');
  if (btn) btn.addEventListener('click', () => { location.href = j.confirmUrl; });
});
</script>"""


@app.get("/u/{name}")
async def file_page(request: Request, name: str):
    if name not in FILES:
        return page(request, "<h1>Plik nie istnieje lub został usunięty</h1>", status=404)
    return page(request, f"""<div id="fileDetails"><h1>{escape(name)}</h1>
      <a class="downloadAction" href="javascript:;" title="Pobierz">Pobierz</a></div>{DOWNLOAD_JS}""")


@app.post("/action/License/Download")
async def license_download(request: Request, file: str):
    if not logged_in(request):
        return JSONResponse({"Content": "<p>Zaloguj się</p>"})
    kind = FILES.get(file.rsplit("/", 1)[-1])
    if kind == "direct":
        return JSONResponse({"redirectUrl": "/files/1"})
    if kind == "transfer":
        return JSONResponse({"Content": "<p>Brak wystarczającego transferu, aby pobrać plik.</p>"})
    if kind == "password":
        return JSONResponse({"Content": "<p>Ten plik jest chroniony. Podaj hasło do folderu.</p>"})
    return JSONResponse({
        "Content": '<p>Pobieranie pliku f.zip (16 KB)</p><input type="button" id="confirmDownload" class="greenButtonCSS" value="Pobierz" />',
        "confirmUrl": "/files/1",
    })


@app.get("/files/1")
async def file_bytes(request: Request):
    if not logged_in(request):
        return Response("forbidden", status_code=403)
    return Response(FILE_BYTES, media_type="application/octet-stream",
                    headers={"Content-Disposition": 'attachment; filename="f.zip"'})


@app.post("/test/expire")
async def expire():
    state["tokens"].clear()
    return {"ok": True}
