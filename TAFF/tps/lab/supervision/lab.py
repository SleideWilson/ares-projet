#!/usr/bin/env python3
"""Maquette TP3 autonome : HTTP, SNMP et NetFlow (root dans une VM de TP)."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
NAMESPACES = ("tp3_client", "tp3_router", "tp3_server")
REQUIRED = ("ip", "tc", "sysctl", "snmpd", "snmpget", "snmpwalk", "softflowd",
            "nfcapd", "nfdump", "iperf3")
STATE = ".tp3-state.json"


def run(*args, capture=False, check=True):
    return subprocess.run(list(map(str, args)), check=check, text=True,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.PIPE if capture else None)


def ns(name, *args, **kwargs):
    if name not in NAMESPACES:
        raise ValueError("Namespace extérieur au TP3")
    return run("ip", "netns", "exec", name, *args, **kwargs)


def save(root, state):
    pending = root / (STATE + ".next")
    pending.write_text(json.dumps(state, indent=2) + "\n")
    pending.replace(root / STATE)


def load(root):
    state = json.loads((root / STATE).read_text())
    if state.get("kind") != "ares-tp3-v1" or any(n not in NAMESPACES for n in state["namespaces"]):
        raise RuntimeError("État non reconnu : aucune ressource ne sera modifiée")
    return state


def namespace_inode(name):
    try:
        return Path("/run/netns", name).stat().st_ino
    except FileNotFoundError:
        return None


def validate_namespaces(state):
    for name, inode in state["namespaces"].items():
        actual = namespace_inode(name)
        if actual is not None and actual != inode:
            raise RuntimeError(f"{name} a été remplacé : opération refusée")


def process_start(pid):
    try:
        # The command name may contain spaces; fields after the final ')' start at 3.
        return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]
    except (FileNotFoundError, ProcessLookupError):
        return None


def alive(process):
    return process_start(process["pid"]) == process["start"]


def start(root, state, label, namespace, command, env=None):
    with (root / f"{label}.log").open("a") as log:
        process = subprocess.Popen(["ip", "netns", "exec", namespace, *map(str, command)],
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                   start_new_session=True, env=env)
    stamp = process_start(process.pid)
    state["processes"][label] = {"pid": process.pid, "start": stamp, "namespace": namespace}
    save(root, state)
    time.sleep(.3)
    if process.poll() is not None:
        raise RuntimeError(f"Échec de {label} : consulter {root / (label + '.log')}")


def mark(root, event):
    timestamp = datetime.now(timezone.utc).isoformat()
    with (root / "injection-enseignant.log").open("a") as handle:
        handle.write(f"{timestamp} {event}\n")
    return timestamp


def setup(root):
    missing = [tool for tool in REQUIRED if shutil.which(tool) is None]
    if missing:
        raise RuntimeError("Paquets manquants : " + ", ".join(missing))
    if root.exists():
        raise RuntimeError("Répertoire existant : choisir --results avec un nouveau nom")
    present = run("ip", "netns", "list", capture=True).stdout.splitlines()
    if any(line.split()[0] in NAMESPACES for line in present if line.split()):
        raise RuntimeError("Un namespace TP3 existe déjà ; aucun changement effectué")
    root.mkdir(parents=True)
    root.chmod(0o755)
    state = {"kind": "ares-tp3-v1", "namespaces": {}, "processes": {}}
    save(root, state)
    try:
        for name in NAMESPACES:
            run("ip", "netns", "add", name)
            state["namespaces"][name] = namespace_inode(name)
            save(root, state)
            ns(name, "ip", "link", "set", "lo", "up")
        # Both ends are created directly in owned namespaces; no host veth is left behind.
        ns("tp3_client", "ip", "link", "add", "eth0", "type", "veth", "peer", "name", "lan-client", "netns", "tp3_router")
        ns("tp3_server", "ip", "link", "add", "eth0", "type", "veth", "peer", "name", "lan-server", "netns", "tp3_router")
        for name, interface, address in (
            ("tp3_client", "eth0", "10.30.1.10/24"),
            ("tp3_router", "lan-client", "10.30.1.1/24"),
            ("tp3_router", "lan-server", "10.30.2.1/24"),
            ("tp3_server", "eth0", "10.30.2.10/24"),
        ):
            ns(name, "ip", "address", "add", address, "dev", interface)
            ns(name, "ip", "link", "set", interface, "up")
        ns("tp3_client", "ip", "route", "add", "default", "via", "10.30.1.1")
        ns("tp3_server", "ip", "route", "add", "default", "via", "10.30.2.1")
        ns("tp3_router", "sysctl", "-qw", "net.ipv4.ip_forward=1")
        ns("tp3_router", "tc", "qdisc", "add", "dev", "lan-client", "root", "tbf",
           "rate", "2mbit", "burst", "16kb", "latency", "1500ms")
        (root / "delai.txt").write_text("0\n")
        (root / "flows").mkdir()
        (root / "snmp-persist").mkdir()
        (root / "snmpd.conf").write_text(
            "agentaddress udp:10.30.1.1:161\n"
            "view tp3 included .1.3.6.1.2.1.1\n"
            "view tp3 included .1.3.6.1.2.1.2\n"
            "view tp3 included .1.3.6.1.2.1.31\n"
            "rocommunity tp3lecture 10.30.1.10/32 -V tp3\n")
        start(root, state, "service", "tp3_server", [sys.executable, HERE / "service.py",
              "--bind", "10.30.2.10", "--delay-file", root / "delai.txt"])
        start(root, state, "iperf-server", "tp3_server", ["iperf3", "-s", "-B", "10.30.2.10"])
        snmp_env = dict(os.environ, SNMP_PERSISTENT_DIR=str(root / "snmp-persist"), MIBS="")
        start(root, state, "snmpd", "tp3_router", ["snmpd", "-f", "-Lo", "-C", "-c", root / "snmpd.conf"], env=snmp_env)
        start(root, state, "nfcapd", "tp3_client", ["nfcapd", "-b", "10.30.1.10", "-p", "9995",
              "-l", root / "flows", "-t", "10"])
        start(root, state, "softflowd", "tp3_router", ["softflowd", "-d", "-i", "lan-server",
              "-n", "10.30.1.10:9995", "-v", "5", "-t", "maxlife=10", "-t", "tcp=5",
              "-t", "tcp.fin=1", "-t", "udp=5", "-t", "expint=1",
              "-p", root / "softflowd.pid", "-c", root / "softflowd.ctl"])
        # Permit the invoking teacher/student to create CSV files and read all evidence.
        uid, gid = int(os.environ.get("SUDO_UID", os.getuid())), int(os.environ.get("SUDO_GID", os.getgid()))
        for path in [root, *root.rglob("*")]:
            if not path.is_symlink():
                os.chown(path, uid, gid)
        print(f"Maquette créée. Contrôle : sudo python3 {HERE / 'lab.py'} check --results {root}")
    except BaseException:
        reset(root, state)
        raise


def require_running(root):
    state = load(root)
    validate_namespaces(state)
    if set(state["namespaces"]) != set(NAMESPACES) or any(namespace_inode(n) is None for n in NAMESPACES):
        raise RuntimeError("Maquette incomplète ou arrêtée")
    for label in ("service", "iperf-server", "snmpd", "nfcapd", "softflowd"):
        if label not in state["processes"] or not alive(state["processes"][label]):
            raise RuntimeError(f"Processus {label} arrêté ; consulter son journal")
    return state


def check(root):
    require_running(root)
    output = ns("tp3_client", sys.executable, "-c",
                "from http.client import HTTPConnection; c=HTTPConnection('10.30.2.10',18080,timeout=3); "
                "c.request('GET','/'); r=c.getresponse(); assert r.status==200; print(r.read().decode()); c.close()",
                capture=True)
    print("HTTP 200 :", output.stdout.strip())
    names = ns("tp3_client", "snmpwalk", "-v2c", "-c", "tp3lecture", "-t", "3", "-r", "0",
               "-On", "10.30.1.1", ".1.3.6.1.2.1.31.1.1.1.1", capture=True).stdout
    interface = next((line.split(" = ", 1)[0].rsplit(".", 1)[1] for line in names.splitlines()
                      if "lan-client" in line), None)
    if interface is None:
        raise RuntimeError("SNMP : interface lan-client absente")
    counters = ns("tp3_client", "snmpget", "-v2c", "-c", "tp3lecture", "-t", "3", "-r", "0",
                  "-On", "10.30.1.1", f".1.3.6.1.2.1.31.1.1.1.6.{interface}",
                  f".1.3.6.1.2.1.31.1.1.1.10.{interface}", capture=True).stdout
    if counters.count("Counter64:") != 2:
        raise RuntimeError("SNMP : compteurs 64 bits indisponibles")
    print("SNMP :", counters.strip())
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        # Never feed nfdump the collector's unfinished nfcapd.current file.
        for path in sorted((root / "flows").glob("nfcapd.[0-9]*")):
            result = run("nfdump", "-r", path, "-q", "-o", "csv", "proto tcp and port 18080", capture=True)
            if any("10.30.2.10" in line and "18080" in line for line in result.stdout.splitlines()):
                print(f"NetFlow : flux HTTP présent dans {path.name}")
                print("Contrôle initial réussi (ne valide pas encore l'incident).")
                return
        time.sleep(1)
    raise RuntimeError("Aucun flux HTTP exporté en 35 s ; inspecter softflowd.log et nfcapd.log")


def incident(root):
    state = require_running(root)
    if "traffic" in state["processes"] and alive(state["processes"]["traffic"]):
        raise RuntimeError("Scénario déjà actif")
    started_at = mark(root, "INCIDENT_DEBUT")
    start(root, state, "traffic", "tp3_client", ["iperf3", "-c", "10.30.2.10", "-u", "-R",
          "-b", "4M", "-l", "1200", "-t", "5400", "-i", "1"])
    print(f"Heure de début du scénario (UTC) : {started_at}")
    print("Scénario de diagnostic démarré. Poursuivez les mesures HTTP, SNMP et NetFlow.")


def correct(root):
    state = require_running(root)
    process = state["processes"].get("traffic")
    if not process or not alive(process):
        raise RuntimeError("Aucun trafic injecté actif : vérifier la cause avant correction")
    # Check both birth time and namespace before signalling a saved PID.
    pids = ns_pids(process["namespace"])
    if process["pid"] not in pids:
        raise RuntimeError("PID de trafic hors de son namespace : arrêt refusé")
    os.kill(process["pid"], signal.SIGTERM)
    mark(root, "CORRECTION_ARRET_TRAFIC")
    print("Trafic concurrent arrêté ; limitation 2 Mbit/s et règle HTTP conservées.")


def ns_pids(name):
    return [int(pid) for pid in run("ip", "netns", "pids", name, capture=True).stdout.split()]


def reset(root, state=None):
    state = load(root) if state is None else state
    validate_namespaces(state)
    # Only namespaces recorded at creation, with an unchanged namespace inode.
    for name in reversed(list(state["namespaces"])):
        if namespace_inode(name) is None:
            continue
        pids = ns_pids(name)
        for pid in pids:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and ns_pids(name):
            time.sleep(.1)
        for pid in ns_pids(name):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        run("ip", "netns", "delete", name)
    state["namespaces"] = {}
    state["processes"] = {}
    save(root, state)
    print("Ressources TP3 retirées ; mesures et journaux conservés.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("setup", "check", "incident", "correct", "reset"))
    parser.add_argument("--results", type=Path, default=Path("tp3-resultats"))
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("exécuter avec sudo dans la VM de TP")
    os.umask(0o022)
    root = args.results.resolve()
    try:
        globals()[args.action](root)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"TP3 : {exc}\n")


if __name__ == "__main__":
    main()
