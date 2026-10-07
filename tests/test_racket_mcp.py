"""Cross-language contracts through the real Python MCP client; no live network."""
import asyncio
import base64
import importlib.util
import json
import os
from pathlib import Path
import shutil
import unittest

ROOT = Path(__file__).resolve().parents[1]
IMAGES = json.loads((ROOT / "tests/fixtures/images.json").read_text())
CONTRACTS = json.loads((ROOT / "tests/fixtures/contracts.json").read_text())


def png():
    return base64.b64decode(IMAGES["png"])


@unittest.skipUnless(shutil.which("racket") and importlib.util.find_spec("mcp"), "Racket and MCP SDK required")
class RacketMCPTests(unittest.IsolatedAsyncioTestCase):
    async def with_server(self, callback, *, fixture=False, writes=False):
        from mcp import ClientSession, StdioServerParameters
        from mcp.client.stdio import stdio_client

        async def exercise():
            parameters = StdioServerParameters(
                command="racket",
                args=[str(ROOT / ("tests/racket-stdio-fixture.rkt" if fixture else "racket/server.rkt"))],
                env=dict(os.environ, MCP_X_ENABLE_WRITES="1" if writes else "0"),
            )
            async with stdio_client(parameters) as (reader, writer):
                async with ClientSession(reader, writer) as session:
                    initialized = await session.initialize()
                    self.assertEqual(initialized.serverInfo.name, "master-control-program-racket")
                    self.assertEqual(initialized.protocolVersion, "2025-11-25")
                    await callback(session)

        await asyncio.wait_for(exercise(), timeout=20)

    async def test_production_handshake_read_only_and_validation(self):
        async def check(session):
            await session.send_ping()
            tools = (await session.list_tools()).tools
            self.assertEqual([tool.name for tool in tools], ["fetch_x_media"])
            self.assertTrue(tools[0].annotations.readOnlyHint)
            result = await session.call_tool("fetch_x_media", {"url": "https://localhost/secret"})
            self.assertTrue(result.isError)
            self.assertIn("Validation:", result.content[0].text)

        await self.with_server(check)

    async def test_actual_image_block_matches_python_prototype(self):
        async def check(session):
            url = "https://pbs.twimg.com/media/synthetic.png"
            result = await session.call_tool("fetch_x_media", {"url": url, "post_id": "123", "media_key": "3_456"})
            self.assertFalse(result.isError)
            self.assertEqual(json.loads(result.content[0].text), CONTRACTS["fetch_metadata"])
            self.assertEqual(result.content[1].type, "image")
            self.assertEqual(result.content[1].mimeType, "image/png")
            self.assertEqual(base64.b64decode(result.content[1].data), png())

        await self.with_server(check, fixture=True)

    async def test_mocked_write_contracts_and_annotations(self):
        async def check(session):
            tools = {tool.name: tool for tool in (await session.list_tools()).tools}
            self.assertEqual(set(tools), {"fetch_x_media", "upload_x_media", "create_x_post"})
            for name in ["upload_x_media", "create_x_post"]:
                self.assertFalse(tools[name].annotations.readOnlyHint)
                self.assertFalse(tools[name].annotations.idempotentHint)
                self.assertTrue(tools[name].annotations.destructiveHint)
            uploaded = await session.call_tool("upload_x_media", {"image_base64": base64.b64encode(png()).decode()})
            self.assertFalse(uploaded.isError)
            self.assertEqual(json.loads(uploaded.content[0].text), CONTRACTS["upload_result"])
            posted = await session.call_tool("create_x_post", {"text": "hello", "media_ids": ["123"], "reply_to": "456"})
            self.assertFalse(posted.isError)
            self.assertEqual(json.loads(posted.content[0].text), CONTRACTS["post_result"])

        await self.with_server(check, fixture=True, writes=True)
