#!/usr/bin/env python3
"""Acceptation réelle TP3 dans une VM : HTTP/SNMP/NetFlow, incident, retour sain.

Exécuter avec sudo et les paquets TP3 installés. Le répertoire de résultats doit
être neuf. Les namespaces TP3 sont retirés même en cas d'échec ; preuves conservées.
"""

import argparse
import csv
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import time

import lab


def rows(path):
    if not path.exists():
        return []
    with path.open() as handle:
        return list(csv.DictReader(handle))


def wait_for(path, predicate, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        data = rows(path)
        if predicate(data):
            return data
        time.sleep(.2)
    raise RuntimeError(f"Transition attendue non observée en {timeout}s ; consulter {path}")


def recovery_confirmed(data, correction_time):
    """Require a new recovery event and five uninterrupted healthy controls after it."""
    index = next((i for i, row in enumerate(data)
                  if row["event"] == "RETOUR_OK"
                  and datetime.fromisoformat(row["time"]) > correction_time), None)
    if index is None:
        return False
    after_recovery = data[index:]
    if any(row["status"] != "200" or row["bad"] != "0" or row["alert"] != "0"
           for row in after_recovery):
        raise RuntimeError("Non-régression : nouvelle dégradation après le retour sain")
    return len(after_recovery) >= 6


def verify(root):
    lab.setup(root)
    probe = None
    try:
        lab.check(root)
        source = root / "validation-http.csv"
        with (root / "validation-sonde.log").open("w") as log:
            probe = subprocess.Popen(["ip", "netns", "exec", "tp3_client", sys.executable,
                                      str(lab.HERE / "sonde.py"), "mesurer", "--host", "10.30.2.10",
                                      "--count", "300", "--interval", "2", "--timeout", "3",
                                      "--threshold-ms", "600", "--confirm", "2", "--recover", "2",
                                      "--csv", str(source)], stdout=log, stderr=log)
        wait_for(source, lambda data: len(data) >= 5)
        baseline = rows(source)
        if any(row["status"] != "200" or row["bad"] != "0" for row in baseline):
            raise RuntimeError("Référence HTTP déjà dégradée ; calibrer la VM avant la séance")
        lab.incident(root)
        wait_for(source, lambda data: any(row["event"] == "ALERTE" for row in data))
        # Observe a real UDP flow in a closed collector file; a running daemon is insufficient.
        deadline = time.monotonic() + 35
        found = False
        while time.monotonic() < deadline and not found:
            for path in sorted((root / "flows").glob("nfcapd.[0-9]*")):
                output = lab.run("nfdump", "-r", path, "-q", "-o", "csv",
                                 "proto udp and port 5201", capture=True).stdout
                if "10.30.2.10" in output and "5201" in output:
                    found = True
                    break
            if not found:
                time.sleep(1)
        if not found:
            raise RuntimeError("Trafic concurrent absent des exports NetFlow")
        before_correction = rows(source)
        if not before_correction or before_correction[-1]["alert"] != "1":
            raise RuntimeError("Alerte non active avant correction : incident non reproductible")
        lab.correct(root)
        correction_time = datetime.now(timezone.utc)
        final = wait_for(source, lambda data: recovery_confirmed(data, correction_time))
        report = {"http_baseline": "pass", "snmp_counter64": "pass", "netflow_http": "pass",
                  "netflow_incident_udp": "pass", "http_alert": "pass", "http_recovery": "pass",
                  "correction_completed_at": correction_time.isoformat(),
                  "events": [{"time": row["time"], "event": row["event"]} for row in final if row["event"]]}
        (root / "validation.json").write_text(json.dumps(report, indent=2) + "\n")
        print("Acceptation réseau réussie ; preuves dans", root)
    finally:
        if probe and probe.poll() is None:
            probe.terminate()
            probe.wait(timeout=5)
        lab.reset(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", type=Path, default=Path("tp3-validation"))
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("exécuter avec sudo dans la VM de TP")
    os.umask(0o022)
    try:
        verify(args.results.resolve())
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"Acceptation TP3 : {exc}\n")


if __name__ == "__main__":
    main()
