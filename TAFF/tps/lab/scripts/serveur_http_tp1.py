#!/usr/bin/env python3
"""Serveur HTTP en clair du TP1, sans fichier ni dépendance à installer."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import sys


MESSAGE = b"ARES TP1 application disponible\n"


class TP1Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/":
            self.send_error(404, "Ressource inconnue")
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(MESSAGE)))
        self.end_headers()
        self.wfile.write(MESSAGE)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="10.20.0.10", help="adresse d'écoute (défaut : 10.20.0.10)")
    parser.add_argument("--port", type=int, default=443, help="port TCP (défaut : 443)")
    args = parser.parse_args()

    try:
        server = ThreadingHTTPServer((args.bind, args.port), TP1Handler)
    except OSError as error:
        print(f"Impossible de démarrer le serveur : {error}", file=sys.stderr)
        print("Vérifier le namespace ns_prod, son adresse et la disponibilité du port.", file=sys.stderr)
        return 1

    with server:
        print(f"HTTP en clair sur http://{args.bind}:{server.server_port}/ -- arrêt : Ctrl-C", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            print("\nServeur arrêté.", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
