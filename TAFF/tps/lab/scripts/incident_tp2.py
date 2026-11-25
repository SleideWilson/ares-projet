#!/usr/bin/env python3
"""Déclenchement autonome d'un seul incident dans la maquette WireGuard TP2."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
from datetime import datetime, timezone

STATE = Path('/run/ares-tp2-incident')
NAMES = ('ns_site_a', 'ns_site_b', 'ns_host_a', 'ns_host_b')


def run(*args):
    return subprocess.run(args, capture_output=True, text=True, timeout=30)


def checked(*args):
    result = run(*args)
    if result.returncode:
        raise RuntimeError('Commande impossible : ' + ' '.join(args))
    return result.stdout.strip()


def namespace_ids():
    return {name: os.stat('/run/netns/' + name).st_ino for name in NAMES}


def http_ok(namespace, address):
    code = ('import http.client,sys; '
            'c=http.client.HTTPConnection(sys.argv[1],8000,timeout=3); '
            'c.request("GET","/"); r=c.getresponse(); '
            'sys.exit(0 if r.status==200 else 1)')
    return run('ip', 'netns', 'exec', namespace, 'python3', '-c', code, address).returncode == 0


def validate_contract():
    # Les témoins locaux évitent d'attribuer à tort un refus au pare-feu.
    for namespace, address in [('ns_host_a', '10.100.1.10'), ('ns_host_b', '10.100.2.10')]:
        if not http_ok(namespace, address):
            raise RuntimeError('Le service HTTP local ne répond pas en 200 dans ' + namespace)
    baseline = Path(__file__).with_name('test_wireguard_lab.sh')
    checked('bash', str(baseline))
    if not http_ok('ns_host_a', '10.100.2.10'):
        raise RuntimeError('Le test HTTP A vers B doit réussir avant de continuer.')
    if http_ok('ns_host_b', '10.100.1.10'):
        raise RuntimeError('Le test HTTP inverse ne doit pas réussir.')
    # Une réponse HTTP non-200 n'est pas un refus réseau : vérifier une connexion TCP.
    code = ('import socket,sys; s=socket.socket(); s.settimeout(3); '
            'sys.exit(0 if s.connect_ex(("10.100.1.10",8000))==0 else 1)')
    if run('ip', 'netns', 'exec', 'ns_host_b', 'python3', '-c', code).returncode == 0:
        raise RuntimeError('Une connexion TCP B vers A reste possible.')


def save(path, state):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(state, indent=2) + '\n')
    temporary.replace(path)


def operate(action, path, ids):
    state = json.loads(path.read_text()) if path.exists() else {}
    if state.get('namespaces') != ids:
        state = {}
    if action == 'statut':
        print('Incident en cours.' if state.get('active') else 'Aucun incident en cours.')
        return
    if action == 'terminer':
        if not state.get('active'):
            raise RuntimeError('Aucun incident en cours pour cette maquette.')
        validate_contract()
        state.update(active=False, fin=datetime.now(timezone.utc).isoformat())
        save(path, state)
        print('Contrat vérifié : incident terminé. Conservez vos preuves de diagnostic.')
        return
    if state.get('active'):
        raise RuntimeError('Un incident est déjà en cours. Corrigez-le puis lancez terminer.')
    validate_contract()
    variant = secrets.choice(('route_retour', 'prefixe_pair'))
    public_b = checked('ip', 'netns', 'exec', 'ns_site_b', 'wg', 'show', 'wg0', 'public-key')
    # Enregistrer avant la modification : une interruption ne permet pas de cumuler les pannes.
    state = dict(namespaces=ids, active=True, variante=variant,
                 debut=datetime.now(timezone.utc).isoformat())
    save(path, state)
    if variant == 'route_retour':
        checked('ip', '-n', 'ns_site_b', 'route', 'del', '10.100.1.0/24', 'dev', 'wg0')
    else:
        checked('ip', 'netns', 'exec', 'ns_site_a', 'wg', 'set', 'wg0', 'peer', public_b,
                'allowed-ips', '10.200.0.2/32')
    print('Incident déclenché. Testez une nouvelle requête HTTP A vers B.\n'
          'Consignez deux hypothèses et une observation discriminante avant de corriger.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('declencher', 'statut', 'terminer'))
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.exit(1, 'Exécuter avec sudo dans la VM de laboratoire TP2.\n')
    try:
        ids = namespace_ids()
        STATE.mkdir(mode=0o700, exist_ok=True)
        with (STATE / 'lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            operate(args.action, STATE / 'etat.json', ids)
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        parser.exit(1, str(error) + '\nAucune réinitialisation automatique effectuée.\n')


if __name__ == '__main__':
    main()
