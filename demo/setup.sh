#!/bin/sh
# Creates a small, realistic fixture repository in /tmp/pretend-nvim-demo
# for recording demo/demo.gif with VHS.
set -eu

demo_dir=/tmp/pretend-nvim-demo

rm -rf "$demo_dir"
mkdir -p "$demo_dir/src" "$demo_dir/tests"
cd "$demo_dir"

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Alex"
export GIT_AUTHOR_EMAIL="alex@example.com"
export GIT_COMMITTER_NAME="Alex"
export GIT_COMMITTER_EMAIL="alex@example.com"

git init -q -b main

cat <<'EOF' >src/server.py
def handle_request(user_id: str, path: str) -> dict:
    return {"status": 200, "user": user_id, "path": path}
EOF

cat <<'EOF' >tests/test_server.py
from src.server import handle_request


def test_handle_request():
    res = handle_request("u1", "/items")
    assert res["status"] == 200
EOF

git add -A
git commit -q -m "Initial request handler"

git switch -q -c feat/rate-limit

cat <<'EOF' >src/limiter.py
class TokenBucket:
    def __init__(self, capacity: int):
        self.capacity = capacity
        self.counts: dict[str, int] = {}

    def allow(self, key: str) -> bool:
        used = self.counts.get(key, 0)
        if used >= self.capacity:
            return False
        self.counts[key] = used + 1
        return True
EOF

git add -A
git commit -q -m "Add per-user token bucket"

cat <<'EOF' >src/server.py
from src.limiter import TokenBucket

limiter = TokenBucket(capacity=60)


def handle_request(user_id: str, path: str) -> dict:
    if not limiter.allow(user_id):
        return {"status": 429, "error": "rate limit exceeded"}
    return {"status": 200, "user": user_id, "path": path}
EOF

git add -A
git commit -q -m "Enforce rate limit in request handler"

cat <<'EOF' >tests/test_server.py
from src.limiter import TokenBucket
from src.server import handle_request


def test_handle_request():
    res = handle_request("u1", "/items")
    assert res["status"] == 200


def test_rate_limit_blocks_excess():
    bucket = TokenBucket(capacity=1)
    assert bucket.allow("u1") is True
    assert bucket.allow("u1") is False
EOF

git add -A
git commit -q -m "Add rate limiter unit tests"
