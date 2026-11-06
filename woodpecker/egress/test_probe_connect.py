"""Offline tests for the bounded, credential-free CONNECT policy probe."""
import unittest
from unittest import mock
import probe_connect


class FakeSocket:
    def __init__(self, response=b"HTTP/1.1 200 Connection Established\r\n\r\n"):
        self.response = response
        self.sent = b""
        self.closed = False
        self.timeout = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.closed = True

    def settimeout(self, timeout):
        self.timeout = timeout

    def sendall(self, data):
        self.sent += data

    def recv(self, _):
        return self.response


class ProbeTests(unittest.TestCase):
    def test_only_fixed_connect_handshake_is_sent(self):
        fake = FakeSocket()
        with mock.patch.object(probe_connect.socket, "create_connection", return_value=fake) as dial:
            result = probe_connect.probe_connect("172.18.0.1", 3188, "registry.opentofu.org", 443, 2)
        self.assertEqual(result, 200)
        dial.assert_called_once_with(("172.18.0.1", 3188), timeout=2)
        self.assertEqual(fake.sent, b"CONNECT registry.opentofu.org:443 HTTP/1.1\r\nHost: registry.opentofu.org:443\r\n\r\n")
        self.assertTrue(fake.closed)

    def test_split_http_status_line_is_reassembled(self):
        fake = FakeSocket()
        chunks = iter((b"HTT", b"P/1.1 200 Connection Established\r\n"))
        fake.recv = lambda _: next(chunks)
        with mock.patch.object(probe_connect.socket, "create_connection", return_value=fake):
            self.assertEqual(
                probe_connect.probe_connect("172.18.0.1", 3188, "github.com", 443, 2),
                200,
            )

    def test_unterminated_response_line_fails_closed(self):
        fake = FakeSocket(b"HTTP/1.1 200 Connection Established")
        with mock.patch.object(probe_connect.socket, "create_connection", return_value=fake):
            self.assertIsNone(
                probe_connect.probe_connect("172.17.0.1", 3188, "github.com", 443, 2)
            )

    def test_malformed_reply_does_not_count_as_success(self):
        fake = FakeSocket(b"HTTP/1.1 2003 Not-A-Status\r\n")
        with mock.patch.object(probe_connect.socket, "create_connection", return_value=fake):
            self.assertIsNone(probe_connect.probe_connect("172.17.0.1", 3188, "github.com", 443, 2))

    def test_positive_and_negative_policy_checks(self):
        expected = {
            ("registry.opentofu.org", 443): 200,
            ("registry.terraform.io", 443): 200,
            ("github.com", 443): 200,
            ("registry.opentofu.org.attacker.example", 443): 403,
            ("registry.opentofu.org", 80): 403,
        }
        def fake_probe(_host, _port, target, target_port, _timeout):
            return expected[(target, target_port)]
        with mock.patch.object(probe_connect, "probe_connect", side_effect=fake_probe) as probe:
            passed, statuses = probe_connect.check_policy("172.18.0.1", 3188, 2)
        self.assertTrue(passed)
        self.assertEqual(len(statuses), 5)
        self.assertEqual(probe.call_count, 5)

    def test_blocked_provider_fails_policy_without_weakening_negative_checks(self):
        result = {
            ("registry.opentofu.org", 443): 403,
            ("registry.terraform.io", 443): 403,
            ("github.com", 443): 200,
            ("registry.opentofu.org.attacker.example", 443): 403,
            ("registry.opentofu.org", 80): 403,
        }
        with mock.patch.object(probe_connect, "probe_connect", side_effect=lambda h, p, target, port, t: result[(target, port)]):
            passed, statuses = probe_connect.check_policy("172.18.0.1", 3188, 2)
        self.assertFalse(passed)
        self.assertEqual(statuses[0][2], 403)

    def test_network_or_502_failure_is_not_accepted(self):
        with mock.patch.object(probe_connect, "probe_connect", return_value=502):
            passed, _ = probe_connect.check_policy("172.18.0.1", 3188, 2)
        self.assertFalse(passed)

if __name__ == "__main__":
    unittest.main()
