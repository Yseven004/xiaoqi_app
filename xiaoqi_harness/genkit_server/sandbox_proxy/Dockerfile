FROM python:3.12-slim-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends squid ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 10001 sandbox-proxy \
 && useradd --uid 10001 --gid 10001 --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin sandbox-proxy

COPY entrypoint.py /opt/xiaoqi/entrypoint.py
COPY test_config.py /opt/xiaoqi/test_config.py
RUN chmod 0555 /opt/xiaoqi/entrypoint.py \
 && PYTHONPATH=/opt/xiaoqi python3 -m unittest /opt/xiaoqi/test_config.py

USER 10001:10001
ENTRYPOINT ["python3", "/opt/xiaoqi/entrypoint.py"]
