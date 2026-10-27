FROM node:24-bookworm-slim

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      python3 python3-pip ca-certificates poppler-utils \
      fontconfig fonts-noto-cjk latexmk texlive-lang-chinese texlive-xetex \
 && rm -rf /var/lib/apt/lists/* \
 && command -v xelatex >/dev/null \
 && kpsewhich xeCJK.sty >/dev/null \
 && fc-match 'Noto Sans CJK SC' | grep -qi 'Noto Sans CJK SC' \
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
