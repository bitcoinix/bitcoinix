"""Offline SOCKS fixture: accept only the external hosts used by Orchard's test."""

import socketserver
import sys


class Proxy(socketserver.StreamRequestHandler):
    def handle(self):
        version, methods = self.rfile.read(2)
        assert version == 5 and 0 in self.rfile.read(methods)
        self.wfile.write(b"\x05\x00")
        # Requiring a domain name also catches accidental local DNS resolution.
        assert self.rfile.read(4) == b"\x05\x01\x00\x03"
        host = self.rfile.read(self.rfile.read(1)[0]).decode()
        assert host in {"orchard-proxy.invalid", "orchard-proxy.onion"}, host
        assert int.from_bytes(self.rfile.read(2), "big") == 80
        self.wfile.write(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x50")
        assert self.rfile.readline().startswith(b"GET ")
        while self.rfile.readline() not in (b"\r\n", b""):
            pass
        body = b'{"via":"socks"}'
        self.wfile.write(
            b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
            + f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode()
            + body
        )


with socketserver.ThreadingTCPServer((sys.argv[1], int(sys.argv[2])), Proxy) as server:
    server.serve_forever()
