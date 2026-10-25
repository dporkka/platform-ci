"""Offline contract tests for the private GitHub CONNECT egress proxy."""
import importlib.util
import ipaddress
import pathlib
import socket
import threading
import unittest
from unittest import mock

SRC = pathlib.Path(__file__).with_name("github_connect.py")
SPEC = importlib.util.spec_from_file_location("github_connect", SRC)
proxy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(proxy)


class ProxyPolicyTests(unittest.TestCase):
    def test_woodpecker_container_bridge_and_exact_rootless_host_are_allowed(self):
        for address in ("172.17.0.17", "172.18.0.15", "172.31.255.1", "82.197.67.39"):
            self.assertTrue(any(ipaddress.ip_address(address) in subnet for subnet in proxy.NETWORKS))
        for address in ("127.0.0.1", "0.0.0.0", "8.8.8.8", "82.197.67.38",
                        "82.197.67.40", "10.88.0.10", "172.16.0.9"):
            self.assertFalse(any(ipaddress.ip_address(address) in subnet for subnet in proxy.NETWORKS))

    def test_allowed_destinations_are_explicit_and_only_https(self):
        self.assertIn("github.com", proxy.ALLOWED)
        self.assertIn("dl-cdn.alpinelinux.org", proxy.ALLOWED)
        self.assertNotIn("*", proxy.ALLOWED)
        self.assertNotIn("example.com", proxy.ALLOWED)
        self.assertIsNotNone(proxy.CONNECT_LINE.fullmatch(b"CONNECT github.com:443 HTTP/1.1\r\n"))
        self.assertIsNone(proxy.CONNECT_LINE.fullmatch(b"CONNECT github.com:80 HTTP/1.1\r\n"))

    def test_go_module_hosts_use_restricted_https_connect(self):
        # Go 1.26/1.27 CI resolves modules through the module proxy and
        # validates integrity through the checksum database. No wildcard is
        # necessary to permit those two trusted origins.
        for hostname in ("proxy.golang.org", "sum.golang.org"):
            result, outbound = self._request(
                f"CONNECT {hostname}:443 HTTP/1.1\r\nHost: {hostname}\r\n\r\n".encode()
            )
            self.assertIn(b"502 Bad Gateway", result, hostname)
            self.assertEqual(outbound, 1, hostname)
        result, outbound = self._request(
            b"CONNECT proxy.golang.org.evil.example:443 HTTP/1.1\r\n"
            b"Host: proxy.golang.org.evil.example\r\n\r\n"
        )
        self.assertIn(b"403 Forbidden", result)
        self.assertEqual(outbound, 0)

    def test_service_listens_only_on_private_bridge_addresses(self):
        source = SRC.read_text()
        self.assertIn('Server(("172.18.0.1", 3188)', source)
        self.assertIn('Server(("172.17.0.1", 3188)', source)
        self.assertNotIn('Server(("0.0.0.0", 3188)', source)

    def _request(self, request: bytes, permit_local=True):
        permitted = (ipaddress.ip_network("127.0.0.1/32"),) if permit_local else proxy.NETWORKS
        with mock.patch.object(proxy, "NETWORKS", permitted), \
             mock.patch.object(proxy.socket, "create_connection", side_effect=OSError("blocked")) as outbound:
            with proxy.Server(("127.0.0.1", 0), proxy.Handler) as server:
                worker = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
                worker.start()
                try:
                    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as client:
                        client.settimeout(2)
                        client.connect(server.server_address)
                        client.sendall(request)
                        response = client.recv(2048)
                finally:
                    server.shutdown()
                    worker.join(timeout=2)
            return response, outbound.call_count

    def test_unknown_connect_host_is_denied_without_upstream_call(self):
        result, outbound = self._request(b"CONNECT example.com:443 HTTP/1.1\r\nHost: example.com\r\n\r\n")
        self.assertIn(b"403 Forbidden", result)
        self.assertEqual(outbound, 0)

    def test_wrong_port_and_method_are_denied(self):
        for payload in (
            b"CONNECT github.com:80 HTTP/1.1\r\nHost: github.com\r\n\r\n",
            b"GET / HTTP/1.1\r\nHost: github.com\r\n\r\n",
        ):
            result, outbound = self._request(payload)
            self.assertIn(b"403 Forbidden", result)
            self.assertEqual(outbound, 0)

    def test_allowed_host_requires_working_upstream(self):
        result, outbound = self._request(b"CONNECT github.com:443 HTTP/1.1\r\nHost: github.com\r\n\r\n")
        self.assertIn(b"502 Bad Gateway", result)
        self.assertEqual(outbound, 1)

    def test_untrusted_source_is_rejected_before_handshake(self):
        result, outbound = self._request(b"CONNECT github.com:443 HTTP/1.1\r\nHost: github.com\r\n\r\n", permit_local=False)
        self.assertEqual(result, b"")
        self.assertEqual(outbound, 0)


if __name__ == "__main__":
    unittest.main()
