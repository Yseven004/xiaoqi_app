FROM dart:3.13.5 AS build
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends python3 \
 && rm -rf /var/lib/apt/lists/*
COPY genkit_server/pubspec.yaml genkit_server/pubspec.lock ./
RUN dart pub get --no-precompile
COPY genkit_server/ ./
RUN dart analyze && dart test --concurrency=1 && dart build cli --target bin/server.dart --output /out \
 && dart build cli --target bin/verify_capability_chain.dart --output /probe

FROM debian:bookworm-slim
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
RUN sed -i 's|http://deb.debian.org|https://deb.debian.org|g' /etc/apt/sources.list.d/debian.sources \
 && apt-get update && apt-get install -y --no-install-recommends ca-certificates libsqlite3-0 curl python3 poppler-utils tesseract-ocr tesseract-ocr-eng tesseract-ocr-chi-sim && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 10001 xiaoqi && useradd --uid 10001 --gid 10001 --create-home --home-dir /run/xiaoqi --shell /usr/sbin/nologin xiaoqi \
 && mkdir -p /var/lib/xiaoqi && chown 10001:10001 /var/lib/xiaoqi
WORKDIR /app
COPY --from=build /out/bundle/ /app/
COPY --from=build /probe/bundle/bin/verify_capability_chain /app/bin/verify_capability_chain
COPY --from=build /probe/bundle/lib/ /app/lib/
COPY genkit_server/bin/docker_worker.py /app/docker_worker.py
COPY genkit_server/bin/prepare_dependencies.py /app/prepare_dependencies.py
ENV PORT=8080 MCP_PORT=8081 XIAOQI_DATA_DIR=/var/lib/xiaoqi SANDBOX_WORKER_PYTHON=/usr/bin/python3 SANDBOX_WORKER_PATH=/app/docker_worker.py PYTHONDONTWRITEBYTECODE=1 LD_LIBRARY_PATH=/app/lib
EXPOSE 8080 8081
USER 10001:10001
ENTRYPOINT ["/app/bin/server"]
