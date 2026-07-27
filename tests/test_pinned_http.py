#!/usr/bin/env python3

import io
import socket
import sys
import unittest
import urllib.error
from email.message import Message
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

import pinned_http  # noqa: E402


def address_answer(address):
    family = socket.AF_INET6 if ":" in address else socket.AF_INET
    return (family, socket.SOCK_STREAM, 6, "", (address, 443))


class FakeResponse(io.BytesIO):
    def __init__(self, payload=b"ok"):
        super().__init__(payload)
        self.headers = Message()

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()


class PinnedHTTPTests(unittest.TestCase):
    def test_resolution_rejects_a_mixed_public_and_private_answer_set(self):
        resolver = mock.Mock(
            return_value=[address_answer("8.8.8.8"), address_answer("127.0.0.1")]
        )

        with self.assertRaisesRegex(
            pinned_http.PinnedHTTPPolicyError,
            "not public",
        ) as raised:
            pinned_http.resolve_public_https_url(
                "https://downloads.example/file",
                resolver=resolver,
            )

        self.assertEqual(raised.exception.code, "unsafe_address")
        self.assertEqual(raised.exception.address, "127.0.0.1")

    def test_redirect_is_resolved_and_pinned_again_before_connecting(self):
        resolutions = {
            "first.example": [address_answer("8.8.8.8")],
            "second.example": [address_answer("1.1.1.1")],
        }
        resolved_hosts = []

        def resolver(host, _port, **_kwargs):
            resolved_hosts.append(host)
            return resolutions[host]

        opened = []

        class Opener:
            def __init__(self, addresses):
                self.addresses = tuple(addresses)

            def open(self, request, timeout):
                opened.append((request.full_url, request.host, self.addresses, timeout))
                if request.host == "first.example":
                    headers = Message()
                    headers["Location"] = "https://second.example/artifact"
                    raise urllib.error.HTTPError(
                        request.full_url,
                        302,
                        "redirect",
                        headers,
                        io.BytesIO(),
                    )
                return FakeResponse()

        with mock.patch.object(
            pinned_http,
            "build_pinned_opener",
            side_effect=lambda addresses, context=None: Opener(addresses),
        ):
            response, final_url, addresses, chain = pinned_http.open_public_https(
                "https://first.example/start",
                resolver=resolver,
            )
            response.close()

        self.assertEqual(resolved_hosts, ["first.example", "second.example"])
        self.assertEqual(opened[0][1:3], ("first.example", ("8.8.8.8",)))
        self.assertEqual(opened[1][1:3], ("second.example", ("1.1.1.1",)))
        self.assertEqual(final_url, "https://second.example/artifact")
        self.assertEqual(addresses, ("1.1.1.1",))
        self.assertEqual(
            chain,
            (
                "https://first.example/start",
                "https://second.example/artifact",
            ),
        )

    def test_unsafe_redirect_is_rejected_before_second_connection(self):
        def resolver(host, _port, **_kwargs):
            if host == "first.example":
                return [address_answer("8.8.8.8")]
            return [address_answer("10.0.0.4")]

        class RedirectingOpener:
            def open(self, request, timeout=None):
                del timeout
                headers = Message()
                headers["Location"] = "https://internal.example/secret"
                raise urllib.error.HTTPError(
                    request.full_url,
                    302,
                    "redirect",
                    headers,
                    io.BytesIO(),
                )

        opener_factory = mock.Mock(return_value=RedirectingOpener())
        with mock.patch.object(pinned_http, "build_pinned_opener", opener_factory):
            with self.assertRaises(pinned_http.PinnedHTTPPolicyError) as raised:
                pinned_http.open_public_https(
                    "https://first.example/start",
                    resolver=resolver,
                )

        self.assertEqual(raised.exception.code, "unsafe_address")
        self.assertEqual(opener_factory.call_count, 1)

    def test_cross_origin_redirect_does_not_forward_credential_headers(self):
        opened_headers = []

        class Opener:
            def open(self, request, timeout=None):
                del timeout
                opened_headers.append(dict(request.header_items()))
                if request.host == "first.example":
                    headers = Message()
                    headers["Location"] = "https://second.example/artifact"
                    raise urllib.error.HTTPError(
                        request.full_url,
                        302,
                        "redirect",
                        headers,
                        io.BytesIO(),
                    )
                return FakeResponse()

        with mock.patch.object(
            pinned_http,
            "build_pinned_opener",
            return_value=Opener(),
        ):
            response, *_details = pinned_http.open_validated_url(
                "https://first.example/start",
                validate_url=lambda candidate: (candidate, ("8.8.8.8",)),
                headers={
                    "Authorization": "Bearer secret",
                    "x-api-key": "secret",
                    "api-subscription-key": "secret",
                    "Cookie": "session=secret",
                    "Accept": "application/json",
                },
            )
            response.close()

        first = {key.lower(): value for key, value in opened_headers[0].items()}
        second = {key.lower(): value for key, value in opened_headers[1].items()}
        self.assertIn("authorization", first)
        self.assertIn("x-api-key", first)
        self.assertNotIn("authorization", second)
        self.assertNotIn("x-api-key", second)
        self.assertNotIn("api-subscription-key", second)
        self.assertNotIn("cookie", second)
        self.assertEqual(second["accept"], "application/json")

    def test_same_origin_redirect_retains_credential_headers(self):
        seen_authorization = []

        class Opener:
            def open(self, request, timeout=None):
                del timeout
                seen_authorization.append(request.get_header("Authorization"))
                if request.full_url.endswith("/start"):
                    headers = Message()
                    headers["Location"] = "/artifact"
                    raise urllib.error.HTTPError(
                        request.full_url,
                        302,
                        "redirect",
                        headers,
                        io.BytesIO(),
                    )
                return FakeResponse()

        with mock.patch.object(
            pinned_http,
            "build_pinned_opener",
            return_value=Opener(),
        ):
            response, *_details = pinned_http.open_validated_url(
                "https://first.example/start",
                validate_url=lambda candidate: (candidate, ("8.8.8.8",)),
                headers={"Authorization": "Bearer secret"},
            )
            response.close()

        self.assertEqual(seen_authorization, ["Bearer secret", "Bearer secret"])

    def test_https_connection_pins_ip_but_preserves_hostname_for_sni(self):
        raw_socket = mock.Mock()
        context = mock.Mock()
        wrapped_socket = mock.sentinel.wrapped_socket
        context.wrap_socket.return_value = wrapped_socket
        connection = pinned_http.PinnedHTTPSConnection(
            "downloads.example:8443",
            context=context,
            resolved_addresses=["8.8.8.8"],
        )

        with mock.patch.object(pinned_http, "_pinned_socket", return_value=raw_socket) as pin:
            connection.connect()

        pin.assert_called_once_with(("8.8.8.8",), 8443, mock.ANY)
        context.wrap_socket.assert_called_once_with(
            raw_socket,
            server_hostname="downloads.example",
        )
        self.assertIs(connection.sock, wrapped_socket)


if __name__ == "__main__":
    unittest.main()
