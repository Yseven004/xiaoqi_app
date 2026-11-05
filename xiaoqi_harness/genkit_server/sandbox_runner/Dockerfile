FROM python:3.12-slim-bookworm AS dependencies

WORKDIR /app
COPY requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt \
 && rm -f requirements.txt

FROM dependencies AS tests
COPY server.py ./server.py
COPY stdio_channel.py ./stdio_channel.py
COPY mcp_journal.py ./mcp_journal.py
COPY mcp_recovery.py ./mcp_recovery.py
COPY mcp_sessions.py ./mcp_sessions.py
COPY execution_sessions.py ./execution_sessions.py
COPY tests/ ./tests/
RUN python3 -m unittest discover -s tests -v

FROM dependencies AS build
COPY server.py ./server.py
COPY stdio_channel.py ./stdio_channel.py
COPY mcp_journal.py ./mcp_journal.py
COPY mcp_recovery.py ./mcp_recovery.py
COPY mcp_sessions.py ./mcp_sessions.py
COPY execution_sessions.py ./execution_sessions.py

ENV SANDBOX_RUNNER_HOST=0.0.0.0 SANDBOX_RUNNER_PORT=8090 PYTHONDONTWRITEBYTECODE=1 XIAOQI_EXECUTION_DB=/var/lib/xiaoqi-runner/executions.sqlite3 XIAOQI_MCP_DB=/var/lib/xiaoqi-runner/mcp.sqlite3
EXPOSE 8090
ENTRYPOINT ["python3", "/app/server.py"]
