import http.server
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import threading
import time

binary = str(Path(sys.argv[1]).resolve())
class CloudStub(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        body = json.dumps({'code': '0', 'data': {'deviceToken': 'isolated-device-token'}}).encode()
        self.send_response(201)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        self.send_response(401)
        self.send_header('Content-Length', '0')
        self.end_headers()
    def log_message(self, *arguments):
        pass

for san, accepted in [('IP:127.0.0.1', True), ('DNS:127.0.0.1', False)]:
    with tempfile.TemporaryDirectory(prefix='se9-ip-cert-') as directory:
        root = Path(directory)
        certificate, key = root / 'certificate.pem', root / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=se9-isolated-test', '-addext', 'subjectAltName=' + san, '-out', str(certificate), '-keyout', str(key)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        server = http.server.HTTPServer(('127.0.0.1', 0), CloudStub)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certificate, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        environment = dict(os.environ)
        for name in ['SE9_AGENT_PROXY_TOKEN', 'SE9_TLS_INSECURE']:
            environment.pop(name, None)
        environment.update({'SE9_CLOUD_URL': 'https://127.0.0.1:' + str(server.server_port), 'SE9_CLOUD_BASE_PATH': '', 'SE9_CA_FILE': str(certificate), 'SE9_KEY_FILE': str(root / 'device.pem'), 'SE9_TOKEN_FILE': str(root / 'device-token'), 'SE9_AGENT_PROXY_TOKEN_FILE': str(root / 'proxy-key'), 'SE9_RTC_ENABLED': '0'})
        with (root / 'agent.log').open('wb') as log:
            process = subprocess.Popen([binary], env=environment, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline and process.poll() is None and not (root / 'device-token').exists():
                    time.sleep(.05)
                if accepted:
                    assert (root / 'device-token').exists() and process.poll() is None, (root / 'agent.log').read_text()
                else:
                    assert process.wait(timeout=5) != 0 and not (root / 'device-token').exists(), (root / 'agent.log').read_text()
            finally:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=5)
                server.shutdown()
                server.server_close()
                worker.join(timeout=5)
print('PASS: trusted IP SAN accepted; DNS-only SAN for an IP rejected; no TLS verification bypass')
