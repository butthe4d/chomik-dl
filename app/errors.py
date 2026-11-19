MESSAGES: dict[str, str] = {
    "invalid_url": "Not a chomikuj.pl file link",
    "login_failed": "Login failed — check CHOMIKUJ_LOGIN/PASSWORD",
    "captcha": "Login needs captcha — log in manually (see README)",
    "out_of_transfer": "Out of transfer on this account",
    "password_protected": "File is password-protected",
    "adult_content": "File is behind an adult-content check",
    "unavailable": "chomikuj is not responding, try again later",
    "not_found": "File not found or removed",
    "timeout": "chomikuj did not respond in time",
    "download_failed": "Download interrupted",
    "storage_unavailable": "Download folder is not available — is the NAS mounted?",
}


class ChomikError(Exception):
    """A user-facing failure with a stable code."""

    def __init__(self, code: str):
        self.code = code
        self.message = MESSAGES[code]
        super().__init__(f"{code}: {self.message}")
