# Verification only: never replaces the running server or mounts user data.
FROM xiaoqi-extension-verification-base
RUN apt-get update && apt-get install -y --no-install-recommends procps \
 && rm -rf /var/lib/apt/lists/*
COPY --from=xiaoqi-code-sandbox:local /usr/local/bin/node /usr/local/bin/node
COPY --from=xiaoqi-code-sandbox:local /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
 && npm install --global --registry=https://registry.npmjs.org genkit-cli@1.44.1
ENV XIAOQI_CAPTURE_TRACES=1 SANDBOX_WORKER_PYTHON=/usr/bin/python3 SANDBOX_WORKER_PATH=/app/bin/docker_worker.py
COPY verify_extension_runtime.dart /app/bin/verify_extension_runtime.dart
CMD ["genkit", "flow:run", "extensionRoundTrip", "\"\"", "--non-interactive", "--", "dart", "run", "bin/verify_extension_runtime.dart"]
