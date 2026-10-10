# SPDX-License-Identifier: AGPL-3.0-only
"""Read-only live acceptance check; not part of the offline test suite."""
import argparse
import asyncio
import base64
import hashlib
import json
import os
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def verify(repository, path, ref, output):
    environment = dict(os.environ, MCP_X_ENABLE_WRITES="0", MCP_GITHUB_ENABLE_WRITES="0",
                       MCP_CHATGPT_FILES="0", MCP_CHATGPT_FILE_HOSTS="")
    parameters = StdioServerParameters(
        command="racket",
        args=[str(Path(__file__).resolve().parents[1] / "racket/server.rkt")],
        env=environment,
    )
    async with stdio_client(parameters) as (reader, writer):
        async with ClientSession(reader, writer) as session:
            await session.initialize()
            listed = await session.list_tools()
            assert [tool.name for tool in listed.tools] == ["fetch_x_media", "fetch_github_image"]
            result = await session.call_tool("fetch_github_image", {"repository_full_name": repository, "path": path, "ref": ref})
            if result.isError:
                raise RuntimeError("; ".join(block.text for block in result.content if block.type == "text"))
            images = [block for block in result.content if block.type == "image"]
            assert len(images) == 1, "Expected one MCP image block"
            raw = base64.b64decode(images[0].data, validate=True)
            metadata = json.loads(next(block.text for block in result.content if block.type == "text"))
            assert len(raw) == metadata["size_bytes"]
            assert hashlib.sha1(f"blob {len(raw)}\0".encode() + raw).hexdigest() == metadata["blob_sha"]
            assert images[0].mimeType == metadata["mime_type"]
            # Explicit output only: this utility does not establish a media cache.
            with output.open("xb") as stream:
                stream.write(raw)
            print(json.dumps({"mime_type": images[0].mimeType,
                              "width": metadata["width"], "height": metadata["height"],
                              "size_bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest(),
                              "blob_sha": metadata["blob_sha"], "output": str(output)}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", help="GitHub owner/repository")
    parser.add_argument("path", help="Repository image path")
    parser.add_argument("--ref", default=None, help="Branch, tag, or commit SHA")
    parser.add_argument("output", type=Path, help="New temporary image file for visual inspection")
    options = parser.parse_args()
    asyncio.run(asyncio.wait_for(verify(options.repository, options.path, options.ref, options.output), timeout=90))
