"""Offline Tor SOCKS/DNS fixture for Orchard's public endpoint checks."""

import socket
import socketserver
import sys
import threading
from pathlib import Path


class DNS(socketserver.BaseRequestHandler):
    def handle(self):
        packet, sock = self.request
        if b"orchard-" in packet:
            Path("/tmp/orchard-dns-leak").touch()
        # NXDOMAIN: preflight lookups must use SOCKS RESOLVE, not this resolver.
        sock.sendto(packet[:2] + b"\x81\x83" + packet[4:6] + b"\x00" * 6 + packet[12:], self.client_address)


class Proxy(socketserver.StreamRequestHandler):
    def handle(self):
        greeting = self.rfile.read(2)
        if not greeting:  # TCP readiness probe
            return
        version, methods = greeting
        assert version == 5 and 0 in self.rfile.read(methods)
        self.wfile.write(b"\x05\x00")
        version, command, reserved, address_type = self.rfile.read(4)
        assert (version, reserved, address_type) == (5, 0, 3)
        host = self.rfile.read(self.rfile.read(1)[0]).decode()
        port = int.from_bytes(self.rfile.read(2), "big")
        if command == 0xF0:  # Tor's RESOLVE extension
            assert port == 0
            if host == "orchard-fail.invalid":
                self.wfile.write(b"\x05\x04\x00\x01" + b"\x00" * 6)
                return
            address = "127.0.0.2" if host == "orchard-private.invalid" else "93.184.215.14"
            assert host in {"orchard-proxy.invalid", "orchard-proxy.local", "orchard-private.invalid"}, host
            self.wfile.write(b"\x05\x00\x00\x01" + socket.inet_aton(address) + b"\x00\x00")
            return
        assert command == 1
        if host in {"orchard-private.invalid", "orchard-fail.invalid"}:
            Path("/tmp/orchard-bad-connect").touch()
        assert host in {"orchard-proxy.invalid", "orchard-proxy.onion", "orchard-proxy.local"}, host
        assert port in {80, 443}
        self.wfile.write(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x50")
        request = self.rfile.readline()
        if not request:  # TCP port check closes after the SOCKS handshake
            return
        assert request.startswith(b"GET ")
        while self.rfile.readline() not in (b"\r\n", b""):
            pass
        body = b'{"via":"socks"}'
        self.wfile.write(
            b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
            + f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode()
            + body
        )


address = sys.argv[1].strip("[]")
class TCPServer(socketserver.ThreadingTCPServer):
    address_family = socket.AF_INET6 if ":" in address else socket.AF_INET
    allow_reuse_address = True


with socketserver.ThreadingUDPServer((sys.argv[3], 53), DNS) as dns:
    threading.Thread(target=dns.serve_forever, daemon=True).start()
    with TCPServer((address, int(sys.argv[2])), Proxy) as server:
        server.serve_forever()
