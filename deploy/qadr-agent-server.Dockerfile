ARG BASE_REPOSITORY=ghcr.io/openhands/agent-server
ARG BASE_TAG=1.12.0-python

FROM ${BASE_REPOSITORY}:${BASE_TAG}

ENV HOME=/home/openhands \
    PATH=/home/openhands/.local/bin:$PATH \
    PLAYWRIGHT_BROWSERS_PATH=/home/openhands/.cache/ms-playwright \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1

RUN mkdir -p /home/openhands/.cache/ms-playwright /home/openhands/.local/bin \
 && python3 -m pip install --user --no-cache-dir \
    browser-use \
    browser-use-sdk \
    playwright \
 && python3 -m playwright install --with-deps chromium
