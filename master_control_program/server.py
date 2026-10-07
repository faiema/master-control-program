"""Local stdio adapter; no unauthenticated public HTTP listener."""
import os

from mcp.server.fastmcp import FastMCP
from mcp.types import CallToolResult, ToolAnnotations

from .auth import access_token
from .tools import fetch_result, invoke, text_result
from .x_api import XAPI


def build_server():
    server = FastMCP("master-control-program")
    writes_enabled = os.environ.get("MCP_X_ENABLE_WRITES") == "1"
    api = XAPI(access_token, writes_enabled=writes_enabled)

    @server.tool(structured_output=False, annotations=ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=True))
    def fetch_x_media(url: str, post_id: str | None = None, media_key: str | None = None) -> CallToolResult:
        """See an X image: pass a pbs.twimg.com/media URL from the official X MCP. Returns original image content and provenance. Optional IDs are caller-provided metadata, not verified associations."""
        return CallToolResult(**invoke(lambda: fetch_result(url, post_id, media_key)))

    if writes_enabled:
        write_annotations = ToolAnnotations(readOnlyHint=False, destructiveHint=True, idempotentHint=False, openWorldHint=True)

        @server.tool(structured_output=False, annotations=write_annotations)
        def upload_x_media(image_base64: str) -> CallToolResult:
            """WRITE: upload a static JPEG or PNG (raw base64, max 5 MiB) to X. Only on explicit user request. Returns an expiring media ID; does not publish a post. Never retry blindly."""
            return CallToolResult(**invoke(lambda: text_result(api.upload(image_base64))))

        @server.tool(structured_output=False, annotations=write_annotations)
        def create_x_post(text: str = "", media_ids: list[str] | None = None, reply_to: str | None = None) -> CallToolResult:
            """WRITE: publish a real X post, optionally attaching uploaded image IDs or replying. Only when the user explicitly asks to publish. Never automatically retry a failed or timed-out call."""
            return CallToolResult(**invoke(lambda: text_result(api.create_post(text, media_ids, reply_to))))

    return server


def main():
    build_server().run(transport="stdio")


if __name__ == "__main__":
    main()
