#!/usr/bin/env python3
"""Serves this instance's peer snapshot (see snapshot.sh) on container port 1337.

GET /snapshot/info.json      what the snapshot holds, for anyone
GET /snapshot.tar            backend + blockbook-db, streamed as a tar
GET /snapshot-blockbook.tar  blockbook-db only

The tar downloads are only for addresses that run the same Flux app (they are
tens to hundreds of GB of the node operator's bandwidth), and only a couple
at a time.
"""
import http.server
import json
import os
import shutil
import socketserver
import subprocess
import threading
import time
import urllib.request

SNAP = '/root/snapshot'
APP = os.environ.get('FLUX_APP_NAME', '')
PORT = int(os.environ.get('SNAPSHOT_SERVER_PORT', '1337'))
PUBLIC = os.environ.get('SNAPSHOT_PUBLIC') == '1'
slots = threading.BoundedSemaphore(int(os.environ.get('SNAPSHOT_MAX_DOWNLOADS', '2')))
_peers = {'at': 0.0, 'ips': set()}
_peers_lock = threading.Lock()


def app_ips():
    with _peers_lock:
        if time.time() - _peers['at'] > 120:
            try:
                url = f'https://api.runonflux.io/apps/location/{APP}'
                with urllib.request.urlopen(url, timeout=20) as response:
                    data = json.load(response)['data']
                _peers['ips'] = {entry['ip'].split(':')[0] for entry in data}
                _peers['at'] = time.time()
            except Exception as error:  # keep the last list when the API is down
                print(f'peer list refresh failed: {error}', flush=True)
        return _peers['ips']


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/snapshot/info.json':
            return self.send_file(os.path.join(SNAP, 'info.json'))
        if self.path == '/snapshot.tar':
            return self.send_tar(['info.json', 'backend', 'blockbook-db'])
        if self.path == '/snapshot-blockbook.tar':
            return self.send_tar(['info.json', 'blockbook-db'])
        self.send_error(404)

    def send_file(self, path):
        try:
            with open(path, 'rb') as f:
                body = f.read()
        except OSError:
            return self.send_error(404)
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_tar(self, members):
        client = self.client_address[0]
        if not PUBLIC and client not in app_ips():
            return self.send_error(403, f'{client} does not run {APP}')
        if not os.path.exists(os.path.join(SNAP, 'info.json')):
            return self.send_error(404, 'no snapshot')
        if not slots.acquire(blocking=False):
            return self.send_error(503, 'busy, try another peer')
        # snapshot.sh create does not replace a snapshot while this exists.
        marker = f'/run/bb/serving.{threading.get_ident()}'
        open(marker, 'w').close()
        tar = None
        try:
            print(f'{client} downloading {self.path}', flush=True)
            self.send_response(200)
            self.send_header('Content-Type', 'application/x-tar')
            self.end_headers()
            tar = subprocess.Popen(['tar', '-C', SNAP, '-cf', '-', *members],
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            shutil.copyfileobj(tar.stdout, self.wfile, 1 << 20)
            tar.wait()
            print(f'{client} finished {self.path}', flush=True)
        except (BrokenPipeError, ConnectionResetError):
            print(f'{client} dropped {self.path}', flush=True)
        finally:
            if tar and tar.poll() is None:
                tar.kill()
            os.remove(marker)
            slots.release()

    def log_message(self, fmt, *args):
        pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == '__main__':
    os.makedirs('/run/bb', exist_ok=True)
    Server(('', PORT), Handler).serve_forever()
