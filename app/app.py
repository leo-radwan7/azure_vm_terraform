import os
import socket

import redis
from flask import Flask, jsonify

# ----- Config from environment variables -----
# In Kubernetes, config reaches the container via env vars populated from
# ConfigMaps (non-secret) and Secrets (sensitive). We never hardcode.
# Using os.environ[...] (not .get) for required vars makes the container
# crash-on-start if they're missing — Kubernetes will then restart it and
# eventually mark it CrashLoopBackOff, which is a very visible signal.
REDIS_HOST = os.environ["REDIS_HOST"]
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6379"))
REDIS_PASSWORD = os.environ["REDIS_PASSWORD"]

app = Flask(__name__)

r = redis.Redis(
    host=REDIS_HOST,
    port=REDIS_PORT,
    password=REDIS_PASSWORD,
    decode_responses=True,
)


@app.route("/")
def index():
    # INCR is atomic in Redis — safe even with multiple API pods racing.
    count = r.incr("visits")
    return jsonify({
        "message": "Hello from Kubernetes!",
        "visit_count": count,
        "pod": socket.gethostname(),
    })


if __name__ == "__main__":
    # Only used for local dev. In the container, gunicorn runs the app.
    app.run(host="0.0.0.0", port=5000)
