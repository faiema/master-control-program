# SPDX-License-Identifier: AGPL-3.0-only
"""Token rotation shared by independent native processes; no live X calls."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKER = r'''
(require "racket/auth.rkt" "racket/http.rkt" json)
(displayln "ready")
(flush-output)
(read-line)
(parameterize ([current-transport
               (lambda (url #:method method #:headers headers #:body body #:limit limit)
                 (unless (equal? url "https://api.x.com/2/oauth2/token") (error "unexpected endpoint"))
                 (call-with-output-file (getenv "REFRESH_TEST_CALLS") #:exists 'append
                   (lambda (out) (displayln "refresh" out)))
                 (sleep 0.2)
                 (values (hash) (jsexpr->bytes
                                (hasheq 'access_token "new-access" 'refresh_token "new-refresh"
                                        'expires_in 7200 'token_type "bearer" 'scope scopes))))])
  (unless (equal? (access-token) "new-access") (error "wrong access token"))
  (displayln "ok"))
'''


@unittest.skipUnless(shutil.which("racket"), "Racket required")
class TokenRefreshTests(unittest.TestCase):
    def test_processes_share_rotation_and_restart_uses_saved_token(self):
        with tempfile.TemporaryDirectory(prefix="mcp-refresh-") as directory:
            token = Path(directory) / "token.json"
            calls = Path(directory) / "calls"
            token.write_text(json.dumps(dict(access_token="old-access", refresh_token="old-refresh",
                                            expires_at=1, client_id="synthetic-client", confidential=False,
                                            scope="tweet.read users.read tweet.write media.write offline.access")))
            token.chmod(0o600)
            env = {k: v for k, v in os.environ.items()
                   if k not in ("X_ACCESS_TOKEN", "X_CLIENT_ID", "X_CLIENT_SECRET")}
            env.update(MCP_X_TOKEN_FILE=str(token), REFRESH_TEST_CALLS=str(calls))
            workers = []
            try:
                for _ in range(2):
                    worker = subprocess.Popen(["racket", "-e", "(begin " + WORKER + ")"], cwd=ROOT,
                                              env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                              stderr=subprocess.PIPE, text=True)
                    workers.append(worker)
                for worker in workers:
                    self.assertEqual(worker.stdout.readline().strip(), "ready")
                for worker in workers:
                    worker.stdin.write("go\n")
                    worker.stdin.flush()
                for worker in workers:
                    out, err = worker.communicate(timeout=10)
                    self.assertEqual(worker.returncode, 0, err)
                    self.assertEqual(out.strip(), "ok")
                restarted = subprocess.run(["racket", "-e", "(begin " + WORKER + ")"], cwd=ROOT,
                                           env=env, input="go\n", capture_output=True, text=True, timeout=10)
                self.assertEqual(restarted.returncode, 0, restarted.stderr)
                self.assertEqual(restarted.stdout.strip(), "ready\nok")
                self.assertEqual(calls.read_text(), "refresh\n")
                self.assertEqual(json.loads(token.read_text())["refresh_token"], "new-refresh")
                self.assertEqual(token.stat().st_mode & 0o777, 0o600)
            finally:
                for worker in workers:
                    if worker.poll() is None:
                        worker.kill()
                    worker.communicate()
