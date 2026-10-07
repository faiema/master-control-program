"""Only the two missing write operations, through official X API v2."""
import base64
import re

from .http import BridgeError, json_request, request
from .media import decode_upload


def x_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{1,30}", value):
        raise BridgeError("Validation: X IDs must be decimal strings.")
    return value


def post_body(text="", media_ids=None, reply_to=None):
    media_ids = [] if media_ids is None else media_ids
    if not isinstance(text, str) or not isinstance(media_ids, list) or len(media_ids) > 4:
        raise BridgeError("Validation: provide text and at most four image media IDs.")
    if not text.strip() and not media_ids:
        raise BridgeError("Validation: a post needs text or media.")
    if len(set(x_id(value) for value in media_ids)) != len(media_ids):
        raise BridgeError("Validation: duplicate media IDs.")
    result = {}
    if text:
        result["text"] = text
    if media_ids:
        result["media"] = {"media_ids": media_ids}
    if reply_to is not None:
        result["reply"] = {"in_reply_to_tweet_id": x_id(reply_to)}
    return result


class XAPI:
    def __init__(self, token_provider, *, writes_enabled=False, transport=request):
        self.token_provider = token_provider
        self.writes_enabled = writes_enabled
        self.transport = transport

    def _write(self, path, payload):
        if not self.writes_enabled:
            raise BridgeError("Configuration: writes are disabled. Set MCP_X_ENABLE_WRITES=1 to expose write tools; publish only on explicit user request.")
        value = json_request("https://api.x.com/2/" + path, method="POST",
                             headers={"Authorization": "Bearer " + self.token_provider()},
                             payload=payload, transport=self.transport)
        data = value.get("data")
        if not isinstance(data, dict):
            raise BridgeError("X API: missing response data. A write may have succeeded; check X before retrying.")
        try:
            x_id(data.get("id"))
        except BridgeError:
            raise BridgeError("X API: missing or invalid response ID. Check X before retrying this write.") from None
        return data

    def upload(self, image_base64):
        raw, metadata = decode_upload(image_base64)
        data = self._write("media/upload", {"media": base64.b64encode(raw).decode(), "media_category": "tweet_image"})
        processing = data.get("processing_info")
        if processing is not None and (not isinstance(processing, dict) or processing.get("state") != "succeeded"):
            raise BridgeError("X upload: media is not ready. Asynchronous processing is unsupported; do not attach it yet.")
        return {"media_id": data["id"], "media_key": data.get("media_key"),
                "expires_after_secs": data.get("expires_after_secs"), **metadata}

    def create_post(self, text="", media_ids=None, reply_to=None):
        data = self._write("tweets", post_body(text, media_ids, reply_to))
        return {"id": data["id"], "url": "https://x.com/i/status/" + data["id"]}
