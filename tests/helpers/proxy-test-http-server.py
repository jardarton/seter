import gzip
import ssl
import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

class Handler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def send_secret_response(self):
        request_path = urlsplit(self.path).path
        if request_path in ("/secret", "/secret-gzip"):
            authorization = self.headers.get("Authorization", "")
            api_key = self.headers.get("X-Api-Key", "")
            unconfigured = self.headers.get("X-Unconfigured", "")
            content_length = int(self.headers.get("Content-Length", "0"))
            request_body = self.rfile.read(content_length) if content_length else b""
            payload = (
                authorization.encode()
                + b"\n"
                + api_key.encode()
                + b"\n"
                + unconfigured.encode()
                + b"\n"
                + self.path.encode()
                + b"\n"
                + request_body
                + b"\n"
            )
            Path("/tmp/seter-secret-received").write_bytes(payload)
            encoded_payload = gzip.compress(payload) if request_path == "/secret-gzip" else payload
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("X-Reflected-Authorization", authorization)
            if request_path == "/secret-gzip":
                self.send_header("Content-Encoding", "gzip")
            self.send_header("Content-Length", str(len(encoded_payload)))
            self.end_headers()
            self.wfile.write(encoded_payload)
            return True
        return False

    def do_GET(self):
        if not self.send_secret_response():
            super().do_GET()

    def do_POST(self):
        if not self.send_secret_response():
            self.send_error(404)

handler = partial(Handler, directory="/tmp/seter-upstream")
port = int(sys.argv[1]) if len(sys.argv) > 1 else 80
server = ThreadingHTTPServer(("11.0.0.2", port), handler)
if port == 443:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(sys.argv[2], sys.argv[3])

    def record_server_name(_socket, server_name, _context):
        if server_name == "bad-cert.example":
            Path("/tmp/seter-bad-cert-tls-seen").touch()

    context.set_servername_callback(record_server_name)
    server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
