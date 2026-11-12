"""Every chomikuj-specific selector and text marker lives here.

Login form ids were confirmed against the live homepage on 2026-11-06.
The download button / popup markers are best guesses; if a real download
fails, check /data/last_error.png and adjust only this file.
"""
import re

# Login form (present on every page while logged out)
LOGIN_INPUT = "#topBarLogin"
PASSWORD_INPUT = "#topBarPassword"
LOGIN_SUBMIT = "#topBar_LoginBtn"
LOGIN_ERROR = "#topBarLoginError"
CAPTCHA_MARKER = 'iframe[src*="recaptcha"]:visible, .g-recaptcha:visible'

# File page
DOWNLOAD_BUTTON = "a.downloadAction"

# Popup shown after clicking Pobierz
DIALOG = '.window:visible, [role="dialog"]:visible, #ChomikujWindow:visible'
POPUP_CONFIRM_BUTTON = (
    ':is(.window, [role="dialog"], #ChomikujWindow) '
    ':is(input[value*="pobierz" i], button:has-text("Pobierz"), a:has-text("Pobierz"))'
)

# Text found in the popup / page (matched case-insensitively against visible text)
TEXT_OUT_OF_TRANSFER = re.compile(r"(brak|za mało|niewystarczając\w*)[^.]{0,60}transfer", re.I)
TEXT_PASSWORD = re.compile(r"(podaj|wpisz|chronion\w*)[^.]{0,40}hasł|hasło do", re.I)
TEXT_NOT_FOUND = re.compile(r"nie istnieje|został\w* usunięt|nie znaleziono|nie został\w* znalezion", re.I)
