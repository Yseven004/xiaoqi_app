"""Alibaba Function Compute entry point for Xiaoqi capability APIs."""

import os

from flask import Flask, jsonify

from capabilities.api import capabilities as capabilities_blueprint


app = Flask(__name__)
app.register_blueprint(capabilities_blueprint, url_prefix="/v1")


@app.get("/health")
def health():
    return jsonify(
        {
            "status": "ok",
            "release_id": os.environ.get("CAPABILITY_API_RELEASE_ID", "unversioned"),
        }
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
