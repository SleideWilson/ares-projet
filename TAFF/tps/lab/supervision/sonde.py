#!/usr/bin/env python3
"""Sonde HTTP pédagogique et bilan CSV, sans dépendance externe."""

import argparse
import csv
from datetime import datetime, timezone
from http.client import HTTPConnection, HTTPException
from pathlib import Path
import time


def positive(text):
    value = float(text)
    if not 0 < value < float("inf"):
        raise argparse.ArgumentTypeError("une valeur finie strictement positive est requise")
    return value


def positive_int(text):
    value = int(text)
    if value < 1:
        raise argparse.ArgumentTypeError("un entier supérieur ou égal à 1 est requis")
    return value


class AlertRule:
    def __init__(self, threshold_ms, confirm, recover):
        self.threshold_ms = threshold_ms
        self.confirm, self.recover = confirm, recover
        self.bad_streak = self.good_streak = 0
        self.active = False

    def observe(self, status, latency):
        bad = status != 200 or latency > self.threshold_ms
        self.bad_streak = self.bad_streak + 1 if bad else 0
        self.good_streak = 0 if bad else self.good_streak + 1
        event = ""
        if not self.active and self.bad_streak >= self.confirm:
            self.active, event = True, "ALERTE"
        elif self.active and self.good_streak >= self.recover:
            self.active, event = False, "RETOUR_OK"
        return bad, event


def monitor(args):
    rule = AlertRule(args.threshold_ms, args.confirm, args.recover)
    try:
        with args.csv.open("x", newline="", encoding="utf-8") as handle:
            fields = ["time", "status", "latency_ms", "bad", "alert", "event", "error"]
            writer = csv.DictWriter(handle, fieldnames=fields)
            writer.writeheader()
            print(f"Règle fixe : HTTP différent de 200 OU latence > {args.threshold_ms} ms ; "
                  f"{args.confirm} anomalies pour alerter, {args.recover} succès pour rétablir.", flush=True)
            for _ in range(args.count):
                started = time.monotonic()
                status, error = 0, ""
                conn = HTTPConnection(args.host, args.port, timeout=args.timeout)
                try:
                    conn.request("GET", "/")
                    response = conn.getresponse()
                    response.read()
                    status = response.status
                except (OSError, HTTPException) as exc:
                    error = str(exc)
                finally:
                    conn.close()
                latency = round((time.monotonic() - started) * 1000, 1)
                stamp = datetime.now(timezone.utc).isoformat()
                bad, event = rule.observe(status, latency)
                writer.writerow(dict(time=stamp, status=status, latency_ms=f"{latency:.1f}",
                                     bad=int(bad), alert=int(rule.active), event=event, error=error))
                handle.flush()
                state = "DEGRADE" if bad else "OK"
                print(f"{stamp} HTTP={status} latence={latency:.1f}ms état={state} alerte={int(rule.active)} {event} {error}", flush=True)
                time.sleep(max(0, args.interval - (time.monotonic() - started)))
    except KeyboardInterrupt:
        print("\nSonde arrêtée ; les mesures déjà écrites sont conservées.")
    except OSError as exc:
        raise SystemExit(f"Impossible d'écrire le CSV : {exc}")


def replay(args):
    rule = AlertRule(args.threshold_ms, args.confirm, args.recover)
    try:
        with args.input.open(newline="", encoding="utf-8") as handle:
            rows = list(csv.DictReader(handle))
        if not rows:
            raise ValueError("aucune mesure")
        for row in rows:
            status, latency = int(row["status"]), float(row["latency_ms"])
            if not 0 <= latency < float("inf") or not (status == 0 or 100 <= status <= 599):
                raise ValueError("statut ou latence invalide")
            bad, event = rule.observe(status, latency)
            row.update(bad=int(bad), alert=int(rule.active), event=event)
        with args.csv.open("x", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
        print(f"REJEU : {len(rows)} mesures conservées, règle fixe seuil={args.threshold_ms} ms, "
              f"confirmation={args.confirm}, retour={args.recover}. Aucun nouvel appel HTTP.")
        summary(args)
    except (OSError, KeyError, ValueError) as exc:
        raise SystemExit(f"Impossible de rejouer les mesures : {exc}")


def summary(args):
    try:
        with args.csv.open(newline="", encoding="utf-8") as handle:
            rows = list(csv.DictReader(handle))
        if not rows:
            raise ValueError("aucune mesure")
        count = len(rows)
        successes = sum(int(row["status"]) == 200 for row in rows)
        satisfied = sum(int(row["bad"]) == 0 for row in rows)
        print(f"Fenêtre : {rows[0]['time']} à {rows[-1]['time']} ; {count} sondes")
        print(f"Réponses HTTP 200 : {successes}/{count} = {100 * successes / count:.1f}%")
        print(f"Réponses satisfaisant la règle : {satisfied}/{count} = {100 * satisfied / count:.1f}%")
        for row in rows:
            if row["event"]:
                print(f"{row['time']} {row['event']}")
    except (OSError, KeyError, ValueError) as exc:
        raise SystemExit(f"Impossible de lire les mesures : {exc}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("mesurer")
    run.add_argument("--host", default="127.0.0.1")
    run.add_argument("--port", type=int, default=18080)
    run.add_argument("--interval", type=positive, default=2)
    run.add_argument("--timeout", type=positive, default=3)
    run.add_argument("--threshold-ms", type=positive, default=500)
    run.add_argument("--confirm", type=positive_int, default=3)
    run.add_argument("--recover", type=positive_int, default=2)
    run.add_argument("--count", type=positive_int, default=300)
    run.add_argument("--csv", type=Path, required=True)
    run.set_defaults(action=monitor)
    report = commands.add_parser("bilan")
    report.add_argument("csv", type=Path)
    report.set_defaults(action=summary)
    rerun = commands.add_parser("rejouer")
    rerun.add_argument("input", type=Path)
    rerun.add_argument("--threshold-ms", type=positive, required=True)
    rerun.add_argument("--confirm", type=positive_int, required=True)
    rerun.add_argument("--recover", type=positive_int, required=True)
    rerun.add_argument("--csv", type=Path, required=True)
    rerun.set_defaults(action=replay)
    args = parser.parse_args()
    args.action(args)


if __name__ == "__main__":
    main()
