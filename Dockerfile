# Browser binaries in this image must match the pinned playwright version below.
FROM mcr.microsoft.com/playwright/python:v1.65.1-noble

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_BREAK_SYSTEM_PACKAGES=1 \
    HOME=/tmp \
    DOWNLOAD_DIR=/downloads \
    DATA_DIR=/data

WORKDIR /srv
COPY pyproject.toml ./
COPY app ./app
RUN pip install "playwright==1.65.1" . \
 && mkdir -p /downloads /data \
 && chown pwuser:pwuser /downloads /data

USER pwuser
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=4)"
CMD ["uvicorn", "--factory", "app.main:build", "--host", "0.0.0.0", "--port", "8080"]
