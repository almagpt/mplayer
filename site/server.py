#!/usr/bin/env python3
import os
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent / "public"
API_ORIGIN = "https://mplayer-api.up.railway.app"
ROUTES = {
    "/": "index.html",
    "/privacidade": "privacidade.html",
    "/privacidade/": "privacidade.html",
    "/termos": "termos.html",
    "/termos/": "termos.html",
    "/contato": "contato.html",
    "/contato/": "contato.html",
    "/saiba-mais": "saiba-mais.html",
    "/saiba-mais/": "saiba-mais.html",
}


def should_proxy(path: str) -> bool:
    base = path.split("?", 1)[0]
    return (
        base == "/partner"
        or base.startswith("/partner/")
        or base == "/admin"
        or base.startswith("/admin/")
        or base.startswith("/auth/")
        or base.startswith("/v1/")
    )


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self._handle()

    def do_POST(self):
        self._handle()

    def do_PUT(self):
        self._handle()

    def do_DELETE(self):
        self._handle()

    def _handle(self):
        if should_proxy(self.path):
            self._proxy()
            return
        if self.command != "GET":
            self.send_error(405)
            return
        path = self.path.split("?", 1)[0]
        if path in ROUTES:
            self._send(ROOT / ROUTES[path], "text/html; charset=utf-8")
            return
        candidate = (ROOT / path.lstrip("/")).resolve()
        if not str(candidate).startswith(str(ROOT.resolve())) or not candidate.is_file():
            self.send_error(404, "Página não encontrada")
            return
        content_type = "text/css; charset=utf-8" if candidate.suffix == ".css" else "application/octet-stream"
        self._send(candidate, content_type)

    def _proxy(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else None
        request = urllib.request.Request(API_ORIGIN + self.path, data=body, method=self.command)
        for header in ("Content-Type", "Cookie", "Accept"):
            value = self.headers.get(header)
            if value:
                request.add_header(header, value)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = response.read()
                status = response.status
                headers = response.headers
        except urllib.error.HTTPError as error:
            payload = error.read()
            status = error.code
            headers = error.headers
        self.send_response(status)
        for key, value in headers.items():
            if key.lower() in {"content-type", "set-cookie", "cache-control"}:
                self.send_header(key, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _send(self, file_path: Path, content_type: str):
        body = file_path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args))


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    print(f"mplayer site listening on {port}")
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
