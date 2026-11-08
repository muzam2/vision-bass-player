#!/usr/bin/env python3
"""Tiny LAN helper for on-device testing without a Mac.

  GET  /<file>   serves files from --dir (e.g. a freshly built .ipa to download in Safari)
  POST /log      stores the body as logs/<device>-<timestamp>.log (Bass Player → Settings →
                 Diagnostics → "Send log to computer")

Run:  python3 tools/diag_receiver.py --bind 192.168.0.191 --port 8799 --dir ~/Downloads/ipa-serve
"""
import argparse
import datetime
import http.server
import os
import re


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_POST(self):
        if self.path.rstrip("/") != "/log":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        device = re.sub(r"[^A-Za-z0-9._-]+", "_", self.headers.get("X-Device-Name", "device"))[:40]
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        os.makedirs(self.log_dir, exist_ok=True)
        path = os.path.join(self.log_dir, f"{device}-{stamp}.log")
        with open(path, "wb") as f:
            f.write(body)
        reply = f"saved {len(body)} bytes as {os.path.basename(path)}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)
        print(f"[log] {path} ({len(body)} bytes) from {self.client_address[0]}", flush=True)

    def log_message(self, fmt, *args):
        print(f"{self.client_address[0]} {fmt % args}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8799)
    ap.add_argument("--dir", default=".", help="directory served for GET")
    ap.add_argument("--logs", default=None, help="where POSTed logs go (default: <dir>/logs)")
    a = ap.parse_args()
    serve_dir = os.path.expanduser(a.dir)
    Handler.log_dir = os.path.expanduser(a.logs) if a.logs else os.path.join(serve_dir, "logs")
    handler = lambda *args, **kw: Handler(*args, directory=serve_dir, **kw)  # noqa: E731
    with http.server.ThreadingHTTPServer((a.bind, a.port), handler) as srv:
        print(f"serving {serve_dir} on http://{a.bind}:{a.port}/  (POST /log → {Handler.log_dir})", flush=True)
        srv.serve_forever()


if __name__ == "__main__":
    main()
