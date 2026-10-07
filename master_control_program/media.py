"""Validate image content without converting or recompressing it."""
import base64
from io import BytesIO
import re
from urllib.parse import urlsplit, parse_qsl
import warnings

from PIL import Image, UnidentifiedImageError

from .http import BridgeError, request

MAX_IMAGE_BYTES = 5 * 1024 * 1024
MIME_TYPES = {"JPEG": "image/jpeg", "PNG": "image/png", "WEBP": "image/webp"}


def media_url(value):
    try:
        url = urlsplit(value)
        valid = (url.scheme == "https" and url.netloc == "pbs.twimg.com"
                 and re.fullmatch(r"/media/[A-Za-z0-9_-]+(?:\.(?:jpg|jpeg|png|webp))?", url.path)
                 and not url.fragment)
        params = parse_qsl(url.query, keep_blank_values=True, strict_parsing=True)
        valid = valid and len({k for k, _ in params}) == len(params)
        valid = valid and all((k == "format" and v in {"jpg", "jpeg", "png", "webp"})
                                 or (k == "name" and v in {"orig", "large", "medium", "small", "thumb", "900x900", "4096x4096"})
                                 for k, v in params)
    except (ValueError, TypeError):
        valid = False
    if not valid:
        raise BridgeError("Validation: use a direct HTTPS pbs.twimg.com/media/ image URL, without credentials or custom query parameters.")
    return value


def inspect_image(data, declared_mime=None):
    if not data or len(data) > MAX_IMAGE_BYTES:
        raise BridgeError("Media: image must be nonempty and at most 5 MiB (local limit).")
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(BytesIO(data)) as image:
                mime = MIME_TYPES.get(image.format)
                if not mime or getattr(image, "is_animated", False):
                    raise BridgeError("Media: only static JPEG, PNG, and WebP images are supported.")
                width, height = image.size
                if width * height > 40_000_000:
                    raise BridgeError("Media: image exceeds the local 40 megapixel limit.")
                image.verify()
    except (UnidentifiedImageError, OSError, ValueError, SyntaxError, Image.DecompressionBombError, Image.DecompressionBombWarning):
        raise BridgeError("Media: invalid, truncated, or unsafe image content.") from None
    if declared_mime and declared_mime.split(";", 1)[0].strip().lower() != mime:
        raise BridgeError("Media: Content-Type does not match the image bytes.")
    return {"mime_type": mime, "width": width, "height": height, "size_bytes": len(data)}


def fetch_media(url, *, post_id=None, media_key=None, transport=request):
    media_url(url)
    headers, data = transport(url, limit=MAX_IMAGE_BYTES)
    mime = next((v for k, v in headers.items() if k.lower() == "content-type"), None)
    if not mime:
        raise BridgeError("Media: server omitted Content-Type.")
    metadata = inspect_image(data, mime)
    metadata.update(source_url=url, source_post_id=post_id, media_key=media_key,
                    provenance="URL supplied by caller; post ID and media key are caller-provided")
    return metadata, {"type": "image", "data": base64.b64encode(data).decode(), "mimeType": metadata["mime_type"]}


def decode_upload(value):
    if len(value) > 4 * ((MAX_IMAGE_BYTES + 2) // 3):
        raise BridgeError("Validation: base64 image exceeds the local 5 MiB limit.")
    try:
        data = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        raise BridgeError("Validation: expected raw base64 image bytes, not a data URL.") from None
    metadata = inspect_image(data)
    if metadata["mime_type"] == "image/webp":
        raise BridgeError("Upload: use JPEG or PNG; WebP upload is not supported by this adapter.")
    return data, metadata
