import os

from flask import Flask

from capabilities.worker_api import worker_api


app = Flask(__name__)
app.register_blueprint(worker_api)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
