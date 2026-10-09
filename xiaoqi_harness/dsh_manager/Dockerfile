FROM node:22.23.2-bookworm-slim AS ui-build

WORKDIR /src
COPY dsh_manager/ui/package.json dsh_manager/ui/package-lock.json ./
RUN npm ci
COPY dsh_manager/ui/ ./
RUN npm run build

FROM node:22.23.2-bookworm-slim

ARG XIAOQI_ADMIN_HOST=admin.localhost
COPY dsh_manager/patch_remote_settings.mjs /tmp/patch_remote_settings.mjs

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-venv ca-certificates git \
    && rm -rf /var/lib/apt/lists/* \
    && git --version \
    && npm install --global --omit=dev --no-audit --no-fund @deepseek-ai/dsh@0.2.0-rc.2 pnpm@11.7.0 \
    && node /tmp/patch_remote_settings.mjs "$XIAOQI_ADMIN_HOST" \
    && test "$(dsh --version)" = "0.2.0-rc.2" \
    && test "$(pnpm --version)" = "11.7.0" \
    && npm cache clean --force

RUN rm /tmp/patch_remote_settings.mjs

WORKDIR /app
COPY requirements-manager.txt ./requirements-manager.txt
RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --requirement requirements-manager.txt \
    && rm requirements-manager.txt
COPY dsh_manager/manager.py ./manager.py
COPY dsh_manager/start_web.py ./start_web.py
COPY dsh_manager/health_web.py ./health_web.py
COPY --from=ui-build /src/dist ./static

RUN groupadd --system --gid 10003 dshreaders \
    && useradd --system --uid 10002 --gid dshreaders --home-dir /run/dsh-manager --shell /usr/sbin/nologin dsh-manager \
    && mkdir -p /opt/xiaoqi-dsh /run/dsh-manager \
    && chown -R dsh-manager:dshreaders /opt/xiaoqi-dsh /run/dsh-manager \
    && chmod 2770 /opt/xiaoqi-dsh

ENV PATH="/opt/venv/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    XIAOQI_DSH_RELEASE_ROOT=/opt/xiaoqi-dsh \
    XIAOQI_DSH_STATIC_ROOT=/app/static \
    XIAOQI_DSH_INTERNAL_API_URL=http://app:8080/v1/internal/dsh \
    XIAOQI_DSH_COOKIE_SECURE=1 \
    HOME=/run/dsh-manager \
    TMPDIR=/run/dsh-manager

USER 10002:10003

EXPOSE 8090

CMD ["gunicorn", "--bind", "0.0.0.0:8090", "--workers", "1", "--worker-class", "gthread", "--threads", "4", "--timeout", "180", "--graceful-timeout", "30", "manager:app"]
