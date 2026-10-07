"""Plain MCP content dictionaries keep media behavior testable without transport."""
import json
from .http import BridgeError
from .media import fetch_media


def text_result(value):
    return {"content": [{"type": "text", "text": json.dumps(value)}]}


def invoke(operation):
    try:
        return operation()
    except BridgeError as error:
        return {"isError": True, "content": [{"type": "text", "text": str(error)}]}
    except Exception:
        # Do not let SDK exception reporting expose credentials in unexpected errors.
        return {"isError": True, "content": [{"type": "text", "text": "Local processing: unexpected failure. Inspect the implementation with synthetic inputs before retrying; a write may have succeeded."}]}


def fetch_result(url, post_id=None, media_key=None, **kwargs):
    metadata, image = fetch_media(url, post_id=post_id, media_key=media_key, **kwargs)
    return {"content": [{"type": "text", "text": json.dumps(metadata)}, image]}
