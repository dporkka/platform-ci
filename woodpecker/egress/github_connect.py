#!/usr/bin/env python3
"""Private, CONNECT-only GitHub egress bridge for CI Docker containers.

No TLS interception, no request/body logging, no arbitrary outbound targets.
"""
import ipaddress
import re
import select
import socket
import socketserver
import threading

# Docker allocates isolated Woodpecker workflow bridges across 172.17–172.31/16.
# Rootless Podman bridge requests are NATed to this VPS host address when
# reaching the Docker-private proxy listener. The listener stays on 172.x only.
# Destination allowlist and CONNECT-only behavior are unchanged.
NETWORKS = tuple(ipaddress.ip_network(f"172.{octet}.0.0/16") for octet in range(17, 32)) + (
    ipaddress.ip_network("82.197.67.39/32"),
)
ALLOWED = frozenset((
    "api.github.com", "github.com", "codeload.github.com",
    "raw.githubusercontent.com", "release-assets.githubusercontent.com",
    "registry.npmjs.org", "auth.docker.io", "registry-1.docker.io",
    "static.rust-lang.org", "dl-cdn.alpinelinux.org",
    "index.crates.io", "static.crates.io",
    "fonts.googleapis.com", "fonts.gstatic.com", "mirror.gcr.io",
    # Exact Go module and integrity endpoints; no wildcard or arbitrary hosts.
    "proxy.golang.org", "sum.golang.org",
))
CONNECT_LINE = re.compile(rb"CONNECT ([A-Za-z0-9.-]+):443 HTTP/1\.[01]\r?\n")

class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        client = self.request
        client.settimeout(6)
        try:
            if not any(ipaddress.ip_address(self.client_address[0]) in network for network in NETWORKS):
                return
            data = b""
            while b"\r\n\r\n" not in data and len(data) < 8192:
                chunk = client.recv(min(2048, 8192 - len(data)))
                if not chunk:
                    return
                data += chunk
            if b"\r\n\r\n" not in data:
                client.sendall(b"HTTP/1.1 431 Request Header Fields Too Large\r\n\r\n")
                return
            match = CONNECT_LINE.fullmatch(data.split(b"\r\n", 1)[0] + b"\r\n")
            if not match or match.group(1).decode("ascii").lower() not in ALLOWED:
                client.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
                return
            host = match.group(1).decode("ascii").lower()
            try:
                upstream = socket.create_connection((host, 443), timeout=10)
            except OSError:
                client.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
                return
            with upstream:
                client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                # Never inspect, log, or terminate end-to-end GitHub TLS.
                client.settimeout(None)
                upstream.settimeout(None)
                for fd in (client, upstream):
                    fd.setblocking(False)
                while True:
                    readable, _, _ = select.select((client, upstream), (), (), 90)
                    if not readable:
                        break
                    for sock in readable:
                        try:
                            buf = sock.recv(65536)
                            if not buf:
                                return
                            other = upstream if sock is client else client
                            other.setblocking(True)
                            other.sendall(buf)
                            other.setblocking(False)
                        except (OSError, ValueError):
                            return
        except (OSError, ValueError):
            pass

class Server(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = 64

if __name__ == "__main__":
    # Separate private bridge listeners: server and checkout/build containers.
    # Never bind the public interface or permit arbitrary TCP destinations.
    with Server(("172.18.0.1", 3188), Handler) as server, Server(("172.17.0.1", 3188), Handler) as checkout:
        threading.Thread(target=checkout.serve_forever, kwargs={"poll_interval": 0.5}, daemon=True).start()
        server.serve_forever(poll_interval=0.5)
