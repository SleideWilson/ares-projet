#!/usr/bin/env python3
"""Service HTTP local du TP3 ; une valeur en secondes pilote sa latence."""

import argparse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18080)
    parser.add_argument("--delay-file", type=Path, required=True)
    args = parser.parse_args()
    if not args.delay_file.is_file():
        parser.error("créer le fichier de délai avec la valeur 0 avant de démarrer")

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            started = time.monotonic()
            delay = None
            try:
                delay = float(args.delay_file.read_text().strip())
                if not 0 <= delay <= 5:
                    raise ValueError("délai hors de [0, 5]")
                status = 200 if self.path == "/" else 404
                time.sleep(delay)
                body = b"ARES service OK\n" if status == 200 else b"Not found\n"
            except (OSError, ValueError):
                status, body = 500, b"Invalid delay file\n"
            self.send_response(status)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass
            print(json.dumps({
                "time": datetime.now(timezone.utc).isoformat(),
                "path": self.path,
                "status": status,
                "injected_delay_s": delay,
                "duration_ms": round((time.monotonic() - started) * 1000, 1),
            }), flush=True)

        def log_message(self, format, *values):
            pass

    try:
        with ThreadingHTTPServer((args.bind, args.port), Handler) as server:
            print(f"Service : http://{args.bind}:{args.port}/", flush=True)
            try:
                server.serve_forever()
            except KeyboardInterrupt:
                pass
    except OSError as exc:
        parser.exit(1, f"Impossible de démarrer le service : {exc}\n")


if __name__ == "__main__":
    main()
