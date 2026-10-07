import base64
from io import BytesIO
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlsplit

from PIL import Image

from master_control_program import auth
from master_control_program.http import BridgeError, json_request, request
from master_control_program.media import decode_upload, fetch_media, inspect_image, media_url
from master_control_program.tools import fetch_result, invoke
from master_control_program.x_api import XAPI, post_body


def png():
    out = BytesIO()
    Image.new("RGB", (3, 2), "red").save(out, "PNG")
    return out.getvalue()


class MediaTests(unittest.TestCase):
    def test_original_image_is_returned_as_mcp_image_content(self):
        raw = png()
        result = fetch_result("https://pbs.twimg.com/media/synthetic.png", "123", "3_456",
                              transport=lambda *a, **k: ({"Content-Type": "image/png"}, raw))
        image = result["content"][1]
        self.assertEqual(image["type"], "image")
        self.assertEqual(image["mimeType"], "image/png")
        self.assertEqual(base64.b64decode(image["data"]), raw)
        metadata = json.loads(result["content"][0]["text"])
        self.assertEqual((metadata["width"], metadata["height"]), (3, 2))
        self.assertEqual(metadata["source_post_id"], "123")

    def test_rejects_ssrf_urls(self):
        for url in ["http://pbs.twimg.com/media/a.png", "https://pbs.twimg.com.evil/media/a.png",
                    "https://pbs.twimg.com@localhost/media/a.png", "file:///etc/passwd",
                    "https://pbs.twimg.com:443/media/a.png", "https://pbs.twimg.com/media/../a.png",
                    "https://pbs.twimg.com/media/a.png?token=secret", "https://pbs.twimg.com/media/a.png#x",
                    "https://pbs.twimg.com/media/a?format=jpg&format=png", "https://127.0.0.1/a"]:
            with self.subTest(url=url), self.assertRaises(BridgeError):
                media_url(url)

    def test_accepts_cdn_query(self):
        url = "https://pbs.twimg.com/media/a?format=jpg&name=orig"
        self.assertEqual(media_url(url), url)

    def test_mime_mismatch_and_invalid_bytes(self):
        for data, mime in [(png(), "image/jpeg"), (b"not an image", "image/png"), (png()[:24], "image/png")]:
            with self.subTest(mime=mime), self.assertRaises(BridgeError):
                inspect_image(data, mime)

    def test_unsupported_gif(self):
        out = BytesIO()
        Image.new("RGB", (2, 2)).save(out, "GIF")
        with self.assertRaises(BridgeError):
            inspect_image(out.getvalue())

    def test_missing_content_type(self):
        with self.assertRaises(BridgeError):
            fetch_media("https://pbs.twimg.com/media/a.png", transport=lambda *a, **k: ({}, png()))

    def test_invalid_base64_and_size_limit(self):
        for value in ["not base64!", "data:image/png;base64,AA==", "A" * (7 * 1024 * 1024)]:
            with self.assertRaises(BridgeError):
                decode_upload(value)


class APITests(unittest.TestCase):
    def test_http_identifies_application_to_cdn(self):
        with patch("master_control_program.http.build_opener") as opener:
            response = opener.return_value.open.return_value.__enter__.return_value
            response.read.return_value = b"image"
            response.headers = {"Content-Type": "image/jpeg"}
            self.assertEqual(request("https://pbs.twimg.com/media/synthetic.jpg")[1], b"image")
            sent = opener.return_value.open.call_args.args[0]
            self.assertEqual(sent.get_header("User-agent"), "master-control-program/0.1")

    def test_post_body(self):
        self.assertEqual(post_body("hello", ["123"], "456"), {
            "text": "hello", "media": {"media_ids": ["123"]}, "reply": {"in_reply_to_tweet_id": "456"}})
        self.assertEqual(post_body("", ["123"]), {"media": {"media_ids": ["123"]}})

    def test_invalid_posts(self):
        for args in [("", None, None), ("hi", [123], None), ("hi", ["1"] * 2, None),
                     ("hi", None, "bad"), ("hi", [str(i) for i in range(5)], None)]:
            with self.subTest(args=args), self.assertRaises(BridgeError):
                post_body(*args)

    def test_write_gate_precedes_auth_and_network(self):
        def forbidden(*args, **kwargs):
            self.fail("must not access auth or network")
        with self.assertRaises(BridgeError):
            XAPI(forbidden, transport=forbidden).create_post("hi")

    def test_upload_and_post_requests(self):
        calls = []
        def transport(url, **kwargs):
            calls.append((url, kwargs))
            return {}, b'{"data":{"id":"123","expires_after_secs":86400}}'
        api = XAPI(lambda: "synthetic-token", writes_enabled=True, transport=transport)
        encoded = base64.b64encode(png()).decode()
        self.assertEqual(api.upload(encoded)["media_id"], "123")
        api.create_post("hi", ["123"], "456")
        self.assertEqual(calls[0][0], "https://api.x.com/2/media/upload")
        self.assertEqual(json.loads(calls[0][1]["body"]), {"media": encoded, "media_category": "tweet_image"})
        self.assertEqual(json.loads(calls[1][1]["body"])["reply"]["in_reply_to_tweet_id"], "456")
        self.assertEqual(calls[1][1]["headers"]["Authorization"], "Bearer synthetic-token")

    def test_schema_errors_and_partial_errors(self):
        for raw in [b'[]', b'not json', b'{"data":{},"errors":[{"detail":"secret"}]}']:
            with self.assertRaises(BridgeError) as ctx:
                json_request("https://api.x.com/2/tweets", transport=lambda *a, **k: ({}, raw))
            self.assertNotIn("secret", str(ctx.exception))

    def test_invalid_write_response_and_processing(self):
        for raw in [b'{"data":{"id":123}}', b'{"data":{"id":"123","processing_info":{"state":"pending"}}}']:
            api = XAPI(lambda: "fake", writes_enabled=True, transport=lambda *a, **k: ({}, raw))
            with self.assertRaises(BridgeError):
                api.upload(base64.b64encode(png()).decode())

    def test_http_auth_error_is_safe_and_not_retried(self):
        for status in [401, 403, 429, 500, 302]:
            with patch("master_control_program.http.build_opener") as opener:
                opener.return_value.open.side_effect = HTTPError("https://example.invalid/?secret", status, "secret", {}, None)
                with self.assertRaises(BridgeError) as ctx:
                    request("https://api.x.com/2/tweets", method="POST")
                self.assertIn(str(status), str(ctx.exception))
                self.assertNotIn("secret", str(ctx.exception))
                self.assertEqual(opener.return_value.open.call_count, 1)

    def test_tool_errors_are_marked_and_sanitized(self):
        def fail():
            raise RuntimeError("secret")
        result = invoke(fail)
        self.assertTrue(result["isError"])
        self.assertNotIn("secret", str(result))


class AuthTests(unittest.TestCase):
    def test_pkce_and_state_are_random(self):
        url, state, verifier = auth.authorization("fake-client")
        query = parse_qs(urlsplit(url).query)
        self.assertEqual(query["code_challenge_method"], ["S256"])
        self.assertNotEqual(query["code_challenge"], [verifier])
        self.assertNotEqual(auth.authorization("fake-client")[1], state)
        self.assertNotIn("offline.access", query["scope"][0])

    def test_token_permissions_expiry_and_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "token.json"
            auth.save_token({"access_token": "synthetic-token", "expires_at": 9999999999}, path)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with patch.dict(os.environ, {"MCP_X_TOKEN_FILE": str(path)}, clear=True):
                self.assertEqual(auth.access_token(), "synthetic-token")
                auth.save_token({"access_token": "synthetic-token", "expires_at": 1}, path)
                with self.assertRaises(BridgeError):
                    auth.access_token()
                path.chmod(0o644)
                with self.assertRaises(BridgeError):
                    auth.access_token()

    def test_exchange_validates_scopes(self):
        response = {"access_token": "synthetic", "expires_in": 7200, "token_type": "bearer", "scope": auth.SCOPES}
        def transport(url, **kwargs):
            self.assertEqual(parse_qs(kwargs["body"].decode())["code_verifier"], ["verifier"])
            return {}, json.dumps(response).encode()
        self.assertEqual(auth.exchange("code", "verifier", "client", transport=transport)["access_token"], "synthetic")
        response["scope"] = "tweet.read"
        with self.assertRaises(BridgeError):
            auth.exchange("code", "verifier", "client", transport=transport)


if __name__ == "__main__":
    unittest.main()
