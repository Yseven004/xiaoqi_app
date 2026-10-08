"""Single-process WSGI entry point for the Xiaoqi Linux server."""

import os

from flask import Flask, jsonify

os.environ["XIAOQI_SINGLE_SERVER"] = "1"

from capabilities.api import capabilities, start_background_runtime  # noqa: E402


def create_app() -> Flask:
    app = Flask(__name__)
    app.register_blueprint(capabilities, url_prefix="/v1")

    @app.get("/health")
    def health():
        return jsonify({
            "status": "ok",
            "release_id": os.environ.get("CAPABILITY_API_RELEASE_ID", "unversioned"),
            "storage": "sqlite",
            "task_queue": "in-process-single-worker",
            "python_execution": "disabled-until-linux-isolation-is-verified",
        })

    start_background_runtime()
    return app


app = create_app()
