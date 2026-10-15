#!/usr/bin/env python3
"""Run the real native client/task34 against controlled HTTP fixtures."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import subprocess
import threading
import time
from urllib.parse import urlparse


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.headers.get('Authorization') != 'Bearer fixture-token':
            self.send_json(401, {'message': 'Unauthorized'})
            return
        path = urlparse(self.path).path
        if path == '/version':
            self.send_json(200, {'version': 'fixture', 'meta': True, 'premium': True})
        elif path in ['/traffic', '/logs']:
            if getattr(self.server, 'truncated', False):
                data = b'{"up":1,"down":2}'
                self.send_response(200)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()
            samples = [{'up': 123, 'down': 456}] if path == '/traffic' else [{'type': 'info', 'payload': 'fixture log'}] * 2
            try:
                # Multiple records share a chunk: traffic must trim to the first.
                payload = b''.join(json.dumps(x).encode() + b'\n' for x in samples)
                self.wfile.write(f'{len(payload):x}\r\n'.encode() + payload + b'\r\n')
                self.wfile.flush()
                time.sleep(3)
                self.wfile.write(b'0\r\n\r\n')
            except (BrokenPipeError, ConnectionResetError):
                pass
        elif path == '/slow':
            time.sleep(1)
            try:
                self.send_json(200, {})
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            self.send_json(404, {})

    def send_json(self, code, value):
        data = json.dumps(value).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--probe', required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        config = {'baseURL': f'http://127.0.0.1:{server.server_port}', 'secret': 'fixture-token', 'timeoutMs': 1000,
                  'tasks': ['1', '34;;1', '2', '60;;2', '11;;missing', '4;;{}', '', 'abc', '13', '70;;x;;-1']}
        run = subprocess.run([args.probe], input=json.dumps(config), text=True, capture_output=True, timeout=10, check=True)
        rows = json.loads(run.stdout)
        assert all(x['ok'] for x in rows[:4]), rows
        version = json.loads(rows[0]['wire'][3:].strip())
        assert version['meta'] is True and version['premium'] is True
        assert json.loads(rows[2]['wire'][3:].strip()) == {'up': 123, 'down': 456}
        assert rows[2]['elapsedMs'] < 1500 and rows[3]['elapsedMs'] < 1500
        assert not rows[4]['ok'] and 'code -3' in rows[4]['wire']
        assert not rows[5]['ok'] and 'code -8' in rows[5]['wire']
        assert all(not x['ok'] for x in rows[6:])
        config.update(secret='wrong', tasks=['1', '2'], timeoutMs=500)
        rows = json.loads(subprocess.run([args.probe], input=json.dumps(config), text=True, capture_output=True, timeout=5, check=True).stdout)
        assert all(not x['ok'] and 'code -5' in x['wire'] for x in rows)
        # Late stream completion after an early client timeout must not use stack storage.
        config.update(secret='fixture-token', timeoutMs=100, tasks=['60;;1000', '1'])
        rows = json.loads(subprocess.run([args.probe], input=json.dumps(config), text=True, capture_output=True, timeout=5, check=True).stdout)
        assert rows[0]['ok'] and rows[1]['ok']
        server.truncated = True
        config.update(timeoutMs=1000, tasks=['2', '60;;1'])
        rows = json.loads(subprocess.run([args.probe], input=json.dumps(config), text=True, capture_output=True, timeout=5, check=True).stdout)
        assert all(not x['ok'] and 'code -4' in x['wire'] for x in rows), rows
        print('Native HTTP transport/task34 regression tests passed')
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
