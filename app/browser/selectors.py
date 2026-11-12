"""Every chomikuj-specific selector and text marker lives here.

Login form ids were confirmed against the live homepage on 2026-11-06.
Login form, consent overlay, Pobierz button and download popup confirmed on
the live site on 2026-11-12. The out-of-transfer / password texts are best guesses; if a real download
fails, check /data/last_error.png and adjust only this file.
"""
import re

# Login form (present on every page while logged out)
LOGIN_INPUT = "#topBarLogin"
PASSWORD_INPUT = "#topBarPassword"
LOGIN_SUBMIT = "#topBar_LoginBtn"
LOGIN_ERROR = "#topBarLoginError"
CAPTCHA_MARKER = 'iframe[src*="recaptcha"]:visible, .g-recaptcha:visible'

# Cookie/terms consent overlay shown to new visitors (live site, 2026-11-12)
TERMS_ACCEPT = "#AcceptChomikujTermsForm button[type=submit]"

# File page — the main Pobierz button; sidebar "other files" links share the downloadAction class
DOWNLOAD_BUTTON = 'a.downloadAction[data-analytics-start-location="fileDetails"]'


# Popup shown after clicking Pobierz (live site: qtip "#ui-tooltip-DownloadWindow", 2026-11-12)
DIALOG = "#ui-tooltip-DownloadWindow:visible, .dialogWindow:visible, [role=\"dialog\"]:visible"
POPUP_CONFIRM_BUTTON = (
    "#downloadWarningForm button[type=submit], "
    ':is(#ui-tooltip-DownloadWindow, [role="dialog"]) '
    ':is(input[value*="pobierz" i], button:has-text("Pobierz"), a:has-text("Pobierz"))'
)

# Text found in the popup / page (matched case-insensitively against visible text)
TEXT_OUT_OF_TRANSFER = re.compile(r"(brak|za mało|niewystarczając\w*)[^.]{0,60}transfer", re.I)
TEXT_PASSWORD = re.compile(r"(podaj|wpisz|chronion\w*)[^.]{0,40}hasł|hasło do", re.I)
TEXT_NOT_FOUND = re.compile(r"nie istnieje|został\w* usunięt|nie znaleziono|nie został\w* znalezion", re.I)
