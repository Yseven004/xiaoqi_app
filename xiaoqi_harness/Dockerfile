FROM node:22-bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-venv ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN npm install --global --omit=dev @deepseek-ai/dsh@0.2.0-rc.2 \
    && test "$(dsh --version)" = "0.2.0-rc.2" \
    && npm cache clean --force

WORKDIR /app

COPY requirements-server.txt ./requirements-server.txt
RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --requirement requirements-server.txt \
    && rm requirements-server.txt

COPY single_server.py ./single_server.py
COPY capabilities ./capabilities

RUN groupadd --system --gid 10001 xiaoqi \
    && useradd --system --uid 10001 --gid xiaoqi --home-dir /run/xiaoqi --shell /usr/sbin/nologin xiaoqi \
    && mkdir -p /var/lib/xiaoqi /run/xiaoqi \
    && chown -R xiaoqi:xiaoqi /var/lib/xiaoqi /run/xiaoqi

ENV PATH="/opt/venv/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app \
    XIAOQI_SINGLE_SERVER=1 \
    XIAOQI_DATA_DIR=/var/lib/xiaoqi \
    XIAOQI_DSH_VERSION=0.2.0-rc.2 \
    HOME=/run/xiaoqi \
    TMPDIR=/run/xiaoqi

USER 10001:10001

EXPOSE 8080

CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "--worker-class", "gthread", "--threads", "8", "--timeout", "180", "--graceful-timeout", "30", "single_server:app"]
