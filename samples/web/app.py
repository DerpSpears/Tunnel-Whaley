"""Subpath-safe sample web challenge.

Responds to ANY path with the same page (so it works under /i/<token>/ without
StripPrefix), and uses only relative asset/form references. A trivial 'login
bypass' reveals the per-instance flag taken from the FLAG env var.
"""
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

FLAG = os.environ.get("FLAG", "flag{unset}")

PAGE = """<!doctype html><html><head><meta charset=utf-8>
<title>Login Portal</title>
<style>body{{font-family:Inter,system-ui,sans-serif;max-width:520px;margin:60px auto}}
input,button{{padding:8px;font-size:15px}} .card{{border:1px solid #ddd;border-radius:12px;padding:24px}}</style>
</head><body><div class=card>
<h2>Course Portal Login</h2>
<p>Log in as <code>admin</code> to retrieve the flag.</p>
<form method=POST action="">
  <p>User: <input name=user value=""></p>
  <p>Pass: <input name=pass type=password></p>
  <button type=submit>Sign in</button>
</form>
<p style="color:#666">Hint: the query is <code>user='$u' AND pass='$p'</code></p>
{result}
</div></body></html>"""


class H(BaseHTTPRequestHandler):
    def _send(self, body):
        b = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        self._send(PAGE.format(result=""))

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        data = parse_qs(self.rfile.read(n).decode(errors="replace"))
        u = (data.get("user", [""])[0])
        p = (data.get("pass", [""])[0])
        # intentionally weak check: classic ' OR '1'='1 bypass
        if "'" in u or "'" in p or (u == "admin" and p == "letmein"):
            res = f"<hr><p><b>Welcome admin!</b></p><p>Flag: <code>{FLAG}</code></p>"
        else:
            res = "<hr><p style='color:#b00'>Invalid credentials.</p>"
        self._send(PAGE.format(result=res))

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
