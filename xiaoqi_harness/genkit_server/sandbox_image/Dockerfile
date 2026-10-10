FROM node:22-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-pip ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 10001 sandbox \
 && useradd --uid 10001 --gid 10001 --create-home --home-dir /tmp/home --shell /usr/sbin/nologin sandbox \
 && mkdir -p /workspace \
 && chmod 0755 /workspace

WORKDIR /workspace
ENV HOME=/tmp/home \
    TMPDIR=/tmp \
    PYTHONUSERBASE=/tmp/.python \
    PATH=/tmp/.python/bin:/usr/local/bin:/usr/bin:/bin \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONNOUSERSITE=0 \
    NPM_CONFIG_CACHE=/tmp/.npm \
    XDG_CACHE_HOME=/tmp

USER 10001:10001
