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
    state["consents"] = 0


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


CONSENT = """<div id="acceptChomikujTermsOverlay" style="position:fixed;inset:0;background:rgba(0,0,0,.4);z-index:10">
  <div id="acceptChomikujTermsContainer" class="dialogWindow" style="background:#fff;margin:200px auto;width:400px">
    <p>Wykorzystujemy pliki cookies...</p>
    <form action="/action/ChomikPage/AcceptChomikujTerms" id="AcceptChomikujTermsForm" method="post">
      <input type="hidden" name="profilingDisabled" value="false">
      <button type="submit" class="greenButtonCSS">Rozumiem<br>Przechodzę do serwisu</button>
    </form>
  </div></div>"""


def page(request: Request, body: str, status: int = 200, **kw) -> HTMLResponse:
    consent = "" if request.cookies.get("terms") == "1" else CONSENT
    return HTMLResponse(f"<html><body>{topbar(request, **kw)}{body}{consent}</body></html>", status_code=status)


@app.post("/action/ChomikPage/AcceptChomikujTerms")
async def accept_terms(request: Request):
    state["consents"] = state.get("consents", 0) + 1
    resp = RedirectResponse(request.headers.get("referer", "/"), status_code=303)
    resp.set_cookie("terms", "1", max_age=3600)
    return resp


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
document.querySelector('#fileDetails a.downloadAction').addEventListener('click', async (e) => {
  e.preventDefault();
  const r = await fetch('/action/License/Download?file=' + encodeURIComponent(location.pathname), {method: 'POST'});
  const j = await r.json();
  if (j.redirectUrl) { location.href = j.redirectUrl; return; }
  // mirrors the live site's qtip popup (2026-11-12)
  const w = document.createElement('div');
  w.id = 'ui-tooltip-DownloadWindow';
  w.className = 'ui-tooltip qtip dialogWindow'; w.setAttribute('role', 'alert');
  w.innerHTML = '<div class="ui-tooltip-titlebar"><div class="winChBoxDownload">Pobieranie od tester</div></div>'
    + '<div class="ui-tooltip-content">' + j.Content + '</div>';
  document.body.appendChild(w);
  const form = w.querySelector('#downloadWarningForm');
  if (form) form.addEventListener('submit', (ev) => { ev.preventDefault(); location.href = j.confirmUrl; });
});
</script>"""


@app.get("/u/{name}")
async def file_page(request: Request, name: str):
    if name not in FILES:
        return page(request, "<h1>Plik nie istnieje lub został usunięty</h1>", status=404)
    return page(request, f"""<div id="otherFiles"><a class="expanderHeader downloadAction showDownloadWarning"
        href="/u/other,9.jpg" data-analytics-start-location="otherFiles">other.jpg</a></div>
      <div id="fileDetails"><h1>{escape(name)}</h1>
      <div class="fileInfo"><p class="fileSize">16 KB</p></div>
      <div class="filedescription" itemprop="description">opis<br>linia 2</div>
      <a class="greenButtonCSS downloadContext downloadAction" href="javascript:;" title="Pobierz"
         data-analytics-start-location="fileDetails">Pobierz</a></div>{DOWNLOAD_JS}""")


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
        "Content": '<div class="windowFileName">f.zip</div>'
                   '<form action="/action/License/DownloadWarningAccept" id="downloadWarningForm" method="post">'
                   '<input id="FileId" name="FileId" type="hidden" value="1">'
                   '<button type="submit" class="greenButtonCSS left expanderGreenButton">Pobierz</button>'
                   '<input type="reset" class="greenButtonCSS right smallWindowButton" value="Anuluj"></form>'
                   '<p>Transfer zostanie odliczony z Twojego konta jednorazowo, zaraz po kliknięciu w przycisk Pobierz.</p>',
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
