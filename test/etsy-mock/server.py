"""Nachgebaute Etsy-API für die lokale Testumgebung (test/docker-compose.yml).

Läuft im Docker-Netz unter dem Namen openapi.etsy.com mit einem selbst
erzeugten Zertifikat; n8n vertraut der Test-CA (NODE_EXTRA_CA_CERTS). Die
Workflows bleiben dadurch unverändert und sprechen dieselben URLs an wie im
Betrieb.

Beantwortet nur, was die Workflows 01 und 02 abfragen:
  GET /v3/application/shops/<id>/receipts
  GET /v3/application/shops/<id>/payment-account/ledger-entries
  GET /v3/application/shops/<id>/payment-account/ledger-entries/payments
Die Testdaten erzeugt fixtures.py, relativ zum aktuellen Monat.
"""
import json
import os
import ssl
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import fixtures

CERTS = os.environ.get('CERTS_DIR', '/certs')
HOST = 'openapi.etsy.com'


def ensure_certs():
    """Test-CA und Serverzertifikat einmalig erzeugen (bleiben im Volume)."""
    ca, key, crt = (os.path.join(CERTS, n) for n in ('ca.crt', 'server.key', 'server.crt'))
    if os.path.exists(crt):
        return
    os.makedirs(CERTS, exist_ok=True)
    run = lambda *a: subprocess.run(a, check=True, capture_output=True)
    run('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '3650',
        '-subj', '/CN=Buchhaltung Test-CA', '-keyout', os.path.join(CERTS, 'ca.key'), '-out', ca)
    run('openssl', 'req', '-newkey', 'rsa:2048', '-nodes', '-subj', f'/CN={HOST}',
        '-keyout', key, '-out', os.path.join(CERTS, 'server.csr'))
    ext = os.path.join(CERTS, 'ext.cnf')
    with open(ext, 'w') as f:
        f.write(f'subjectAltName=DNS:{HOST}\n')
    run('openssl', 'x509', '-req', '-in', os.path.join(CERTS, 'server.csr'), '-CA', ca,
        '-CAkey', os.path.join(CERTS, 'ca.key'), '-CAcreateserial', '-days', '3650',
        '-extfile', ext, '-out', crt)
    os.chmod(ca, 0o644)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f'{self.command} {self.path}', flush=True)

    def send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def page(self, rows, q):
        off, lim = int(q.get('offset', 0)), int(q.get('limit', 25))
        return {'count': len(rows), 'results': rows[off:off + lim]}

    def do_GET(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if not self.headers.get('authorization', '').startswith('Bearer '):
            return self.send_json(401, {'error': 'missing bearer token'})

        if u.path.endswith('/receipts'):
            rows = fixtures.receipts()
            if 'min_created' in q:
                rows = [r for r in rows if r['created_timestamp'] >= int(q['min_created'])]
            if 'min_last_modified' in q:
                rows = [r for r in rows if r['updated_timestamp'] >= int(q['min_last_modified'])]
            key = 'updated_timestamp' if q.get('sort_on') == 'updated' else 'created_timestamp'
            rows.sort(key=lambda r: r[key], reverse=q.get('sort_order', 'desc') in ('desc', 'down'))
            return self.send_json(200, self.page(rows, q))

        if u.path.endswith('/payment-account/ledger-entries/payments'):
            ids = set(q.get('ledger_entry_ids', '').split(','))
            rows = fixtures.payments(ids)
            return self.send_json(200, {'count': len(rows), 'results': rows})

        if u.path.endswith('/payment-account/ledger-entries'):
            if 'min_created' not in q or 'max_created' not in q:
                return self.send_json(400, {'error': 'min_created and max_created are required'})
            lo, hi = int(q['min_created']), int(q['max_created'])
            if hi - lo > 31 * 86400:
                return self.send_json(400, {'error': 'date range too large'})
            rows = [e for e in fixtures.ledger() if lo <= e['create_date'] <= hi]
            rows.sort(key=lambda e: e['create_date'], reverse=True)   # Etsy: neueste zuerst
            return self.send_json(200, self.page(rows, q))

        self.send_json(404, {'error': f'not mocked: {u.path}'})


if __name__ == '__main__':
    ensure_certs()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(os.path.join(CERTS, 'server.crt'), os.path.join(CERTS, 'server.key'))
    srv = ThreadingHTTPServer(('0.0.0.0', 443), Handler)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    open(os.path.join(CERTS, 'ready'), 'w').close()
    print(f'Etsy-Mock bereit: {len(fixtures.receipts())} Bestellungen, '
          f'{len(fixtures.ledger())} Ledger-Einträge', flush=True)
    srv.serve_forever()
